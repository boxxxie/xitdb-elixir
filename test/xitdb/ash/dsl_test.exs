if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.DslTest do
    use ExUnit.Case, async: true

    alias Spark.Error.DslError
    alias Xitdb.Ash.{Index, Info, NestedIn, Reference, SearchField}

    defmodule StoreA do
    end

    defmodule StoreB do
    end

    defmodule Event do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [Xitdb.Ash.Dsl]

      xitdb do
        store StoreA
        collection :events
        counted_set_fields [:tags]
        index :status
        index [:status, :inserted_at], name: :idx_status_recent
        search_field :title, boost: 2.5
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:title, :string, public?: true)
        attribute(:status, :atom, default: :draft, public?: true)
        attribute(:tags, {:array, :string}, default: [], public?: true)
        create_timestamp(:inserted_at)
      end
    end

    defmodule Session do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [Xitdb.Ash.Dsl]

      xitdb do
        store StoreA
        collection :sessions
        nested_in :events, foreign_key: :event_id, path: :sessions, cardinality: :many

        references do
          reference :event, on_delete: :delete
        end
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:title, :string, public?: true)
      end

      relationships do
        belongs_to(:event, Event, allow_nil?: false, attribute_type: :uuid)
      end
    end

    defmodule DedupAndDisabledRelIndexResource do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [Xitdb.Ash.Dsl]

      xitdb do
        store StoreA
        collection :dedup_children
        index_relationships? false
        index [:event_id, :title], name: :idx_event_title
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:title, :string, public?: true)
      end

      relationships do
        belongs_to(:event, Event, attribute_type: :uuid)
        belongs_to(:parent_session, Session, attribute_type: :uuid)
      end
    end

    defmodule DeduplicatedAutoFkResource do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [Xitdb.Ash.Dsl]

      xitdb do
        store StoreA
        collection :auto_dedup_children
        index [:event_id, :title], name: :idx_event_title
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:title, :string, public?: true)
      end

      relationships do
        belongs_to(:event, Event, attribute_type: :uuid)
        belongs_to(:parent_session, Session, attribute_type: :uuid)
      end
    end

    defmodule LegacyMdmResource do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [Xitdb.Ash.Resource]

      xitdb do
        store StoreA
        collection :legacy_orgs
        editable_fields [:domain]
        indexes(domain: "domain->id")
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:domain, :string, public?: true)
      end
    end

    defmodule NonXitdbResource do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false

      attributes do
        uuid_primary_key(:id)
      end
    end

    defmodule CrossStoreNothingAllowed do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [Xitdb.Ash.Dsl]

      xitdb do
        store StoreB
        collection :cross_store_nothing
      end

      attributes do
        uuid_primary_key(:id)
      end

      relationships do
        belongs_to(:event, Event, attribute_type: :uuid)
        belongs_to(:external, NonXitdbResource, attribute_type: :uuid)
      end
    end

    test "BuildIndexPlan persists indexes, nesting plan, search fields, references, and tx_for hooks" do
      assert Info.store!(Event) == StoreA
      assert Info.collection!(Event) == :events
      assert Info.counted_set_fields(Event) == [:tags]
      assert Info.index_relationships?(Event) == true
      assert [%SearchField{field: :title, boost: 2.5}] = Info.search_fields(Event)

      assert [
               %Index{fields: [:status], name: nil},
               %Index{fields: [:status, :inserted_at], name: :idx_status_recent}
             ] = Info.indexes_for_field(Event, :status)

      assert Event.__xitdb_store__() == StoreA
      assert Event.__xitdb_collection__() == :events
      assert Event.__xitdb_indexes__() == [{:events, :status, "attr_status"}]

      assert %NestedIn{parent_collection: :events, foreign_key: :event_id, path: :sessions} =
               Info.nested_in(Session)

      assert Info.nested_mappings(Session) == []
      assert Info.nested?(Session) == true

      assert [%Index{fields: [:event_id], name: nil}] = Info.indexes(Session)
      assert [%Reference{relationship: :event, on_delete: :delete}] = Info.references(Session)
      assert Info.references(CrossStoreNothingAllowed) == []
    end

    test "auto-generates belongs_to indexes unless covered or index_relationships? is false" do
      assert [%Index{fields: [:event_id, :title], name: :idx_event_title}] =
               Info.indexes(DedupAndDisabledRelIndexResource)

      assert Info.index_relationships?(DedupAndDisabledRelIndexResource) == false

      # `event_id` is already covered as leading field of [:event_id, :title], while
      # `parent_session_id` gets auto-generated.
      assert [
               %Index{fields: [:event_id, :title], name: :idx_event_title},
               %Index{fields: [:parent_session_id], name: nil}
             ] = Info.indexes(DeduplicatedAutoFkResource)
    end

    test "tx_for works seamlessly across both Xitdb.Ash.Dsl and Xitdb.Ash.Resource modules" do
      use Xitdb.DSL

      {:ok, db} = Xitdb.open(backend: :memory)

      try do
        {:ok, updated_db} =
          tx_for db, [Event, LegacyMdmResource] do
            init_col events, :hash_map
            init_col legacy_orgs, :hash_map
            put events["e1"].id, "e1"
            put events["e1"].status, "live"
            put events["e1"].title, "Forum"
            put legacy_orgs["o1"].id, "o1"
            put legacy_orgs["o1"].domain, "caasa.ca"
          end

        assert updated_db["attr_status"]["live"] == "e1"
        assert updated_db["domain->id"]["caasa.ca"] == "o1"
      after
        Xitdb.close(db)
      end
    end

    test "rejects composite primary keys at compile time" do
      assert_raise DslError, ~r/composite primary keys are not yet supported/, fn ->
        Code.compile_string("""
        defmodule Xitdb.Ash.DslTest.CompositePkResource do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [Xitdb.Ash.Dsl]

          xitdb do
            store Xitdb.Ash.DslTest.StoreA
            collection :memberships
          end

          attributes do
            attribute :org_id, :uuid, primary_key?: true, allow_nil?: false
            attribute :user_id, :uuid, primary_key?: true, allow_nil?: false
          end
        end
        """)
      end
    end

    test "rejects unknown index fields, duplicate indexes, bad counted_set_fields, and unknown editable attributes" do
      assert_raise DslError, ~r/unknown attribute\(s\) \[:missing_col\] in `xitdb.index`/, fn ->
        Code.compile_string("""
        defmodule Xitdb.Ash.DslTest.UnknownIndexAttr do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [Xitdb.Ash.Dsl]

          xitdb do
            store Xitdb.Ash.DslTest.StoreA
            collection :bad_idx_attr
            index :missing_col
          end

          attributes do
            uuid_primary_key :id
          end
        end
        """)
      end

      assert_raise DslError, ~r/duplicate `index \[:status\]`/, fn ->
        Code.compile_string("""
        defmodule Xitdb.Ash.DslTest.DupIndexFields do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [Xitdb.Ash.Dsl]

          xitdb do
            store Xitdb.Ash.DslTest.StoreA
            collection :dup_idx
            index :status
            index :status, name: :other_status
          end

          attributes do
            uuid_primary_key :id
            attribute :status, :atom, public?: true
          end
        end
        """)
      end

      assert_raise DslError, ~r/colliding index slot name "same_name"/, fn ->
        Code.compile_string("""
        defmodule Xitdb.Ash.DslTest.CollidingIndexName do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [Xitdb.Ash.Dsl]

          xitdb do
            store Xitdb.Ash.DslTest.StoreA
            collection :collide_idx
            index :a, name: :same_name
            index :b, name: "same_name"
          end

          attributes do
            uuid_primary_key :id
            attribute :a, :string, public?: true
            attribute :b, :string, public?: true
          end
        end
        """)
      end

      assert_raise DslError,
                   ~r/counted_set_fields entry :score must have `\{:array, inner_type\}`/,
                   fn ->
                     Code.compile_string("""
                     defmodule Xitdb.Ash.DslTest.BadCountedSetType do
                       use Ash.Resource,
                         domain: nil,
                         validate_domain_inclusion?: false,
                         extensions: [Xitdb.Ash.Dsl]

                       xitdb do
                         store Xitdb.Ash.DslTest.StoreA
                         collection :bad_cs
                         counted_set_fields [:score]
                       end

                       attributes do
                         uuid_primary_key :id
                         attribute :score, :integer, public?: true
                       end
                     end
                     """)
                   end

      assert_raise DslError, ~r/unknown attribute\(s\) \[:ghost\] in `editable_fields`/, fn ->
        Code.compile_string("""
        defmodule Xitdb.Ash.DslTest.BadEditableAttr do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [Xitdb.Ash.Dsl]

          xitdb do
            store Xitdb.Ash.DslTest.StoreA
            collection :bad_edit
            editable_fields [:ghost]
          end

          attributes do
            uuid_primary_key :id
          end
        end
        """)
      end
    end

    # Spark runs `Spark.Dsl.Verifier`s inside `@after_verify`, where errors surface as compiler
    # diagnostics instead of raised `DslError`s, so verifier tests assert on diagnostics and call
    # `verify/1` directly. Transformer (`BuildIndexPlan`) tests keep using `assert_raise`.
    defp assert_verifier_error(code_str, mod_name, verifier_mod, expected_regex) do
      {compiled, diagnostics} =
        Code.with_diagnostics(fn ->
          Code.compile_string(code_str)
        end)

      assert Enum.any?(diagnostics, &(&1.message =~ expected_regex))
      assert Enum.any?(compiled, fn {mod, _bin} -> mod == mod_name end)

      assert {:error, %DslError{message: msg}} =
               verifier_mod.verify(mod_name.spark_dsl_config())

      assert msg =~ expected_regex
    end

    test "rejects SQL fragment(...) in calculations, aggregates, relationship filters, actions, and policies" do
      assert_verifier_error(
        """
        defmodule Xitdb.Ash.DslTest.BadFragmentCalc do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [Xitdb.Ash.Dsl]

          xitdb do
            store Xitdb.Ash.DslTest.StoreA
            collection :bad_calcs
          end

          attributes do
            uuid_primary_key :id
            attribute :name, :string, public?: true
          end

          calculations do
            calculate :lower_name, :string, expr(fragment("lower(?)", name))
          end
        end
        """,
        Xitdb.Ash.DslTest.BadFragmentCalc,
        Xitdb.Ash.Verifiers.VerifyNoSqlFragments,
        ~r/SQL `fragment\(\.\.\.\)` is not supported/
      )

      assert_verifier_error(
        """
        defmodule Xitdb.Ash.DslTest.BadFragmentAggAndRel do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [Xitdb.Ash.Dsl]

          xitdb do
            store Xitdb.Ash.DslTest.StoreA
            collection :bad_aggs
          end

          attributes do
            uuid_primary_key :id
          end

          relationships do
            has_many :events, Xitdb.Ash.DslTest.Event do
              no_attributes? true
              filter expr(fragment("true"))
            end
          end
        end
        """,
        Xitdb.Ash.DslTest.BadFragmentAggAndRel,
        Xitdb.Ash.Verifiers.VerifyNoSqlFragments,
        ~r/SQL `fragment\(\.\.\.\)` is not supported/
      )

      assert_verifier_error(
        """
        defmodule Xitdb.Ash.DslTest.BadFragmentPolicy do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            authorizers: [Ash.Policy.Authorizer],
            extensions: [Xitdb.Ash.Dsl]

          xitdb do
            store Xitdb.Ash.DslTest.StoreA
            collection :bad_policies
          end

          attributes do
            uuid_primary_key :id
            attribute :name, :string, public?: true
          end

          policies do
            policy always() do
              authorize_if expr(fragment("1 = 1"))
            end
          end
        end
        """,
        Xitdb.Ash.DslTest.BadFragmentPolicy,
        Xitdb.Ash.Verifiers.VerifyNoSqlFragments,
        ~r/SQL `fragment\(\.\.\.\)` is not supported/
      )
    end

    test "rejects unknown reference names, non-nullable :nilify, cross-store cascades, and mismatched nested_in parents" do
      assert_verifier_error(
        """
        defmodule Xitdb.Ash.DslTest.UnknownRefResource do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [Xitdb.Ash.Dsl]

          xitdb do
            store Xitdb.Ash.DslTest.StoreA
            collection :bad_refs

            references do
              reference :typo_rel, on_delete: :delete
            end
          end

          attributes do
            uuid_primary_key :id
          end
        end
        """,
        Xitdb.Ash.DslTest.UnknownRefResource,
        Xitdb.Ash.Verifiers.VerifyCrossStoreReferences,
        ~r/must match a `belongs_to` relationship/
      )

      assert_verifier_error(
        """
        defmodule Xitdb.Ash.DslTest.NonNullableNilifyResource do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [Xitdb.Ash.Dsl]

          xitdb do
            store Xitdb.Ash.DslTest.StoreA
            collection :bad_nilify

            references do
              reference :event, on_delete: :nilify
            end
          end

          attributes do
            uuid_primary_key :id
          end

          relationships do
            belongs_to :event, Xitdb.Ash.DslTest.Event, allow_nil?: false, attribute_type: :uuid
          end
        end
        """,
        Xitdb.Ash.DslTest.NonNullableNilifyResource,
        Xitdb.Ash.Verifiers.VerifyCrossStoreReferences,
        ~r/cannot set `on_delete: :nilify`.*allow_nil\?: false/
      )

      assert_verifier_error(
        """
        defmodule Xitdb.Ash.DslTest.CrossStoreCascadeResource do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [Xitdb.Ash.Dsl]

          xitdb do
            store Xitdb.Ash.DslTest.StoreB
            collection :cross_store_children

            references do
              reference :event, on_delete: :delete
            end
          end

          attributes do
            uuid_primary_key :id
          end

          relationships do
            belongs_to :event, Xitdb.Ash.DslTest.Event, attribute_type: :uuid
          end
        end
        """,
        Xitdb.Ash.DslTest.CrossStoreCascadeResource,
        Xitdb.Ash.Verifiers.VerifyCrossStoreReferences,
        ~r/[Cc]ross-store .*on_delete: :delete/
      )

      assert_verifier_error(
        """
        defmodule Xitdb.Ash.DslTest.BadNestedParentStore do
          use Ash.Resource,
            domain: nil,
            validate_domain_inclusion?: false,
            extensions: [Xitdb.Ash.Dsl]

          xitdb do
            store Xitdb.Ash.DslTest.StoreB
            collection :bad_nested
            nested_in :events, foreign_key: :event_id, path: :sessions
          end

          attributes do
            uuid_primary_key :id
          end

          relationships do
            belongs_to :event, Xitdb.Ash.DslTest.Event, attribute_type: :uuid
          end
        end
        """,
        Xitdb.Ash.DslTest.BadNestedParentStore,
        Xitdb.Ash.Verifiers.VerifyCrossStoreReferences,
        ~r/must share the same store as parent/
      )
    end
  end
end
