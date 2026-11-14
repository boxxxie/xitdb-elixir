# Reference: `Xitdb.Ash.Codec` & `Xitdb.Ash.Indexer`

> [!IMPORTANT]
> **Track Reference Metadata:**
> - **Associated Track:** [`ash_codec_and_indexer_20261111`](./index.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Modules:** `lib/xitdb/ash/codec.ex`, `lib/xitdb/ash/indexer.ex`
> - **Purpose:** Complete specification and reference implementation for entity cursor encoding, order-preserving binary B+Tree keys, tenant-scoped composite identities, `_parent` subtree locators, and recursive nested-index cleanup for `Xitdb.Ash.DataLayer`.

---

## 1. Concurrency, Encoding & Safety Invariants

### 1.1 Order-Preserving Binary B+Tree Keys
64-bit integers and epoch-microsecond timestamps flip their two's-complement sign bit (`bxor(msb, 0x80)`) into 8-byte big-endian binaries; IEEE-754 floats and `Decimal` values normalize `-0.0` / trailing zeros (`60.0 == 60.00`) into canonical order-preserving byte sequences; `:date` and `:time` use ISO-8601 strings; and `:ci_string` downcases index keys while preserving original casing in entity cursors.

### 1.2 Collision-Free Composite & Multitenant Keys
Unique identity keys (`idx.<col>.id_<name>`) prefix each component with a presence tag and 32-bit byte length (`<<len::unsigned-big-32, part::binary>>`) scoped by `tenant` (unless `identity.all_tenants?` is `true`) and honor `identity.nils_distinct?`. Composite secondary indexes escape interior `0x00` bytes (`<<0x00, 0xFF>>`) and terminate variable-width strings with `<<0x00, 0x00>>` so multi-column B+Tree prefix + range scans remain both collision-free and lexicographically ordered.

### 1.3 Subtree Co-Location & Recursive Cleanup
`Indexer` routes `nested_in` `:one` and `:many` entities into `root[parent_col][parent_id][path]` while maintaining `idx.<col>._parent` for `O(log N)` direct primary-key lookups, handling reparenting on FK updates and recursively purging child `_parent`, secondary, identity, and `Xitdb.Ash.Search` entries when a parent subtree is deleted.

---

## 2. Reference Implementation: `lib/xitdb/ash/codec.ex`

```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Codec do
    @moduledoc """
    Bidirectional `Ash.Type` cursor serialization and order-preserving B+Tree binary key
    encoding for `Xitdb.Ash.DataLayer`.
    """

    alias Ash.Resource.Attribute

    @null_tag 0x00
    @value_tag 0x01
    @global_tenant_tag 0x00
    @scoped_tenant_tag 0x01

    # -- Entity Cursor Serialization --

    @doc """
    Encodes a `%Resource{}` struct (or attribute map) into a string-keyed map suitable
    for writing into a Xitdb `:hash_map` cursor.
    """
    @spec to_cursor_map(module(), struct() | map()) :: {:ok, %{String.t() => term()}} | {:error, term()}
    def to_cursor_map(resource, record) when is_atom(resource) and is_map(record) do
      resource
      |> Ash.Resource.Info.attributes()
      |> Enum.reduce_while({:ok, %{}}, fn %Attribute{} = attr, {:ok, acc} ->
        value = Map.get(record, attr.name)

        case dump_attribute(attr, value) do
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
    def encode_doc_id(%Ash.CiString{} = ci), do: ci |> Ash.CiString.value() |> String.downcase() |> :binary.copy()
    def encode_doc_id(id) when is_atom(id) and not is_nil(id), do: Atom.to_string(id)
    def encode_doc_id(id), do: to_string(id)

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

    Single-column indexes emit `<<0x00>>` for `nil` and `<<0x01, scalar::binary>>` for values.
    Multi-column indexes escape interior `0x00` bytes on variable-width strings and terminate
    them with `<<0x00, 0x00>>` so composite prefix + range scans preserve lexicographical order.
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
      # Only called when `attr` is the full 1-column index; callers with >1 columns pass all attrs.
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
        effective_tenant = resolve_identity_tenant(resource, all_tenants?, record_or_map, tenant)
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
    Encodes a `Decimal` into a canonical, scale-normalized (`60.0 == 60.00`) order-preserving binary.
    """
    @spec encode_decimal_key(Decimal.t()) :: binary()
    def encode_decimal_key(%Decimal{coef: coef}) when coef in [:NaN, :inf] do
      raise ArgumentError, "cannot index non-finite Decimal #{inspect(coef)} in Xitdb B+Tree"
    end

    def encode_decimal_key(%Decimal{} = dec) do
      if Decimal.eq?(dec, 0) do
        <<0x80>>
      else
        digits = dec.coef |> Integer.digits() |> strip_trailing_zeros()
        exp10 = length(digits) + dec.exp

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
    @spec decode_length_prefixed_part(binary()) :: {:nil_part, binary()} | {{:bytes, binary()}, binary()}
    def decode_length_prefixed_part(<<@null_tag, rest::binary>>), do: {:nil_part, rest}

    def decode_length_prefixed_part(
          <<@value_tag, len::unsigned-big-32, part::binary-size(^len), rest::binary>>
        ) do
      {{:bytes, part}, rest}
    end

    # -- Attribute Dump / Load Internals --

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
          %Decimal{} = dec = if is_struct(value, Decimal), do: value, else: Decimal.new(value)
          {:ok, Decimal.to_string(dec, :normal)}

        :atom when is_atom(value) ->
          {:ok, Atom.to_string(value)}

        kind when kind in [:utc_datetime, :utc_datetime_usec, :datetime] ->
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
          {:ok, Time.to_iso8601(t)}

        :uuid when is_binary(value) ->
          {:ok, :binary.copy(value)}

        _complex ->
          Ash.Type.dump_to_embedded(attr.type, value, constraints)
      end
    end

    defp load_attribute(_attr, nil), do: {:ok, nil}

    defp load_attribute(%Attribute{} = attr, raw) do
      {kind, _constraints} = unwrap_type(attr.type, attr.constraints)

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
          {:ok, Time.from_iso8601!(raw)}

        :uuid when is_binary(raw) ->
          {:ok, :binary.copy(raw)}

        _other ->
          # Handles `:atom` safely via `String.to_existing_atom` + `:one_of` inside Ash.Type.Atom,
          # as well as `:embedded` structs, unions, and `{:array, _}` attributes.
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

    defp encode_typed_scalar(:decimal, %Decimal{} = dec), do: encode_decimal_key(dec)
    defp encode_typed_scalar(:decimal, val), do: val |> Decimal.new() |> encode_decimal_key()

    defp encode_typed_scalar(kind, %DateTime{} = dt)
         when kind in [:utc_datetime, :utc_datetime_usec, :datetime] do
      dt |> DateTime.to_unix(:microsecond) |> encode_i64_be()
    end

    defp encode_typed_scalar(:naive_datetime, %NaiveDateTime{} = ndt) do
      ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond) |> encode_i64_be()
    end

    defp encode_typed_scalar(:date, %Date{} = d), do: Date.to_iso8601(d)
    defp encode_typed_scalar(:time, %Time{} = t), do: Time.to_iso8601(t)

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

    defp fixed_width_kind?(kind) do
      kind in [
        :integer,
        :boolean,
        :float,
        :utc_datetime,
        :utc_datetime_usec,
        :datetime,
        :naive_datetime,
        :date
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
          Map.get(record, tenant_attr, tenant)

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
    (with partial `where` filters), secondary `:sorted_map` B+Tree indexes, and recursive
    nested-subtree cleanup for `Xitdb.Ash.DataLayer`.
    """

    alias Ash.Error.Changes.InvalidChanges
    alias Xitdb.Ash.{Codec, Info, Search, Store}
    alias Xitdb.Ash.Indexer.Storage

    @parent_slot "_parent"

    @type bound :: {:inclusive | :exclusive, term()} | :unbounded
    @type range_spec :: %{
            optional(:prefix) => [term()],
            optional(:min) => bound(),
            optional(:max) => bound()
          }

    # -- Transactional Write Operations (`create` / `update` / `destroy`) --

    @doc """
    Writes `new_record` (and diffs `old_record` when updating) across the entity slot tree,
    `_parent` locator, unique `identities`, secondary `:sorted_map` indexes, and `Xitdb.Ash.Search`.

    Returns `{:error, %Ash.Error.Changes.InvalidChanges{}}` if a unique identity collides
    or if a `nested_in` parent entity does not exist.
    """
    @spec put_record(term(), module(), struct() | nil, struct(), term()) ::
            {:ok, term()} | {:error, Exception.t()}
    def put_record(db, resource, old_record, %_{} = new_record, tenant \\ nil)
        when is_atom(resource) do
      with {:ok, cursor_map} <- Codec.to_cursor_map(resource, new_record),
           {:ok, identity_ops} <- plan_identity_ops(db, resource, old_record, new_record, tenant),
           {:ok, locator_plan} <- plan_entity_location(db, resource, old_record, new_record) do
        secondary_ops = plan_secondary_ops(resource, old_record, new_record)
        collection = resource |> Info.collection!() |> Atom.to_string()

        updated_db =
          db
          |> Storage.apply_entity_and_indexes(collection, cursor_map, locator_plan, identity_ops, secondary_ops)
          |> Search.index_record(resource, new_record)

        {:ok, updated_db}
      end
    end

    @doc """
    Removes `record` from its entity slot (top-level or `nested_in`), `_parent` locator,
    unique identities, secondary indexes, `Xitdb.Ash.Search`, and any nested child indexes.
    """
    @spec delete_record(term(), module(), struct(), term()) :: {:ok, term()}
    def delete_record(db, resource, %_{} = record, tenant \\ nil) when is_atom(resource) do
      collection = resource |> Info.collection!() |> Atom.to_string()
      pk_attr = pk_attribute(resource)
      pk_val = Map.fetch!(record, pk_attr.name)
      doc_id = Codec.encode_doc_id(pk_val)

      # Purge nested children's `_parent`, identity, secondary, and BM25 indexes BEFORE
      # deleting the parent cursor that physically houses their co-located subtrees.
      db_after_children = purge_nested_children(db, resource, pk_val, tenant)

      {:ok, identity_ops} = plan_identity_ops(db_after_children, resource, record, nil, tenant)
      secondary_ops = plan_secondary_ops(resource, record, nil)
      delete_location = build_delete_location(resource, record, pk_attr, pk_val, doc_id)

      updated_db =
        db_after_children
        |> Storage.delete_entity_and_indexes(collection, delete_location, identity_ops, secondary_ops)
        |> Search.remove_record(resource, pk_val)

      {:ok, updated_db}
    end

    # -- Point, Subtree, Identity & B+Tree Read Operations --

    @doc """
    Fetches a single raw entity cursor by primary key in `O(1)` for top-level collections
    or `O(log N)` via `idx.<col>._parent` for `nested_in` resources.
    """
    @spec fetch_cursor(term(), module(), term()) :: {:ok, term()} | :none
    def fetch_cursor(_db, _resource, nil), do: :none

    def fetch_cursor(db, resource, pk_value) when is_atom(resource) do
      collection = resource |> Info.collection!() |> Atom.to_string()
      pk_attr = pk_attribute(resource)
      doc_id = Codec.encode_doc_id(pk_value)

      case Info.nested_in(resource) do
        nil ->
          Storage.fetch_top_level_cursor(db, collection, doc_id)

        %{parent_collection: parent_col, path: path, cardinality: cardinality} ->
          pk_key = Codec.encode_scalar_key(pk_attr, pk_value)

          with {:ok, parent_doc_id} <- Storage.lookup_unique(db, collection, @parent_slot, pk_key),
               {:ok, cursor} <-
                 Storage.fetch_nested_cursor(
                   db,
                   Atom.to_string(parent_col),
                   parent_doc_id,
                   Atom.to_string(path),
                   cardinality,
                   doc_id
                 ),
               true <- cursor_matches_doc_id?(cursor, Atom.to_string(pk_attr.name), doc_id) do
            {:ok, cursor}
          else
            _ -> :none
          end
      end
    end

    @doc """
    Streams all `{doc_id, cursor}` pairs for a top-level collection or across all `_parent`
    entries of a `nested_in` collection.
    """
    @spec all_cursors(term(), module()) :: [{String.t(), term()}]
    def all_cursors(db, resource) when is_atom(resource) do
      collection = resource |> Info.collection!() |> Atom.to_string()
      pk_attr = pk_attribute(resource)

      case Info.nested_in(resource) do
        nil ->
          Storage.list_top_level_cursors(db, collection)

        %{parent_collection: parent_col, path: path, cardinality: cardinality} ->
          parent_col_str = Atom.to_string(parent_col)
          path_str = Atom.to_string(path)
          pk_field_str = Atom.to_string(pk_attr.name)

          db
          |> Storage.list_unique_entries(collection, @parent_slot)
          |> Enum.flat_map(fn {_pk_key, parent_doc_id} ->
            Storage.list_nested_cursors_for_parent(
              db,
              parent_col_str,
              parent_doc_id,
              path_str,
              cardinality,
              pk_field_str
            )
          end)
      end
    end

    @doc """
    Jumps directly to `root[parent_col][parent_id][path]` in `O(1)` when filtering a
    `nested_in` resource by its parent foreign key (`event_id == ^eid`).
    """
    @spec nested_cursors_for_parent(term(), module(), term()) :: [{String.t(), term()}]
    def nested_cursors_for_parent(db, resource, parent_id) when is_atom(resource) do
      %{parent_collection: parent_col, path: path, cardinality: cardinality} =
        Info.nested_in(resource)

      pk_field_str = resource |> pk_attribute() |> Map.fetch!(:name) |> Atom.to_string()

      Storage.list_nested_cursors_for_parent(
        db,
        Atom.to_string(parent_col),
        Codec.encode_doc_id(parent_id),
        Atom.to_string(path),
        cardinality,
        pk_field_str
      )
    end

    @doc """
    Resolves an existing entity's canonical `doc_id` string by `Ash.Resource.Identity` in `O(log N)`.
    """
    @spec lookup_by_identity(term(), module(), Ash.Resource.Identity.t(), map(), term()) ::
            {:ok, String.t()} | :none
    def lookup_by_identity(db, resource, identity, key_map, tenant \\ nil)
        when is_atom(resource) and is_map(key_map) do
      case Codec.encode_identity_key(resource, identity, key_map, tenant) do
        :skip ->
          :none

        {:ok, encoded_key} ->
          collection = resource |> Info.collection!() |> Atom.to_string()
          Storage.lookup_unique(db, collection, identity_slot_name(identity.name), encoded_key)
      end
    end

    @doc """
    Returns the `MapSet` of matching `doc_id` strings for an exact secondary index match in `O(log N)`.
    """
    @spec lookup_secondary_eq(term(), module(), map(), [term()]) :: MapSet.t(String.t())
    def lookup_secondary_eq(db, resource, %{fields: fields} = index_spec, values)
        when is_atom(resource) and is_list(values) do
      collection = resource |> Info.collection!() |> Atom.to_string()
      attrs = Enum.map(fields, &Ash.Resource.Info.attribute(resource, &1))
      encoded_key = Codec.encode_index_key(attrs, values)
      slot = index_slot_name(index_spec)

      db
      |> Storage.lookup_set(collection, slot, encoded_key)
      |> MapSet.new()
    end

    @doc """
    Returns the `O(log N)` cardinality of matching child records for `:restrict` FK checks
    and indexed count shortcuts without materializing structs.
    """
    @spec count_by_attribute(term(), module(), atom(), term()) :: non_neg_integer()
    def count_by_attribute(db, resource, field, value) when is_atom(resource) and is_atom(field) do
      collection = resource |> Info.collection!() |> Atom.to_string()
      attr = Ash.Resource.Info.attribute(resource, field)
      encoded_key = Codec.encode_index_key([attr], [value])
      Storage.count_set(db, collection, "attr_#{field}", encoded_key)
    end

    @doc """
    Scans a `:sorted_map` secondary index over `[min, max]` bounds (optionally scoped to a
    composite `prefix` tuple) and returns the union `MapSet` of `doc_id` strings.
    """
    @spec scan_secondary_range(term(), module(), map(), range_spec()) :: MapSet.t(String.t())
    def scan_secondary_range(db, resource, %{fields: fields} = index_spec, range_spec)
        when is_atom(resource) and is_map(range_spec) do
      collection = resource |> Info.collection!() |> Atom.to_string()
      attrs = Enum.map(fields, &Ash.Resource.Info.attribute(resource, &1))
      prefix_vals = Map.get(range_spec, :prefix, [])
      range_attr = Enum.at(attrs, length(prefix_vals))

      prefix_bin =
        if prefix_vals == [] do
          <<>>
        else
          Codec.encode_index_prefix(attrs, prefix_vals)
        end

      {start_key, min_pred} = build_lower_bound(attrs, prefix_vals, prefix_bin, range_attr, Map.get(range_spec, :min, :unbounded))
      max_pred = build_upper_bound(attrs, prefix_vals, prefix_bin, range_attr, Map.get(range_spec, :max, :unbounded))

      db
      |> Storage.stream_index_from(collection, index_slot_name(index_spec), start_key)
      |> Stream.take_while(fn {key, _ids} ->
        binary_starts_with?(key, prefix_bin) and max_pred.(key)
      end)
      |> Enum.reduce(MapSet.new(), fn {key, ids}, acc ->
        # Exclude `nil` entries (`0x00` tag) on open-ended `<` / `<=` scans unless explicitly matched
        if not non_null_at_offset?(key, byte_size(prefix_bin)) or not min_pred.(key) do
          acc
        else
          Enum.reduce(ids, acc, &MapSet.put(&2, &1))
        end
      end)
    end

    @doc """
    Returns the canonical slot name under `idx.<collection>` for a `%Xitdb.Ash.Dsl.Index{}`.
    """
    @spec index_slot_name(map()) :: String.t()
    def index_slot_name(%{name: name}) when is_atom(name) and not is_nil(name) do
      Atom.to_string(name)
    end

    def index_slot_name(%{fields: [single_field]}), do: "attr_#{single_field}"

    def index_slot_name(%{fields: fields}) when is_list(fields) do
      "idx_" <> Enum.map_join(fields, "_", &Atom.to_string/1)
    end

    @doc """
    Returns the canonical slot name under `idx.<collection>` for an `Ash.Resource.Identity`.
    """
    @spec identity_slot_name(atom()) :: String.t()
    def identity_slot_name(name) when is_atom(name), do: "id_#{name}"

    # -- Internal Planning & Diffing --

    defp plan_entity_location(db, resource, old_record, new_record) do
      pk_attr = pk_attribute(resource)
      pk_val = Map.fetch!(new_record, pk_attr.name)
      doc_id = Codec.encode_doc_id(pk_val)

      case Info.nested_in(resource) do
        nil ->
          {:ok, {:top_level, doc_id}}

        %{
          parent_collection: parent_col,
          foreign_key: fk_attr,
          path: path,
          cardinality: cardinality
        } ->
          new_parent_val = Map.get(new_record, fk_attr)

          if is_nil(new_parent_val) do
            {:error,
             InvalidChanges.exception(
               fields: [fk_attr],
               message: "is required for nested Xitdb resource"
             )}
          else
            parent_col_str = Atom.to_string(parent_col)
            new_parent_doc_id = Codec.encode_doc_id(new_parent_val)

            case Storage.fetch_top_level_cursor(db, parent_col_str, new_parent_doc_id) do
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
                    path: Atom.to_string(path),
                    cardinality: cardinality,
                    doc_id: doc_id,
                    pk_key: pk_key
                  }}}
            end
          end
      end
    end

    defp build_delete_location(resource, record, pk_attr, pk_val, doc_id) do
      case Info.nested_in(resource) do
        nil ->
          {:top_level, doc_id}

        %{parent_collection: parent_col, foreign_key: fk_attr, path: path, cardinality: cardinality} ->
          {:nested,
           %{
             parent_collection: Atom.to_string(parent_col),
             parent_doc_id: record |> Map.get(fk_attr) |> maybe_encode_doc_id(),
             path: Atom.to_string(path),
             cardinality: cardinality,
             doc_id: doc_id,
             pk_key: Codec.encode_scalar_key(pk_attr, pk_val)
           }}
      end
    end

    defp plan_identity_ops(db, resource, old_record, new_record, tenant) do
      collection = resource |> Info.collection!() |> Atom.to_string()
      pk_name = resource |> Ash.Resource.Info.primary_key() |> hd()

      current_doc_id =
        cond do
          new_record != nil -> new_record |> Map.fetch!(pk_name) |> Codec.encode_doc_id()
          old_record != nil -> old_record |> Map.fetch!(pk_name) |> Codec.encode_doc_id()
        end

      resource
      |> Ash.Resource.Info.identities()
      |> Enum.reduce_while({:ok, []}, fn identity, {:ok, acc} ->
        slot = identity_slot_name(identity.name)
        old_key = active_identity_key(resource, identity, old_record, tenant)
        new_key = active_identity_key(resource, identity, new_record, tenant)

        case check_identity_collision(db, collection, slot, new_key, current_doc_id, identity) do
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
      if matches_identity_where?(record, Map.get(identity, :where)) do
        case Codec.encode_identity_key(resource, identity, record, tenant) do
          {:ok, key} -> key
          :skip -> nil
        end
      else
        nil
      end
    end

    defp matches_identity_where?(_record, nil), do: true

    defp matches_identity_where?(record, where_filter) do
      case Ash.Filter.Runtime.matches?(nil, record, where_filter) do
        {:ok, matched?} -> matched?
        matched? when is_boolean(matched?) -> matched?
        _ -> false
      end
    end

    defp check_identity_collision(_db, _collection, _slot, nil, _doc_id, _identity), do: :ok

    defp check_identity_collision(db, collection, slot, new_key, current_doc_id, identity) do
      case Storage.lookup_unique(db, collection, slot, new_key) do
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
      pk_name = resource |> Ash.Resource.Info.primary_key() |> hd()

      doc_id =
        cond do
          new_record != nil -> new_record |> Map.fetch!(pk_name) |> Codec.encode_doc_id()
          old_record != nil -> old_record |> Map.fetch!(pk_name) |> Codec.encode_doc_id()
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

    defp purge_nested_children(db, parent_resource, parent_pk_val, tenant) do
      store = Info.store!(parent_resource)

      nested_rules =
        store
        |> Store.reverse_fks(parent_resource)
        |> Enum.filter(&Map.get(&1, :nested?, false))

      Enum.reduce(nested_rules, db, fn %{source_resource: child_resource}, acc_db ->
        acc_db
        |> nested_cursors_for_parent(child_resource, parent_pk_val)
        |> Enum.reduce(acc_db, fn {_child_doc_id, child_cursor}, inner_db ->
          case Codec.from_cursor(child_resource, child_cursor, tenant) do
            {:ok, child_record} ->
              {:ok, next_db} = delete_record(inner_db, child_resource, child_record, tenant)
              next_db

            {:error, _} ->
              inner_db
          end
        end)
      end)
    end

    # -- Range Scan Boundary Helpers --

    defp build_lower_bound(_attrs, _prefix_vals, prefix_bin, _range_attr, :unbounded) do
      # Skip `0x00` nil entries by starting at `<prefix_bin> <> <<0x01>>`
      start_key = <<prefix_bin::binary, 0x01>>
      {start_key, fn _key -> true end}
    end

    defp build_lower_bound(attrs, prefix_vals, _prefix_bin, %Ash.Resource.Attribute{}, {inclusivity, min_val}) do
      bound_key = Codec.encode_index_prefix(attrs, prefix_vals ++ [min_val])

      pred =
        case inclusivity do
          :inclusive -> fn key -> key >= bound_key end
          :exclusive -> fn key -> key > bound_key end
        end

      {bound_key, pred}
    end

    defp build_upper_bound(_attrs, _prefix_vals, _prefix_bin, _range_attr, :unbounded) do
      fn _key -> true end
    end

    defp build_upper_bound(attrs, prefix_vals, _prefix_bin, %Ash.Resource.Attribute{}, {inclusivity, max_val}) do
      bound_key = Codec.encode_index_prefix(attrs, prefix_vals ++ [max_val])

      case inclusivity do
        :inclusive -> fn key -> key <= bound_key end
        :exclusive -> fn key -> key < bound_key end
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

    defp cursor_matches_doc_id?(cursor, pk_field_str, expected_doc_id) do
      case cursor[pk_field_str] do
        nil -> false
        val -> Codec.encode_doc_id(val) == expected_doc_id
      end
    end

    defp maybe_encode_doc_id(nil), do: nil
    defp maybe_encode_doc_id(val), do: Codec.encode_doc_id(val)
  end

  defmodule Xitdb.Ash.Indexer.Storage do
    @moduledoc false
    # Thin slot-tree adapter isolating Xitdb cursor primitives for:
    #   root[collection][doc_id]                         (:hash_map)
    #   root[parent_col][parent_id][path]                (:hash_map for :many | entity map for :one)
    #   root["idx"][collection]["_parent"][pk_key]       (:sorted_map -> parent_doc_id)
    #   root["idx"][collection]["id_<name>"][id_key]     (:sorted_map -> doc_id)
    #   root["idx"][collection]["attr_<f>"][idx_key]     (:sorted_map -> :counted_hash_set(doc_id))

    @parent_slot "_parent"

    @spec fetch_top_level_cursor(term(), String.t(), String.t()) :: {:ok, term()} | :none
    def fetch_top_level_cursor(db, collection, doc_id) do
      with root when not is_nil(root) <- Xitdb.root(db),
           col when not is_nil(col) <- root[collection],
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
    def fetch_nested_cursor(db, parent_col, parent_doc_id, path, cardinality, doc_id) do
      with {:ok, parent} <- fetch_top_level_cursor(db, parent_col, parent_doc_id),
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
    def list_top_level_cursors(db, collection) do
      with root when not is_nil(root) <- Xitdb.root(db),
           col when not is_nil(col) <- root[collection] do
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
            String.t()
          ) :: [{String.t(), term()}]
    def list_nested_cursors_for_parent(db, parent_col, parent_doc_id, path, cardinality, pk_field) do
      with {:ok, parent} <- fetch_top_level_cursor(db, parent_col, parent_doc_id),
           subtree when not is_nil(subtree) <- parent[path] do
        case cardinality do
          :many ->
            Enum.to_list(subtree)

          :one ->
            case subtree[pk_field] do
              nil -> []
              pk_val -> [{Xitdb.Ash.Codec.encode_doc_id(pk_val), subtree}]
            end
        end
      else
        _ -> []
      end
    end

    @spec lookup_unique(term(), String.t(), String.t(), binary()) :: {:ok, String.t()} | :none
    def lookup_unique(db, collection, slot, key) do
      with btree when not is_nil(btree) <- get_index_slot(db, collection, slot),
           doc_id when not is_nil(doc_id) <- btree[key] do
        {:ok, doc_id}
      else
        _ -> :none
      end
    end

    @spec list_unique_entries(term(), String.t(), String.t()) :: [{binary(), String.t()}]
    def list_unique_entries(db, collection, slot) do
      case get_index_slot(db, collection, slot) do
        nil -> []
        btree -> Enum.to_list(btree)
      end
    end

    @spec lookup_set(term(), String.t(), String.t(), binary()) :: [String.t()]
    def lookup_set(db, collection, slot, key) do
      with btree when not is_nil(btree) <- get_index_slot(db, collection, slot),
           set when not is_nil(set) <- btree[key] do
        Enum.to_list(set)
      else
        _ -> []
      end
    end

    @spec count_set(term(), String.t(), String.t(), binary()) :: non_neg_integer()
    def count_set(db, collection, slot, key) do
      with btree when not is_nil(btree) <- get_index_slot(db, collection, slot),
           set when not is_nil(set) <- btree[key] do
        Enum.count(set)
      else
        _ -> 0
      end
    end

    @spec stream_index_from(term(), String.t(), String.t(), binary()) :: Enumerable.t()
    def stream_index_from(db, collection, slot, start_key) do
      case get_index_slot(db, collection, slot) do
        nil -> []
        btree -> Xitdb.SortedMap.stream_from(btree, start_key)
      end
    end

    @spec apply_entity_and_indexes(
            term(),
            String.t(),
            map(),
            tuple(),
            [tuple()],
            [tuple()]
          ) :: term()
    def apply_entity_and_indexes(db, collection, cursor_map, locator_plan, identity_ops, secondary_ops) do
      Xitdb.transact(db, fn root ->
        col_idx = ensure_col_idx(root, collection)
        write_entity_cursor(root, col_idx, collection, cursor_map, locator_plan)
        apply_unique_ops(col_idx, identity_ops)
        apply_set_ops(col_idx, secondary_ops)
      end)
    end

    @spec delete_entity_and_indexes(
            term(),
            String.t(),
            tuple(),
            [tuple()],
            [tuple()]
          ) :: term()
    def delete_entity_and_indexes(db, collection, delete_location, identity_ops, secondary_ops) do
      Xitdb.transact(db, fn root ->
        col_idx = ensure_col_idx(root, collection)
        remove_entity_cursor(root, col_idx, collection, delete_location)
        apply_unique_ops(col_idx, identity_ops)
        apply_set_ops(col_idx, secondary_ops)
      end)
    end

    defp write_entity_cursor(root, _col_idx, collection, cursor_map, {:top_level, doc_id}) do
      col = Xitdb.Map.ensure(root, collection, :hash_map)
      Xitdb.Map.put(col, doc_id, cursor_map)
    end

    defp write_entity_cursor(root, col_idx, _collection, cursor_map, {:nested, plan}) do
      %{
        parent_collection: parent_col,
        old_parent_doc_id: old_parent_id,
        new_parent_doc_id: new_parent_id,
        path: path,
        cardinality: cardinality,
        doc_id: doc_id,
        pk_key: pk_key
      } = plan

      parents = Xitdb.Map.ensure(root, parent_col, :hash_map)

      # Clean old subtree slot when reparenting across parents
      if old_parent_id != nil and old_parent_id != new_parent_id do
        remove_from_parent_subtree(parents, old_parent_id, path, cardinality, doc_id)
      end

      new_parent = parents[new_parent_id]

      case cardinality do
        :one ->
          Xitdb.Map.put(new_parent, path, cursor_map)

        :many ->
          children = Xitdb.Map.ensure(new_parent, path, :hash_map)
          Xitdb.Map.put(children, doc_id, cursor_map)
      end

      parent_btree = Xitdb.Map.ensure(col_idx, @parent_slot, :sorted_map)
      Xitdb.Map.put(parent_btree, pk_key, new_parent_id)
    end

    defp remove_entity_cursor(root, _col_idx, collection, {:top_level, doc_id}) do
      case root[collection] do
        nil -> :ok
        col -> Xitdb.Map.delete(col, doc_id)
      end
    end

    defp remove_entity_cursor(root, col_idx, _collection, {:nested, plan}) do
      %{
        parent_collection: parent_col,
        parent_doc_id: parent_id,
        path: path,
        cardinality: cardinality,
        doc_id: doc_id,
        pk_key: pk_key
      } = plan

      if parent_id != nil and root[parent_col] != nil do
        remove_from_parent_subtree(root[parent_col], parent_id, path, cardinality, doc_id)
      end

      case col_idx[@parent_slot] do
        nil -> :ok
        parent_btree -> Xitdb.Map.delete(parent_btree, pk_key)
      end
    end

    defp remove_from_parent_subtree(parents, parent_id, path, cardinality, doc_id) do
      case parents[parent_id] do
        nil ->
          :ok

        parent ->
          case {cardinality, parent[path]} do
            {_, nil} -> :ok
            {:one, _} -> Xitdb.Map.delete(parent, path)
            {:many, children} -> Xitdb.Map.delete(children, doc_id)
          end
      end
    end

    defp apply_unique_ops(col_idx, ops) do
      Enum.each(ops, fn
        {:put_unique, slot, key, doc_id} ->
          btree = Xitdb.Map.ensure(col_idx, slot, :sorted_map)
          Xitdb.Map.put(btree, key, doc_id)

        {:del_unique, slot, key, doc_id} ->
          case col_idx[slot] do
            nil ->
              :ok

            btree ->
              if btree[key] == doc_id, do: Xitdb.Map.delete(btree, key)
          end
      end)
    end

    defp apply_set_ops(col_idx, ops) do
      Enum.each(ops, fn
        {:put_set, slot, key, doc_id} ->
          btree = Xitdb.Map.ensure(col_idx, slot, :sorted_map)
          set = Xitdb.Map.ensure(btree, key, :counted_hash_set)
          Xitdb.Set.put(set, doc_id)

        {:del_set, slot, key, doc_id} ->
          with btree when not is_nil(btree) <- col_idx[slot],
               set when not is_nil(set) <- btree[key] do
            Xitdb.Set.delete(set, doc_id)
            if Enum.empty?(set), do: Xitdb.Map.delete(btree, key)
          end
      end)
    end

    defp ensure_col_idx(root, collection) do
      idx = Xitdb.Map.ensure(root, "idx", :hash_map)
      Xitdb.Map.ensure(idx, collection, :hash_map)
    end

    defp get_index_slot(db, collection, slot) do
      with root when not is_nil(root) <- Xitdb.root(db),
           idx when not is_nil(idx) <- root["idx"],
           col_idx when not is_nil(col_idx) <- idx[collection] do
        col_idx[slot]
      else
        _ -> nil
      end
    end
  end
end
```
