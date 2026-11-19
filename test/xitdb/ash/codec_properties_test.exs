if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.CodecPropertiesTest do
    use ExUnit.Case, async: true
    use ExUnitProperties

    alias Ash.Resource.Attribute
    alias Xitdb.Ash.Codec
    alias Xitdb.TestSupport.MemberProfile

    @min_i64 -9_223_372_036_854_775_808
    @max_i64 9_223_372_036_854_775_807
    @max_u64 18_446_744_073_709_551_615

    property ":unsigned_integer attribute index keys preserve strict u64 ordering across 0..2^64-1" do
      u64_attr = %Attribute{name: :big_u64, type: :unsigned_integer, constraints: []}

      u64_gen =
        one_of([
          integer(0..@max_i64),
          integer((@max_i64 + 1)..@max_u64),
          member_of([0, 1, @max_i64, @max_i64 + 1, @max_u64 - 1, @max_u64])
        ])

      check all(a <- u64_gen, b <- u64_gen) do
        ka = Codec.encode_scalar_key(u64_attr, a)
        kb = Codec.encode_scalar_key(u64_attr, b)
        ia = Codec.encode_index_key([u64_attr], [a])
        ib = Codec.encode_index_key([u64_attr], [b])

        assert byte_size(ka) == 8
        assert compare_terms(ka, kb) == compare_terms(a, b)
        assert compare_terms(ia, ib) == compare_terms(a, b)
      end
    end

    property "encode_i64_be/1 round-trips and preserves strict signed ordering across all 64-bit bounds" do
      i64_gen =
        one_of([
          integer(@min_i64..@max_i64),
          member_of([@min_i64, @min_i64 + 1, -1, 0, 1, @max_i64 - 1, @max_i64])
        ])

      check all(a <- i64_gen, b <- i64_gen) do
        bin_a = Codec.encode_i64_be(a)
        bin_b = Codec.encode_i64_be(b)

        assert Codec.decode_i64_be(bin_a) == a
        assert Codec.decode_i64_be(bin_b) == b
        assert compare_terms(bin_a, bin_b) == compare_terms(a, b)
      end
    end

    property "encode_f64_be/1 normalizes -0.0/+0.0 and preserves IEEE-754 ordering" do
      assert Codec.encode_f64_be(-0.0) == Codec.encode_f64_be(+0.0)

      check all(
              a <- float(min: -1.0e12, max: 1.0e12),
              b <- float(min: -1.0e12, max: 1.0e12)
            ) do
        assert compare_terms(Codec.encode_f64_be(a), Codec.encode_f64_be(b)) ==
                 compare_terms(a, b)
      end
    end

    property "encode_decimal_key/1 is scale-invariant (60.0 == 60.00) and order-preserving" do
      assert Codec.encode_decimal_key(Decimal.new("60")) ==
               Codec.encode_decimal_key(Decimal.new("60.000"))

      assert Codec.encode_decimal_key(Decimal.new("-0.00")) ==
               Codec.encode_decimal_key(Decimal.new("0"))

      dec_gen =
        gen all(
              sign <- member_of(["", "-"]),
              whole <- integer(0..999_999),
              frac <- integer(0..9999),
              trailing <- string(?0..?0, max_length: 3)
            ) do
          Decimal.new("#{sign}#{whole}.#{frac}#{trailing}")
        end

      check all(a <- dec_gen, b <- dec_gen) do
        assert compare_terms(Codec.encode_decimal_key(a), Codec.encode_decimal_key(b)) ==
                 Decimal.compare(a, b)
      end
    end

    property "composite secondary index keys escape interior NUL bytes without collisions" do
      str_attr = %Attribute{name: :a, type: Ash.Type.String, constraints: []}
      int_attr = %Attribute{name: :b, type: Ash.Type.Integer, constraints: []}
      attrs = [str_attr, int_attr]

      bin_with_nuls =
        gen all(
              bytes <-
                list_of(one_of([constant(0), constant(255), integer(97..102)]), max_length: 12)
            ) do
          :erlang.list_to_binary(bytes)
        end

      check all(
              s1 <- bin_with_nuls,
              s2 <- bin_with_nuls,
              n1 <- integer(-500..500),
              n2 <- integer(-500..500)
            ) do
        k1 = Codec.encode_index_key(attrs, [s1, n1])
        k2 = Codec.encode_index_key(attrs, [s2, n2])

        assert compare_terms(k1, k2) == compare_terms({s1, n1}, {s2, n2})
      end
    end

    defmodule ContextTenantProfile do
      @moduledoc false
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [Xitdb.Ash.Dsl]

      xitdb do
        store Xitdb.TestSupport.MdmStore
        collection :context_tenant_profiles
      end

      multitenancy do
        strategy(:context)
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:full_name, :string, public?: true)
        attribute(:headline, :string, public?: true)
      end
    end

    defmodule MapPropRecord do
      @moduledoc false
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [Xitdb.Ash.Dsl]

      xitdb do
        store Xitdb.TestSupport.MdmStore
        collection :map_prop_records
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:raw_bin, :binary, public?: true)
        attribute(:meta, :map, default: %{}, allow_nil?: false, public?: true)
      end
    end

    property "tenant-scoped composite identity keys never collide across boundaries or tenants" do
      fake_identity = %{
        name: :composite,
        keys: [:full_name, :headline],
        nils_distinct?: false,
        all_tenants?: false
      }

      seg_gen = string([?a..?c, ?:, ?0], min_length: 0, max_length: 8)

      check all(
              f1 <- seg_gen,
              h1 <- seg_gen,
              t1 <- one_of([constant(nil), seg_gen]),
              f2 <- seg_gen,
              h2 <- seg_gen,
              t2 <- one_of([constant(nil), seg_gen])
            ) do
        {:ok, k1} =
          Codec.encode_identity_key(
            ContextTenantProfile,
            fake_identity,
            %{full_name: f1, headline: h1},
            t1
          )

        {:ok, k2} =
          Codec.encode_identity_key(
            ContextTenantProfile,
            fake_identity,
            %{full_name: f2, headline: h2},
            t2
          )

        if {t1, f1, h1} == {t2, f2, h2} do
          assert k1 == k2
        else
          assert k1 != k2
        end

        # Non-multitenant resources ignore stray parent tenant values so nil and "" share keys.
        assert Codec.encode_identity_key(
                 MemberProfile,
                 fake_identity,
                 %{full_name: f1, headline: h1},
                 t1
               ) ==
                 Codec.encode_identity_key(
                   MemberProfile,
                   fake_identity,
                   %{full_name: f1, headline: h1},
                   nil
                 )
      end
    end

    property ":binary scalar keys preserve bytewise order (including 0x00/0xFF) and round-trip" do
      bin_attr = %Attribute{name: :raw_bin, type: Ash.Type.Binary, constraints: []}

      bin_gen =
        one_of([
          constant(<<>>),
          constant(<<0, "__xitdb_nil__">>),
          constant(<<0, "__xitdb_esc__raw">>),
          binary(min_length: 0, max_length: 24),
          map(
            list_of(one_of([constant(0), constant(255), integer(1..254)]), max_length: 16),
            &:erlang.list_to_binary/1
          )
        ])

      {:ok, db} = Xitdb.open(backend: :memory)

      try do
        check all(a <- bin_gen, b <- bin_gen, max_runs: 50) do
          assert compare_terms(
                   Codec.encode_scalar_key(bin_attr, a),
                   Codec.encode_scalar_key(bin_attr, b)
                 ) == compare_terms(a, b)

          id = "00000000-0000-0000-0000-000000000001"
          {:ok, dumped} = Codec.to_cursor_map(MapPropRecord, %{id: id, raw_bin: a, meta: %{}})

          {:ok, db} =
            Xitdb.transact(db, fn root ->
              put_in(root["recs"][id], dumped)
            end)

          assert {:ok, loaded} = Codec.from_cursor(MapPropRecord, db["recs"][id])
          assert loaded.raw_bin === a
        end
      after
        :ok = Xitdb.close(db)
      end
    end

    property "BC Dates and varying-scale negative Decimals preserve order under encode_scalar_key" do
      date_attr = %Attribute{name: :d, type: Ash.Type.Date, constraints: []}
      dec_attr = %Attribute{name: :dec, type: Ash.Type.Decimal, constraints: []}

      date_gen =
        one_of([
          member_of([~D[-0044-03-15], ~D[-0001-12-31], ~D[0000-01-01], ~D[0001-01-01]]),
          gen all(
                year <- integer(-2000..2100),
                month <- integer(1..12),
                day <- integer(1..28)
              ) do
            Date.new!(year, month, day)
          end
        ])

      dec_gen =
        one_of([
          constant(Decimal.new(0)),
          constant(Decimal.new("-0.000")),
          gen all(
                sign <- member_of([1, -1]),
                coef <- integer(0..9_999_999),
                exp <- integer(-8..8)
              ) do
            Decimal.new(sign, coef, exp)
          end
        ])

      check all(d1 <- date_gen, d2 <- date_gen, x <- dec_gen, y <- dec_gen) do
        assert compare_terms(
                 Codec.encode_scalar_key(date_attr, d1),
                 Codec.encode_scalar_key(date_attr, d2)
               ) == Date.compare(d1, d2)

        assert compare_terms(
                 Codec.encode_scalar_key(dec_attr, x),
                 Codec.encode_scalar_key(dec_attr, y)
               ) == Decimal.compare(x, y)
      end
    end

    property "3-component composite index keys with 0x00 and 0xFF preserve exact tuple order" do
      attrs = [
        %Attribute{name: :k1, type: Ash.Type.Binary, constraints: []},
        %Attribute{name: :k2, type: Ash.Type.Binary, constraints: []},
        %Attribute{name: :n, type: Ash.Type.Integer, constraints: []}
      ]

      edge_bins = [
        <<>>,
        <<0>>,
        <<255>>,
        <<0, 0>>,
        <<0, 255>>,
        <<255, 0>>,
        <<0, 255, 0>>,
        <<0, 0, 255>>
      ]

      byte_bin_gen =
        one_of([
          member_of(edge_bins),
          map(
            list_of(one_of([constant(0), constant(255), integer(97..99)]), max_length: 8),
            &:erlang.list_to_binary/1
          )
        ])

      check all(
              a1 <- byte_bin_gen,
              b1 <- byte_bin_gen,
              n1 <- integer(-100..100),
              a2 <- byte_bin_gen,
              b2 <- byte_bin_gen,
              n2 <- integer(-100..100)
            ) do
        k1 = Codec.encode_index_key(attrs, [a1, b1, n1])
        k2 = Codec.encode_index_key(attrs, [a2, b2, n2])

        assert compare_terms(k1, k2) == compare_terms({a1, b1, n1}, {a2, b2, n2})
      end
    end

    property "empty, nested, and nil-valued :map attributes round-trip losslessly" do
      key_gen = string([?a..?f, ?_], min_length: 1, max_length: 8)

      leaf_gen =
        one_of([
          constant(nil),
          boolean(),
          integer(-10_000..10_000),
          string(:alphanumeric, max_length: 12),
          constant(<<0, "__xitdb_nil__">>),
          constant(<<0, "__xitdb_esc__nested">>),
          constant(%{})
        ])

      nested_map_gen =
        map_of(
          key_gen,
          one_of([
            leaf_gen,
            list_of(leaf_gen, max_length: 4),
            map_of(key_gen, leaf_gen, max_length: 4)
          ]),
          max_length: 6
        )

      {:ok, db} = Xitdb.open(backend: :memory)

      try do
        check all(meta <- one_of([constant(%{}), nested_map_gen]), max_runs: 50) do
          id = "00000000-0000-0000-0000-000000000002"
          {:ok, dumped} = Codec.to_cursor_map(MapPropRecord, %{id: id, raw_bin: nil, meta: meta})

          {:ok, db} =
            Xitdb.transact(db, fn root ->
              put_in(root["recs"][id], dumped)
            end)

          assert {:ok, loaded} = Codec.from_cursor(MapPropRecord, db["recs"][id])
          assert loaded.meta === meta
          assert is_map(loaded.meta)

          for {k, v} <- meta do
            assert Map.has_key?(loaded.meta, k)
            assert loaded.meta[k] === v
          end
        end
      after
        :ok = Xitdb.close(db)
      end
    end

    defp compare_terms(a, b) when a < b, do: :lt
    defp compare_terms(a, b) when a > b, do: :gt
    defp compare_terms(_a, _b), do: :eq
  end
end
