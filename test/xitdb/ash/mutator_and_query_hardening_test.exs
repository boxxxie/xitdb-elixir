if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.MutatorAndQueryHardeningTest do
    use ExUnit.Case, async: true

    require Ash.Query
    import Ash.Expr

    alias Xitdb.Ash.{DataLayer, Mutator, Store, TestSandbox}

    defmodule HardeningStore do
      use Xitdb.Ash.Store
    end

    defmodule Item do
      use Ash.Resource,
        domain: Xitdb.Ash.MutatorAndQueryHardeningTest.Domain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store HardeningStore
        collection :h_items
        index([:category, :priority])
        index([:status])
      end

      attributes do
        attribute(:id, :integer,
          primary_key?: true,
          allow_nil?: false,
          generated?: true,
          writable?: true,
          public?: true
        )

        attribute(:code, :ci_string, allow_nil?: false, public?: true)
        attribute(:category, :string, default: "general", public?: true)
        attribute(:priority, :integer, default: 0, public?: true)
        attribute(:status, :atom, default: :active, public?: true)
        attribute(:label, :string, public?: true)
      end

      identities do
        identity :unique_active_code, [:code] do
          where expr(status == :active)
        end
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:id, :code, :category, :priority, :status, :label])
        end

        create :upsert_by_id do
          accept([:id, :code, :category, :priority, :status, :label])
          upsert?(true)
          upsert_fields([:label, :priority])
        end

        create :upsert_by_code do
          accept([:code, :category, :priority, :status, :label])
          upsert?(true)
          upsert_identity(:unique_active_code)
          upsert_fields([:label, :priority])
        end

        update :update do
          primary?(true)
          accept([:label, :priority, :status, :category])
        end
      end
    end

    defmodule Domain do
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        resource(Item)
      end
    end

    setup_all do
      TestSandbox.init()
      {:ok, pid} = Store.start_link(name: HardeningStore, path: :memory, domains: [Domain])

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
      :ok = TestSandbox.checkout([HardeningStore])
      :ok
    end

    test "Mutator.upsert/4 directly handles PK upsert, identity upsert, and arbitrary key upsert" do
      cs1 =
        Ash.Changeset.for_create(Item, :create, %{id: 1, code: "A1", label: "v1", priority: 1})

      assert {:ok, rec1} = Mutator.upsert(Item, cs1, [:id])
      assert rec1.id == 1
      assert rec1.label == "v1"

      # Upsert by PK updates existing record
      cs2 =
        Ash.Changeset.for_create(Item, :upsert_by_id, %{
          id: 1,
          code: "A1",
          label: "v2",
          priority: 2
        })

      assert {:ok, rec2} = Mutator.upsert(Item, cs2, [:id])
      assert rec2.id == 1
      assert rec2.label == "v2"
      assert rec2.priority == 2

      # Upsert by identity name atom
      cs3 =
        Ash.Changeset.for_create(Item, :upsert_by_code, %{
          code: "a1",
          label: "v3",
          priority: 3
        })

      assert {:ok, rec3} = Mutator.upsert(Item, cs3, [:code], :unique_active_code)
      assert rec3.id == 1
      assert rec3.label == "v3"

      # Upsert by arbitrary non-identity key [:category, :label]
      cs4 =
        Ash.Changeset.for_create(Item, :upsert_by_id, %{
          code: "A1",
          category: "general",
          label: "v3",
          priority: 99
        })

      assert {:ok, rec4} = Mutator.upsert(Item, cs4, [:category, :label])
      assert rec4.id == 1
      assert rec4.priority == 99
    end

    test "bulk_create with conditional identities and staged upserts handles skip, collision, and intra-batch updates" do
      # Inactive records skip the conditional :unique_active_code identity
      %Ash.BulkResult{status: :success, records: inactive} =
        Ash.bulk_create!(
          [
            %{code: "DUP", status: :inactive, label: "i1"},
            %{code: "DUP", status: :inactive, label: "i2"}
          ],
          Item,
          :create,
          domain: Domain,
          return_records?: true
        )

      assert length(inactive) == 2

      # Active records with duplicate code fail intra-batch identity tracking
      err_res =
        Ash.bulk_create(
          [
            %{code: "ACT", status: :active, label: "a1"},
            %{code: "act", status: :active, label: "a2"}
          ],
          Item,
          :create,
          domain: Domain,
          return_errors?: true
        )

      assert err_res.status == :error

      # Bulk upsert by PK with intra-batch duplicate PK updates staged record
      %Ash.BulkResult{status: :success, records: upserted} =
        Ash.bulk_create!(
          [
            %{id: 10, code: "U10", label: "first", priority: 1},
            %{id: 10, code: "U10", label: "second", priority: 2},
            %{id: 11, code: "U11", label: "other", priority: 3}
          ],
          Item,
          :upsert_by_id,
          domain: Domain,
          upsert_fields: [:label, :priority],
          return_records?: true
        )

      assert length(upserted) == 3
      assert Ash.get!(Item, 10, domain: Domain).label == "second"
      assert Ash.get!(Item, 10, domain: Domain).priority == 2
      assert Ash.get!(Item, 11, domain: Domain).label == "other"
    end

    test "Query limit/offset/sort/filter boundaries and DataLayer.calculate with/without record and time-travel context" do
      # Empty collection aggregates
      assert Ash.count!(Item, domain: Domain) == 0

      items =
        for i <- 1..5 do
          Ash.create!(
            Item,
            %{
              code: "C#{i}",
              category: if(rem(i, 2) == 0, do: "even", else: "odd"),
              priority: i * 10,
              label: "Item #{i}"
            },
            domain: Domain
          )
        end

      m_after_seed = Store.root(HardeningStore).moment
      assert length(items) == 5

      # Exact limit / offset boundaries: 0, 1, n - 1, n, n + 1
      assert [] ==
               Item
               |> Ash.Query.sort(priority: :asc)
               |> Ash.Query.limit(0)
               |> Ash.read!(domain: Domain)

      assert [10] ==
               Item
               |> Ash.Query.sort(priority: :asc)
               |> Ash.Query.limit(1)
               |> Ash.read!(domain: Domain)
               |> Enum.map(& &1.priority)

      assert [50] ==
               Item
               |> Ash.Query.sort(priority: :asc)
               |> Ash.Query.offset(4)
               |> Ash.read!(domain: Domain)
               |> Enum.map(& &1.priority)

      assert [] ==
               Item
               |> Ash.Query.sort(priority: :asc)
               |> Ash.Query.offset(5)
               |> Ash.read!(domain: Domain)

      assert [] ==
               Item
               |> Ash.Query.sort(priority: :asc)
               |> Ash.Query.offset(6)
               |> Ash.read!(domain: Domain)

      # Desc sort + range filter boundaries (>, >=, <, <=)
      assert [40, 30, 20] ==
               Item
               |> Ash.Query.filter(priority >= 20 and priority <= 40)
               |> Ash.Query.sort(priority: :desc)
               |> Ash.read!(domain: Domain)
               |> Enum.map(& &1.priority)

      assert [30] ==
               Item
               |> Ash.Query.filter(priority > 20 and priority < 40)
               |> Ash.read!(domain: Domain)
               |> Enum.map(& &1.priority)

      # Update one item and verify time-travel context overrides (data_layer: %{as_of: m} and xitdb: %{moment: m})
      first = hd(items)
      Ash.update!(first, %{priority: 999}, domain: Domain)

      assert [10] ==
               Item
               |> Ash.Query.filter(id == ^first.id)
               |> Ash.Query.set_context(%{data_layer: %{as_of: m_after_seed}})
               |> Ash.read!(domain: Domain)
               |> Enum.map(& &1.priority)

      assert [10] ==
               Item
               |> Ash.Query.filter(id == ^first.id)
               |> Ash.Query.set_context(%{xitdb: %{moment: m_after_seed}})
               |> Ash.read!(domain: Domain)
               |> Enum.map(& &1.priority)

      # DataLayer.calculate/3 without record (pure expression) and with record
      assert {:ok, [3]} == DataLayer.calculate(Item, [expr(1 + 2)], %{})
      assert {:ok, [true]} == DataLayer.calculate(Item, [expr(priority == 10)], %{record: first})
      assert {:ok, [false]} == DataLayer.calculate(Item, [expr(priority == 20)], %{record: first})
    end
  end
end
