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
      kind = canonical_kind(resolved)

      cond do
        kind != resolved ->
          {kind, constraints}

        Ash.Type.NewType.new_type?(resolved) ->
          sub = Ash.Type.NewType.subtype_of(resolved)
          sub_constraints = Ash.Type.NewType.constraints(resolved, constraints)
          unwrap_type(sub, sub_constraints)

        true ->
          {resolved, constraints}
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
    defp canonical_kind(Ash.Type.NaiveDatetime), do: :naive_datetime
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
