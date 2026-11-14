if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.CodecPropertiesTest do
    use ExUnit.Case, async: true
    use ExUnitProperties

    alias Ash.Resource.Attribute
    alias Xitdb.Ash.Codec
    alias Xitdb.TestSupport.MemberProfile

    @min_i64 -9_223_372_036_854_775_808
    @max_i64 9_223_372_036_854_775_807

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
            MemberProfile,
            fake_identity,
            %{full_name: f1, headline: h1},
            t1
          )

        {:ok, k2} =
          Codec.encode_identity_key(
            MemberProfile,
            fake_identity,
            %{full_name: f2, headline: h2},
            t2
          )

        if {t1, f1, h1} == {t2, f2, h2} do
          assert k1 == k2
        else
          assert k1 != k2
        end
      end
    end

    defp compare_terms(a, b) when a < b, do: :lt
    defp compare_terms(a, b) when a > b, do: :gt
    defp compare_terms(_a, _b), do: :eq
  end
end
