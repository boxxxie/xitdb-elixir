defmodule Xitdb.Ash.CompanionAndTxForTest do
  use ExUnit.Case, async: true

  if Code.ensure_loaded?(Ash.Resource) do
    defmodule MutualUser do
      use Ash.Resource, domain: nil, extensions: [Xitdb.Ash.Resource]

      xitdb do
        collection :users
        companion_resource Xitdb.Ash.CompanionAndTxForTest.MutualProfile
        editable_fields [:email]
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:email, :string, public?: true)
      end
    end

    defmodule MutualProfile do
      use Ash.Resource, domain: nil, extensions: [Xitdb.Ash.Resource]

      xitdb do
        collection :users
        companion_resource MutualUser
        editable_fields [:bio]
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:bio, :string, public?: true)
      end
    end

    test "mutual companion_resource declarations compile without deadlock and preserve ordering" do
      alias Xitdb.Ash.Info

      assert Info.editable_field_strings([MutualUser, MutualProfile]) == ["email", "bio"]
      assert Info.editable_field_strings([MutualProfile, MutualUser]) == ["bio", "email"]
      assert Info.pull_pattern_for([MutualUser, MutualProfile]) == "{id, email, bio}"

      assert :persistent_term.get(
               {Info, :pair, :pull_pattern, MutualUser, MutualProfile},
               nil
             ) == "{id, email, bio}"

      assert :ok == Info.__purge_pair_cache__(MutualUser)

      assert :persistent_term.get(
               {Info, :pair, :pull_pattern, MutualUser, MutualProfile},
               :purged
             ) == :purged
    end
  end

  test "tx_for raises CompileError with caller line on missing module or missing __xitdb_collection__" do
    assert_raise CompileError, ~r/could not load schema module/, fn ->
      Code.compile_quoted(
        quote do
          defmodule Xitdb.Ash.CompanionAndTxForTest.MissingSchemaCaller do
            use Xitdb.DSL
            def run(db), do: tx_for(db, NonExistentSchemaModule, do: :ok)
          end
        end
      )
    end
  end
end
