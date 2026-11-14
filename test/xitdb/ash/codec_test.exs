if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.CodecTest do
    use ExUnit.Case, async: true

    alias Xitdb.Ash.Codec

    defmodule DummyStore do
    end

    defmodule PositiveIntNewType do
      use Ash.Type.NewType, subtype_of: :integer, constraints: [min: 0]
    end

    defmodule EnumStatus do
      use Ash.Type.Enum, values: [:alpha, :beta, :gamma]
    end

    defmodule TypedRecord do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [Xitdb.Ash.Dsl]

      xitdb do
        store DummyStore
        collection :typed_records
        counted_set_fields [:tags]
      end

      attributes do
        integer_primary_key(:id)
        attribute(:name, :string, public?: true)
        attribute(:email, :ci_string, public?: true)
        attribute(:active?, :boolean, default: true, public?: true)
        attribute(:score, :float, public?: true)
        attribute(:amount, :decimal, public?: true)
        attribute(:status, :atom, public?: true)
        attribute(:enum_status, EnumStatus, public?: true)
        attribute(:rank, PositiveIntNewType, public?: true)
        attribute(:tags, {:array, :string}, default: [], public?: true)
        attribute(:published_on, :date, public?: true)
        attribute(:cutoff_time, :time, public?: true)
        attribute(:precise_time, :time_usec, public?: true)
        attribute(:published_at, :utc_datetime, public?: true)
        attribute(:precise_at, :utc_datetime_usec, public?: true)
        attribute(:local_at, :naive_datetime, public?: true)
        attribute(:ext_id, :uuid, public?: true)
      end

      identities do
        identity(:unique_pair, [:name, :email])
        identity(:unique_nullable, [:email, :status], nils_distinct?: false)
      end
    end

    defmodule CiPkRecord do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [Xitdb.Ash.Dsl]

      xitdb do
        store DummyStore
        collection :ci_pk_records
      end

      attributes do
        attribute(:code, :ci_string, primary_key?: true, allow_nil?: false, public?: true)
        attribute(:label, :string, public?: true)
      end
    end

    defmodule ContextTenantRecord do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [Xitdb.Ash.Dsl]

      xitdb do
        store DummyStore
        collection :context_docs
      end

      multitenancy do
        strategy(:context)
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:slug, :string, allow_nil?: false, public?: true)
      end

      identities do
        identity(:unique_slug, [:slug])
        identity(:global_slug, [:slug], all_tenants?: true)
      end
    end

    defmodule AttributeTenantRecord do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [Xitdb.Ash.Dsl]

      xitdb do
        store DummyStore
        collection :attr_docs
      end

      multitenancy do
        strategy(:attribute)
        attribute(:org_id)
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:org_id, :integer, allow_nil?: true, public?: true)
        attribute(:slug, :string, allow_nil?: false, public?: true)
      end

      identities do
        identity(:unique_org_slug, [:slug])
      end
    end

    describe "encode_i64_be/1 and decode_i64_be/1" do
      test "round-trips and preserves total signed 64-bit ordering" do
        samples = [
          -9_223_372_036_854_775_808,
          -1_000_000_000,
          -1,
          0,
          1,
          42,
          1_000_000_000,
          9_223_372_036_854_775_807
        ]

        encoded = Enum.map(samples, &Codec.encode_i64_be/1)

        assert Enum.all?(encoded, &(byte_size(&1) == 8))
        assert Enum.map(encoded, &Codec.decode_i64_be/1) == samples
        assert encoded == Enum.sort(encoded)
        assert Enum.uniq(encoded) == encoded
      end
    end

    describe "temporal order-preserving keys and truncation" do
      test ":date uses fixed-width 8-byte key preserving negative BCE through future chronological order" do
        attr = Ash.Resource.Info.attribute(TypedRecord, :published_on)

        dates = [
          Date.new!(-500, 1, 1),
          Date.new!(-1, 12, 31),
          Date.new!(0, 1, 1),
          Date.new!(1970, 1, 1),
          Date.new!(2026, 11, 11)
        ]

        keys = Enum.map(dates, &Codec.encode_scalar_key(attr, &1))

        assert Enum.all?(keys, &(byte_size(&1) == 8))
        assert keys == Enum.sort(keys)
        assert Enum.uniq(keys) == keys
      end

      test ":time truncates to second while :time_usec preserves microseconds" do
        time_attr = Ash.Resource.Info.attribute(TypedRecord, :cutoff_time)
        time_usec_attr = Ash.Resource.Info.attribute(TypedRecord, :precise_time)

        t1 = ~T[09:30:05.111222]
        t2 = ~T[09:30:05.888999]
        t3 = ~T[09:30:06.000001]

        assert Codec.encode_scalar_key(time_attr, t1) == Codec.encode_scalar_key(time_attr, t2)
        assert Codec.encode_scalar_key(time_attr, t2) < Codec.encode_scalar_key(time_attr, t3)

        k1 = Codec.encode_scalar_key(time_usec_attr, t1)
        k2 = Codec.encode_scalar_key(time_usec_attr, t2)
        k3 = Codec.encode_scalar_key(time_usec_attr, t3)

        assert byte_size(k1) == 8
        assert byte_size(k2) == 8
        assert k1 < k2
        assert k2 < k3
      end

      test ":utc_datetime truncates to :second in both dump and index key while :utc_datetime_usec preserves usec" do
        dt_attr = Ash.Resource.Info.attribute(TypedRecord, :published_at)
        usec_attr = Ash.Resource.Info.attribute(TypedRecord, :precise_at)
        naive_attr = Ash.Resource.Info.attribute(TypedRecord, :local_at)

        dt1 = ~U[2026-11-11 10:15:30.123456Z]
        dt2 = ~U[2026-11-11 10:15:30.987654Z]
        dt3 = ~U[2026-11-11 10:15:31.000001Z]

        assert Codec.encode_scalar_key(dt_attr, dt1) == Codec.encode_scalar_key(dt_attr, dt2)
        assert Codec.encode_scalar_key(dt_attr, dt2) < Codec.encode_scalar_key(dt_attr, dt3)

        assert Codec.encode_scalar_key(usec_attr, dt1) < Codec.encode_scalar_key(usec_attr, dt2)
        assert Codec.encode_scalar_key(usec_attr, dt2) < Codec.encode_scalar_key(usec_attr, dt3)

        ndt1 = ~N[2026-11-11 10:15:30.100000]
        ndt2 = ~N[2026-11-11 10:15:30.900000]

        assert Codec.encode_scalar_key(naive_attr, ndt1) <
                 Codec.encode_scalar_key(naive_attr, ndt2)

        assert {:ok, dumped} =
                 Codec.to_cursor_map(TypedRecord, %{
                   id: 1,
                   published_at: dt1,
                   precise_at: dt1,
                   local_at: ndt1
                 })

        assert dumped["published_at"] ==
                 dt1 |> DateTime.truncate(:second) |> DateTime.to_unix(:microsecond)

        assert dumped["precise_at"] == DateTime.to_unix(dt1, :microsecond)

        assert {:ok, hydrated} = Codec.from_cursor(TypedRecord, dumped)
        assert hydrated.published_at == ~U[2026-11-11 10:15:30Z]
        assert hydrated.precise_at == dt1
        assert hydrated.local_at == ndt1
      end
    end

    describe "encode_f64_be/1 and encode_decimal_key/1" do
      test "encode_f64_be normalizes -0.0 and +0.0 and preserves IEEE float order" do
        assert Codec.encode_f64_be(-0.0) == Codec.encode_f64_be(+0.0)

        floats = [-1.0e12, -100.5, -0.001, 0.0, 0.001, 100.5, 1.0e12]
        encoded = Enum.map(floats, &Codec.encode_f64_be/1)

        assert Enum.all?(encoded, &(byte_size(&1) == 8))
        assert encoded == Enum.sort(encoded)
        assert Enum.uniq(encoded) == encoded
      end

      test "encode_decimal_key is scale-invariant (60 == 60.0 == 60.000) and orders negatives, zeros, and positives" do
        assert Codec.encode_decimal_key(Decimal.new("60")) ==
                 Codec.encode_decimal_key(Decimal.new("60.0"))

        assert Codec.encode_decimal_key(Decimal.new("60.0")) ==
                 Codec.encode_decimal_key(Decimal.new("60.000"))

        assert Codec.encode_decimal_key(Decimal.new("0")) == <<0x80>>

        assert Codec.encode_decimal_key(Decimal.new("-0.000")) ==
                 Codec.encode_decimal_key(Decimal.new("0.00"))

        ordered = [
          Decimal.new("-1000"),
          Decimal.new("-100.5"),
          Decimal.new("-10"),
          Decimal.new("-0.001"),
          Decimal.new("0"),
          Decimal.new("0.001"),
          Decimal.new("10"),
          Decimal.new("60.00"),
          Decimal.new("100.5"),
          Decimal.new("1000")
        ]

        keys = Enum.map(ordered, &Codec.encode_decimal_key/1)
        assert keys == Enum.sort(keys)
        assert Enum.uniq(keys) == keys

        attr = Ash.Resource.Info.attribute(TypedRecord, :amount)
        assert Codec.encode_scalar_key(attr, 60.0) == Codec.encode_decimal_key(Decimal.new("60"))

        assert_raise ArgumentError, fn ->
          Codec.encode_decimal_key(Decimal.new("NaN"))
        end

        assert_raise ArgumentError, fn ->
          Codec.encode_decimal_key(Decimal.new("Infinity"))
        end
      end
    end

    describe "CiString, NewType, and counted_set_fields round-trip" do
      test "CiString preserves original casing in cursor round-trip but lowercases keys and doc IDs" do
        ci_attr = Ash.Resource.Info.attribute(TypedRecord, :email)
        pk_attr = Ash.Resource.Info.attribute(CiPkRecord, :code)

        assert {:ok, dumped} =
                 Codec.to_cursor_map(TypedRecord, %{
                   id: 7,
                   email: Ash.CiString.new("Alice.Chen@Acme.IO"),
                   rank: 5
                 })

        assert dumped["email"] == "Alice.Chen@Acme.IO"
        assert {:ok, loaded} = Codec.from_cursor(TypedRecord, dumped)
        assert loaded.email == Ash.CiString.new("Alice.Chen@Acme.IO")

        assert Codec.encode_scalar_key(ci_attr, Ash.CiString.new("Alice@ACME.io")) ==
                 Codec.encode_scalar_key(ci_attr, "alice@acme.io")

        assert Codec.encode_doc_id(Ash.CiString.new("CaAsA-01")) == "caasa-01"
        assert Codec.encode_pk_doc_id(pk_attr, "MixedCase") == "mixedcase"
        assert Codec.encode_pk_doc_id(pk_attr, Ash.CiString.new("MixedCase")) == "mixedcase"

        rank_attr = Ash.Resource.Info.attribute(TypedRecord, :rank)
        assert Codec.encode_scalar_key(rank_attr, 5) < Codec.encode_scalar_key(rank_attr, 20)
      end

      test "counted_set_fields writes Xitdb.counted_set and hydrates back to list from a real Xitdb cursor" do
        tags = ["fintech", "ai", "allocator"]

        assert {:ok, dumped} =
                 Codec.to_cursor_map(TypedRecord, %{
                   id: 1,
                   name: "Alpha",
                   tags: tags,
                   amount: Decimal.new("125.50"),
                   published_on: ~D[2026-11-11],
                   cutoff_time: ~T[14:05:09.999999],
                   precise_time: ~T[14:05:09.123456],
                   published_at: ~U[2026-11-11 14:05:09.500000Z],
                   precise_at: ~U[2026-11-11 14:05:09.123456Z],
                   local_at: ~N[2026-11-11 14:05:09.123456],
                   score: 98.5,
                   active?: false
                 })

        assert %Xitdb.Collection{kind: :counted_hash_set, data: _} = dumped["tags"]

        {:ok, db} = Xitdb.open(backend: :memory)

        on_exit(fn ->
          try do
            Xitdb.close(db)
          catch
            _, _ -> :ok
          end
        end)

        {:ok, _} =
          Xitdb.transact(db, fn root ->
            put_in(root["typed_records"], %{"1" => dumped})
          end)

        cursor = Xitdb.db(db)["typed_records"]["1"]
        assert {:ok, loaded} = Codec.from_cursor(TypedRecord, cursor)
        assert loaded.id == 1
        assert loaded.name == "Alpha"
        assert Enum.sort(loaded.tags) == Enum.sort(tags)
        assert loaded.amount == Decimal.new("125.50")
        assert loaded.published_on == ~D[2026-11-11]
        assert loaded.cutoff_time == ~T[14:05:09]
        assert loaded.precise_time == ~T[14:05:09.123456]
        assert loaded.published_at == ~U[2026-11-11 14:05:09Z]
        assert loaded.precise_at == ~U[2026-11-11 14:05:09.123456Z]
        assert loaded.local_at == ~N[2026-11-11 14:05:09.123456]
        assert loaded.score == 98.5
        assert loaded.active? == false
      end

      test "encode_doc_id/1 and decode_doc_id/2 handle integer and ci_string PKs" do
        assert Codec.encode_doc_id(42) == "42"
        assert {:ok, 42} = Codec.decode_doc_id(TypedRecord, "42")

        assert {:error, {:invalid_integer_pk, "not_int"}} =
                 Codec.decode_doc_id(TypedRecord, "not_int")

        assert {:ok, ci} = Codec.decode_doc_id(CiPkRecord, "alpha")
        assert ci == Ash.CiString.new("alpha")
      end
    end

    describe "composite index keys, prefixes, and identity encoding" do
      test "composite index keys escape interior null bytes and support leading prefix encoding" do
        attrs = [
          Ash.Resource.Info.attribute(TypedRecord, :name),
          Ash.Resource.Info.attribute(TypedRecord, :email)
        ]

        k1 = Codec.encode_index_key(attrs, ["ab", "cd"])
        k2 = Codec.encode_index_key(attrs, ["a", "bcd"])
        k_null_interior = Codec.encode_index_key(attrs, [<<65, 0, 66>>, "x"])
        k_split = Codec.encode_index_key(attrs, ["A", <<66, 0, "x">>])

        assert k1 != k2
        assert k_null_interior != k_split

        prefix = Codec.encode_index_prefix(attrs, ["ab"])
        assert :binary.match(k1, prefix) == {0, byte_size(prefix)}

        # Multi-column with fixed-width integer + string
        id_attr = Ash.Resource.Info.attribute(TypedRecord, :id)
        name_attr = Ash.Resource.Info.attribute(TypedRecord, :name)

        fixed_prefix = Codec.encode_index_prefix([id_attr, name_attr], [10])
        full_key = Codec.encode_index_key([id_attr, name_attr], [10, "zeta"])
        other_key = Codec.encode_index_key([id_attr, name_attr], [11, "alpha"])

        assert :binary.match(full_key, fixed_prefix) == {0, byte_size(fixed_prefix)}
        assert fixed_prefix < full_key
        assert full_key < other_key
      end

      test "composite identity keys are length-prefixed, decodable, and honor nils_distinct?" do
        ident_distinct = Ash.Resource.Info.identity(TypedRecord, :unique_pair)
        ident_nullable = Ash.Resource.Info.identity(TypedRecord, :unique_nullable)

        assert {:ok, k1} =
                 Codec.encode_identity_key(TypedRecord, ident_distinct, %{name: "ab", email: "cd"})

        assert {:ok, k2} =
                 Codec.encode_identity_key(TypedRecord, ident_distinct, %{name: "a", email: "bcd"})

        assert k1 != k2

        # Strip 1-byte global tenant prefix (0x00) and verify length-prefixed parts decode cleanly
        <<0x00, parts_bin::binary>> = k1
        assert {{:bytes, "ab"}, rest} = Codec.decode_length_prefixed_part(parts_bin)
        assert {{:bytes, "cd"}, <<>>} = Codec.decode_length_prefixed_part(rest)

        # Case-insensitive comparison inside identity key
        assert {:ok, ci1} =
                 Codec.encode_identity_key(TypedRecord, ident_distinct, %{
                   name: "Alice",
                   email: Ash.CiString.new("Alice@Acme.IO")
                 })

        assert {:ok, ci2} =
                 Codec.encode_identity_key(TypedRecord, ident_distinct, %{
                   name: "Alice",
                   email: "alice@acme.io"
                 })

        assert ci1 == ci2

        # nils_distinct?: true -> :skip on any nil
        assert :skip ==
                 Codec.encode_identity_key(TypedRecord, ident_distinct, %{
                   name: "Alice",
                   email: nil
                 })

        # nils_distinct?: false -> encodes nil part cleanly without colliding with empty string ""
        assert {:ok, nil_key} =
                 Codec.encode_identity_key(TypedRecord, ident_nullable, %{
                   email: "a@b.c",
                   status: nil
                 })

        assert {:ok, empty_key} =
                 Codec.encode_identity_key(TypedRecord, ident_nullable, %{
                   email: "a@b.c",
                   status: ""
                 })

        assert nil_key != empty_key
        <<0x00, p1_rest::binary>> = nil_key
        assert {{:bytes, "a@b.c"}, p2_rest} = Codec.decode_length_prefixed_part(p1_rest)
        assert {:nil_part, <<>>} = Codec.decode_length_prefixed_part(p2_rest)
      end
    end

    describe "multitenancy (:context and :attribute)" do
      test ":context multitenancy scopes collection names, identity keys, and loaded metadata" do
        assert Codec.scoped_collection(ContextTenantRecord, nil) == "context_docs"
        assert Codec.scoped_collection(ContextTenantRecord, "org_a") == "t:org_a:context_docs"
        assert Codec.scoped_collection(TypedRecord, "ignored") == "typed_records"

        scoped_ident = Ash.Resource.Info.identity(ContextTenantRecord, :unique_slug)
        global_ident = Ash.Resource.Info.identity(ContextTenantRecord, :global_slug)

        assert {:ok, ka} =
                 Codec.encode_identity_key(
                   ContextTenantRecord,
                   scoped_ident,
                   %{slug: "same"},
                   "t1"
                 )

        assert {:ok, kb} =
                 Codec.encode_identity_key(
                   ContextTenantRecord,
                   scoped_ident,
                   %{slug: "same"},
                   "t2"
                 )

        assert ka != kb

        assert {:ok, ga} =
                 Codec.encode_identity_key(
                   ContextTenantRecord,
                   global_ident,
                   %{slug: "same"},
                   "t1"
                 )

        assert {:ok, gb} =
                 Codec.encode_identity_key(
                   ContextTenantRecord,
                   global_ident,
                   %{slug: "same"},
                   "t2"
                 )

        assert ga == gb

        {:ok, dumped} =
          Codec.to_cursor_map(ContextTenantRecord, %{
            id: "11111111-1111-1111-1111-111111111111",
            slug: "hello"
          })

        assert {:ok, loaded} = Codec.from_cursor(ContextTenantRecord, dumped, "org_a")
        assert loaded.__metadata__.tenant == "org_a"
      end

      test ":attribute multitenancy falls back to explicit tenant when struct attribute is nil" do
        ident = Ash.Resource.Info.identity(AttributeTenantRecord, :unique_org_slug)

        # nil struct attr falls back to explicit tenant arg
        assert {:ok, k_fallback} =
                 Codec.encode_identity_key(
                   AttributeTenantRecord,
                   ident,
                   %{org_id: nil, slug: "home"},
                   42
                 )

        assert {:ok, k_explicit_on_struct} =
                 Codec.encode_identity_key(
                   AttributeTenantRecord,
                   ident,
                   %{org_id: 42, slug: "home"},
                   999
                 )

        assert {:ok, k_other_tenant} =
                 Codec.encode_identity_key(
                   AttributeTenantRecord,
                   ident,
                   %{org_id: nil, slug: "home"},
                   99
                 )

        # Struct non-nil attribute (42) wins over explicit fallback (999)
        assert k_fallback == k_explicit_on_struct
        assert k_fallback != k_other_tenant
      end
    end

    describe "custom Ash.Type.Enum handling" do
      test "encodes scalar and composite keys using storage type instead of ETF and round-trips atoms" do
        enum_attr = Ash.Resource.Info.attribute(TypedRecord, :enum_status)
        name_attr = Ash.Resource.Info.attribute(TypedRecord, :name)

        assert Codec.encode_scalar_key(enum_attr, :alpha) == "alpha"
        assert Codec.encode_scalar_key(enum_attr, "alpha") == "alpha"
        assert Codec.encode_scalar_key(enum_attr, :beta) == "beta"

        k_alpha = Codec.encode_index_key([enum_attr, name_attr], [:alpha, "z"])
        k_beta = Codec.encode_index_key([enum_attr, name_attr], [:beta, "a"])
        assert k_alpha < k_beta
        refute String.starts_with?(k_alpha, <<0x01, 131>>)

        record = %TypedRecord{id: 1, enum_status: :beta}
        assert {:ok, dumped} = Codec.to_cursor_map(TypedRecord, record)
        assert dumped["enum_status"] == "beta"
        assert {:ok, loaded} = Codec.from_cursor(TypedRecord, dumped)
        assert loaded.enum_status == :beta
      end
    end

    describe "counted_set_fields with non-string array element types" do
      defmodule CountedSetTypedResource do
        use Ash.Resource,
          domain: nil,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(DummyStore)
          collection(:counted_set_typed)
          counted_set_fields([:int_ids, :uuid_ids, :flags, :scores, :timestamps])
        end

        attributes do
          integer_primary_key(:id)
          attribute(:int_ids, {:array, :integer}, default: [])
          attribute(:uuid_ids, {:array, :uuid}, default: [])
          attribute(:flags, {:array, :boolean}, default: [])
          attribute(:scores, {:array, :float}, default: [])
          attribute(:timestamps, {:array, :utc_datetime}, default: [])
        end
      end

      test "round-trips integer, uuid, boolean, float, and utc_datetime counted_set_fields" do
        u1 = Ash.UUID.generate()
        u2 = Ash.UUID.generate()
        ts = ~U[2026-11-14 12:00:00Z]

        assert {:ok, dumped} =
                 Codec.to_cursor_map(CountedSetTypedResource, %{
                   id: 1,
                   int_ids: [10, 20, 30],
                   uuid_ids: [u1, u2],
                   flags: [true, false],
                   scores: [1.5, 2.25],
                   timestamps: [ts]
                 })

        {:ok, db} = Xitdb.open(backend: :memory)

        on_exit(fn ->
          try do
            Xitdb.close(db)
          catch
            _, _ -> :ok
          end
        end)

        {:ok, _} =
          Xitdb.transact(db, fn root ->
            put_in(root["counted_set_typed"], %{"1" => dumped})
          end)

        cursor = Xitdb.db(db)["counted_set_typed"]["1"]
        assert {:ok, loaded} = Codec.from_cursor(CountedSetTypedResource, cursor)
        assert Enum.sort(loaded.int_ids) == [10, 20, 30]
        assert Enum.sort(loaded.uuid_ids) == Enum.sort([u1, u2])
        assert Enum.sort(loaded.flags) == [false, true]
        assert Enum.sort(loaded.scores) == [1.5, 2.25]
        assert loaded.timestamps == [ts]
      end
    end
  end
end
