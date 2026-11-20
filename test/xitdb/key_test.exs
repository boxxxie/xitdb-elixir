defmodule Xitdb.KeyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Xitdb.Key

  @min_i64 -9_223_372_036_854_775_808
  @max_i64 9_223_372_036_854_775_807
  @max_u64 18_446_744_073_709_551_615

  defp compare_values(a, b) when a < b, do: :lt
  defp compare_values(a, b) when a > b, do: :gt
  defp compare_values(_a, _b), do: :eq

  property "encode_i64_be/1 and decode_i64_be/1 preserve signed 64-bit ordering" do
    gen_i64 =
      one_of([
        integer(@min_i64..@max_i64),
        member_of([@min_i64, @min_i64 + 1, -100, -1, 0, 1, 100, @max_i64 - 1, @max_i64])
      ])

    check all(a <- gen_i64, b <- gen_i64) do
      bin_a = Key.encode_i64_be(a)
      bin_b = Key.encode_i64_be(b)

      assert byte_size(bin_a) == 8
      assert Key.decode_i64_be(bin_a) == a
      assert Key.decode_i64_be(bin_b) == b
      assert compare_values(bin_a, bin_b) == compare_values(a, b)
    end
  end

  property "encode_u64_be/1 and decode_u64_be/1 preserve full unsigned 64-bit ordering including > max(i64)" do
    gen_u64 =
      one_of([
        integer(0..@max_i64),
        integer((@max_i64 + 1)..@max_u64),
        member_of([0, 1, @max_i64, @max_i64 + 1, @max_u64 - 1, @max_u64])
      ])

    check all(a <- gen_u64, b <- gen_u64) do
      bin_a = Key.encode_u64_be(a)
      bin_b = Key.encode_u64_be(b)

      assert byte_size(bin_a) == 8
      assert Key.decode_u64_be(bin_a) == a
      assert Key.decode_u64_be(bin_b) == b
      assert compare_values(bin_a, bin_b) == compare_values(a, b)
    end
  end

  test "encode_i64_be/1 and encode_u64_be/1 reject out-of-range integers" do
    assert_raise FunctionClauseError, fn -> Key.encode_i64_be(@min_i64 - 1) end
    assert_raise FunctionClauseError, fn -> Key.encode_i64_be(@max_i64 + 1) end
    assert_raise FunctionClauseError, fn -> Key.encode_u64_be(-1) end
    assert_raise FunctionClauseError, fn -> Key.encode_u64_be(@max_u64 + 1) end
  end

  property "encode_f64_be/1 normalizes -0.0 and preserves IEEE-754 float ordering" do
    assert Key.encode_f64_be(-0.0) == Key.encode_f64_be(+0.0)

    check all(
            a <- float(min: -1.0e15, max: 1.0e15),
            b <- float(min: -1.0e15, max: 1.0e15)
          ) do
      assert compare_values(Key.encode_f64_be(a), Key.encode_f64_be(b)) == compare_values(a, b)
    end
  end

  if Code.ensure_loaded?(Decimal) do
    property "encode_decimal_key/1 is scale-invariant and order-preserving" do
      assert Key.encode_decimal_key(Decimal.new("42")) ==
               Key.encode_decimal_key(Decimal.new("42.0000"))

      assert Key.encode_decimal_key(Decimal.new("-0.00")) ==
               Key.encode_decimal_key(Decimal.new("0"))

      dec_gen =
        gen all(
              sign <- member_of(["", "-"]),
              whole <- integer(0..999_999),
              frac <- integer(0..9_999),
              trailing <- string(?0..?0, max_length: 3)
            ) do
          Decimal.new("#{sign}#{whole}.#{frac}#{trailing}")
        end

      check all(a <- dec_gen, b <- dec_gen) do
        assert compare_values(Key.encode_decimal_key(a), Key.encode_decimal_key(b)) ==
                 Decimal.compare(a, b)
      end
    end

    property "encode_fixed_decimal64_be/2 preserves signed and unsigned ordering and round-trips" do
      check all(
              raw_a <- integer(-1_000_000_000..1_000_000_000),
              raw_b <- integer(-1_000_000_000..1_000_000_000)
            ) do
        dec_a = Decimal.new("#{raw_a}") |> Decimal.div(10_000)
        dec_b = Decimal.new("#{raw_b}") |> Decimal.div(10_000)

        k_a = Key.encode_fixed_decimal64_be(dec_a)
        k_b = Key.encode_fixed_decimal64_be(dec_b)

        assert k_a == Key.encode_fixed_decimal64_be({:scaled, raw_a})
        assert compare_values(k_a, k_b) == Decimal.compare(dec_a, dec_b)
        assert Decimal.equal?(Key.decode_fixed_decimal64_be(k_a), dec_a)
      end

      check all(
              raw_a <- one_of([integer(0..1_000_000), integer((@max_i64 + 1)..@max_u64)]),
              raw_b <- one_of([integer(0..1_000_000), integer((@max_i64 + 1)..@max_u64)])
            ) do
        k_a = Key.encode_fixed_decimal64_be({:scaled, raw_a}, signed?: false)
        k_b = Key.encode_fixed_decimal64_be({:scaled, raw_b}, signed?: false)

        assert compare_values(k_a, k_b) == compare_values(raw_a, raw_b)
        assert Key.decode_fixed_decimal64_be(k_a, signed?: false, as: :scaled) == {:scaled, raw_a}
      end
    end

    test "encode_fixed_decimal64_be/2 aligns integers with Decimal equivalents and validates bounds" do
      assert Key.encode_fixed_decimal64_be(12) ==
               Key.encode_fixed_decimal64_be(Decimal.new("12.0000"))

      assert Key.encode_fixed_decimal64_be(12, scale: 100) ==
               Key.encode_fixed_decimal64_be(Decimal.new("12.00"), scale: 100)

      assert Key.encode_fixed_decimal64_be(-5) < Key.encode_fixed_decimal64_be(0)

      assert Key.encode_fixed_decimal64_be(0) <
               Key.encode_fixed_decimal64_be(Decimal.new("0.0001"))

      # Exceeds max(i64) when unscaled? Wait: scaled value > max(i64) requires signed?: false
      large_unsigned_dec = Decimal.new("1000000000000000.1234")
      k_large = Key.encode_fixed_decimal64_be(large_unsigned_dec, signed?: false)

      assert Decimal.equal?(
               Key.decode_fixed_decimal64_be(k_large, signed?: false),
               large_unsigned_dec
             )

      assert_raise ArgumentError, fn ->
        Key.encode_fixed_decimal64_be(large_unsigned_dec, signed?: true)
      end

      assert_raise ArgumentError, fn ->
        Key.encode_fixed_decimal64_be(Decimal.new("-0.0001"), signed?: false)
      end

      assert_raise ArgumentError, fn ->
        Key.encode_fixed_decimal64_be(Decimal.new("1.23456"), scale: 10_000)
      end

      assert_raise ArgumentError, fn ->
        Key.encode_fixed_decimal64_be(10, scale: 25)
      end
    end
  end

  test "stream_range/2 scans :sorted_map ranges in O(log N + K) across binary keys and pagination" do
    {:ok, db} = Xitdb.open(backend: :memory)
    on_exit(fn -> Xitdb.close(db) end)

    signed_entries =
      for v <- [-100, -1, 0, 10, 0x225C, @max_i64] do
        {Key.encode_i64_be(v), %{"val" => v}}
      end

    unsigned_entries =
      for v <- [0, 1, @max_i64, @max_i64 + 1, @max_u64] do
        {Key.encode_u64_be(v), %{"val" => Integer.to_string(v)}}
      end

    {:ok, db} =
      Xitdb.transact(db, %{
        "signed_idx" => Xitdb.sorted_map(signed_entries),
        "unsigned_idx" => Xitdb.sorted_map(unsigned_entries),
        "raw_map" => %{"a" => 1}
      })

    signed_cur = Xitdb.db(db)["signed_idx"]
    unsigned_cur = Xitdb.db(db)["unsigned_idx"]

    assert Enum.map(
             Key.stream_range(signed_cur,
               min: Key.encode_i64_be(-1),
               min_inclusive?: false,
               max: Key.encode_i64_be(0x225C),
               max_inclusive?: true,
               page_size: 2
             ),
             fn {_k, cur} -> cur["val"] end
           ) == [0, 10, 0x225C]

    assert Enum.map(
             Key.stream_range(unsigned_cur,
               min: Key.encode_u64_be(@max_i64),
               min_inclusive?: true,
               page_size: 2
             ),
             fn {k, cur} -> {Key.decode_u64_be(k), cur["val"]} end
           ) == [
             {@max_i64, Integer.to_string(@max_i64)},
             {@max_i64 + 1, Integer.to_string(@max_i64 + 1)},
             {@max_u64, Integer.to_string(@max_u64)}
           ]

    assert_raise ArgumentError, ~r/:sorted_map/, fn ->
      Key.stream_range(Xitdb.db(db)["raw_map"]) |> Enum.to_list()
    end
  end
end
