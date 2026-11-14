# Reference: `Xitdb.Ash.Codec` & `Xitdb.Ash.Indexer`

> [!IMPORTANT]
> **Track Reference Metadata:**
> - **Associated Track:** [`ash_codec_and_indexer_20261111`](./index.md)
> - **Wave:** Wave 2 (`Track 11A`: Flat Codec & Indexer) / Wave 3 (`Track 11B`: `nested_in` Physical Subtrees)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Modules:** `lib/xitdb/ash/codec.ex`, `lib/xitdb/ash/indexer.ex`
> - **Purpose:** Complete specification and reference implementation for entity cursor encoding (`counted_set_fields`, `:utc_datetime` truncation, `:context` tenant scoping), order-preserving binary B+Tree keys, prefix-accurate composite range scans, single-commit operation staging (including BM25 `idx.search` token cleanup), and real-API `Xitdb` cursor/NIF storage adapters.

---

## 1. Concurrency, Encoding & Safety Invariants

### 1.1 Order-Preserving Binary B+Tree Keys
- **Signed 64-Bit Primitives (`encode_i64_be/1`):** 64-bit integers, `:utc_datetime` (truncated to `:second` on both dump and index key encoding), `:utc_datetime_usec` / `:datetime` / `:naive_datetime` (microseconds), `:date` (`Date.to_gregorian_days/1`), and `:time` / `:time_usec` (microseconds since midnight, with `:time` truncated to `:second`) all flip their two's-complement sign bit (`bxor(msb, 0x80)`) into fixed-width 8-byte big-endian binaries (`fixed_width_kind?/1 == true`).
- **Floats & `Decimal` Keys:** IEEE-754 floats normalize `-0.0` to `+0.0` and invert negative bit patterns. `encode_decimal_key/1` computes `raw_digits = Integer.digits(dec.coef)` and `exp10 = length(raw_digits) + dec.exp` *before* stripping trailing zeros (`60 == 60.0 == 60.000` -> `exp10 = 2, digits = [6]`), guards `coef == 0` (`<<0x80>>`), and converts floats via `Decimal.from_float/1`.
- **`:ci_string` & `counted_set_fields`:** `:ci_string` preserves casing in stored entity maps while lowercasing index keys and `encode_doc_id/1`. Array attributes declared in `Info.counted_set_fields(resource)` write `Xitdb.counted_set(items)` (`:counted_hash_set`) and hydrate back into Elixir lists.

### 1.2 Collision-Free Composite & Multitenant Keys
- **Tenant Isolation:** `Codec.scoped_collection(resource, tenant)` scopes `:context`-multitenant resources under `"t:#{encode_doc_id(tenant)}:#{collection}"`. `resolve_identity_tenant/4` evaluates `Map.get(record, tenant_attr) || tenant` so a `nil` struct key never masks an explicit `tenant`.
- **Identities & Composite Prefixes:** Unique identity keys (`idx.<scoped_col>.id_<name>`) prefix each component with a presence tag and 32-bit byte length (`<<len::unsigned-big-32, part::binary>>`) and honor `identity.nils_distinct?`. Composite secondary indexes escape interior `0x00` bytes (`<<0x00, 0xFF>>`) and terminate variable-width components with `<<0x00, 0x00>>`.
- **Hex-Encoded B+Tree Slot Keys:** `Indexer.Storage` encodes binary B+Tree keys with `Base.encode16(key, case: :lower)` when addressing `:sorted_map` slots. Lowercase hex is strictly ASCII `[0-9a-f]` (immune to selector metacharacters, null bytes, and invalid UTF-8) and strictly preserves unsigned byte lexicographical order (`a < b <=> hex(a) < hex(b)`).

### 1.3 Single-Commit Staging, Composite Range Bounds & Deduplicated Subtrees
- **Single-Commit Batching:** `Indexer.plan_put_ops/5` and `Indexer.plan_delete_ops/4` return pure `ops` lists combining entity cursor updates, `_parent` locators, unique identities, secondary `:sorted_map` B+Tree sets, and incremental BM25 `idx.search.<scoped_col>` posting diffs so `Mutator` commits once per mutation (`Xitdb.transact_ops(db, ops, base_moment: moment)`).
- **Partial Composite Range Bounds:** On composite indexes where `prefix_vals ++ [bound_val]` specifies `k < length(attrs)` columns, `:inclusive` upper bounds accept `key <= bound_key or binary_starts_with?(key, bound_key)` and `:exclusive` lower bounds require `key > bound_key and not binary_starts_with?(key, bound_key)`.
- **Deduplicated `_parent` Scans:** `Indexer.all_cursors/3` deduplicates `parent_doc_id` via `Stream.map(&elem(&1, 1)) |> Stream.uniq()` so parents with `K` children are scanned once (`O(K)`) rather than `K` times (`O(K^2)`).

---

## 2. Reference Implementation: `lib/xitdb/ash/codec.ex`

