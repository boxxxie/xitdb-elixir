# Reference: `xitdb/.formatter.exs`, `Xitdb.Ash.Dsl` & `Xitdb.Ash.Info`

> [!IMPORTANT]
> **Track Reference Metadata:**
> - **Associated Track:** [`ash_dsl_and_verifiers_20261111`](./index.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Modules & Files:** `xitdb/.formatter.exs`, `lib/xitdb/ash/dsl.ex`, `lib/xitdb/ash/info.ex`
> - **Purpose:** Complete specification and reference implementation for the `xitdb do ... end` Spark DSL, local `BuildIndexPlan` transformer, compile-time verifiers (`VerifyNoSqlFragments`, `VerifyCrossStoreReferences`), and `O(1)` persisted introspection helpers.

---

## 1. Compile-Time Guarantees & Invariants

### 1.1 Zero `mix xref` Cycles in `BuildIndexPlan`
`BuildIndexPlan` runs strictly on the local resource's `dsl_state` after `Ash.Resource.Transformers.BelongsToAttribute`, validating local attributes, deduplicating auto-indexed `belongs_to` foreign keys, and persisting pre-partitioned entity lists (`:xitdb_indexes`, `:xitdb_nested_in`, `:xitdb_search_fields`, `:xitdb_references`) for `O(1)` runtime introspection.

### 1.2 Post-Compile Cross-Store & Parent Verification
`VerifyCrossStoreReferences` executes in Spark's post-compile verifier phase (avoiding cyclic compilation locks) to reject `on_delete` cascades across distinct `.xit` stores and verify `nested_in` parent store/collection alignment.

### 1.3 Deep `fragment(...)` Detection
`VerifyNoSqlFragments` walks resource calculations, identities, global/action validations, atomic changes, read filters, and `Ash.Policy.Authorizer` conditions, catching both `%Ash.Query.Function.Fragment{}` structs and unexpanded `{:fragment, _, _}` AST nodes.

---

## 2. Reference Implementation: `xitdb/.formatter.exs`

Exports `locals_without_parens` so consumer apps (`caasa/connect`) can add `import_deps: [:xitdb]` to format `xitdb do ... end` blocks cleanly without requiring `:spark` in non-Ash projects.

```elixir
spark_locals_without_parens = [
  collection: 1,
  counted_set_fields: 1,
  editable_fields: 1,
  index: 1,
  index: 2,
  index_relationships?: 1,
  nested_in: 1,
  nested_in: 2,
  reference: 1,
  reference: 2,
  search_field: 1,
  search_field: 2,
  store: 1
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [
    locals_without_parens: spark_locals_without_parens
  ]
]

```

## 3. Reference Implementation: `lib/xitdb/ash/dsl.ex`

Defines the `xitdb` Spark DSL entities and schema alongside `BuildIndexPlan`, `VerifyNoSqlFragments`, and `VerifyCrossStoreReferences`.

```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Dsl do
    @moduledoc """
    Spark DSL definition for `Xitdb.Ash.DataLayer` (`xitdb do ... end`).
    """

    defmodule Index do
      @moduledoc """
      Secondary `:sorted_map` B+Tree index specification.
      """
      defstruct [:fields, :name, :__spark_metadata__]

      @type t :: %__MODULE__{
              fields: [atom()],
              name: atom() | nil,
              __spark_metadata__: term()
            }
    end

    defmodule NestedIn do
      @moduledoc """
      Co-locates a child resource inside a parent collection's entity map for 9-byte `fork` snapshots.
      """
      defstruct [:parent_collection, :foreign_key, :path, :__spark_metadata__, cardinality: :many]

      @type t :: %__MODULE__{
              parent_collection: atom(),
              foreign_key: atom(),
              path: atom(),
              cardinality: :one | :many,
              __spark_metadata__: term()
            }
    end

    defmodule SearchField do
      @moduledoc """
      Declares a tokenized attribute or cross-collection resolver for transactional BM25 search.
      """
      defstruct [:field, :resolver, :__spark_metadata__, boost: 1.0]

      @type t :: %__MODULE__{
              field: atom(),
              boost: float(),
              resolver: (struct(), term() -> term()) | nil,
              __spark_metadata__: term()
            }
    end

    defmodule Reference do
      @moduledoc """
      Configures same-store incoming foreign-key `on_delete` behavior for a `belongs_to` relationship.
      """
      defstruct [:relationship, :__spark_metadata__, on_delete: :nothing]

      @type on_delete_action :: :nothing | :delete | :nilify | :restrict

      @type t :: %__MODULE__{
              relationship: atom(),
              on_delete: on_delete_action(),
              __spark_metadata__: term()
            }
    end

    @index %Spark.Dsl.Entity{
      name: :index,
      describe: "Declares a single-attribute or composite `:sorted_map` B+Tree secondary index.",
      examples: [
        "index :status",
        "index [:status, :inserted_at], name: :idx_status_recent"
      ],
      target: Index,
      args: [:fields],
      schema: [
        fields: [
          type: {:wrap_list, :atom},
          required: true,
          doc: "Ordered attribute name(s) composing the B+Tree index key."
        ],
        name: [
          type: :atom,
          doc: "Optional custom slot name under `idx.<collection>`."
        ]
      ]
    }

    @nested_in %Spark.Dsl.Entity{
      name: :nested_in,
      describe: "Co-locates records inside `root[parent_collection][parent_id][path]`.",
      examples: [
        "nested_in :events, foreign_key: :event_id, path: :sessions, cardinality: :many"
      ],
      target: NestedIn,
      args: [:parent_collection],
      schema: [
        parent_collection: [
          type: :atom,
          required: true,
          doc: "Parent collection key at the `.xit` root."
        ],
        foreign_key: [
          type: :atom,
          required: true,
          doc: "Attribute on this resource storing the parent primary key."
        ],
        path: [
          type: :atom,
          required: true,
          doc: "Map key inside the parent entity cursor holding child cursor(s)."
        ],
        cardinality: [
          type: {:one_of, [:one, :many]},
          default: :many,
          doc: "Whether the parent slot stores `:many` keyed records or `:one` embedded map."
        ]
      ]
    }

    @search_field %Spark.Dsl.Entity{
      name: :search_field,
      describe: "Indexes an attribute (or resolved value) in `idx.search.<collection>` for BM25 + prefix search.",
      examples: [
        "search_field :full_name, boost: 3.0",
        "search_field :firm_name, boost: 2.0, resolver: &__MODULE__.resolve_firm_name/2"
      ],
      target: SearchField,
      args: [:field],
      schema: [
        field: [
          type: :atom,
          required: true,
          doc: "Attribute name (or virtual label when `:resolver` is provided)."
        ],
        boost: [
          type: :float,
          default: 1.0,
          doc: "Positive BM25 field weight multiplier."
        ],
        resolver: [
          type: {:fun, 2},
          doc: "Optional `(record, db) -> term()` callback for cross-collection fields."
        ]
      ]
    }

    @reference %Spark.Dsl.Entity{
      name: :reference,
      describe: "Configures referential action when the referenced `belongs_to` parent is destroyed.",
      examples: [
        "reference :organization, on_delete: :nilify",
        "reference :organizer, on_delete: :restrict"
      ],
      target: Reference,
      args: [:relationship],
      schema: [
        relationship: [
          type: :atom,
          required: true,
          doc: "Name of a `belongs_to` relationship on this resource."
        ],
        on_delete: [
          type: {:one_of, [:nothing, :delete, :nilify, :restrict]},
          default: :nothing,
          doc: "Action enforced atomically when the target parent record is destroyed."
        ]
      ]
    }

    @references %Spark.Dsl.Section{
      name: :references,
      describe: "Foreign-key `on_delete` rules within the same `.xit` store.",
      entities: [@reference]
    }

    @xitdb %Spark.Dsl.Section{
      name: :xitdb,
      describe: "Configures Xitdb storage, subtree nesting, B+Tree indexes, BM25 search, and FK rules.",
      entities: [@nested_in, @index, @search_field],
      sections: [@references],
      schema: [
        store: [
          type: :atom,
          required: true,
          doc: "Supervised `Xitdb.Ash.Store` module or registered name."
        ],
        collection: [
          type: :atom,
          required: true,
          doc: "Logical collection & sequence key in the `.xit` store."
        ],
        editable_fields: [
          type: {:list, :atom},
          default: [],
          doc: "Steward-editable attribute list preserved for MDM governance."
        ],
        counted_set_fields: [
          type: {:list, :atom},
          default: [],
          doc: "Attributes backed by `:counted_hash_set` slots."
        ],
        index_relationships?: [
          type: :boolean,
          default: true,
          doc: "Automatically creates secondary B+Tree indexes for all `belongs_to` foreign keys."
        ]
      ]
    }

    @spec sections() :: [Spark.Dsl.Section.t()]
    def sections, do: [@xitdb]
  end

  defmodule Xitdb.Ash.Transformers.BuildIndexPlan do
    @moduledoc false
    use Spark.Dsl.Transformer

    alias Spark.Dsl.Transformer
    alias Spark.Error.DslError
    alias Xitdb.Ash.Dsl.{Index, NestedIn, SearchField}

    @impl Spark.Dsl.Transformer
    def after?(Ash.Resource.Transformers.BelongsToAttribute), do: true
    def after?(Ash.Resource.Transformers.CreateJoinRelationship), do: true
    def after?(_other), do: false

    @impl Spark.Dsl.Transformer
    def transform(dsl_state) do
      module = Transformer.get_persisted(dsl_state, :module)
      attr_names = dsl_state |> Ash.Resource.Info.attributes() |> MapSet.new(& &1.name)
      pk_fields = Ash.Resource.Info.primary_key(dsl_state)
      entities = Transformer.get_entities(dsl_state, [:xitdb])
      references = Transformer.get_entities(dsl_state, [:xitdb, :references])

      nested_entries = for %NestedIn{} = n <- entities, do: n
      explicit_indexes = for %Index{} = i <- entities, do: i
      search_fields = for %SearchField{} = s <- entities, do: s

      with {:ok, nested_in} <- validate_nested_in(module, nested_entries, attr_names),
           :ok <- validate_explicit_indexes(module, explicit_indexes, attr_names),
           :ok <- validate_search_fields(module, search_fields, attr_names) do
        all_indexes =
          maybe_append_relationship_indexes(dsl_state, explicit_indexes, pk_fields)

        updated_state =
          dsl_state
          |> Transformer.persist(:xitdb_nested_in, nested_in)
          |> Transformer.persist(:xitdb_indexes, all_indexes)
          |> Transformer.persist(:xitdb_search_fields, search_fields)
          |> Transformer.persist(:xitdb_references, references)

        {:ok, updated_state}
      end
    end

    defp validate_nested_in(_module, [], _attr_names), do: {:ok, nil}

    defp validate_nested_in(module, [%NestedIn{foreign_key: fk} = nested], attr_names) do
      if MapSet.member?(attr_names, fk) do
        {:ok, nested}
      else
        {:error,
         DslError.exception(
           module: module,
           path: [:xitdb, :nested_in, nested.parent_collection],
           message:
             "nested_in foreign_key #{inspect(fk)} is not a defined attribute on #{inspect(module)}"
         )}
      end
    end

    defp validate_nested_in(module, [_first, _second | _rest], _attr_names) do
      {:error,
       DslError.exception(
         module: module,
         path: [:xitdb, :nested_in],
         message: "at most one `nested_in` declaration is allowed per resource"
       )}
    end

    defp validate_explicit_indexes(module, indexes, attr_names) do
      Enum.reduce_while(indexes, :ok, fn %Index{fields: fields}, :ok ->
        cond do
          fields == [] ->
            {:halt,
             {:error,
              DslError.exception(
                module: module,
                path: [:xitdb, :index],
                message: "index `fields` cannot be empty"
              )}}

          Enum.any?(fields, &(not MapSet.member?(attr_names, &1))) ->
            missing = Enum.reject(fields, &MapSet.member?(attr_names, &1))

            {:halt,
             {:error,
              DslError.exception(
                module: module,
                path: [:xitdb, :index, fields],
                message:
                  "unknown attribute(s) #{inspect(missing)} in `xitdb.index` on #{inspect(module)}"
              )}}

          true ->
            {:cont, :ok}
        end
      end)
    end

    defp validate_search_fields(module, search_fields, attr_names) do
      Enum.reduce_while(search_fields, :ok, fn %SearchField{} = sf, :ok ->
        cond do
          sf.boost <= 0.0 ->
            {:halt,
             {:error,
              DslError.exception(
                module: module,
                path: [:xitdb, :search_field, sf.field],
                message: "`search_field` boost must be > 0.0, got: #{inspect(sf.boost)}"
              )}}

          is_nil(sf.resolver) and not MapSet.member?(attr_names, sf.field) ->
            {:halt,
             {:error,
              DslError.exception(
                module: module,
                path: [:xitdb, :search_field, sf.field],
                message:
                  "search_field #{inspect(sf.field)} must match an attribute on #{inspect(module)} or supply a `resolver: fun/2`"
              )}}

          true ->
            {:cont, :ok}
        end
      end)
    end

    defp maybe_append_relationship_indexes(dsl_state, explicit_indexes, pk_fields) do
      index_rels? =
        Spark.Dsl.Transformer.get_option(dsl_state, [:xitdb], :index_relationships?, true)

      if not index_rels? do
        explicit_indexes
      else
        covered_leading_fields =
          explicit_indexes
          |> Enum.map(fn %Index{fields: [first | _]} -> first end)
          |> MapSet.new()

        auto_fk_indexes =
          dsl_state
          |> Ash.Resource.Info.relationships()
          |> Enum.filter(&(&1.type == :belongs_to))
          |> Enum.map(& &1.source_attribute)
          |> Enum.uniq()
          |> Enum.reject(fn fk_attr ->
            [fk_attr] == pk_fields or MapSet.member?(covered_leading_fields, fk_attr)
          end)
          |> Enum.map(fn fk_attr -> %Index{fields: [fk_attr], name: nil} end)

        explicit_indexes ++ auto_fk_indexes
      end
    end
  end

  defmodule Xitdb.Ash.Verifiers.VerifyNoSqlFragments do
    @moduledoc false
    use Spark.Dsl.Verifier

    alias Spark.Dsl.Verifier
    alias Spark.Error.DslError

    @impl Spark.Dsl.Verifier
    def verify(dsl_state) do
      module = Verifier.get_persisted(dsl_state, :module)

      with :ok <- check_calculations(module, dsl_state),
           :ok <- check_identities(module, dsl_state),
           :ok <- check_resource_validations_and_changes(module, dsl_state),
           :ok <- check_actions(module, dsl_state) do
        check_policies(module, dsl_state)
      end
    end

    defp check_calculations(module, dsl_state) do
      dsl_state
      |> Ash.Resource.Info.calculations()
      |> Enum.reduce_while(:ok, fn calc, :ok ->
        if contains_sql_fragment?(calc.calculation) do
          {:halt,
           fragment_error(module, [:calculations, calc.name], "calculation #{inspect(calc.name)}")}
        else
          {:cont, :ok}
        end
      end)
    end

    defp check_identities(module, dsl_state) do
      dsl_state
      |> Ash.Resource.Info.identities()
      |> Enum.reduce_while(:ok, fn identity, :ok ->
        if contains_sql_fragment?(Map.get(identity, :where)) do
          {:halt,
           fragment_error(
             module,
             [:identities, identity.name],
             "identity #{inspect(identity.name)} `where` clause"
           )}
        else
          {:cont, :ok}
        end
      end)
    end

    defp check_resource_validations_and_changes(module, dsl_state) do
      validations = Ash.Resource.Info.validations(dsl_state)
      changes = Ash.Resource.Info.changes(dsl_state)

      cond do
        Enum.any?(validations, &contains_sql_fragment?/1) ->
          fragment_error(module, [:validations], "resource `validations` block")

        Enum.any?(changes, &contains_sql_fragment?/1) ->
          fragment_error(module, [:changes], "resource `changes` block")

        true ->
          :ok
      end
    end

    defp check_actions(module, dsl_state) do
      dsl_state
      |> Ash.Resource.Info.actions()
      |> Enum.reduce_while(:ok, fn action, :ok ->
        action_terms = [
          Map.get(action, :filter),
          Map.get(action, :changes),
          Map.get(action, :validations)
        ]

        if contains_sql_fragment?(action_terms) do
          {:halt,
           fragment_error(module, [:actions, action.name], "action #{inspect(action.name)}")}
        else
          {:cont, :ok}
        end
      end)
    end

    defp check_policies(module, dsl_state) do
      if Code.ensure_loaded?(Ash.Policy.Info) and
           Ash.Policy.Authorizer in Ash.Resource.Info.authorizers(dsl_state) do
        policies = Ash.Policy.Info.policies(dsl_state)

        if contains_sql_fragment?(policies) do
          fragment_error(module, [:policies], "`policies` block")
        else
          :ok
        end
      else
        :ok
      end
    end

    defp contains_sql_fragment?(%Ash.Query.Function.Fragment{}), do: true

    defp contains_sql_fragment?({:fragment, _meta, args}) when is_list(args), do: true

    defp contains_sql_fragment?(%_{} = struct) do
      struct
      |> Map.from_struct()
      |> Map.delete(:__spark_metadata__)
      |> Map.values()
      |> Enum.any?(&contains_sql_fragment?/1)
    end

    defp contains_sql_fragment?(map) when is_map(map) do
      Enum.any?(map, fn {k, v} -> contains_sql_fragment?(k) or contains_sql_fragment?(v) end)
    end

    defp contains_sql_fragment?(list) when is_list(list) do
      Enum.any?(list, &contains_sql_fragment?/1)
    end

    defp contains_sql_fragment?(tuple) when is_tuple(tuple) do
      tuple
      |> Tuple.to_list()
      |> Enum.any?(&contains_sql_fragment?/1)
    end

    defp contains_sql_fragment?(_scalar), do: false

    defp fragment_error(module, path, location_desc) do
      {:error,
       DslError.exception(
         module: module,
         path: path,
         message:
           "SQL `fragment(...)` in #{location_desc} is not supported by `Xitdb.Ash.DataLayer`. " <>
             "Replace it with a portable `Ash.Expr` expression or an `Ash.Resource.Calculation` module."
       )}
    end
  end

  defmodule Xitdb.Ash.Verifiers.VerifyCrossStoreReferences do
    @moduledoc false
    use Spark.Dsl.Verifier

    alias Spark.Dsl.Verifier
    alias Spark.Error.DslError
    alias Xitdb.Ash.Dsl.{NestedIn, Reference}
    alias Xitdb.Ash.Info

    @impl Spark.Dsl.Verifier
    def verify(dsl_state) do
      module = Verifier.get_persisted(dsl_state, :module)
      source_store = Info.store!(dsl_state)

      with :ok <- verify_references(module, dsl_state, source_store) do
        verify_nested_parent(module, dsl_state, source_store)
      end
    end

    defp verify_references(module, dsl_state, source_store) do
      dsl_state
      |> Info.references()
      |> Enum.reduce_while(:ok, fn %Reference{relationship: rel_name, on_delete: on_delete}, :ok ->
        rel = Ash.Resource.Info.relationship(dsl_state, rel_name)

        case validate_single_reference(module, source_store, rel_name, rel, on_delete) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end

    defp validate_single_reference(module, _source_store, rel_name, nil, _on_delete) do
      {:error,
       DslError.exception(
         module: module,
         path: [:xitdb, :references, :reference, rel_name],
         message:
           "reference #{inspect(rel_name)} does not match any relationship on #{inspect(module)}"
       )}
    end

    defp validate_single_reference(module, _source_store, rel_name, %{type: type}, _on_delete)
         when type != :belongs_to do
      {:error,
       DslError.exception(
         module: module,
         path: [:xitdb, :references, :reference, rel_name],
         message:
           "reference #{inspect(rel_name)} must target a `belongs_to` relationship, got `#{inspect(type)}`"
       )}
    end

    defp validate_single_reference(_module, _source_store, _rel_name, _rel, :nothing), do: :ok

    defp validate_single_reference(module, source_store, rel_name, %{destination: dest}, on_delete) do
      cond do
        Ash.Resource.Info.data_layer(dest) != Xitdb.Ash.DataLayer ->
          {:error,
           DslError.exception(
             module: module,
             path: [:xitdb, :references, :reference, rel_name],
             message:
               "reference #{inspect(rel_name)} configures `on_delete: #{inspect(on_delete)}`, " <>
                 "but destination #{inspect(dest)} does not use `Xitdb.Ash.DataLayer`"
           )}

        Info.store(dest) != {:ok, source_store} ->
          {:ok, dest_store} = Info.store(dest)

          {:error,
           DslError.exception(
             module: module,
             path: [:xitdb, :references, :reference, rel_name],
             message:
               "cross-store `on_delete: #{inspect(on_delete)}` from #{inspect(module)} (#{inspect(source_store)}) " <>
                 "to #{inspect(dest)} (#{inspect(dest_store)}) cannot execute in a single `.xit` transaction. " <>
                 "Set `on_delete: :nothing` (or omit the reference) and coordinate cross-store cleanup via `Ash.Signals` or an `after_action` hook."
           )}

        true ->
          :ok
      end
    end

    defp verify_nested_parent(module, dsl_state, source_store) do
      case Info.nested_in(dsl_state) do
        nil ->
          :ok

        %NestedIn{parent_collection: parent_col, foreign_key: fk_attr} ->
          parent_rel =
            dsl_state
            |> Ash.Resource.Info.relationships()
            |> Enum.find(&(&1.type == :belongs_to and &1.source_attribute == fk_attr))

          validate_nested_relationship(module, source_store, parent_col, parent_rel)
      end
    end

    defp validate_nested_relationship(_module, _source_store, _parent_col, nil), do: :ok

    defp validate_nested_relationship(module, source_store, parent_col, %{destination: dest}) do
      cond do
        Ash.Resource.Info.data_layer(dest) != Xitdb.Ash.DataLayer ->
          {:error,
           DslError.exception(
             module: module,
             path: [:xitdb, :nested_in, parent_col],
             message:
               "`nested_in` parent resource #{inspect(dest)} must use `Xitdb.Ash.DataLayer`"
           )}

        Info.store(dest) != {:ok, source_store} ->
          {:ok, dest_store} = Info.store(dest)

          {:error,
           DslError.exception(
             module: module,
             path: [:xitdb, :nested_in, parent_col],
             message:
               "`nested_in` child #{inspect(module)} (#{inspect(source_store)}) must share the same store as parent #{inspect(dest)} (#{inspect(dest_store)})"
           )}

        Info.collection(dest) != {:ok, parent_col} ->
          {:ok, actual_col} = Info.collection(dest)

          {:error,
           DslError.exception(
             module: module,
             path: [:xitdb, :nested_in, parent_col],
             message:
               "`nested_in #{inspect(parent_col)}` does not match parent #{inspect(dest)} collection #{inspect(actual_col)}"
           )}

        true ->
          :ok
      end
    end
  end
