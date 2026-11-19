if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.TypesTest do
    use ExUnit.Case, async: true

    require Ash.Query

    alias Xitdb.Ash.{Store, TestSandbox}
    alias Xitdb.Ash.Types.{FixedDecimal64, RangedUnit}

    defmodule TypesStore do
      use Xitdb.Ash.Store
    end

    defmodule LedgerEntry do
      use Ash.Resource,
        domain: Xitdb.Ash.TypesTest.TypesDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store TypesStore
        collection :ledger_entries
        index [:signed_price]
        index [:tagged_amount]
        index [:unsigned_qty]
      end

      attributes do
        integer_primary_key(:id)

        attribute :signed_price, FixedDecimal64 do
          public?(true)
          constraints(scale: 10_000, signed?: true, representation: :integer)
        end

        attribute :tagged_amount, FixedDecimal64 do
          public?(true)
          constraints(scale: 10_000, signed?: true, representation: :tagged)
        end

        attribute :unsigned_qty, FixedDecimal64 do
          public?(true)
          constraints(scale: 10_000, signed?: false, representation: :integer)
        end

        attribute :tagged_u_qty, FixedDecimal64 do
          public?(true)
          constraints(scale: 10_000, signed?: false, representation: :tagged)
        end
      end

      actions do
        defaults([:read, :destroy, create: :*, update: :*])
      end
    end

    defmodule FundMandate do
      use Ash.Resource,
        domain: Xitdb.Ash.TypesTest.TypesDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store TypesStore
        collection :fund_mandates
        index [:ticket_min_d64]
        index [:ticket_max_d64]
      end

      attributes do
        integer_primary_key(:id)
        attribute(:name, :string, allow_nil?: false, public?: true)
        attribute(:ticket_size, RangedUnit, public?: true)

        attribute :ticket_min_d64, FixedDecimal64 do
          public?(true)
          constraints(scale: 10_000, signed?: true, representation: :integer)
        end

        attribute :ticket_max_d64, FixedDecimal64 do
          public?(true)
          constraints(scale: 10_000, signed?: true, representation: :integer)
        end

        attribute(:ticket_bound, :string, public?: true)
        attribute(:ticket_unit, :string, public?: true)
      end

      actions do
        defaults([:read, :destroy, create: :*, update: :*])
      end
    end

    defmodule TypesDomain do
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        resource(LedgerEntry)
        resource(FundMandate)
      end
    end

    setup_all do
      TestSandbox.init()
      {:ok, pid} = Store.start_link(name: TypesStore, path: :memory, domains: [TypesDomain])

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      :ok
    end

    setup do
      :ok = TestSandbox.checkout([TypesStore])
      on_exit(fn -> TestSandbox.checkin([TypesStore]) end)
      :ok
    end

    describe "Xitdb.Ash.Types.FixedDecimal64" do
      @max_i64 9_223_372_036_854_775_807
      @max_u64 18_446_744_073_709_551_615

      test "to_scaled/2, from_scaled/2, cast_input/2, and constraints validation" do
        assert FixedDecimal64.to_scaled(Decimal.new("12.3456")) == 123_456
        assert FixedDecimal64.to_scaled(12) == 120_000
        assert FixedDecimal64.to_scaled({:scaled, -42}) == -42
        assert Decimal.equal?(FixedDecimal64.from_scaled(123_456), Decimal.new("12.3456"))
        assert Decimal.equal?(FixedDecimal64.from_scaled(-120_000, 100), Decimal.new("-1200.00"))

        assert {:ok, opts} = Ash.Type.init(FixedDecimal64, scale: 100, signed?: false)
        assert opts[:scale] == 100
        assert opts[:signed?] == false
        assert opts[:representation] == :integer

        assert {:error, _} = Ash.Type.init(FixedDecimal64, scale: 25)

        assert {:ok, d} = Ash.Type.cast_input(FixedDecimal64, "12.3400", scale: 10_000)
        assert Decimal.equal?(d, Decimal.new("12.34"))

        assert {:ok, d_int} = Ash.Type.cast_input(FixedDecimal64, 50, scale: 10_000)
        assert Decimal.equal?(d_int, Decimal.new("50"))

        assert {:error, _} = Ash.Type.cast_input(FixedDecimal64, "1.23456", scale: 10_000)
        assert {:error, _} = Ash.Type.cast_input(FixedDecimal64, "-0.0001", signed?: false)
      end

      test "stores :integer and :tagged slots faithfully and executes Ash.Query range scans across i64 and > max(i64)" do
        huge_u64_dec = Decimal.new("1500000000000000.1234")
        max_u64_dec = FixedDecimal64.from_scaled(@max_u64, 10_000)

        e1 =
          Ash.create!(
            LedgerEntry,
            %{
              signed_price: Decimal.new("-10.5000"),
              tagged_amount: Decimal.new("-10.5000"),
              unsigned_qty: Decimal.new("5.0000"),
              tagged_u_qty: Decimal.new("5.0000")
            },
            domain: TypesDomain
          )

        e2 =
          Ash.create!(
            LedgerEntry,
            %{
              signed_price: Decimal.new("0.2500"),
              tagged_amount: Decimal.new("0.2500"),
              unsigned_qty: FixedDecimal64.from_scaled(@max_i64 + 1, 10_000),
              tagged_u_qty: FixedDecimal64.from_scaled(@max_i64 + 1, 10_000)
            },
            domain: TypesDomain
          )

        e3 =
          Ash.create!(
            LedgerEntry,
            %{
              signed_price: Decimal.new("250.7500"),
              tagged_amount: Decimal.new("250.7500"),
              unsigned_qty: huge_u64_dec,
              tagged_u_qty: max_u64_dec
            },
            domain: TypesDomain
          )

        # Inspect physical Xitdb storage slots directly
        db = Store.current_db(TypesStore)
        raw1 = db["ledger_entries"][to_string(e1.id)]
        raw2 = db["ledger_entries"][to_string(e2.id)]
        raw3 = db["ledger_entries"][to_string(e3.id)]

        assert raw1["signed_price"] == -105_000
        assert raw1["tagged_amount"] == {:tagged, "d6", <<-105_000::signed-big-64>>}
        assert raw1["unsigned_qty"] == 50_000

        above_i64 = @max_i64 + 1
        assert raw2["unsigned_qty"] == {:tagged, "u8", <<above_i64::unsigned-big-64>>}
        assert raw2["tagged_u_qty"] == {:tagged, "d6", <<above_i64::unsigned-big-64>>}
        assert raw3["tagged_u_qty"] == {:tagged, "d6", <<@max_u64::unsigned-big-64>>}

        # Ash read round-trips %Decimal{} accurately
        reloaded3 = Ash.get!(LedgerEntry, e3.id, domain: TypesDomain)
        assert Decimal.equal?(reloaded3.signed_price, Decimal.new("250.75"))
        assert Decimal.equal?(reloaded3.unsigned_qty, huge_u64_dec)
        assert Decimal.equal?(reloaded3.tagged_u_qty, max_u64_dec)

        # Indexed range scans on signed :integer representation
        pos_entries =
          LedgerEntry
          |> Ash.Query.filter(signed_price >= 0 and signed_price < ^Decimal.new("250.75"))
          |> Ash.read!(domain: TypesDomain)

        assert Enum.map(pos_entries, & &1.id) == [e2.id]

        neg_entries =
          LedgerEntry
          |> Ash.Query.filter(signed_price < 0)
          |> Ash.read!(domain: TypesDomain)

        assert Enum.map(neg_entries, & &1.id) == [e1.id]

        # Indexed range scans on :tagged representation
        tagged_high =
          LedgerEntry
          |> Ash.Query.filter(tagged_amount > ^Decimal.new("0.25"))
          |> Ash.read!(domain: TypesDomain)

        assert Enum.map(tagged_high, & &1.id) == [e3.id]

        # Indexed range scans on unsigned u64 exceeding max(i64)
        u_above =
          LedgerEntry
          |> Ash.Query.filter(unsigned_qty > ^FixedDecimal64.from_scaled(@max_i64, 10_000))
          |> Ash.Query.sort(unsigned_qty: :asc)
          |> Ash.read!(domain: TypesDomain)

        assert Enum.map(u_above, & &1.id) == [e2.id, e3.id]
      end
    end

    describe "Xitdb.Ash.Types.RangedUnit" do
      test "round-trips through Ash resource storage, Xitdb.Encoder, and checks overlaps?/2" do
        ru_closed = %RangedUnit{
          bound_kind: :closed_range,
          dimension: :currency,
          currency: :usd,
          min_val: Decimal.new("250000.00"),
          max_val: Decimal.new("2000000")
        }

        ru_exact = %RangedUnit{
          bound_kind: :exact,
          dimension: :currency,
          currency: :usd,
          min_val: Decimal.new("2000000")
        }

        ru_gt = %RangedUnit{
          bound_kind: :greater_than,
          dimension: :currency,
          currency: :usd,
          min_val: Decimal.new("2000000")
        }

        ru_at_least = %RangedUnit{
          bound_kind: :at_least,
          dimension: :currency,
          currency: :usd,
          min_val: Decimal.new("2000000")
        }

        ru_eur = %RangedUnit{
          bound_kind: :closed_range,
          dimension: :currency,
          currency: :eur,
          min_val: Decimal.new("100000"),
          max_val: Decimal.new("500000")
        }

        ru_ratio = %RangedUnit{
          bound_kind: :closed_range,
          dimension: :ratio,
          min_val: Decimal.new("1.5"),
          max_val: Decimal.new("3.0")
        }

        ru_dirty = %RangedUnit{
          bound_kind: :unparsed_dirty,
          dimension: :currency,
          currency: :usd
        }

        assert RangedUnit.overlaps?(ru_closed, ru_exact)
        assert not RangedUnit.overlaps?(ru_closed, ru_gt)
        assert RangedUnit.overlaps?(ru_closed, ru_at_least)
        assert not RangedUnit.overlaps?(ru_closed, ru_eur)
        assert not RangedUnit.overlaps?(ru_closed, ru_ratio)
        assert not RangedUnit.overlaps?(ru_closed, ru_dirty)

        # Direct Xitdb.Encoder support outside Ash
        {:ok, raw_db} = Xitdb.open(backend: :memory)
        on_exit(fn -> Xitdb.close(raw_db) end)
        {:ok, raw_db} = Xitdb.transact(raw_db, %{"ru" => ru_closed})
        stored_map = Xitdb.materialize(Xitdb.db(raw_db)["ru"])
        assert {:ok, loaded_ru} = Ash.Type.cast_stored(RangedUnit, stored_map, [])
        assert Ash.Type.equal?(RangedUnit, loaded_ru, ru_closed)

        # Decomposition helpers (unprefixed, prefixed, nil, and sentinel)
        assert %{
                 min_d64: min_d,
                 max_d64: max_d,
                 bound: "closed_range",
                 unit: "usd"
               } = RangedUnit.to_indexed_fields(ru_closed)

        assert Decimal.equal?(min_d, Decimal.new("250000"))
        assert Decimal.equal?(max_d, Decimal.new("2000000"))

        assert %{
                 ticket_min_d64: nil,
                 ticket_max_d64: nil,
                 ticket_bound: nil,
                 ticket_unit: nil
               } = RangedUnit.to_indexed_fields(nil, :ticket)

        assert %{
                 ticket_min_d64: s_min,
                 ticket_max_d64: s_max,
                 ticket_bound: "at_least",
                 ticket_unit: "usd"
               } = RangedUnit.to_indexed_fields(ru_at_least, :ticket, unbounded: :sentinel)

        assert Decimal.equal?(s_min, Decimal.new("2000000"))
        assert Decimal.gt?(s_max, s_min)

        # Seed Ash resource with decomposed indexed bounds and run interval overlap query
        seed_fund = fn name, ru ->
          attrs =
            ru
            |> RangedUnit.to_indexed_fields(:ticket, unbounded: :sentinel)
            |> Map.merge(%{name: name, ticket_size: ru})

          Ash.create!(FundMandate, attrs, domain: TypesDomain)
        end

        f_seed =
          seed_fund.("Seed", %RangedUnit{
            bound_kind: :closed_range,
            dimension: :currency,
            currency: :usd,
            min_val: Decimal.new("100000"),
            max_val: Decimal.new("500000")
          })

        f_series_a = seed_fund.("Series A", ru_closed)
        f_growth = seed_fund.("Growth", ru_at_least)

        reloaded_a = Ash.get!(FundMandate, f_series_a.id, domain: TypesDomain)
        assert Ash.Type.equal?(RangedUnit, reloaded_a.ticket_size, ru_closed)
        assert reloaded_a.ticket_unit == "usd"

        q_min = Decimal.new("400000")
        q_max = Decimal.new("600000")

        matching_low =
          FundMandate
          |> Ash.Query.filter(ticket_min_d64 <= ^q_max and ticket_max_d64 >= ^q_min)
          |> Ash.Query.sort(id: :asc)
          |> Ash.read!(domain: TypesDomain)

        assert Enum.map(matching_low, & &1.name) == [f_seed.name, f_series_a.name]

        q2_min = Decimal.new("1500000")
        q2_max = Decimal.new("3000000")

        matching_high =
          FundMandate
          |> Ash.Query.filter(ticket_min_d64 <= ^q2_max and ticket_max_d64 >= ^q2_min)
          |> Ash.Query.sort(id: :asc)
          |> Ash.read!(domain: TypesDomain)

        assert Enum.map(matching_high, & &1.name) == [f_series_a.name, f_growth.name]
      end
    end
  end
end