```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Codec do
    @moduledoc """
    Bidirectional `Ash.Type` cursor serialization, tenant-scoped collection naming, and
    order-preserving B+Tree binary key encoding for `Xitdb.Ash.DataLayer`.
    """

    alias Ash.Resource.Attribute
    alias Xitdb.Ash.Info

    @null_tag 0x00
    @value_tag 0x01
    @global_tenant_tag 0x00
    @scoped_tenant_tag 0x01

    # -- Collection Scoping & Entity Cursor Serialization --

    @doc """
    Returns the physical collection key for `(resource, tenant)`.
    Resources with `multitenancy_strategy(resource) == :context` and a non-nil `tenant`
    are isolated under `"t:<tenant>:<collection>"`.
    """
    @spec scoped_collection(module(), term()) :: String.t()
    def scoped_collection(resource, tenant \\ nil) when is_atom(resource) do
      base = resource |> Info.collection!() |> Atom.to_string()

      if Ash.Resource.Info.multitenancy_strategy(resource) == :context and not is_nil(tenant) do
        "t:" <> encode_doc_id(tenant) <> ":" <> base
      else
        base
      end
    end

    @doc """
    Encodes a `%Resource{}` struct (or attribute map) into a string-keyed map suitable
    for compiling into a Xitdb `:hash_map` cursor, wrapping `counted_set_fields` in
    `Xitdb.counted_set/1`.
    """
    @spec to_cursor_map(module(), struct() | map()) ::
            {:ok, %{String.t() => term()}} | {:error, term()}
    def to_cursor_map(resource, record) when is_atom(resource) and is_map(record) do
      counted_sets =
        if function_exported?(Info, :counted_set_fields, 1) do
          MapSet.new(apply(Info, :counted_set_fields, [resource]))
        else
          MapSet.new()
        end

      resource
      |> Ash.Resource.Info.attributes()
      |> Enum.reduce_while({:ok, %{}}, fn %Attribute{} = attr, {:ok, acc} ->
        value = Map.get(record, attr.name)
        as_counted_set? = MapSet.member?(counted_sets, attr.name)

        case dump_attribute_or_set(attr, value, as_counted_set?) do
          {:ok, nil} ->
            {:cont, {:ok, acc}}

          {:ok, dumped} ->
            {:cont, {:ok, Map.put(acc, Atom.to_string(attr.name), dumped)}}

          {:error, _reason} = err ->
            {:halt, err}
        end
      end)
    end

    @doc """
    Hydrates a Xitdb entity cursor back into a loaded `%Resource{}` struct.
    """
    @spec from_cursor(module(), term(), term()) :: {:ok, struct()} | {:error, term()}
    def from_cursor(resource, cursor, tenant \\ nil) when is_atom(resource) do
      attrs_result =
        resource
        |> Ash.Resource.Info.attributes()
        |> Enum.reduce_while({:ok, %{}}, fn %Attribute{} = attr, {:ok, acc} ->
          raw = fetch_cursor_field(cursor, Atom.to_string(attr.name))

          case load_attribute(attr, raw) do
            {:ok, loaded} ->
              {:cont, {:ok, Map.put(acc, attr.name, loaded)}}

            {:error, _reason} = err ->
              {:halt, err}
          end
        end)

      case attrs_result do
        {:ok, field_map} ->
          {:ok, build_loaded_struct(resource, field_map, tenant)}

        {:error, _reason} = err ->
          err
      end
    end

    @doc """
    Encodes a primary or foreign key value into its canonical Xitdb map slot string (`"42"`, UUID, etc.).
    """
    @spec encode_doc_id(term()) :: String.t()
    def encode_doc_id(id) when is_integer(id), do: Integer.to_string(id)
    def encode_doc_id(id) when is_binary(id), do: :binary.copy(id)

    def encode_doc_id(%Ash.CiString{} = ci) do
      ci |> Ash.CiString.value() |> String.downcase() |> :binary.copy()
    end

    def encode_doc_id(id) when is_atom(id) and not is_nil(id), do: Atom.to_string(id)
    def encode_doc_id(id), do: to_string(id)

    @doc """
    Encodes a primary key value using its attribute definition (normalizing `:ci_string` strings).
    """
    @spec encode_pk_doc_id(Attribute.t(), term()) :: String.t()
    def encode_pk_doc_id(%Attribute{} = attr, value) do
      case unwrap_type(attr.type, attr.constraints) do
        {:ci_string, _} when is_binary(value) -> value |> String.downcase() |> :binary.copy()
        _ -> encode_doc_id(value)
      end
    end

    @doc """
    Decodes a canonical string slot ID back into the resource's primary-key Elixir type.
    """
    @spec decode_doc_id(module(), String.t()) :: {:ok, term()} | {:error, term()}
    def decode_doc_id(resource, doc_id) when is_atom(resource) and is_binary(doc_id) do
      [pk_name | _] = Ash.Resource.Info.primary_key(resource)
      attr = Ash.Resource.Info.attribute(resource, pk_name)

      case unwrap_type(attr.type, attr.constraints) do
        {:integer, _} ->
          case Integer.parse(doc_id) do
            {int, ""} -> {:ok, int}
            _ -> {:error, {:invalid_integer_pk, doc_id}}
          end

        _other ->
          load_attribute(attr, doc_id)
      end
    end

    # -- B+Tree Secondary & Primary Locator Key Encoding --

    @doc """
    Encodes a single attribute value into a non-nullable B+Tree scalar key (used for `_parent`
    locators and range boundary construction).
    """
    @spec encode_scalar_key(Attribute.t(), term()) :: binary()
    def encode_scalar_key(%Attribute{} = attr, value) when not is_nil(value) do
      {kind, _constraints} = unwrap_type(attr.type, attr.constraints)
      encode_typed_scalar(kind, value)
    end

    @doc """
    Encodes one or more attribute values into an order-preserving, collision-free binary key
    for `:sorted_map` secondary indexes.
    """
    @spec encode_index_key([Attribute.t()], [term()]) :: binary()
    def encode_index_key([%Attribute{} = attr], [value]) do
      encode_single_component(attr, value)
    end

    def encode_index_key(attrs, values)
        when is_list(attrs) and is_list(values) and length(attrs) == length(values) do
      attrs
      |> Enum.zip(values)
      |> Enum.map(fn {%Attribute{} = attr, val} -> encode_composite_component(attr, val) end)
      |> IO.iodata_to_binary()
    end

    @doc """
    Encodes a leading subset of attributes for a composite secondary index prefix scan
    (for example, `status == :active` on `index [:status, :inserted_at]`).
    """
    @spec encode_index_prefix([Attribute.t()], [term()]) :: binary()
    def encode_index_prefix([%Attribute{} = attr], [value]) do
      encode_single_component(attr, value)
    end

    def encode_index_prefix(all_attrs, prefix_values)
        when is_list(all_attrs) and is_list(prefix_values) and
               length(prefix_values) <= length(all_attrs) do
      all_attrs
      |> Enum.take(length(prefix_values))
      |> Enum.zip(prefix_values)
      |> Enum.map(fn {%Attribute{} = attr, val} -> encode_composite_component(attr, val) end)
      |> IO.iodata_to_binary()
    end

    @doc """
    Encodes a length-prefixed, tenant-scoped unique identity key (`idx.<col>.id_<name>`).

    Returns `:skip` when `identity.nils_distinct?` is `true` (default) and any identity key
    value is `nil`, matching PostgreSQL `UNIQUE` null semantics.
    """
    @spec encode_identity_key(module(), Ash.Resource.Identity.t(), map(), term()) ::
            {:ok, binary()} | :skip
    def encode_identity_key(resource, identity, record_or_map, tenant \\ nil)
        when is_atom(resource) and is_map(record_or_map) do
      nils_distinct? = Map.get(identity, :nils_distinct?, true)
      all_tenants? = Map.get(identity, :all_tenants?, false)
      values = Enum.map(identity.keys, &Map.get(record_or_map, &1))

      if nils_distinct? and Enum.any?(values, &is_nil/1) do
        :skip
      else
        effective_tenant =
          resolve_identity_tenant(resource, all_tenants?, record_or_map, tenant)

        tenant_prefix = encode_tenant_prefix(effective_tenant)

        parts =
          identity.keys
          |> Enum.zip(values)
          |> Enum.map(fn {field, val} ->
            attr = Ash.Resource.Info.attribute(resource, field)
            encode_length_prefixed_part(attr, val)
          end)

        {:ok, IO.iodata_to_binary([tenant_prefix | parts])}
      end
    end

    # -- Low-Level Order-Preserving Primitive Codecs (Public for Property Testing) --

    @doc """
    Encodes a signed 64-bit integer into an 8-byte sign-flipped big-endian binary
    preserving `<, <=, ==, >=, >` under unsigned byte comparison.
    """
    @spec encode_i64_be(integer()) :: <<_::64>>
    def encode_i64_be(val)
        when is_integer(val) and val >= -9_223_372_036_854_775_808 and
               val <= 9_223_372_036_854_775_807 do
      <<msb::unsigned-8, rest::binary-size(7)>> = <<val::signed-big-64>>
      <<Bitwise.bxor(msb, 0x80)::unsigned-8, rest::binary>>
    end

    @doc """
    Decodes an 8-byte sign-flipped big-endian binary back into a signed 64-bit integer.
    """
    @spec decode_i64_be(<<_::64>>) :: integer()
    def decode_i64_be(<<msb::unsigned-8, rest::binary-size(7)>>) do
      <<val::signed-big-64>> = <<Bitwise.bxor(msb, 0x80)::unsigned-8, rest::binary>>
      val
    end

    @doc """
    Encodes an IEEE-754 float into an 8-byte order-preserving binary (`-0.0` normalized to `+0.0`).
    """
    @spec encode_f64_be(float()) :: <<_::64>>
    def encode_f64_be(val) when is_float(val) do
      normalized = if val == 0.0, do: +0.0, else: val
      <<b0::8, b1::8, b2::8, b3::8, b4::8, b5::8, b6::8, b7::8>> = <<normalized::float-big-64>>

      if Bitwise.band(b0, 0x80) == 0 do
        <<Bitwise.bxor(b0, 0x80)::8, b1::8, b2::8, b3::8, b4::8, b5::8, b6::8, b7::8>>
      else
        <<
          Bitwise.bxor(b0, 0xFF)::8,
          Bitwise.bxor(b1, 0xFF)::8,
          Bitwise.bxor(b2, 0xFF)::8,
          Bitwise.bxor(b3, 0xFF)::8,
          Bitwise.bxor(b4, 0xFF)::8,
          Bitwise.bxor(b5, 0xFF)::8,
          Bitwise.bxor(b6, 0xFF)::8,
          Bitwise.bxor(b7, 0xFF)::8
        >>
      end
    end

    @doc """
    Encodes a `Decimal` into a canonical, scale-normalized (`60 == 60.0 == 60.000`)
    order-preserving binary. Computes `exp10 = length(raw_digits) + dec.exp` *before*
    stripping trailing zeros so integer multiples of 10 retain their true magnitude.
    """
    @spec encode_decimal_key(Decimal.t()) :: binary()
    def encode_decimal_key(%Decimal{coef: coef}) when coef in [:NaN, :inf] do
      raise ArgumentError, "cannot index non-finite Decimal #{inspect(coef)} in Xitdb B+Tree"
    end

    def encode_decimal_key(%Decimal{coef: 0}), do: <<0x80>>

    def encode_decimal_key(%Decimal{} = dec) do
      if Decimal.eq?(dec, 0) do
        <<0x80>>
      else
        raw_digits = Integer.digits(dec.coef)
        exp10 = length(raw_digits) + dec.exp
        digits = strip_trailing_zeros(raw_digits)

        case dec.sign do
          1 ->
            exp_bin = encode_i64_be(exp10)
            mantissa = for d <- digits, into: <<>>, do: <<d + 1::unsigned-8>>
            <<0xC0, exp_bin::binary, mantissa::binary, 0x00>>

          -1 ->
            exp_bin = invert_bytes(encode_i64_be(exp10))
            mantissa = for d <- digits, into: <<>>, do: <<10 - d::unsigned-8>>
            <<0x40, exp_bin::binary, mantissa::binary, 0xFF>>
        end
      end
    end

    @doc """
    Decodes a length-prefixed binary part `<<tag::8, ...>>`, returning `{value_or_nil, rest}`.
    """
    @spec decode_length_prefixed_part(binary()) ::
            {:nil_part, binary()} | {{:bytes, binary()}, binary()}
    def decode_length_prefixed_part(<<@null_tag, rest::binary>>), do: {:nil_part, rest}

    def decode_length_prefixed_part(
          <<@value_tag, len::unsigned-big-32, part::binary-size(len), rest::binary>>
        ) do
      {{:bytes, part}, rest}
    end

    # -- Attribute Dump / Load Internals --

    defp dump_attribute_or_set(_attr, nil, _as_counted_set?), do: {:ok, nil}

    defp dump_attribute_or_set(%Attribute{} = attr, values, true) when is_list(values) do
      case dump_attribute(attr, values) do
        {:ok, dumped_list} when is_list(dumped_list) -> {:ok, Xitdb.counted_set(dumped_list)}
        {:ok, other} -> {:ok, other}
        {:error, _} = err -> err
      end
    end

    defp dump_attribute_or_set(attr, value, _as_counted_set?), do: dump_attribute(attr, value)

    defp dump_attribute(_attr, nil), do: {:ok, nil}

    defp dump_attribute(%Attribute{} = attr, value) do
      {kind, constraints} = unwrap_type(attr.type, attr.constraints)

      case kind do
        :integer when is_integer(value) ->
          {:ok, value}

        :string when is_binary(value) ->
          {:ok, :binary.copy(value)}

        :ci_string ->
          str =
            case value do
              %Ash.CiString{} = ci -> Ash.CiString.value(ci)
              bin when is_binary(bin) -> bin
            end

          {:ok, :binary.copy(str)}

        :boolean when is_boolean(value) ->
          {:ok, value}

        :float when is_float(value) ->
          {:ok, value}

        :float when is_integer(value) ->
          {:ok, value * 1.0}

        :decimal ->
          dec = coerce_decimal(value)
          {:ok, Decimal.to_string(dec, :normal)}

        :atom when is_atom(value) ->
          {:ok, Atom.to_string(value)}

        :utc_datetime ->
          %DateTime{} = dt = value
          {:ok, dt |> DateTime.truncate(:second) |> DateTime.to_unix(:microsecond)}

        kind when kind in [:utc_datetime_usec, :datetime] ->
          %DateTime{} = dt = value
          {:ok, DateTime.to_unix(dt, :microsecond)}

        :naive_datetime ->
          %NaiveDateTime{} = ndt = value
          {:ok, ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)}

        :date ->
          %Date{} = d = value
          {:ok, Date.to_iso8601(d)}

        :time ->
          %Time{} = t = value
          {:ok, t |> Time.truncate(:second) |> Time.to_iso8601()}

        :time_usec ->
          %Time{} = t = value
          {:ok, Time.to_iso8601(t)}

        :uuid when is_binary(value) ->
          {:ok, :binary.copy(value)}

        {:array, inner_type} when is_list(value) ->
          item_constraints = Keyword.get(constraints || [], :items, [])
          elem_attr = %Attribute{attr | type: inner_type, constraints: item_constraints}

          value
          |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
            case dump_attribute(elem_attr, item) do
              {:ok, dumped_item} -> {:cont, {:ok, [dumped_item | acc]}}
              {:error, _} = err -> {:halt, err}
            end
          end)
          |> case do
            {:ok, dumped_rev} -> {:ok, Enum.reverse(dumped_rev)}
            {:error, _} = err -> err
          end

        _complex ->
          Ash.Type.dump_to_embedded(attr.type, value, constraints)
      end
    end

    defp load_attribute(_attr, nil), do: {:ok, nil}

    defp load_attribute(%Attribute{} = attr, raw) do
      {kind, constraints} = unwrap_type(attr.type, attr.constraints)

      case kind do
        :integer when is_integer(raw) ->
          {:ok, raw}

        :string when is_binary(raw) ->
          {:ok, :binary.copy(raw)}

        :ci_string when is_binary(raw) ->
          {:ok, Ash.CiString.new(:binary.copy(raw))}

        :boolean when is_boolean(raw) ->
          {:ok, raw}

        :float when is_number(raw) ->
          {:ok, raw * 1.0}

        :decimal when is_binary(raw) ->
          {:ok, Decimal.new(raw)}

        :utc_datetime when is_integer(raw) ->
          {:ok, raw |> DateTime.from_unix!(:microsecond) |> DateTime.truncate(:second)}

        :utc_datetime_usec when is_integer(raw) ->
          {:ok, DateTime.from_unix!(raw, :microsecond)}

        :datetime when is_integer(raw) ->
          {:ok, DateTime.from_unix!(raw, :microsecond)}

        :naive_datetime when is_integer(raw) ->
          {:ok, raw |> DateTime.from_unix!(:microsecond) |> DateTime.to_naive()}

        :date when is_binary(raw) ->
          {:ok, Date.from_iso8601!(raw)}

        :time when is_binary(raw) ->
          {:ok, raw |> Time.from_iso8601!() |> Time.truncate(:second)}

        :time_usec when is_binary(raw) ->
          {:ok, Time.from_iso8601!(raw)}

        :uuid when is_binary(raw) ->
          {:ok, :binary.copy(raw)}

        {:array, inner_type} ->
          item_constraints = Keyword.get(constraints || [], :items, [])
          elem_attr = %Attribute{attr | type: inner_type, constraints: item_constraints}
          items = materialize_cursor_term(raw)

          if is_list(items) do
            items
            |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
              case load_attribute(elem_attr, item) do
                {:ok, loaded_item} -> {:cont, {:ok, [loaded_item | acc]}}
                {:error, _} = err -> {:halt, err}
              end
            end)
            |> case do
              {:ok, loaded_rev} -> {:ok, Enum.reverse(loaded_rev)}
              {:error, _} = err -> err
            end
          else
            Ash.Type.cast_stored(attr.type, items, attr.constraints)
          end

        _other ->
          materialized = materialize_cursor_term(raw)
          Ash.Type.cast_stored(attr.type, materialized, attr.constraints)
      end
    end

    defp build_loaded_struct(resource, field_map, tenant) do
      record = struct(resource, field_map)

      record =
        if Map.has_key?(record, :__meta__) and Code.ensure_loaded?(Ecto) do
          Ecto.put_meta(record, state: :loaded)
        else
          record
        end

      if tenant != nil do
        Ash.Resource.put_metadata(record, :tenant, tenant)
      else
        record
      end
    end

    # -- B+Tree Key Encoding Helpers --

    defp encode_single_component(_attr, nil), do: <<@null_tag>>

    defp encode_single_component(%Attribute{} = attr, value) do
      <<@value_tag, encode_scalar_key(attr, value)::binary>>
    end

    defp encode_composite_component(_attr, nil), do: <<@null_tag>>

    defp encode_composite_component(%Attribute{} = attr, value) do
      {kind, _constraints} = unwrap_type(attr.type, attr.constraints)
      scalar = encode_typed_scalar(kind, value)

      if fixed_width_kind?(kind) do
        <<@value_tag, scalar::binary>>
      else
        <<@value_tag, escape_null_terminated(scalar)::binary>>
      end
    end

    defp encode_length_prefixed_part(_attr, nil), do: <<@null_tag>>

    defp encode_length_prefixed_part(%Attribute{} = attr, value) do
      scalar = encode_scalar_key(attr, value)
      <<@value_tag, byte_size(scalar)::unsigned-big-32, scalar::binary>>
    end

    defp encode_typed_scalar(:integer, val) when is_integer(val), do: encode_i64_be(val)
    defp encode_typed_scalar(:boolean, false), do: <<0x00>>
    defp encode_typed_scalar(:boolean, true), do: <<0x01>>
    defp encode_typed_scalar(:float, val) when is_number(val), do: encode_f64_be(val * 1.0)

    defp encode_typed_scalar(:decimal, val), do: val |> coerce_decimal() |> encode_decimal_key()

    defp encode_typed_scalar(:utc_datetime, %DateTime{} = dt) do
      dt |> DateTime.truncate(:second) |> DateTime.to_unix(:microsecond) |> encode_i64_be()
    end

    defp encode_typed_scalar(kind, %DateTime{} = dt)
         when kind in [:utc_datetime_usec, :datetime] do
      dt |> DateTime.to_unix(:microsecond) |> encode_i64_be()
    end

    defp encode_typed_scalar(:naive_datetime, %NaiveDateTime{} = ndt) do
      ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond) |> encode_i64_be()
    end

    defp encode_typed_scalar(:date, %Date{} = d) do
      d |> Date.to_gregorian_days() |> encode_i64_be()
    end

    defp encode_typed_scalar(:time, %Time{} = t) do
      {sec, _usec} = Time.to_seconds_after_midnight(t)
      encode_i64_be(sec * 1_000_000)
    end

    defp encode_typed_scalar(:time_usec, %Time{} = t) do
      {sec, usec} = Time.to_seconds_after_midnight(t)
      encode_i64_be(sec * 1_000_000 + usec)
    end

    defp encode_typed_scalar(:ci_string, %Ash.CiString{} = ci) do
      ci |> Ash.CiString.value() |> String.downcase()
    end

    defp encode_typed_scalar(:ci_string, val) when is_binary(val), do: String.downcase(val)
    defp encode_typed_scalar(:string, val) when is_binary(val), do: val
    defp encode_typed_scalar(:uuid, val) when is_binary(val), do: String.downcase(val)
    defp encode_typed_scalar(:atom, val) when is_atom(val), do: Atom.to_string(val)
    defp encode_typed_scalar(:atom, val) when is_binary(val), do: val

    defp encode_typed_scalar(_other, val) do
      :erlang.term_to_binary(val, [:deterministic])
    end

    defp coerce_decimal(%Decimal{} = dec), do: dec
    defp coerce_decimal(val) when is_float(val), do: Decimal.from_float(val)
    defp coerce_decimal(val), do: Decimal.new(val)

    defp fixed_width_kind?(kind) do
      kind in [
        :integer,
        :boolean,
        :float,
        :utc_datetime,
        :utc_datetime_usec,
        :datetime,
        :naive_datetime,
        :date,
        :time,
        :time_usec
      ]
    end

    defp escape_null_terminated(bin) when is_binary(bin) do
      escaped = :binary.replace(bin, <<0x00>>, <<0x00, 0xFF>>, [:global])
      <<escaped::binary, 0x00, 0x00>>
    end

    defp resolve_identity_tenant(_resource, true, _record, _tenant), do: nil

    defp resolve_identity_tenant(resource, false, record, tenant) do
      case Ash.Resource.Info.multitenancy_strategy(resource) do
        :attribute ->
          tenant_attr = Ash.Resource.Info.multitenancy_attribute(resource)
          Map.get(record, tenant_attr) || tenant

        :context ->
          tenant

        nil ->
          nil
      end
    end

    defp encode_tenant_prefix(nil), do: <<@global_tenant_tag>>

    defp encode_tenant_prefix(tenant) do
      bin = encode_doc_id(tenant)
      <<@scoped_tenant_tag, byte_size(bin)::unsigned-big-32, bin::binary>>
    end

    defp unwrap_type({:array, _} = array_type, constraints), do: {array_type, constraints}

    defp unwrap_type(type, constraints) when is_atom(type) do
      resolved = Ash.Type.get_type(type)

      if Ash.Type.NewType.new_type?(resolved) do
        sub = Ash.Type.NewType.subtype_of(resolved)
        sub_constraints = Ash.Type.NewType.constraints(resolved, constraints)
        unwrap_type(sub, sub_constraints)
      else
        {canonical_kind(resolved), constraints}
      end
    end

    defp canonical_kind(Ash.Type.Integer), do: :integer
    defp canonical_kind(Ash.Type.String), do: :string
    defp canonical_kind(Ash.Type.CiString), do: :ci_string
    defp canonical_kind(Ash.Type.Boolean), do: :boolean
    defp canonical_kind(Ash.Type.Float), do: :float
    defp canonical_kind(Ash.Type.Decimal), do: :decimal
    defp canonical_kind(Ash.Type.Atom), do: :atom
    defp canonical_kind(Ash.Type.UtcDatetime), do: :utc_datetime
    defp canonical_kind(Ash.Type.UtcDatetimeUsec), do: :utc_datetime_usec
    defp canonical_kind(Ash.Type.DateTime), do: :datetime
    defp canonical_kind(Ash.Type.NaiveDateTime), do: :naive_datetime
    defp canonical_kind(Ash.Type.Date), do: :date
    defp canonical_kind(Ash.Type.Time), do: :time
    defp canonical_kind(Ash.Type.TimeUsec), do: :time_usec
    defp canonical_kind(Ash.Type.UUID), do: :uuid
    defp canonical_kind(Ash.Type.UUIDv7), do: :uuid
    defp canonical_kind(other), do: other

    defp fetch_cursor_field(cursor, key) when is_map(cursor) and not is_struct(cursor) do
      Map.get(cursor, key)
    end

    defp fetch_cursor_field(cursor, key), do: cursor[key]

    defp materialize_cursor_term(val)
         when is_binary(val) or is_number(val) or is_boolean(val) or is_nil(val) do
      val
    end

    defp materialize_cursor_term(val) when is_list(val) do
      Enum.map(val, &materialize_cursor_term/1)
    end

    defp materialize_cursor_term(%MapSet{} = set) do
      set |> Enum.to_list() |> Enum.map(&materialize_cursor_term/1)
    end

    defp materialize_cursor_term(%Xitdb.Collection{kind: kind, data: data})
         when kind in [:hash_set, :counted_hash_set, :sorted_set] do
      data |> Enum.to_list() |> Enum.map(&materialize_cursor_term/1)
    end

    defp materialize_cursor_term(%Xitdb.Cursor{tag: tag} = cursor)
         when tag in [:hash_set, :counted_hash_set, :sorted_set] do
      cursor |> Enum.to_list() |> Enum.map(&materialize_cursor_term/1)
    end

    defp materialize_cursor_term(val) when is_map(val) and not is_struct(val) do
      Map.new(val, fn {k, v} -> {k, materialize_cursor_term(v)} end)
    end

    defp materialize_cursor_term(cursor) do
      case Enumerable.impl_for(cursor) do
        nil ->
          cursor

        _impl ->
          items = Enum.to_list(cursor)

          if match?([{_, _} | _], items) do
            Map.new(items, fn {k, v} -> {to_string(k), materialize_cursor_term(v)} end)
          else
            Enum.map(items, &materialize_cursor_term/1)
          end
      end
    end

    defp strip_trailing_zeros([0]), do: [0]

    defp strip_trailing_zeros(digits) do
      digits
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == 0))
      |> Enum.reverse()
    end

    defp invert_bytes(bin) do
      for <<b::unsigned-8 <- bin>>, into: <<>>, do: <<Bitwise.bxor(b, 0xFF)::unsigned-8>>
    end
  end
end
```