end

```

## 4. Reference Implementation: `lib/xitdb/ash/info.ex`

Provides `O(1)` introspection helpers over both compiled `Ash.Resource` modules and in-flight `Spark.Dsl.t()` maps.

```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Info do
    @moduledoc """
    Introspection helpers for `Xitdb.Ash.DataLayer` resource configurations.
    """

    alias Spark.Dsl.Extension
    alias Xitdb.Ash.Dsl.{Index, NestedIn, Reference, SearchField}

    @type resource_or_dsl :: module() | Spark.Dsl.t()

    @doc """
    Fetches the configured `Xitdb.Ash.Store` name for `resource`.
    """
    @spec store(resource_or_dsl()) :: {:ok, module()} | :error
    def store(resource) do
      Extension.fetch_opt(resource, [:xitdb], :store)
    end

    @doc """
    Returns the configured `Xitdb.Ash.Store` name or raises `ArgumentError`.
    """
    @spec store!(resource_or_dsl()) :: module()
    def store!(resource) do
      case store(resource) do
        {:ok, store_mod} when is_atom(store_mod) ->
          store_mod

        :error ->
          raise ArgumentError,
                "#{inspect(resource)} has no `xitdb.store` configured"
      end
    end

    @doc """
    Fetches the logical `.xit` collection key for `resource`.
    """
    @spec collection(resource_or_dsl()) :: {:ok, atom()} | :error
    def collection(resource) do
      Extension.fetch_opt(resource, [:xitdb], :collection)
    end

    @doc """
    Returns the logical `.xit` collection key or raises `ArgumentError`.
    """
    @spec collection!(resource_or_dsl()) :: atom()
    def collection!(resource) do
      case collection(resource) do
        {:ok, col} when is_atom(col) ->
          col

        :error ->
          raise ArgumentError,
                "#{inspect(resource)} has no `xitdb.collection` configured"
      end
    end

    @doc """
    Returns steward-editable field names declared on `resource`.
    """
    @spec editable_fields(resource_or_dsl()) :: [atom()]
    def editable_fields(resource) do
      Extension.get_opt(resource, [:xitdb], :editable_fields, [])
    end

    @doc """
    Returns attributes configured as `:counted_hash_set` slots on `resource`.
    """
    @spec counted_set_fields(resource_or_dsl()) :: [atom()]
    def counted_set_fields(resource) do
      Extension.get_opt(resource, [:xitdb], :counted_set_fields, [])
    end

    @doc """
    Returns whether `belongs_to` foreign keys are indexed automatically on `resource`.
    """
    @spec index_relationships?(resource_or_dsl()) :: boolean()
    def index_relationships?(resource) do
      Extension.get_opt(resource, [:xitdb], :index_relationships?, true)
    end

    @doc """
    Returns the `%Xitdb.Ash.Dsl.NestedIn{}` specification if `resource` is subtree-nested, or `nil`.
    """
    @spec nested_in(resource_or_dsl()) :: NestedIn.t() | nil
    def nested_in(resource) do
      case Extension.get_persisted(resource, :xitdb_nested_in, :not_persisted) do
        :not_persisted ->
          resource
          |> Extension.get_entities([:xitdb])
          |> Enum.find(&match?(%NestedIn{}, &1))

        persisted ->
          persisted
      end
    end

    @doc """
    Returns all explicit and auto-generated `%Xitdb.Ash.Dsl.Index{}` definitions for `resource`.
    """
    @spec indexes(resource_or_dsl()) :: [Index.t()]
    def indexes(resource) do
      case Extension.get_persisted(resource, :xitdb_indexes, :not_persisted) do
        :not_persisted ->
          for %Index{} = idx <- Extension.get_entities(resource, [:xitdb]), do: idx

        persisted ->
          persisted
      end
    end

    @doc """
    Returns secondary indexes whose leading column is `field`, ordered from narrowest
    (single-column `[field]`) to widest composite index for the Stage 1 query planner.
    """
    @spec indexes_for_field(resource_or_dsl(), atom()) :: [Index.t()]
    def indexes_for_field(resource, field) when is_atom(field) do
      resource
      |> indexes()
      |> Enum.filter(fn %Index{fields: [leading | _]} -> leading == field end)
      |> Enum.sort_by(fn %Index{fields: fields} -> length(fields) end)
    end

    @doc """
    Returns all `%Xitdb.Ash.Dsl.SearchField{}` definitions for `resource`.
    """
    @spec search_fields(resource_or_dsl()) :: [SearchField.t()]
    def search_fields(resource) do
      case Extension.get_persisted(resource, :xitdb_search_fields, :not_persisted) do
        :not_persisted ->
          for %SearchField{} = sf <- Extension.get_entities(resource, [:xitdb]), do: sf

        persisted ->
          persisted
      end
    end

    @doc """
    Returns outgoing `%Xitdb.Ash.Dsl.Reference{}` foreign-key rules declared on `resource`.
    """
    @spec references(resource_or_dsl()) :: [Reference.t()]
    def references(resource) do
      case Extension.get_persisted(resource, :xitdb_references, :not_persisted) do
        :not_persisted ->
          Extension.get_entities(resource, [:xitdb, :references])

        persisted ->
          persisted
      end
    end
  end
end

```