---

## 3. Reference Implementation: `lib/xitdb/ash/indexer.ex`

```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Indexer do
    @moduledoc """
    Maintains and queries entity cursors, `_parent` subtree locators, unique `identities`
    (with partial `where` filters), secondary `:sorted_map` B+Tree indexes, transactional
    BM25 `idx.search` postings, and recursive nested-subtree cleanup for `Xitdb.Ash.DataLayer`.
    """

    alias Ash.Error.Changes.InvalidChanges
    alias Xitdb.Ash.{Codec, Info, Search, Store}
    alias Xitdb.Ash.Indexer.Storage

    @parent_slot "_parent"
    @search_weight_scale 100

    @type bound :: {:inclusive | :exclusive, term()} | :unbounded
    @type range_spec :: %{
            optional(:prefix) => [term()],
            optional(:min) => bound(),
            optional(:max) => bound()
          }

    # -- Single-Commit Operation Staging & Transactional Write Helpers --

    @type batch_state :: map()

    @doc """
    Plans all low-level `Xitdb.transact_ops/3` tuples for writing `new_record` (and diffing
    `old_record` on update) across entity cursors, `_parent` locators, unique `identities`,
    secondary `:sorted_map` B+Trees, and BM25 `idx.search` postings—without committing yet.
    """
    @spec plan_put_ops(term(), module(), struct() | nil, struct(), term()) ::
            {:ok, [tuple()]} | {:error, Exception.t()}
    def plan_put_ops(db_or_cursor, resource, old_record, %_{} = new_record, tenant \\ nil)
        when is_atom(resource) do
      case plan_put_ops_batched(db_or_cursor, resource, old_record, new_record, tenant, %{}) do
        {:ok, ops, _batch_state} -> {:ok, ops}
        {:error, _} = err -> err
      end
    end

    @doc """
    Batch-aware variant of `plan_put_ops/5` that threads `batch_state` across multi-row
    `bulk_create` streams so BM25 `doc_count`/`total_len` and secondary set memberships
    accumulate accurately against a single pre-batch `cursor_root`.
    """
    @spec plan_put_ops_batched(
            term(),
            module(),
            struct() | nil,
            struct(),
            term(),
            batch_state()
          ) :: {:ok, [tuple()], batch_state()} | {:error, Exception.t()}
    def plan_put_ops_batched(
          db_or_cursor,
          resource,
          old_record,
          %_{} = new_record,
          tenant,
          batch_state
        )
        when is_atom(resource) and is_map(batch_state) do
      collection = Codec.scoped_collection(resource, tenant)

      with {:ok, cursor_map} <- Codec.to_cursor_map(resource, new_record),
           {:ok, identity_ops} <-
             plan_identity_ops(db_or_cursor, resource, old_record, new_record, tenant),
           {:ok, locator_plan} <-
             plan_entity_location(db_or_cursor, resource, old_record, new_record, tenant) do
        secondary_ops = plan_secondary_ops(resource, old_record, new_record)

        {entity_and_idx_ops, batch_after_idx} =
          Storage.compile_put_ops(
            db_or_cursor,
            collection,
            cursor_map,
            locator_plan,
            identity_ops,
            secondary_ops,
            batch_state
          )

        {search_ops, batch_after_search} =
          plan_search_ops(db_or_cursor, resource, collection, new_record, nil, batch_after_idx)

        {:ok, entity_and_idx_ops ++ search_ops, batch_after_search}
      end
    end

    @doc """
    Plans all low-level `Xitdb.transact_ops/3` tuples for deleting `record`, including recursive
    cleanup of nested children's `_parent`, unique, secondary, and BM25 search indexes.
    """
    @spec plan_delete_ops(term(), module(), struct(), term()) :: {:ok, [tuple()]}
    def plan_delete_ops(db_or_cursor, resource, %_{} = record, tenant \\ nil)
        when is_atom(resource) do
      {:ok, ops, _batch_state} =
        plan_delete_ops_batched(db_or_cursor, resource, record, tenant, %{})

      {:ok, ops}
    end

    @spec plan_delete_ops_batched(term(), module(), struct(), term(), batch_state()) ::
            {:ok, [tuple()], batch_state()}
    def plan_delete_ops_batched(db_or_cursor, resource, %_{} = record, tenant, batch_state)
        when is_atom(resource) and is_map(batch_state) do
      collection = Codec.scoped_collection(resource, tenant)
      pk_attr = pk_attribute(resource)
      pk_val = Map.fetch!(record, pk_attr.name)
      doc_id = Codec.encode_pk_doc_id(pk_attr, pk_val)

      {child_ops, batch_after_children} =
        plan_purge_nested_children_ops(db_or_cursor, resource, pk_val, tenant, batch_state)

      {:ok, identity_ops} = plan_identity_ops(db_or_cursor, resource, record, nil, tenant)
      secondary_ops = plan_secondary_ops(resource, record, nil)
      delete_location = build_delete_location(resource, record, pk_attr, pk_val, doc_id, tenant)

      {own_delete_ops, batch_after_idx} =
        Storage.compile_delete_ops(
          db_or_cursor,
          collection,
          delete_location,
          identity_ops,
          secondary_ops,
          batch_after_children
        )

      {search_ops, batch_after_search} =
        plan_search_ops(db_or_cursor, resource, collection, nil, doc_id, batch_after_idx)

      {:ok, child_ops ++ own_delete_ops ++ search_ops, batch_after_search}
    end

    @doc """
    Commits `new_record` (and diffs `old_record` when updating) in a single atomic
    `Xitdb.transact_ops/3` commit on `{db, moment}` (or `%Xitdb{}`).
    """
    @spec put_record(
            {Xitdb.t(), non_neg_integer()} | Xitdb.t(),
            module(),
            struct() | nil,
            struct(),
            term()
          ) :: {:ok, {Xitdb.t(), non_neg_integer()} | Xitdb.t()} | {:error, Exception.t()}
    def put_record(snapshot_or_db, resource, old_record, new_record, tenant \\ nil)

    def put_record({%Xitdb{} = db, moment}, resource, old_record, %_{} = new_record, tenant)
        when is_atom(resource) and is_integer(moment) do
      cursor_root = Xitdb.as_of(db, moment)

      with {:ok, ops} <- plan_put_ops(cursor_root, resource, old_record, new_record, tenant),
           {:ok, next_db} <- Xitdb.transact_ops(db, ops, base_moment: moment) do
        {:ok, {next_db, Xitdb.moment_count(next_db) - 1}}
      end
    end

    def put_record(%Xitdb{} = db, resource, old_record, %_{} = new_record, tenant)
        when is_atom(resource) do
      with {:ok, ops} <- plan_put_ops(db, resource, old_record, new_record, tenant),
           {:ok, next_db} <- Xitdb.transact_ops(db, ops) do
        {:ok, next_db}
      end
    end

    @doc """
    Deletes `record` and all of its secondary, identity, search, and nested-child indexes in a
    single atomic `Xitdb.transact_ops/3` commit.
    """
    @spec delete_record(
            {Xitdb.t(), non_neg_integer()} | Xitdb.t(),
            module(),
            struct(),
            term()
          ) :: {:ok, {Xitdb.t(), non_neg_integer()} | Xitdb.t()}
    def delete_record(snapshot_or_db, resource, record, tenant \\ nil)

    def delete_record({%Xitdb{} = db, moment}, resource, %_{} = record, tenant)
        when is_atom(resource) and is_integer(moment) do
      cursor_root = Xitdb.as_of(db, moment)
      {:ok, ops} = plan_delete_ops(cursor_root, resource, record, tenant)
      {:ok, next_db} = Xitdb.transact_ops(db, ops, base_moment: moment)
      {:ok, {next_db, Xitdb.moment_count(next_db) - 1}}
    end

    def delete_record(%Xitdb{} = db, resource, %_{} = record, tenant) when is_atom(resource) do
      {:ok, ops} = plan_delete_ops(db, resource, record, tenant)
      {:ok, next_db} = Xitdb.transact_ops(db, ops)
      {:ok, next_db}
    end

    # -- Point, Subtree, Identity & B+Tree Read Operations --

    @doc """
    Fetches a single raw entity cursor by primary key in `O(1)` for top-level collections
    or `O(log N)` via `idx.<col>._parent` for `nested_in` resources.
    """
    @spec fetch_cursor(term(), module(), term(), term()) :: {:ok, term()} | :none
    def fetch_cursor(db_or_cursor, resource, pk_value, tenant \\ nil)
    def fetch_cursor(_db_or_cursor, _resource, nil, _tenant), do: :none

    def fetch_cursor(db_or_cursor, resource, pk_value, tenant) when is_atom(resource) do
      collection = Codec.scoped_collection(resource, tenant)
      pk_attr = pk_attribute(resource)
      doc_id = Codec.encode_pk_doc_id(pk_attr, pk_value)

      case resolve_nested_spec(resource) do
        nil ->
          Storage.fetch_top_level_cursor(db_or_cursor, collection, doc_id)

        nested ->
          pk_key = Codec.encode_scalar_key(pk_attr, pk_value)
          parent_col_str = resolve_parent_collection(nested, tenant, resource)

          with {:ok, parent_doc_id} <-
                 Storage.lookup_unique(db_or_cursor, collection, @parent_slot, pk_key),
               {:ok, cursor} <-
                 Storage.fetch_nested_cursor(
                   db_or_cursor,
                   parent_col_str,
                   parent_doc_id,
                   nested.path,
                   nested.cardinality,
                   doc_id
                 ),
               true <- cursor_matches_doc_id?(cursor, pk_attr, doc_id) do
            {:ok, cursor}
          else
            _ -> :none
          end
      end
    end

    @doc """
    Returns all `{doc_id, cursor}` pairs for a top-level collection or across deduplicated
    `_parent` entries of a `nested_in` collection.
    """
    @spec all_cursors(term(), module(), term()) :: [{String.t(), term()}]
    def all_cursors(db_or_cursor, resource, tenant \\ nil) when is_atom(resource) do
      collection = Codec.scoped_collection(resource, tenant)
      pk_attr = pk_attribute(resource)

      case resolve_nested_spec(resource) do
        nil ->
          Storage.list_top_level_cursors(db_or_cursor, collection)

        nested ->
          parent_col_str = resolve_parent_collection(nested, tenant, resource)

          db_or_cursor
          |> Storage.list_unique_entries(collection, @parent_slot)
          |> Stream.map(&elem(&1, 1))
          |> Stream.uniq()
          |> Enum.flat_map(fn parent_doc_id ->
            Storage.list_nested_cursors_for_parent(
              db_or_cursor,
              parent_col_str,
              parent_doc_id,
              nested.path,
              nested.cardinality,
              pk_attr
            )
          end)
      end
    end

    @doc """
    Jumps directly to `root[parent_col][parent_id][path]` in `O(1)` when filtering a
    `nested_in` resource by its parent foreign key (`event_id == ^eid`).
    """
    @spec nested_cursors_for_parent(term(), module(), term(), term()) :: [{String.t(), term()}]
    def nested_cursors_for_parent(db_or_cursor, resource, parent_id, tenant \\ nil)
        when is_atom(resource) do
      nested = resolve_nested_spec!(resource)
      pk_attr = pk_attribute(resource)
      parent_col_str = resolve_parent_collection(nested, tenant, resource)

      Storage.list_nested_cursors_for_parent(
        db_or_cursor,
        parent_col_str,
        Codec.encode_doc_id(parent_id),
        nested.path,
        nested.cardinality,
        pk_attr
      )
    end

    @doc """
    Resolves an existing entity's canonical `doc_id` string by `Ash.Resource.Identity` in `O(log N)`.
    """
    @spec lookup_by_identity(term(), module(), Ash.Resource.Identity.t(), map(), term()) ::
            {:ok, String.t()} | :none
    def lookup_by_identity(db_or_cursor, resource, identity, key_map, tenant \\ nil)
        when is_atom(resource) and is_map(key_map) do
      case Codec.encode_identity_key(resource, identity, key_map, tenant) do
        :skip ->
          :none

        {:ok, encoded_key} ->
          collection = Codec.scoped_collection(resource, tenant)
          Storage.lookup_unique(db_or_cursor, collection, identity_slot_name(identity.name), encoded_key)
      end
    end

    @doc """
    Returns the `MapSet` of matching `doc_id` strings for an exact secondary index match in `O(log N)`.
    """
    @spec lookup_secondary_eq(term(), module(), map(), [term()], term()) :: MapSet.t(String.t())
    def lookup_secondary_eq(db_or_cursor, resource, %{fields: fields} = index_spec, values, tenant \\ nil)
        when is_atom(resource) and is_list(values) do
      collection = Codec.scoped_collection(resource, tenant)
      attrs = Enum.map(fields, &Ash.Resource.Info.attribute(resource, &1))
      encoded_key = Codec.encode_index_key(attrs, values)
      slot = index_slot_name(index_spec)

      db_or_cursor
      |> Storage.lookup_set(collection, slot, encoded_key)
      |> MapSet.new()
    end

    @doc """
    Returns the `O(log N)` cardinality of matching child records for `:restrict` FK checks
    and indexed count shortcuts without materializing structs.
    """
    @spec count_by_attribute(term(), module(), atom(), term(), term()) :: non_neg_integer()
    def count_by_attribute(db_or_cursor, resource, field, value, tenant \\ nil)
        when is_atom(resource) and is_atom(field) do
      collection = Codec.scoped_collection(resource, tenant)
      attr = Ash.Resource.Info.attribute(resource, field)
      encoded_key = Codec.encode_index_key([attr], [value])
      Storage.count_set(db_or_cursor, collection, "attr_#{field}", encoded_key)
    end

    @doc """
    Scans a `:sorted_map` secondary index over `[min, max]` bounds (optionally scoped to a
    composite `prefix` tuple) and returns the union `MapSet` of `doc_id` strings.
    """
    @spec scan_secondary_range(term(), module(), map(), range_spec(), term()) ::
            MapSet.t(String.t())
    def scan_secondary_range(
          db_or_cursor,
          resource,
          %{fields: fields} = index_spec,
          range_spec,
          tenant \\ nil
        )
        when is_atom(resource) and is_map(range_spec) do
      collection = Codec.scoped_collection(resource, tenant)
      attrs = Enum.map(fields, &Ash.Resource.Info.attribute(resource, &1))
      prefix_vals = Map.get(range_spec, :prefix, [])
      range_attr = Enum.at(attrs, length(prefix_vals))

      prefix_bin =
        if prefix_vals == [] do
          <<>>
        else
          Codec.encode_index_prefix(attrs, prefix_vals)
        end

      min_spec = Map.get(range_spec, :min, :unbounded)
      max_spec = Map.get(range_spec, :max, :unbounded)
      has_range_bound? = min_spec != :unbounded or max_spec != :unbounded

      {start_key, min_pred} =
        build_lower_bound(
          attrs,
          prefix_vals,
          prefix_bin,
          range_attr,
          min_spec,
          has_range_bound?
        )

      max_pred =
        build_upper_bound(
          attrs,
          prefix_vals,
          prefix_bin,
          range_attr,
          max_spec
        )

      db_or_cursor
      |> Storage.stream_index_from(collection, index_slot_name(index_spec), start_key)
      |> Stream.take_while(fn {key, _ids} ->
        binary_starts_with?(key, prefix_bin) and max_pred.(key)
      end)
      |> Enum.reduce(MapSet.new(), fn {key, ids}, acc ->
        if (has_range_bound? and not non_null_at_offset?(key, byte_size(prefix_bin))) or
             not min_pred.(key) do
          acc
        else
          Enum.reduce(ids, acc, &MapSet.put(&2, &1))
        end
      end)
    end

    @doc """
    Returns the canonical slot name under `idx.<collection>` for a `%Xitdb.Ash.Index{}`.
    """
    @spec index_slot_name(map()) :: String.t()
    def index_slot_name(%{name: name}) when is_atom(name) and not is_nil(name) do
      Atom.to_string(name)
    end

    def index_slot_name(%{name: name}) when is_binary(name) and name != "", do: name
    def index_slot_name(%{fields: [single_field]}), do: "attr_#{single_field}"

    def index_slot_name(%{fields: fields}) when is_list(fields) do
      "idx_" <> Enum.map_join(fields, "_", &Atom.to_string/1)
    end

    @doc """
    Returns the canonical slot name under `idx.<collection>` for an `Ash.Resource.Identity`.
    """
    @spec identity_slot_name(atom()) :: String.t()
    def identity_slot_name(name) when is_atom(name), do: "id_#{name}"

    # -- Internal Planning, Search Diffing & Nesting Helpers --

    defp plan_entity_location(db_or_cursor, resource, old_record, new_record, tenant) do
      pk_attr = pk_attribute(resource)
      pk_val = Map.fetch!(new_record, pk_attr.name)
      doc_id = Codec.encode_pk_doc_id(pk_attr, pk_val)

      case resolve_nested_spec(resource) do
        nil ->
          {:ok, {:top_level, doc_id}}

        nested ->
          fk_attr = nested.foreign_key
          new_parent_val = Map.get(new_record, fk_attr)

          if is_nil(new_parent_val) do
            {:error,
             InvalidChanges.exception(
               fields: [fk_attr],
               message: "is required for nested Xitdb resource"
             )}
          else
            parent_col_str = resolve_parent_collection(nested, tenant, resource)
            new_parent_doc_id = Codec.encode_doc_id(new_parent_val)

            case Storage.fetch_top_level_cursor(db_or_cursor, parent_col_str, new_parent_doc_id) do
              :none ->
                {:error,
                 InvalidChanges.exception(
                   fields: [fk_attr],
                   message: "does not exist"
                 )}

              {:ok, _parent_cursor} ->
                old_parent_doc_id =
                  case old_record do
                    nil -> nil
                    prev -> prev |> Map.get(fk_attr) |> maybe_encode_doc_id()
                  end

                pk_key = Codec.encode_scalar_key(pk_attr, pk_val)

                {:ok,
                 {:nested,
                  %{
                    parent_collection: parent_col_str,
                    old_parent_doc_id: old_parent_doc_id,
                    new_parent_doc_id: new_parent_doc_id,
                    path: nested.path,
                    cardinality: nested.cardinality,
                    doc_id: doc_id,
                    pk_key: pk_key
                  }}}
            end
          end
      end
    end

    defp build_delete_location(resource, record, pk_attr, pk_val, doc_id, tenant) do
      case resolve_nested_spec(resource) do
        nil ->
          {:top_level, doc_id}

        nested ->
          {:nested,
           %{
             parent_collection: resolve_parent_collection(nested, tenant, resource),
             parent_doc_id: record |> Map.get(nested.foreign_key) |> maybe_encode_doc_id(),
             path: nested.path,
             cardinality: nested.cardinality,
             doc_id: doc_id,
             pk_key: Codec.encode_scalar_key(pk_attr, pk_val)
           }}
      end
    end

    defp plan_identity_ops(db_or_cursor, resource, old_record, new_record, tenant) do
      collection = Codec.scoped_collection(resource, tenant)
      pk_attr = pk_attribute(resource)

      current_doc_id =
        cond do
          new_record != nil ->
            Codec.encode_pk_doc_id(pk_attr, Map.fetch!(new_record, pk_attr.name))

          old_record != nil ->
            Codec.encode_pk_doc_id(pk_attr, Map.fetch!(old_record, pk_attr.name))
        end

      resource
      |> Ash.Resource.Info.identities()
      |> Enum.reduce_while({:ok, []}, fn identity, {:ok, acc} ->
        slot = identity_slot_name(identity.name)
        old_key = active_identity_key(resource, identity, old_record, tenant)
        new_key = active_identity_key(resource, identity, new_record, tenant)

        case check_identity_collision(
               db_or_cursor,
               collection,
               slot,
               new_key,
               current_doc_id,
               identity
             ) do
          :ok ->
            ops = diff_unique_keys(slot, old_key, new_key, current_doc_id)
            {:cont, {:ok, ops ++ acc}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)
    end

    defp active_identity_key(_resource, _identity, nil, _tenant), do: nil

    defp active_identity_key(resource, identity, record, tenant) do
      if matches_identity_where?(resource, record, Map.get(identity, :where), tenant) do
        case Codec.encode_identity_key(resource, identity, record, tenant) do
          {:ok, key} -> key
          :skip -> nil
        end
      else
        nil
      end
    end

    defp matches_identity_where?(_resource, _record, nil, _tenant), do: true

    defp matches_identity_where?(resource, record, where_filter, tenant) do
      struct_record = if is_struct(record, resource), do: record, else: struct(resource, record)

      case Ash.Filter.Runtime.filter_matches(nil, [struct_record], where_filter,
             tenant: tenant,
             authorize?: false
           ) do
        {:ok, [_ | _]} -> true
        _ -> false
      end
    end

    defp check_identity_collision(_db, _collection, _slot, nil, _doc_id, _identity), do: :ok

    defp check_identity_collision(db_or_cursor, collection, slot, new_key, current_doc_id, identity) do
      case Storage.lookup_unique(db_or_cursor, collection, slot, new_key) do
        :none ->
          :ok

        {:ok, ^current_doc_id} ->
          :ok

        {:ok, _other_doc_id} ->
          {:error,
           InvalidChanges.exception(
             fields: identity.keys,
             message: Map.get(identity, :message) || "has already been taken"
           )}
      end
    end

    defp diff_unique_keys(_slot, key, key, _doc_id), do: []
    defp diff_unique_keys(slot, nil, new_key, doc_id), do: [{:put_unique, slot, new_key, doc_id}]
    defp diff_unique_keys(slot, old_key, nil, doc_id), do: [{:del_unique, slot, old_key, doc_id}]

    defp diff_unique_keys(slot, old_key, new_key, doc_id) do
      [{:del_unique, slot, old_key, doc_id}, {:put_unique, slot, new_key, doc_id}]
    end

    defp plan_secondary_ops(resource, old_record, new_record) do
      pk_attr = pk_attribute(resource)

      doc_id =
        cond do
          new_record != nil ->
            Codec.encode_pk_doc_id(pk_attr, Map.fetch!(new_record, pk_attr.name))

          old_record != nil ->
            Codec.encode_pk_doc_id(pk_attr, Map.fetch!(old_record, pk_attr.name))
        end

      resource
      |> Info.indexes()
      |> Enum.flat_map(fn %{fields: fields} = index_spec ->
        attrs = Enum.map(fields, &Ash.Resource.Info.attribute(resource, &1))
        slot = index_slot_name(index_spec)

        old_key = encode_record_index_key(attrs, fields, old_record)
        new_key = encode_record_index_key(attrs, fields, new_record)

        diff_set_keys(slot, old_key, new_key, doc_id)
      end)
    end

    defp encode_record_index_key(_attrs, _fields, nil), do: nil

    defp encode_record_index_key(attrs, fields, record) do
      values = Enum.map(fields, &Map.get(record, &1))
      Codec.encode_index_key(attrs, values)
    end

    defp diff_set_keys(_slot, key, key, _doc_id), do: []
    defp diff_set_keys(slot, nil, new_key, doc_id), do: [{:put_set, slot, new_key, doc_id}]
    defp diff_set_keys(slot, old_key, nil, doc_id), do: [{:del_set, slot, old_key, doc_id}]

    defp diff_set_keys(slot, old_key, new_key, doc_id) do
      [{:del_set, slot, old_key, doc_id}, {:put_set, slot, new_key, doc_id}]
    end

    # Generates exact `idx.search.<collection>` ops matching `Xitdb.Ash.Search.Storage` layout
    # so BM25 token additions, weight updates, and removals commit atomically in ONE moment.
    defp plan_search_ops(
           db_or_cursor,
           resource,
           collection,
           new_record,
           explicit_doc_id,
           batch_state
         ) do
      case Info.search_fields(resource) do
        [] ->
          {[], batch_state}

        search_fields ->
          pk_attr = pk_attribute(resource)

          doc_key =
            explicit_doc_id ||
              Codec.encode_pk_doc_id(pk_attr, Map.fetch!(new_record, pk_attr.name))

          new_terms =
            if is_nil(new_record) do
              %{}
            else
              extract_search_terms(new_record, search_fields, db_or_cursor)
            end

          Storage.compile_search_diff_ops(
            db_or_cursor,
            collection,
            doc_key,
            new_terms,
            batch_state
          )
      end
    end

    defp extract_search_terms(record, search_fields, db_or_cursor) do
      Enum.reduce(search_fields, %{}, fn %{field: field, boost: boost, resolver: resolver}, acc ->
        weight = max(1, round(boost * @search_weight_scale))

        raw_value =
          case resolver do
            fun when is_function(fun, 2) -> fun.(record, db_or_cursor)
            nil -> Map.get(record, field)
          end

        raw_value
        |> tokenize_search_value()
        |> Enum.reduce(acc, fn token, term_acc ->
          Map.update(term_acc, token, weight, &(&1 + weight))
        end)
      end)
    end

    defp tokenize_search_value(values) when is_list(values) do
      Enum.flat_map(values, &tokenize_search_value/1)
    end

    defp tokenize_search_value(value) when is_binary(value) or is_struct(value, Ash.CiString) do
      Search.tokenize(value)
    end

    defp tokenize_search_value(value)
         when is_atom(value) and not is_nil(value) and not is_boolean(value) do
      value |> Atom.to_string() |> Search.tokenize()
    end

    defp tokenize_search_value(_other), do: []

    defp plan_purge_nested_children_ops(
           db_or_cursor,
           parent_resource,
           parent_pk_val,
           tenant,
           batch_state
         ) do
      store = Info.store!(parent_resource)

      nested_rules =
        store
        |> Store.reverse_fks(parent_resource)
        |> Enum.filter(&Map.get(&1, :nested?, false))

      Enum.flat_map_reduce(nested_rules, batch_state, fn %{source_resource: child_resource},
                                                         outer_batch ->
        db_or_cursor
        |> nested_cursors_for_parent(child_resource, parent_pk_val, tenant)
        |> Enum.flat_map_reduce(outer_batch, fn {_child_doc_id, child_cursor}, inner_batch ->
          case Codec.from_cursor(child_resource, child_cursor, tenant) do
            {:ok, child_record} ->
              {:ok, ops, next_batch} =
                plan_delete_ops_batched(
                  db_or_cursor,
                  child_resource,
                  child_record,
                  tenant,
                  inner_batch
                )

              {ops, next_batch}

            {:error, _} ->
              {[], inner_batch}
          end
        end)
      end)
    end

    # -- Range Scan Boundary Helpers (Prefix-Aware for Composite Indexes) --

    defp build_lower_bound(_attrs, _prefix_vals, prefix_bin, _range_attr, :unbounded, true) do
      start_key = <<prefix_bin::binary, 0x01>>
      {start_key, fn _key -> true end}
    end

    defp build_lower_bound(_attrs, _prefix_vals, prefix_bin, _range_attr, :unbounded, false) do
      {prefix_bin, fn _key -> true end}
    end

    defp build_lower_bound(
           attrs,
           prefix_vals,
           _prefix_bin,
           %Ash.Resource.Attribute{},
           {inclusivity, min_val},
           _has_range_bound?
         ) do
      specified_vals = prefix_vals ++ [min_val]
      bound_key = Codec.encode_index_prefix(attrs, specified_vals)
      partial_prefix? = length(specified_vals) < length(attrs)

      pred =
        case {inclusivity, partial_prefix?} do
          {:inclusive, _} ->
            fn key -> key >= bound_key end

          {:exclusive, true} ->
            fn key -> key > bound_key and not binary_starts_with?(key, bound_key) end

          {:exclusive, false} ->
            fn key -> key > bound_key end
        end

      {bound_key, pred}
    end

    defp build_upper_bound(_attrs, _prefix_vals, _prefix_bin, _range_attr, :unbounded) do
      fn _key -> true end
    end

    defp build_upper_bound(
           attrs,
           prefix_vals,
           _prefix_bin,
           %Ash.Resource.Attribute{},
           {inclusivity, max_val}
         ) do
      specified_vals = prefix_vals ++ [max_val]
      bound_key = Codec.encode_index_prefix(attrs, specified_vals)
      partial_prefix? = length(specified_vals) < length(attrs)

      case {inclusivity, partial_prefix?} do
        {:inclusive, true} ->
          fn key -> key <= bound_key or binary_starts_with?(key, bound_key) end

        {:inclusive, false} ->
          fn key -> key <= bound_key end

        {:exclusive, _} ->
          fn key -> key < bound_key end
      end
    end

    defp binary_starts_with?(bin, <<>>), do: is_binary(bin)

    defp binary_starts_with?(bin, prefix) do
      plen = byte_size(prefix)

      case bin do
        <<^prefix::binary-size(^plen), _rest::binary>> -> true
        _ -> false
      end
    end

    defp non_null_at_offset?(bin, offset) when byte_size(bin) > offset do
      :binary.at(bin, offset) != 0x00
    end

    defp non_null_at_offset?(_bin, _offset), do: true

    defp pk_attribute(resource) do
      [pk_name | _] = Ash.Resource.Info.primary_key(resource)
      Ash.Resource.Info.attribute(resource, pk_name)
    end

    defp cursor_matches_doc_id?(cursor, pk_attr, expected_doc_id) do
      pk_field_str = Atom.to_string(pk_attr.name)

      case cursor[pk_field_str] do
        nil -> false
        val -> Codec.encode_pk_doc_id(pk_attr, val) == expected_doc_id
      end
    end

    defp maybe_encode_doc_id(nil), do: nil
    defp maybe_encode_doc_id(val), do: Codec.encode_doc_id(val)

    defp resolve_nested_spec(resource) do
      raw =
        case fallback_nested_in(resource) do
          nil ->
            if function_exported?(Info, :nested_mappings, 1) do
              case Info.nested_mappings(resource) do
                [first | _] -> first
                [] -> nil
              end
            end

          spec ->
            spec
        end

      normalize_nested_spec(raw)
    end

    defp resolve_nested_spec!(resource) do
      case resolve_nested_spec(resource) do
        nil -> raise ArgumentError, "#{inspect(resource)} is not a nested_in resource"
        spec -> spec
      end
    end

    defp fallback_nested_in(resource) do
      if function_exported?(Info, :nested_in, 1) do
        apply(Info, :nested_in, [resource])
      else
        nil
      end
    end

    defp normalize_nested_spec(nil), do: nil

    defp normalize_nested_spec(%{
           parent: parent,
           as: as_slot,
           parent_key: fk_attr,
           cardinality: cardinality
         })
         when is_atom(parent) and not is_nil(parent) do
      %{
        parent_resource: parent,
        parent_collection: Info.collection!(parent),
        foreign_key: fk_attr,
        path: Atom.to_string(as_slot),
        cardinality: cardinality
      }
    end

    defp normalize_nested_spec(%{
           parent_collection: parent_col,
           foreign_key: fk_attr,
           path: path,
           cardinality: cardinality
         })
         when is_atom(parent_col) and not is_nil(parent_col) do
      %{
        parent_resource: nil,
        parent_collection: parent_col,
        foreign_key: fk_attr,
        path: Atom.to_string(path),
        cardinality: cardinality
      }
    end

    defp resolve_parent_collection(%{parent_resource: parent}, tenant, _resource)
         when is_atom(parent) and not is_nil(parent) do
      Codec.scoped_collection(parent, tenant)
    end

    defp resolve_parent_collection(%{parent_collection: parent_col}, tenant, resource) do
      if Ash.Resource.Info.multitenancy_strategy(resource) == :context and not is_nil(tenant) do
        "t:" <> Codec.encode_doc_id(tenant) <> ":" <> Atom.to_string(parent_col)
      else
        Atom.to_string(parent_col)
      end
    end
  end

  defmodule Xitdb.Ash.Indexer.Storage do
    @moduledoc false
    # Slot-tree adapter built strictly over real `Xitdb` APIs:
    #   root[collection][doc_id]                         (:hash_map)
    #   root[parent_col][parent_id][path]                (:hash_map for :many | entity map for :one)
    #   root["idx"][collection]["_parent"][hex_pk_key]   (:sorted_map -> parent_doc_id)
    #   root["idx"][collection]["id_<name>"][hex_id_key] (:sorted_map -> doc_id)
    #   root["idx"][collection]["attr_<f>"][hex_idx_key] (:sorted_map -> :counted_hash_set(doc_id))
    #   root["idx"]["search"][collection]                (BM25 `meta` / `docs` / `terms`)

    alias Xitdb.Ash.Codec
    alias Xitdb.TxCompiler

    @parent_slot "_parent"

    @spec fetch_top_level_cursor(term(), String.t(), String.t()) :: {:ok, term()} | :none
    def fetch_top_level_cursor(db_or_cursor, collection, doc_id) do
      with %Xitdb.Cursor{} = root <- root_cursor(db_or_cursor),
           %Xitdb.Cursor{} = col <- root[collection],
           cursor when not is_nil(cursor) <- col[doc_id] do
        {:ok, cursor}
      else
        _ -> :none
      end
    end

    @spec fetch_nested_cursor(
            term(),
            String.t(),
            String.t(),
            String.t(),
            :one | :many,
            String.t()
          ) :: {:ok, term()} | :none
    def fetch_nested_cursor(db_or_cursor, parent_col, parent_doc_id, path, cardinality, doc_id) do
      with {:ok, parent} <- fetch_top_level_cursor(db_or_cursor, parent_col, parent_doc_id),
           subtree when not is_nil(subtree) <- parent[path] do
        case cardinality do
          :one ->
            {:ok, subtree}

          :many ->
            case subtree[doc_id] do
              nil -> :none
              cursor -> {:ok, cursor}
            end
        end
      else
        _ -> :none
      end
    end

    @spec list_top_level_cursors(term(), String.t()) :: [{String.t(), term()}]
    def list_top_level_cursors(db_or_cursor, collection) do
      with %Xitdb.Cursor{} = root <- root_cursor(db_or_cursor),
           %Xitdb.Cursor{} = col <- root[collection] do
        Enum.to_list(col)
      else
        _ -> []
      end
    end

    @spec list_nested_cursors_for_parent(
            term(),
            String.t(),
            String.t(),
            String.t(),
            :one | :many,
            Ash.Resource.Attribute.t()
          ) :: [{String.t(), term()}]
    def list_nested_cursors_for_parent(
          db_or_cursor,
          parent_col,
          parent_doc_id,
          path,
          cardinality,
          pk_attr
        ) do
      pk_field = Atom.to_string(pk_attr.name)

      with {:ok, parent} <- fetch_top_level_cursor(db_or_cursor, parent_col, parent_doc_id),
           subtree when not is_nil(subtree) <- parent[path] do
        case cardinality do
          :many ->
            Enum.to_list(subtree)

          :one ->
            case subtree[pk_field] do
              nil -> []
              pk_val -> [{Codec.encode_pk_doc_id(pk_attr, pk_val), subtree}]
            end
        end
      else
        _ -> []
      end
    end

    @spec lookup_unique(term(), String.t(), String.t(), binary()) :: {:ok, String.t()} | :none
    def lookup_unique(db_or_cursor, collection, slot, raw_key) do
      hex_key = encode_btree_key(raw_key)

      with %Xitdb.Cursor{} = btree <- get_index_slot(db_or_cursor, collection, slot),
           doc_id when is_binary(doc_id) <- btree[hex_key] do
        {:ok, doc_id}
      else
        _ -> :none
      end
    end

    @spec list_unique_entries(term(), String.t(), String.t()) :: [{binary(), String.t()}]
    def list_unique_entries(db_or_cursor, collection, slot) do
      case get_index_slot(db_or_cursor, collection, slot) do
        nil ->
          []

        %Xitdb.Cursor{} = btree ->
          Enum.map(btree, fn {hex_key, doc_id} -> {decode_btree_key(hex_key), doc_id} end)
      end
    end

    @spec lookup_set(term(), String.t(), String.t(), binary()) :: [String.t()]
    def lookup_set(db_or_cursor, collection, slot, raw_key) do
      hex_key = encode_btree_key(raw_key)

      with %Xitdb.Cursor{} = btree <- get_index_slot(db_or_cursor, collection, slot),
           %Xitdb.Cursor{} = set <- btree[hex_key] do
        Enum.to_list(set)
      else
        _ -> []
      end
    end

    @spec count_set(term(), String.t(), String.t(), binary()) :: non_neg_integer()
    def count_set(db_or_cursor, collection, slot, raw_key) do
      hex_key = encode_btree_key(raw_key)

      with %Xitdb.Cursor{} = btree <- get_index_slot(db_or_cursor, collection, slot),
           %Xitdb.Cursor{} = set <- btree[hex_key] do
        Enum.count(set)
      else
        _ -> 0
      end
    end

    @spec stream_index_from(term(), String.t(), String.t(), binary()) :: Enumerable.t()
    def stream_index_from(db_or_cursor, collection, slot, start_raw_key) do
      start_hex = encode_btree_key(start_raw_key)

      case get_index_slot(db_or_cursor, collection, slot) do
        nil ->
          []

        %Xitdb.Cursor{} = btree ->
          case Xitdb.NIF.nif_slot_count(btree.db_ref, btree.tag_id, btree.value) do
            {:ok, total_count} when total_count > 0 ->
              start_idx = find_btree_start_index(btree, start_hex, 0, total_count)
              stream_btree_entries(btree, start_idx)

            _ ->
              []
          end
      end
    end

    @spec compile_put_ops(term(), String.t(), map(), tuple(), [tuple()], [tuple()], map()) ::
            {[tuple()], map()}
    def compile_put_ops(
          db_or_cursor,
          collection,
          cursor_map,
          locator_plan,
          identity_ops,
          secondary_ops,
          batch_state \\ %{}
        ) do
      {entity_ops, b1} =
        compile_write_entity_ops(db_or_cursor, collection, cursor_map, locator_plan, batch_state)

      {unique_ops, b2} = compile_unique_ops(db_or_cursor, collection, identity_ops, b1)
      {set_ops, b3} = compile_set_ops(db_or_cursor, collection, secondary_ops, b2)
      {entity_ops ++ unique_ops ++ set_ops, b3}
    end

    @spec compile_delete_ops(term(), String.t(), tuple(), [tuple()], [tuple()], map()) ::
            {[tuple()], map()}
    def compile_delete_ops(
          db_or_cursor,
          collection,
          delete_location,
          identity_ops,
          secondary_ops,
          batch_state \\ %{}
        ) do
      {entity_ops, b1} =
        compile_remove_entity_ops(db_or_cursor, collection, delete_location, batch_state)

      {unique_ops, b2} = compile_unique_ops(db_or_cursor, collection, identity_ops, b1)
      {set_ops, b3} = compile_set_ops(db_or_cursor, collection, secondary_ops, b2)
      {entity_ops ++ unique_ops ++ set_ops, b3}
    end

    @spec compile_search_diff_ops(
            term(),
            String.t(),
            String.t(),
            %{optional(String.t()) => pos_integer()},
            map()
          ) :: {[tuple()], map()}
    def compile_search_diff_ops(
          db_or_cursor,
          collection,
          doc_key,
          new_terms,
          batch_state \\ %{}
        ) do
      doc_state_key = {:search_doc, collection, doc_key}

      %{len: old_len, terms: old_terms} =
        Map.get_lazy(batch_state, doc_state_key, fn ->
          Xitdb.Ash.Search.Storage.read_doc(db_or_cursor, collection, doc_key)
        end)

      new_len = Enum.reduce(new_terms, 0, fn {_term, weight}, sum -> sum + weight end)

      if old_terms == new_terms do
        {[], batch_state}
      else
        was_indexed? = old_len > 0
        now_indexed? = new_len > 0

        doc_count_delta =
          cond do
            not was_indexed? and now_indexed? -> 1
            was_indexed? and not now_indexed? -> -1
            true -> 0
          end

        len_delta = new_len - old_len
        term_diffs = diff_search_terms(old_terms, new_terms)

        col_str = TxCompiler.format_key(collection)
        doc_str = TxCompiler.format_key(doc_key)
        meta_prefix = ".idx.search." <> col_str <> ".meta"
        docs_prefix = ".idx.search." <> col_str <> ".docs"
        terms_prefix = ".idx.search." <> col_str <> ".terms"

        stats_key = {:search_stats, collection}

        %{doc_count: cur_doc_count, total_len: cur_total_len} =
          Map.get_lazy(batch_state, stats_key, fn ->
            Xitdb.Ash.Search.Storage.read_corpus_stats(db_or_cursor, collection)
          end)

        new_doc_count = max(0, cur_doc_count + doc_count_delta)
        new_total_len = max(0, cur_total_len + len_delta)

        next_batch =
          batch_state
          |> Map.put(stats_key, %{doc_count: new_doc_count, total_len: new_total_len})
          |> Map.put(doc_state_key, %{len: new_len, terms: new_terms})

        meta_ops = [
          {:put, meta_prefix <> ".doc_count", new_doc_count},
          {:put, meta_prefix <> ".total_len", new_total_len}
        ]

        doc_path = docs_prefix <> "." <> doc_str

        doc_ops =
          if now_indexed? do
            put_terms =
              Enum.map(new_terms, fn {term, weight} ->
                {:put, doc_path <> ".terms." <> TxCompiler.format_key(term), weight}
              end)

            [
              {:put, doc_path <> ".len", new_len},
              {:reset_col, doc_path <> ".terms", "hash_map"} | put_terms
            ]
          else
            if was_indexed?, do: [{:rm, doc_path}], else: []
          end

        {term_ops, final_batch} =
          Enum.flat_map_reduce(term_diffs, next_batch, fn
            {:put, term, weight}, b_acc ->
              term_key = {:search_term_docs, collection, term}

              docs_set =
                Map.get_lazy(b_acc, term_key, fn ->
                  db_or_cursor
                  |> Xitdb.Ash.Search.Storage.lookup_term(collection, term)
                  |> MapSet.new(&elem(&1, 0))
                end)

              term_str = TxCompiler.format_key(term)

              {[{:put, terms_prefix <> "$" <> term_str <> "." <> doc_str, weight}],
               Map.put(b_acc, term_key, MapSet.put(docs_set, doc_key))}

            {:delete, term}, b_acc ->
              term_key = {:search_term_docs, collection, term}

              docs_set =
                Map.get_lazy(b_acc, term_key, fn ->
                  db_or_cursor
                  |> Xitdb.Ash.Search.Storage.lookup_term(collection, term)
                  |> MapSet.new(&elem(&1, 0))
                end)

              remaining = MapSet.delete(docs_set, doc_key)
              term_str = TxCompiler.format_key(term)

              op =
                if MapSet.size(remaining) == 0 do
                  {:rm, terms_prefix <> "$" <> term_str}
                else
                  {:rm, terms_prefix <> "$" <> term_str <> "." <> doc_str}
                end

              {[op], Map.put(b_acc, term_key, remaining)}
          end)

        {meta_ops ++ doc_ops ++ term_ops, final_batch}
      end
    end

    # -- Internal Compilation & Binary-Search Helpers --

    defp compile_write_entity_ops(
           _db_or_cursor,
           collection,
           cursor_map,
           {:top_level, doc_id},
           batch_state
         ) do
      prefix =
        TxCompiler.format_step(:hash_map, collection) <>
          TxCompiler.format_step(:hash_map, doc_id)

      {TxCompiler.compile_node(prefix, cursor_map, true), batch_state}
    end

    defp compile_write_entity_ops(
           db_or_cursor,
           collection,
           cursor_map,
           {:nested, plan},
           batch_state
         ) do
      %{
        parent_collection: parent_col,
        old_parent_doc_id: old_parent_id,
        new_parent_doc_id: new_parent_id,
        path: path,
        cardinality: cardinality,
        doc_id: doc_id,
        pk_key: pk_key
      } = plan

      reparent_rm_ops =
        if old_parent_id != nil and old_parent_id != new_parent_id do
          compile_remove_from_parent_ops(
            db_or_cursor,
            parent_col,
            old_parent_id,
            path,
            cardinality,
            doc_id
          )
        else
          []
        end

      parent_prefix =
        TxCompiler.format_step(:hash_map, parent_col) <>
          TxCompiler.format_step(:hash_map, new_parent_id) <>
          TxCompiler.format_step(:hash_map, path)

      target_prefix =
        case cardinality do
          :one -> parent_prefix
          :many -> parent_prefix <> TxCompiler.format_step(:hash_map, doc_id)
        end

      write_ops = TxCompiler.compile_node(target_prefix, cursor_map, true)

      {parent_locator_ops, next_batch} =
        compile_unique_ops(
          db_or_cursor,
          collection,
          [{:put_unique, @parent_slot, pk_key, new_parent_id}],
          batch_state
        )

      {reparent_rm_ops ++ write_ops ++ parent_locator_ops, next_batch}
    end

    defp compile_remove_entity_ops(
           db_or_cursor,
           collection,
           {:top_level, doc_id},
           batch_state
         ) do
      case fetch_top_level_cursor(db_or_cursor, collection, doc_id) do
        {:ok, _} ->
          path =
            TxCompiler.format_step(:hash_map, collection) <>
              TxCompiler.format_step(:hash_map, doc_id)

          {[{:rm, path}], batch_state}

        :none ->
          {[], batch_state}
      end
    end

    defp compile_remove_entity_ops(db_or_cursor, collection, {:nested, plan}, batch_state) do
      %{
        parent_collection: parent_col,
        parent_doc_id: parent_id,
        path: path,
        cardinality: cardinality,
        doc_id: doc_id,
        pk_key: pk_key
      } = plan

      subtree_rm =
        if parent_id != nil do
          compile_remove_from_parent_ops(
            db_or_cursor,
            parent_col,
            parent_id,
            path,
            cardinality,
            doc_id
          )
        else
          []
        end

      {locator_rm, next_batch} =
        compile_unique_ops(
          db_or_cursor,
          collection,
          [{:del_unique, @parent_slot, pk_key, parent_id}],
          batch_state
        )

      {subtree_rm ++ locator_rm, next_batch}
    end

    defp compile_remove_from_parent_ops(
           db_or_cursor,
           parent_col,
           parent_id,
           path,
           cardinality,
           doc_id
         ) do
      case fetch_nested_cursor(db_or_cursor, parent_col, parent_id, path, cardinality, doc_id) do
        {:ok, _} ->
          base =
            TxCompiler.format_step(:hash_map, parent_col) <>
              TxCompiler.format_step(:hash_map, parent_id) <>
              TxCompiler.format_step(:hash_map, path)

          target =
            case cardinality do
              :one -> base
              :many -> base <> TxCompiler.format_step(:hash_map, doc_id)
            end

          [{:rm, target}]

        :none ->
          []
      end
    end

    defp compile_unique_ops(db_or_cursor, collection, ops, batch_state) do
      col_step = TxCompiler.format_step(:hash_map, collection)

      Enum.flat_map_reduce(ops, batch_state, fn
        {:put_unique, slot, raw_key, doc_id}, b_acc ->
          hex_key = encode_btree_key(raw_key)
          slot_path = ".idx" <> col_step <> TxCompiler.format_step(:hash_map, slot)
          init_key = {:init_slot, collection, slot}

          {init_op, b_next} =
            if Map.has_key?(b_acc, init_key) or
                 get_index_slot(db_or_cursor, collection, slot) != nil do
              {[], Map.put(b_acc, init_key, true)}
            else
              {[{:init_col, slot_path, "sorted_map"}], Map.put(b_acc, init_key, true)}
            end

          {init_op ++ [{:put, slot_path <> "$" <> hex_key, doc_id}], b_next}

        {:del_unique, slot, raw_key, expected_doc_id}, b_acc ->
          case lookup_unique(db_or_cursor, collection, slot, raw_key) do
            {:ok, current} when is_nil(expected_doc_id) or current == expected_doc_id ->
              hex_key = encode_btree_key(raw_key)
              slot_path = ".idx" <> col_step <> TxCompiler.format_step(:hash_map, slot)
              {[{:rm, slot_path <> "$" <> hex_key}], b_acc}

            _ ->
              {[], b_acc}
          end
      end)
    end

    defp compile_set_ops(db_or_cursor, collection, ops, batch_state) do
      col_step = TxCompiler.format_step(:hash_map, collection)

      Enum.flat_map_reduce(ops, batch_state, fn
        {:put_set, slot, raw_key, doc_id}, b_acc ->
          hex_key = encode_btree_key(raw_key)
          slot_path = ".idx" <> col_step <> TxCompiler.format_step(:hash_map, slot)
          set_path = slot_path <> "$" <> hex_key
          init_key = {:init_slot, collection, slot}
          members_key = {:set_members, collection, slot, raw_key}

          {init_btree, b_init} =
            if Map.has_key?(b_acc, init_key) or
                 get_index_slot(db_or_cursor, collection, slot) != nil do
              {[], Map.put(b_acc, init_key, true)}
            else
              {[{:init_col, slot_path, "sorted_map"}], Map.put(b_acc, init_key, true)}
            end

          cur_members =
            Map.get_lazy(b_init, members_key, fn ->
              db_or_cursor |> lookup_set(collection, slot, raw_key) |> MapSet.new()
            end)

          b_next = Map.put(b_init, members_key, MapSet.put(cur_members, doc_id))

          init_set =
            if MapSet.size(cur_members) == 0 do
              [{:init_col, set_path, "counted_hash_set"}]
            else
              []
            end

          ops_out =
            init_btree ++
              init_set ++
              [
                {:put, set_path <> TxCompiler.format_step(:counted_hash_set, doc_id), true}
              ]

          {ops_out, b_next}

        {:del_set, slot, raw_key, doc_id}, b_acc ->
          members_key = {:set_members, collection, slot, raw_key}

          cur_members =
            Map.get_lazy(b_acc, members_key, fn ->
              db_or_cursor |> lookup_set(collection, slot, raw_key) |> MapSet.new()
            end)

          if MapSet.member?(cur_members, doc_id) do
            remaining = MapSet.delete(cur_members, doc_id)
            hex_key = encode_btree_key(raw_key)
            slot_path = ".idx" <> col_step <> TxCompiler.format_step(:hash_map, slot)
            set_path = slot_path <> "$" <> hex_key

            rm_op =
              if MapSet.size(remaining) == 0 do
                {:rm, set_path}
              else
                {:rm, set_path <> TxCompiler.format_step(:counted_hash_set, doc_id)}
              end

            {[rm_op], Map.put(b_acc, members_key, remaining)}
          else
            {[], b_acc}
          end
      end)
    end

    defp diff_search_terms(old_terms, new_terms) do
      deletes_and_updates =
        Enum.reduce(old_terms, [], fn {term, old_w}, acc ->
          case Map.fetch(new_terms, term) do
            {:ok, ^old_w} -> acc
            {:ok, new_w} -> [{:put, term, new_w} | acc]
            :error -> [{:delete, term} | acc]
          end
        end)

      Enum.reduce(new_terms, deletes_and_updates, fn {term, new_w}, acc ->
        if Map.has_key?(old_terms, term) do
          acc
        else
          [{:put, term, new_w} | acc]
        end
      end)
    end

    defp find_btree_start_index(btree, start_hex, low, high) when low < high do
      mid = div(low + high, 2)

      case Xitdb.NIF.nif_slot_entries(btree.db_ref, btree.tag_id, btree.value, mid, 1) do
        {:ok, [{hex_key, _}]} ->
          if hex_key < start_hex do
            find_btree_start_index(btree, start_hex, mid + 1, high)
          else
            find_btree_start_index(btree, start_hex, low, mid)
          end

        _ ->
          low
      end
    end

    defp find_btree_start_index(_btree, _start_hex, low, _high), do: low

    defp stream_btree_entries(btree, start_idx) do
      Stream.unfold(start_idx, fn idx ->
        case Xitdb.NIF.nif_slot_entries(btree.db_ref, btree.tag_id, btree.value, idx, 64) do
          {:ok, []} -> nil
          {:ok, chunk} -> {chunk, idx + length(chunk)}
          _ -> nil
        end
      end)
      |> Stream.flat_map(& &1)
      |> Stream.map(fn {hex_key, raw_set} ->
        ids =
          case raw_set do
            {:cursor, _tag, _tag_id, _val, _full} = c_tuple ->
              btree.db_ref
              |> Xitdb.Cursor.from_nif_tuple(c_tuple, btree.moment)
              |> Enum.to_list()

            %Xitdb.Cursor{} = cur ->
              Enum.to_list(cur)

            list when is_list(list) ->
              list
          end

        {decode_btree_key(hex_key), ids}
      end)
    end

    defp encode_btree_key(bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)
    defp decode_btree_key(hex) when is_binary(hex), do: Base.decode16!(hex, case: :lower)

    defp root_cursor(%Xitdb.Cursor{} = cursor), do: cursor
    defp root_cursor(%Xitdb{} = db), do: Xitdb.db(db)
    defp root_cursor(_), do: nil

    defp get_index_slot(db_or_cursor, collection, slot) do
      with %Xitdb.Cursor{} = root <- root_cursor(db_or_cursor),
           %Xitdb.Cursor{} = idx <- root["idx"],
           %Xitdb.Cursor{} = col <- idx[collection] do
        col[slot]
      else
        _ -> nil
      end
    end
  end
end
```
