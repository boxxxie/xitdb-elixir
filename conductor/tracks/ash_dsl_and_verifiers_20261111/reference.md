# Reference: `.formatter.exs`, Top-Level Spark Structs, `Xitdb.Ash.Resource`, `Xitdb.Ash.Dsl`, `Xitdb.Ash.Info` & Wave 1 Bootstrap Baselines

> [!IMPORTANT]
> **Track Reference Metadata:**
> - **Associated Track:** [`ash_dsl_and_verifiers_20261111`](./index.md) (`Track 8 [Wave 1]`)
> - **Prerequisite:** [`client_fixes_and_dedup_20261111`](../client_fixes_and_dedup_20261111/index.md) (`Track 5A [Wave 1]` only; `split_dsl_and_invert_ash_dependency_20261111` is deferred to Wave 4)
> - **Conductor Patch & Scope Note:** `wave1_mvp_prereqs_and_schema.patch` packages the Conductor specifications, execution plans, and complete self-contained reference implementations/diffs for Wave 1 execution (Tracks 5A and 8) against `master` (`v1.0.2`), including complete bootstrap implementations for `lib/xitdb/ash/store/snapshot.ex` and `lib/xitdb/ash/search.ex` so applying Wave 1 from `master` has zero missing module baselines.
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Modules & Files:**
>   - [`.formatter.exs`](../../../.formatter.exs)
>   - [`lib/xitdb/ash/index.ex`](../../../lib/xitdb/ash/index.ex)
>   - [`lib/xitdb/ash/nested_in.ex`](../../../lib/xitdb/ash/nested_in.ex)
>   - [`lib/xitdb/ash/reference.ex`](../../../lib/xitdb/ash/reference.ex)
>   - [`lib/xitdb/ash/search_field.ex`](../../../lib/xitdb/ash/search_field.ex)
>   - [`lib/xitdb/ash/resource.ex`](../../../lib/xitdb/ash/resource.ex)
>   - `lib/xitdb/ash/dsl.ex` (including `BuildIndexPlan`, `VerifyNoSqlFragments`, `VerifyCrossStoreReferences`)
>   - [`lib/xitdb/ash/info.ex`](../../../lib/xitdb/ash/info.ex)
>   - [`lib/xitdb/ash/tx.ex`](../../../lib/xitdb/ash/tx.ex)
>   - [`lib/xitdb/ash/store/snapshot.ex`](../../../lib/xitdb/ash/store/snapshot.ex)
>   - [`lib/xitdb/ash/search.ex`](../../../lib/xitdb/ash/search.ex)

---

## 1. Compile-Time & Compatibility Invariants

### 1.1 Additive Preservation of `v1.0.2` MDM & `Xitdb.DSL` Contracts
- **Zero destructive overwrites:** `.formatter.exs`, `lib/xitdb/ash/resource.ex`, and `lib/xitdb/ash/info.ex` preserve 100% of `Xitdb.DSL` transaction/Datalog macros and `v1.0.2` `Xitdb.Ash.Resource` MDM sync-projection options/helpers (`editable_field_strings/1`, `pull_fields/1`, `pull_pattern_for/1`, `nested_mappings/1`, `nested?/1`, `nested_under/2`, `entity_paths/2`, `resolve_store/2`, `resolve_lock_change/1`, `WireChanges`, `VerifySyncProjection`, atomic per-pair `cached_pair/4`, and `__purge_pair_cache__/1`).
- **Optional `store` on `Xitdb.Ash.Resource`:** `Xitdb.Ash.Resource` keeps `store` optional (falling back to `:default_store` / `context[:xitdb_store]`) so `v1.0.2` MDM resources like `MutualUser` and `TestPerson` that omit `store` compile cleanly, whereas `BuildIndexPlan` enforces explicit `store` and `collection` on `Xitdb.Ash.Dsl` / `Xitdb.Ash.DataLayer` resources.
- **Distinct nesting persistence keys:** `WireChanges` (`Xitdb.Ash.Resource`) persists `:xitdb_nested_in` as `[%Xitdb.Ash.NestedIn{}]`, whereas `BuildIndexPlan` (`Xitdb.Ash.Dsl` / `Xitdb.Ash.DataLayer`) persists `:xitdb_nesting_plan` as `%Xitdb.Ash.NestedIn{} | nil`. `Info.nested_in/1` reads `:xitdb_nesting_plan` while `Info.nested_mappings/1` reads `:xitdb_nested_in`—eliminating any persistence key collision.
- **Unified `tx_for` support:** Both `WireChanges` (`indexes: [domain: "domain->org_id"]`) and `BuildIndexPlan` (`index :email`, `index :domain, name: :idx_domain`) persist `:xitdb_normalized_indexes` and emit `__xitdb_collection__/0` + `__xitdb_indexes__/0`, so `Xitdb.DSL.tx_for` and `Xitdb.Ash.Tx.tx_for` work identically across both extensions.

### 1.2 Zero `mix xref` Cycles & Complete Local Validation in `BuildIndexPlan`
`BuildIndexPlan` runs strictly on the local resource's `dsl_state` after `Ash.Resource.Transformers.BelongsToAttribute` and `Ash.Resource.Transformers.CreateJoinRelationship`, rejecting composite primary keys (`length(pk_fields) > 1`), validating explicit `index` fields/duplicates/names, `counted_set_fields`, `editable_fields`, `passthru_fields`, and `search_field` entries, and deduplicating auto-generated `belongs_to` FK indexes against primary keys and explicit leading fields.

### 1.3 Exhaustive `VerifyNoSqlFragments` & Safe Post-Compile `VerifyCrossStoreReferences`
- `VerifyNoSqlFragments` places `%Ash.Query.Function.Fragment{}`, `%Ash.Query.Call{name: :fragment}`, and `{:fragment, _meta, args} when is_list(args)` **before** the generic `%_{} = struct` clause (zero Elixir 1.20 unreachable-clause warnings) and audits `calculations`, `aggregates` (`filter`, `join_filters`), `relationships` (`filter`), `identities` (`where`), resource `validations`/`changes`/`preparations`, `actions` (`filter`, `changes`, `validations`, `preparations`), `Ash.Policy.Info.policies/1`, and `Ash.Policy.Info.field_policies/1`.
- `VerifyCrossStoreReferences` validates every declared `%Xitdb.Ash.Reference{}` against `belongs_to` relationships (rejecting typos), rejects `on_delete: :nilify` when `allow_nil?: false`, calls `Code.ensure_compiled(dest)` before inspecting destinations, allows plain `:nothing` cross-DB `belongs_to` links, rejects cross-store/cross-DB cascades (`~r/[Cc]ross-store .*on_delete: :delete/`), and validates `nested_in` parents via safe `case` expressions without bare-match crashes.

---

## 2. Reference Implementation: `.formatter.exs`

Preserves all `Xitdb.DSL` macros and `v1.0.2` `Xitdb.Ash.Resource` MDM locals while adding `Xitdb.Ash.DataLayer` locals and keeping ATDD `scenario: 2` local-only:

```elixir
dsl_locals_without_parens = [
  # Xitdb.DSL transaction blocks
  tx: 2,
  tx: 3,
  tx!: 2,
  tx!: 3,
  tx_for: 2,
  tx_for: 3,
  tx_for: 4,
  tx_for!: 2,
  tx_for!: 3,
  tx_for!: 4,
  # Xitdb.DSL transaction operations
  put: 1,
  put: 2,
  update: 2,
  update: 3,
  rm: 1,
  append: 2,
  insert: 2,
  insert: 3,
  slice: 2,
  slice: 3,
  fork: 2,
  index_on: 3,
  init_col: 2,
  reset_col: 2,
  meta: 2,
  instant: 1,
  abort: 1,
  # Xitdb.DSL Datalog blocks & clauses
  datalog: 1,
  query: 2,
  query: 3,
  query!: 2,
  query!: 3,
  find: 1,
  find: 2,
  find: 3,
  find: 4,
  from: 1,
  where: 1
]

spark_locals_without_parens = [
  # Shared & Xitdb.Ash.DataLayer options/entities
  store: 1,
  collection: 1,
  nested_in: 1,
  nested_in: 2,
  index: 1,
  index: 2,
  index_relationships?: 1,
  counted_set_fields: 1,
  search_field: 1,
  search_field: 2,
  reference: 1,
  reference: 2,
  # Xitdb.Ash.Resource (v1.0.2 hybrid MDM projection) options
  merge_redirect_collection: 1,
  locked_ids_set: 1,
  companion_resource: 1,
  editable_fields: 1,
  passthru_fields: 1,
  computed_xitdb_fields: 1,
  field_aliases: 1,
  indexes: 1,
  sync_update_action: 1,
  ignored_sync_attributes: 1,
  lock_action: 1,
  unlock_action: 1,
  lock_change: 1
]

exported_locals = dsl_locals_without_parens ++ spark_locals_without_parens

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test,benchmarks}/**/*.{ex,exs}"],
  locals_without_parens: exported_locals ++ [scenario: 2],
  export: [locals_without_parens: exported_locals]
]
```

---

## 3. Unified Top-Level Spark Entity Structs

### 3.1 `lib/xitdb/ash/index.ex`

```elixir
if Code.ensure_loaded?(Ash.Resource) do
  defmodule Xitdb.Ash.Index do
    @moduledoc """
    Declares an explicit single-attribute or composite B+Tree (`:sorted_map`) secondary index
    on a `Xitdb.Ash.DataLayer` or `Xitdb.Ash.Resource` module.
    """

    @type t :: %__MODULE__{
            fields: [atom()],
            name: String.t() | atom() | nil,
            __identifier__: term(),
            __spark_metadata__: term()
          }

    defstruct [
      :fields,
      :name,
      :__identifier__,
      :__spark_metadata__
    ]
  end
end
```

### 3.2 `lib/xitdb/ash/nested_in.ex`

Unifies both `v1.0.2` MDM projection fields (`parent`, `as`, `parent_key`, `key`) and `Xitdb.Ash.DataLayer` co-located subtree fields (`parent_collection`, `foreign_key`, `path`, `cardinality`):

```elixir
defmodule Xitdb.Ash.NestedIn do
  @moduledoc """
  Unified subtree nesting specification supporting both:

  1. **`Xitdb.Ash.Resource` (MDM sync projection):**
     `nested_in MyApp.Accounts.User, as: :phones, parent_key: :user_id, key: :e164`
     (`:parent`, `:as`, `:parent_key`, `:key`, `:cardinality`)
  2. **`Xitdb.Ash.DataLayer` / `Xitdb.Ash.Dsl` (co-located `.xit` subtree):**
     `nested_in :events, foreign_key: :event_id, path: :sessions, cardinality: :many`
     (`:parent_collection`, `:foreign_key`, `:path`, `:cardinality`)
  """

  @type t :: %__MODULE__{
          parent: module() | nil,
          as: atom() | nil,
          parent_key: atom() | nil,
          key: atom() | nil,
          parent_collection: atom() | nil,
          foreign_key: atom() | nil,
          path: atom() | nil,
          cardinality: :one | :many,
          __identifier__: term(),
          __spark_metadata__: term()
        }

  defstruct [
    :parent,
    :as,
    :parent_key,
    :key,
    :parent_collection,
    :foreign_key,
    :path,
    cardinality: :many,
    __identifier__: nil,
    __spark_metadata__: nil
  ]
end
```

### 3.3 `lib/xitdb/ash/search_field.ex`

```elixir
if Code.ensure_loaded?(Ash.Resource) do
  defmodule Xitdb.Ash.SearchField do
    @moduledoc """
    Declares a field indexed for transactional BM25 and B+Tree prefix search
    in `idx.search.<collection>`.
    """

    @type t :: %__MODULE__{
            field: atom(),
            boost: float(),
            resolver: (struct(), term() -> term()) | nil,
            __identifier__: term(),
            __spark_metadata__: term()
          }

    defstruct [
      :field,
      :resolver,
      :__identifier__,
      :__spark_metadata__,
      boost: 1.0
    ]
  end
end
```

### 3.4 `lib/xitdb/ash/reference.ex`

```elixir
if Code.ensure_loaded?(Ash.Resource) do
  defmodule Xitdb.Ash.Reference do
    @moduledoc """
    Declares foreign-key `on_delete` actions (`:nothing`, `:delete`, `:nilify`, `:restrict`)
    for `belongs_to` relationships targeting same-store resources.
    """

    @type on_delete_action :: :nothing | :delete | :nilify | :restrict

    @type t :: %__MODULE__{
            relationship: atom(),
            on_delete: on_delete_action(),
            __identifier__: term(),
            __spark_metadata__: term()
          }

    defstruct [
      :relationship,
      :__identifier__,
      :__spark_metadata__,
      on_delete: :nothing
    ]
  end
end
```

---

## 4. Additive `lib/xitdb/ash/resource.ex` & `lib/xitdb/ash/tx.ex`

### 4.1 `lib/xitdb/ash/resource.ex`

Preserves 100% of `v1.0.2` MDM options (`store` optional, `collection` optional, `WireChanges`, `VerifySyncProjection`) while adding `counted_set_fields` and `index_relationships?` so `Spark.InfoGenerator` generates `xitdb_*` accessors for every shared option:

```elixir
if Code.ensure_loaded?(Spark.Dsl.Extension) and Code.ensure_loaded?(Ash.Resource) do
  defmodule Xitdb.Ash.Resource do
    @moduledoc """
    Spark DSL extension declaring Xitdb MDM collection mappings, synced field
    projections, secondary B+Tree indexes, and lock actions on an `Ash.Resource`.
    """

    @default_ignored_sync_attributes [
      :locked_by_user,
      :locked_fields,
      :dirty_for_upstream_sync,
      :local_overrides,
      :status
    ]

    @doc false
    def validate_resolver(fun) when is_function(fun, 2), do: {:ok, fun}
    def validate_resolver(nil), do: {:ok, nil}
    def validate_resolver(_), do: {:error, "must be a 2-arity function (record, db) or nil"}

    @search_field %Spark.Dsl.Entity{
      name: :search_field,
      describe: "Declares a field to be indexed in the transactional BM25 search index.",
      examples: [
        "search_field :full_name, boost: 3.0",
        "search_field :firm_name, boost: 2.0, resolver: fn profile, db -> ... end"
      ],
      target: Xitdb.Ash.SearchField,
      args: [:field],
      identifier: :field,
      schema: [
        field: [
          type: :atom,
          required: true,
          doc: "The attribute or virtual search field name."
        ],
        boost: [
          type: :float,
          default: 1.0,
          doc: "BM25 field weight multiplier."
        ],
        resolver: [
          type: {:custom, __MODULE__, :validate_resolver, []},
          doc: "Custom 2-arity resolver fn(record, db) -> string or enumerable of strings."
        ]
      ]
    }

    @index %Spark.Dsl.Entity{
      name: :index,
      describe: "Declares a single-attribute or composite B+Tree (:sorted_map) secondary index.",
      examples: [
        "index :email",
        "index [:status, :inserted_at], name: :idx_status_recent"
      ],
      target: Xitdb.Ash.Index,
      args: [:fields],
      identifier: {:auto, :unique_integer},
      schema: [
        fields: [
          type: {:wrap_list, :atom},
          required: true,
          doc: "The attribute or list of attributes comprising the secondary index key."
        ],
        name: [
          type: {:or, [:atom, :string]},
          doc: "Optional custom name for the secondary index."
        ]
      ]
    }

    @reference %Spark.Dsl.Entity{
      name: :reference,
      describe: "Declares an incoming/outgoing foreign key on_delete action for a relationship.",
      examples: [
        "reference :user, on_delete: :delete",
        "reference :organization, on_delete: :nilify"
      ],
      target: Xitdb.Ash.Reference,
      args: [:relationship],
      identifier: :relationship,
      schema: [
        relationship: [
          type: :atom,
          required: true,
          doc: "Relationship name."
        ],
        on_delete: [
          type: {:in, [:nothing, :delete, :nilify, :restrict]},
          default: :nothing,
          doc: "Action taken when referenced target entity is destroyed."
        ]
      ]
    }

    @references_section %Spark.Dsl.Section{
      name: :references,
      describe:
        "Configures incoming/outgoing foreign key actions targeting same-store resources.",
      entities: [@reference]
    }

    @nested_in %Spark.Dsl.Entity{
      name: :nested_in,
      describe: """
      Stores this resource inside a parent entity (`<parent collection>[parent_id].<as>[key]`)
      instead of a top-level collection. Repeat the entity to allow several parents.
      """,
      examples: [
        "nested_in MyApp.Accounts.User, as: :phones, parent_key: :user_id, key: :e164",
        "nested_in MyApp.Events.Event, as: :conference, parent_key: :event_id, cardinality: :one"
      ],
      target: Xitdb.Ash.NestedIn,
      args: [:parent],
      identifier: {:auto, :unique_integer},
      schema: [
        parent: [
          type: :atom,
          required: true,
          doc: "Parent `Xitdb.Ash.Resource`, which must declare a top-level `collection`."
        ],
        as: [
          type: :atom,
          required: true,
          doc: "Slot name under the parent entity (e.g. `:phones`, `:sessions`)."
        ],
        parent_key: [
          type: :atom,
          required: true,
          doc: "Attribute on this resource that holds the parent entity id."
        ],
        key: [
          type: :atom,
          doc:
            "Attribute whose value is the entry key inside the sub-collection. Required for `cardinality: :many`."
        ],
        cardinality: [
          type: {:in, [:one, :many]},
          default: :many,
          doc: "`:many` stores a map of entries; `:one` stores a single map at the slot."
        ]
      ]
    }

    @xitdb_section %Spark.Dsl.Section{
      name: :xitdb,
      describe: "Configures Xitdb MDM projection, survivorship locks, and secondary indexes.",
      entities: [@nested_in, @search_field, @index],
      sections: [@references_section],
      schema: [
        store: [
          type: :atom,
          doc:
            "Default Xitdb Store GenServer name (overridable via `context[:xitdb_store]` or `config :xitdb, :default_store`)."
        ],
        collection: [
          type: :atom,
          doc:
            "Primary Xitdb hash_map collection (`:organizations`, `:people`, `:events`). Required unless the resource declares `nested_in`."
        ],
        merge_redirect_collection: [
          type: :atom,
          doc:
            "Sorted map storing loser -> winner redirects (`:org_merged_into`, `:merged_into`)."
        ],
        locked_ids_set: [
          type: :atom,
          doc: "Curation counted_hash_set tracking locked entity IDs (`:locked_org_ids`, etc.)."
        ],
        companion_resource: [
          type: :atom,
          doc:
            "Optional companion resource sharing the same Xitdb entity (e.g. `Profile` <-> `User`)."
        ],
        editable_fields: [
          type: {:list, :atom},
          default: [],
          doc:
            "Canonical attributes subject to per-field survivorship locks and conflict detection."
        ],
        passthru_fields: [
          type: {:list, :atom},
          default: [],
          doc:
            "Attributes projected into Xitdb without per-field conflict logging (e.g. `:creatio_id`)."
        ],
        computed_xitdb_fields: [
          type: {:list, :atom},
          default: [],
          doc:
            "Derived Xitdb-only fields maintained by the engine (e.g. `:normalized_name`, `:activity_count`)."
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
        ],
        field_aliases: [
          type: :keyword_list,
          default: [],
          doc:
            "Maps Ash attribute names to Xitdb slot names (e.g. `[parent_organization_id: :parent_org_id]`)."
        ],
        indexes: [
          type: :keyword_list,
          default: [],
          doc: "Secondary B+Tree index declarations (`[domain: \"domain->org_id\", ...]`)."
        ],
        sync_update_action: [
          type: :atom,
          default: :mdm_sync_update,
          doc: "Ash update action invoked by reconciler projectors."
        ],
        ignored_sync_attributes: [
          type: {:list, :atom},
          default: @default_ignored_sync_attributes,
          doc:
            "Attributes accepted by `sync_update_action` that are bookkeeping metadata rather than projected Xitdb fields."
        ],
        lock_action: [
          type: :atom,
          default: :lock_field,
          doc: "Ash update action that locks a single field."
        ],
        unlock_action: [
          type: :atom,
          default: :unlock_field,
          doc: "Ash update action that unlocks a single field."
        ],
        lock_change: [
          type: :atom,
          doc:
            "`Ash.Resource.Change` module automatically wired into `lock_action` and `unlock_action` (defaults to `config :xitdb, :default_lock_change`)."
        ]
      ]
    }

    use Spark.Dsl.Extension,
      sections: [@xitdb_section],
      transformers: [Xitdb.Ash.Transformers.WireChanges],
      verifiers: [Xitdb.Ash.Verifiers.VerifySyncProjection]
  end
end
```

### 4.2 `lib/xitdb/ash/tx.ex`

Works seamlessly across both `Xitdb.Ash.Resource` (`indexes: [...]`) and `Xitdb.Ash.Dsl` / `Xitdb.Ash.DataLayer` (`index ...`) modules via `__xitdb_collection__/0`, `__xitdb_indexes__/0`, and `:xitdb_normalized_indexes`:

```elixir
defmodule Xitdb.Ash.Tx do
  @moduledoc """
  Provides `tx_for/3`, `tx_for/4`, `tx_for!/3`, and `tx_for!/4` macros that wrap
  `Xitdb.DSL.tx` and automatically inject all single-field `index_on` declarations
  configured on one or more `Xitdb.Ash.Resource` or `Xitdb.Ash.DataLayer` modules.

  Note: `use Xitdb.DSL` also imports `tx_for` and `tx_for!` directly.
  """

  defmacro tx_for(db, resources, do: body) do
    quote do
      Xitdb.DSL.tx_for(unquote(db), unquote(resources), [], do: unquote(body))
    end
  end

  defmacro tx_for(db, resources, opts, do: body) do
    quote do
      Xitdb.DSL.tx_for(unquote(db), unquote(resources), unquote(opts), do: unquote(body))
    end
  end

  defmacro tx_for!(db, resources, do: body) do
    quote do
      Xitdb.DSL.tx_for!(unquote(db), unquote(resources), [], do: unquote(body))
    end
  end

  defmacro tx_for!(db, resources, opts, do: body) do
    quote do
      Xitdb.DSL.tx_for!(unquote(db), unquote(resources), unquote(opts), do: unquote(body))
    end
  end
end
```

---

## 5. Reference Implementation: `lib/xitdb/ash/dsl.ex` (`Xitdb.Ash.Dsl`, `BuildIndexPlan`, `VerifyNoSqlFragments`, `VerifyCrossStoreReferences`)

`Xitdb.Ash.Dsl` invokes `use Spark.Dsl.Extension` directly, so:
1. In Wave 1 (`test/xitdb/ash/dsl_test.exs`), resources can attach `extensions: [Xitdb.Ash.Dsl]` before `Xitdb.Ash.DataLayer` exists in Wave 2, automatically running `BuildIndexPlan`, `VerifyNoSqlFragments`, and `VerifyCrossStoreReferences`.
2. In Wave 2 (`Xitdb.Ash.DataLayer`), `sections: Xitdb.Ash.Dsl.sections()`, `transformers: [Xitdb.Ash.Transformers.BuildIndexPlan]`, and `verifiers: [Xitdb.Ash.Verifiers.VerifyNoSqlFragments, Xitdb.Ash.Verifiers.VerifyCrossStoreReferences]` reuse the exact same Spark schema, transformer, and verifiers cleanly.

```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Dsl do
    @moduledoc """
    Spark DSL extension for `Xitdb.Ash.DataLayer` (`xitdb do ... end`).
    """

    alias Xitdb.Ash.{Index, NestedIn, Reference, SearchField}

    @doc false
    def validate_resolver(fun) when is_function(fun, 2), do: {:ok, fun}
    def validate_resolver(nil), do: {:ok, nil}
    def validate_resolver(_), do: {:error, "must be a 2-arity function (record, db) or nil"}

    @index %Spark.Dsl.Entity{
      name: :index,
      describe: "Declares a single-attribute or composite `:sorted_map` B+Tree secondary index.",
      examples: [
        "index :status",
        "index [:status, :inserted_at], name: :idx_status_recent"
      ],
      target: Index,
      args: [:fields],
      identifier: {:auto, :unique_integer},
      schema: [
        fields: [
          type: {:wrap_list, :atom},
          required: true,
          doc: "Ordered attribute name(s) composing the B+Tree index key."
        ],
        name: [
          type: {:or, [:atom, :string]},
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
      identifier: {:auto, :unique_integer},
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
          type: {:in, [:one, :many]},
          default: :many,
          doc: "Whether the parent slot stores `:many` keyed records or `:one` embedded map."
        ]
      ]
    }

    @search_field %Spark.Dsl.Entity{
      name: :search_field,
      describe:
        "Indexes an attribute (or resolved value) in `idx.search.<collection>` for BM25 + prefix search.",
      examples: [
        "search_field :full_name, boost: 3.0",
        "search_field :firm_name, boost: 2.0, resolver: &__MODULE__.resolve_firm_name/2"
      ],
      target: SearchField,
      args: [:field],
      identifier: :field,
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
          type: {:custom, __MODULE__, :validate_resolver, []},
          doc: "Optional `(record, db) -> term()` callback for cross-collection fields."
        ]
      ]
    }

    @reference %Spark.Dsl.Entity{
      name: :reference,
      describe:
        "Configures referential action when the referenced `belongs_to` parent is destroyed.",
      examples: [
        "reference :organization, on_delete: :nilify",
        "reference :organizer, on_delete: :restrict"
      ],
      target: Reference,
      args: [:relationship],
      identifier: :relationship,
      schema: [
        relationship: [
          type: :atom,
          required: true,
          doc: "Name of a `belongs_to` relationship on this resource."
        ],
        on_delete: [
          type: {:in, [:nothing, :delete, :nilify, :restrict]},
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
      describe:
        "Configures Xitdb storage, subtree nesting, B+Tree indexes, BM25 search, and FK rules.",
      entities: [@nested_in, @index, @search_field],
      sections: [@references],
      schema: [
        store: [
          type: :atom,
          doc:
            "Supervised `Xitdb.Ash.Store` module or registered name (falls back to `config :xitdb, :default_store` unless required by `BuildIndexPlan`)."
        ],
        collection: [
          type: :atom,
          doc: "Logical collection & sequence key in the `.xit` store."
        ],
        editable_fields: [
          type: {:list, :atom},
          default: [],
          doc: "Steward-editable attribute list preserved for MDM governance."
        ],
        passthru_fields: [
          type: {:list, :atom},
          default: [],
          doc: "Passthrough attribute list preserved for MDM sync compatibility."
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

    use Spark.Dsl.Extension,
      sections: [@xitdb],
      transformers: [Xitdb.Ash.Transformers.BuildIndexPlan],
      verifiers: [
        Xitdb.Ash.Verifiers.VerifyNoSqlFragments,
        Xitdb.Ash.Verifiers.VerifyCrossStoreReferences
      ]
  end

  defmodule Xitdb.Ash.Transformers.BuildIndexPlan do
    @moduledoc false
    use Spark.Dsl.Transformer

    alias Spark.Dsl.Transformer
    alias Spark.Error.DslError
    alias Xitdb.Ash.{Index, NestedIn, SearchField}

    @impl Spark.Dsl.Transformer
    def after?(Ash.Resource.Transformers.BelongsToAttribute), do: true
    def after?(Ash.Resource.Transformers.CreateJoinRelationship), do: true
    def after?(Ash.Resource.Transformers.SetTypes), do: true
    def after?(_other), do: false

    @impl Spark.Dsl.Transformer
    def transform(dsl_state) do
      module = Transformer.get_persisted(dsl_state, :module)
      attributes = Ash.Resource.Info.attributes(dsl_state)
      attrs_by_name = Map.new(attributes, &{&1.name, &1})
      attr_names = MapSet.new(Map.keys(attrs_by_name))
      pk_fields = Ash.Resource.Info.primary_key(dsl_state)

      entities = Transformer.get_entities(dsl_state, [:xitdb])
      references = strip_entities(Transformer.get_entities(dsl_state, [:xitdb, :references]))

      nested_entries =
        for %NestedIn{parent_collection: pc} = n <- entities, not is_nil(pc) do
          %NestedIn{n | __identifier__: nil, __spark_metadata__: nil}
        end

      explicit_indexes =
        for %Index{} = i <- entities do
          %Index{i | __identifier__: nil, __spark_metadata__: nil}
        end

      search_fields =
        for %SearchField{} = s <- entities do
          %SearchField{s | __identifier__: nil, __spark_metadata__: nil}
        end

      with {:ok, store} <- validate_store(module, dsl_state),
           {:ok, collection} <- validate_collection(module, dsl_state),
           :ok <- validate_primary_key(module, pk_fields),
           {:ok, nesting_plan} <- validate_nested_in(module, nested_entries, attr_names),
           :ok <- validate_explicit_indexes(module, explicit_indexes, attr_names),
           :ok <- validate_counted_set_fields(module, dsl_state, attrs_by_name),
           :ok <- validate_projected_fields(module, dsl_state, attr_names),
           :ok <- validate_search_fields(module, search_fields, attr_names) do
        all_indexes =
          maybe_append_relationship_indexes(dsl_state, explicit_indexes, pk_fields)

        normalized_indexes = build_tx_for_indexes(collection, all_indexes)

        updated_state =
          dsl_state
          |> Transformer.persist(:xitdb_store, store)
          |> Transformer.persist(:xitdb_collection, collection)
          |> Transformer.persist(:xitdb_nesting_plan, nesting_plan)
          |> Transformer.persist(:xitdb_indexes, all_indexes)
          |> Transformer.persist(:xitdb_search_fields, search_fields)
          |> Transformer.persist(:xitdb_references, references)
          |> Transformer.persist(:xitdb_normalized_indexes, normalized_indexes)
          |> define_direct_callbacks(store, collection, normalized_indexes)

        {:ok, updated_state}
      end
    end

    defp strip_entities(list) do
      Enum.map(list, &%{&1 | __identifier__: nil, __spark_metadata__: nil})
    end

    defp validate_store(module, dsl_state) do
      case Transformer.get_option(dsl_state, [:xitdb], :store) ||
             Application.get_env(:xitdb, :default_store) do
        store when is_atom(store) and not is_nil(store) ->
          {:ok, store}

        _ ->
          {:error,
           DslError.exception(
             module: module,
             path: [:xitdb, :store],
             message: "#{inspect(module)} must configure `xitdb.store`"
           )}
      end
    end

    defp validate_collection(module, dsl_state) do
      case Transformer.get_option(dsl_state, [:xitdb], :collection) do
        col when is_atom(col) and not is_nil(col) ->
          {:ok, col}

        _ ->
          {:error,
           DslError.exception(
             module: module,
             path: [:xitdb, :collection],
             message: "#{inspect(module)} must configure `xitdb.collection`"
           )}
      end
    end

    defp validate_primary_key(module, pk_fields) when length(pk_fields) > 1 do
      {:error,
       DslError.exception(
         module: module,
         path: [:attributes],
         message:
           "composite primary keys are not yet supported by Xitdb.Ash.DataLayer (got #{inspect(pk_fields)})"
       )}
    end

    defp validate_primary_key(_module, _pk_fields), do: :ok

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
      indexes
      |> Enum.reduce_while({MapSet.new(), MapSet.new()}, fn %Index{fields: fields, name: name} = idx,
                                                           {seen_fields, seen_names} ->
        slot_name = canonical_index_slot_name(idx)

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

          MapSet.member?(seen_fields, fields) ->
            {:halt,
             {:error,
              DslError.exception(
                module: module,
                path: [:xitdb, :index, fields],
                message:
                  "duplicate `index #{inspect(fields)}` declaration on #{inspect(module)}"
              )}}

          MapSet.member?(seen_names, slot_name) ->
            {:halt,
             {:error,
              DslError.exception(
                module: module,
                path: [:xitdb, :index, name || fields],
                message:
                  "colliding index slot name #{inspect(slot_name)} in `xitdb.index` on #{inspect(module)}"
              )}}

          true ->
            {:cont, {MapSet.put(seen_fields, fields), MapSet.put(seen_names, slot_name)}}
        end
      end)
      |> case do
        {:error, _} = err -> err
        {_seen_fields, _seen_names} -> :ok
      end
    end

    defp canonical_index_slot_name(%Index{name: name}) when is_atom(name) and not is_nil(name),
      do: Atom.to_string(name)

    defp canonical_index_slot_name(%Index{name: name}) when is_binary(name), do: name
    defp canonical_index_slot_name(%Index{fields: [single]}), do: "attr_#{single}"

    defp canonical_index_slot_name(%Index{fields: fields}) when is_list(fields),
      do: "idx_" <> Enum.map_join(fields, "_", &Atom.to_string/1)

    defp validate_counted_set_fields(module, dsl_state, attrs_by_name) do
      counted_fields = Transformer.get_option(dsl_state, [:xitdb], :counted_set_fields, [])

      Enum.reduce_while(counted_fields, :ok, fn field, :ok ->
        case Map.fetch(attrs_by_name, field) do
          :error ->
            {:halt,
             {:error,
              DslError.exception(
                module: module,
                path: [:xitdb, :counted_set_fields],
                message:
                  "counted_set_fields entry #{inspect(field)} is not a defined attribute on #{inspect(module)}"
              )}}

          {:ok, %{type: {:array, _}}} ->
            {:cont, :ok}

          {:ok, %{type: type}} ->
            {:halt,
             {:error,
              DslError.exception(
                module: module,
                path: [:xitdb, :counted_set_fields, field],
                message:
                  "counted_set_fields entry #{inspect(field)} must have `{:array, inner_type}` attribute type, got #{inspect(type)}"
              )}}
        end
      end)
    end

    defp validate_projected_fields(module, dsl_state, attr_names) do
      editable = Transformer.get_option(dsl_state, [:xitdb], :editable_fields, [])
      passthru = Transformer.get_option(dsl_state, [:xitdb], :passthru_fields, [])

      case Enum.reject(editable ++ passthru, &MapSet.member?(attr_names, &1)) do
        [] ->
          :ok

        missing ->
          {:error,
           DslError.exception(
             module: module,
             path: [:xitdb, :editable_fields],
             message:
               "unknown attribute(s) #{inspect(Enum.uniq(missing))} in `editable_fields` / `passthru_fields` on #{inspect(module)}"
           )}
      end
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
        Transformer.get_option(dsl_state, [:xitdb], :index_relationships?, true)

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

    defp build_tx_for_indexes(collection, all_indexes) do
      for %Index{fields: [single_field]} = idx <- all_indexes do
        {collection, single_field, canonical_index_slot_name(idx)}
      end
    end

    defp define_direct_callbacks(dsl_state, store, collection, normalized_indexes) do
      Transformer.eval(
        dsl_state,
        [store: store, collection: collection, normalized_indexes: normalized_indexes],
        quote do
          @doc false
          def __xitdb_store__, do: unquote(Macro.escape(store))

          @doc false
          def __xitdb_collection__, do: unquote(Macro.escape(collection))

          @doc false
          def __xitdb_indexes__, do: unquote(Macro.escape(normalized_indexes))
        end
      )
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
           :ok <- check_aggregates(module, dsl_state),
           :ok <- check_relationships(module, dsl_state),
           :ok <- check_identities(module, dsl_state),
           :ok <- check_resource_validations_changes_and_preparations(module, dsl_state),
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
           fragment_error(
             module,
             [:calculations, calc.name],
             "calculation #{inspect(calc.name)}"
           )}
        else
          {:cont, :ok}
        end
      end)
    end

    defp check_aggregates(module, dsl_state) do
      dsl_state
      |> Ash.Resource.Info.aggregates()
      |> Enum.reduce_while(:ok, fn agg, :ok ->
        agg_terms = [Map.get(agg, :filter), Map.get(agg, :join_filters)]

        if contains_sql_fragment?(agg_terms) do
          {:halt,
           fragment_error(
             module,
             [:aggregates, agg.name],
             "aggregate #{inspect(agg.name)}"
           )}
        else
          {:cont, :ok}
        end
      end)
    end

    defp check_relationships(module, dsl_state) do
      dsl_state
      |> Ash.Resource.Info.relationships()
      |> Enum.reduce_while(:ok, fn rel, :ok ->
        if contains_sql_fragment?(Map.get(rel, :filter)) do
          {:halt,
           fragment_error(
             module,
             [:relationships, rel.name],
             "relationship #{inspect(rel.name)} `filter`"
           )}
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

    defp check_resource_validations_changes_and_preparations(module, dsl_state) do
      validations = Ash.Resource.Info.validations(dsl_state)
      changes = Ash.Resource.Info.changes(dsl_state)
      preparations = Ash.Resource.Info.preparations(dsl_state)

      cond do
        Enum.any?(validations, &contains_sql_fragment?/1) ->
          fragment_error(module, [:validations], "resource `validations` block")

        Enum.any?(changes, &contains_sql_fragment?/1) ->
          fragment_error(module, [:changes], "resource `changes` block")

        Enum.any?(preparations, &contains_sql_fragment?/1) ->
          fragment_error(module, [:preparations], "resource `preparations` block")

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
          Map.get(action, :validations),
          Map.get(action, :preparations)
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

        field_policies =
          if function_exported?(Ash.Policy.Info, :field_policies, 1) do
            Ash.Policy.Info.field_policies(dsl_state)
          else
            []
          end

        cond do
          contains_sql_fragment?(policies) ->
            fragment_error(module, [:policies], "`policies` block")

          contains_sql_fragment?(field_policies) ->
            fragment_error(module, [:field_policies], "`field_policies` block")

          true ->
            :ok
        end
      else
        :ok
      end
    end

    # Specific fragment struct/call/AST matches MUST appear before generic `%_{} = struct`
    defp contains_sql_fragment?(%Ash.Query.Function.Fragment{}), do: true
    defp contains_sql_fragment?(%Ash.Query.Call{name: :fragment}), do: true
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
           "SQL `fragment(...)` is not supported by `Xitdb.Ash.DataLayer` (found in #{location_desc}). " <>
             "Replace it with a portable `Ash.Expr` expression or an `Ash.Resource.Calculation` module."
       )}
    end
  end

  defmodule Xitdb.Ash.Verifiers.VerifyCrossStoreReferences do
    @moduledoc false
    use Spark.Dsl.Verifier

    alias Spark.Dsl.Verifier
    alias Spark.Error.DslError
    alias Xitdb.Ash.{Info, NestedIn, Reference}

    @impl Spark.Dsl.Verifier
    def verify(dsl_state) do
      module = Verifier.get_persisted(dsl_state, :module)
      own_store = Info.store!(dsl_state)
      declared_refs = Info.references(dsl_state)

      belongs_to_rels =
        dsl_state
        |> Ash.Resource.Info.relationships()
        |> Enum.filter(&match?(%Ash.Resource.Relationships.BelongsTo{}, &1))

      belongs_to_by_name = Map.new(belongs_to_rels, &{&1.name, &1})
      refs_by_rel = Map.new(declared_refs, &{&1.relationship, &1})

      with :ok <- verify_declared_references_exist(module, declared_refs, belongs_to_by_name),
           :ok <-
             Enum.reduce_while(belongs_to_rels, :ok, fn rel, :ok ->
               ref = Map.get(refs_by_rel, rel.name)
               on_delete = if ref, do: ref.on_delete, else: :nothing
               validate_reference(module, own_store, rel, on_delete)
             end) do
        verify_nested_parent(module, dsl_state, own_store)
      end
    end

    defp verify_declared_references_exist(module, declared_refs, belongs_to_by_name) do
      Enum.reduce_while(declared_refs, :ok, fn %Reference{relationship: rel_name}, :ok ->
        case Map.fetch(belongs_to_by_name, rel_name) do
          {:ok, _rel} ->
            {:cont, :ok}

          :error ->
            {:halt,
             {:error,
              DslError.exception(
                module: module,
                path: [:xitdb, :references, rel_name],
                message:
                  "reference #{inspect(rel_name)} must match a `belongs_to` relationship on #{inspect(module)}"
              )}}
        end
      end)
    end

    defp validate_reference(_mod, _store, _rel, :nothing), do: {:cont, :ok}

    defp validate_reference(mod, _own_store, %{name: name, allow_nil?: false}, :nilify) do
      {:halt,
       {:error,
        DslError.exception(
          module: mod,
          path: [:xitdb, :references, name],
          message:
            "cannot set `on_delete: :nilify` when `belongs_to #{inspect(name)}` has `allow_nil?: false`"
        )}}
    end

    defp validate_reference(mod, own_store, %{name: name, destination: dest}, on_delete) do
      _ = Code.ensure_compiled(dest)

      if not xitdb_datalayer_or_dsl_resource?(dest) do
        {:halt,
         {:error,
          DslError.exception(
            module: mod,
            path: [:xitdb, :references, name],
            message:
              "Cannot enforce on_delete: #{inspect(on_delete)} toward non-Xitdb resource #{inspect(dest)}; use an Ash.Notifier or AshOban trigger instead."
          )}}
      else
        case Info.fetch_store(dest) do
          {:ok, ^own_store} ->
            {:cont, :ok}

          {:ok, dest_store} ->
            {:halt,
             {:error,
              DslError.exception(
                module: mod,
                path: [:xitdb, :references, name],
                message:
                  "Cross-store on_delete: #{inspect(on_delete)} from #{inspect(own_store)} to #{inspect(dest_store)} is not supported."
              )}}

          :error ->
            {:halt,
             {:error,
              DslError.exception(
                module: mod,
                path: [:xitdb, :references, name],
                message:
                  "Cross-store on_delete: #{inspect(on_delete)} toward #{inspect(dest)} without a configured `xitdb.store` is not supported."
              )}}
        end
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
      _ = Code.ensure_compiled(dest)

      if not xitdb_datalayer_or_dsl_resource?(dest) do
        {:error,
         DslError.exception(
           module: module,
           path: [:xitdb, :nested_in, parent_col],
           message:
             "`nested_in` parent resource #{inspect(dest)} must use `Xitdb.Ash.DataLayer`"
         )}
      else
        case Info.fetch_store(dest) do
          :error ->
            {:error,
             DslError.exception(
               module: module,
               path: [:xitdb, :nested_in, parent_col],
               message:
                 "`nested_in` parent resource #{inspect(dest)} has no `xitdb.store` configured"
             )}

          {:ok, dest_store} when dest_store != source_store ->
            {:error,
             DslError.exception(
               module: module,
               path: [:xitdb, :nested_in, parent_col],
               message:
                 "`nested_in` child #{inspect(module)} (#{inspect(source_store)}) must share the same store as parent #{inspect(dest)} (#{inspect(dest_store)})"
             )}

          {:ok, ^source_store} ->
            case Info.fetch_collection(dest) do
              :error ->
                {:error,
                 DslError.exception(
                   module: module,
                   path: [:xitdb, :nested_in, parent_col],
                   message:
                     "`nested_in` parent resource #{inspect(dest)} has no `xitdb.collection` configured"
                 )}

              {:ok, actual_col} when actual_col != parent_col ->
                {:error,
                 DslError.exception(
                   module: module,
                   path: [:xitdb, :nested_in, parent_col],
                   message:
                     "`nested_in #{inspect(parent_col)}` does not match parent #{inspect(dest)} collection #{inspect(actual_col)}"
                 )}

              {:ok, ^parent_col} ->
                :ok
            end
        end
      end
    end

    defp xitdb_datalayer_or_dsl_resource?(dest) when is_atom(dest) do
      Ash.Resource.Info.data_layer(dest) == Xitdb.Ash.DataLayer or
        Xitdb.Ash.Dsl in Spark.extensions(dest)
    end
  end
end
```

---

## 6. Additive Reference Implementation: `lib/xitdb/ash/info.ex`

Preserves **100%** of `v1.0.2` MDM + Track 5A Step 3 helpers (`use Spark.InfoGenerator, extension: Xitdb.Ash.Resource, sections: [:xitdb]`, `editable_field_strings/1`, `pull_fields/1`, `pull_pattern_for/1`, `nested_mappings/1`, `nested?/1`, `nested_under/2`, `entity_paths/2`, `resolve_store/2`, `resolve_lock_change/1`, atomic per-pair `cached_pair/4`, `__purge_pair_cache__/1`) while adding all `Xitdb.Ash.DataLayer` / `Xitdb.Ash.Dsl` `O(1)` persisted introspection helpers:

```elixir
if Code.ensure_loaded?(Spark.InfoGenerator) and Code.ensure_loaded?(Ash.Resource) do
  defmodule Xitdb.Ash.Info do
    @moduledoc """
    Compile-time and runtime introspection helpers for `Xitdb.Ash.DataLayer`,
    `Xitdb.Ash.Dsl`, and `Xitdb.Ash.Resource`.
    """

    use Spark.InfoGenerator,
      extension: Xitdb.Ash.Resource,
      sections: [:xitdb]

    alias Spark.Dsl.Extension
    alias Xitdb.Ash.{Index, NestedIn, Reference, SearchField}
    alias Xitdb.Pull

    @type resource_or_dsl :: Ash.Resource.t() | Spark.Dsl.t()

    # ==========================================================================
    # Shared & DataLayer Persisted Introspection Helpers
    # ==========================================================================

    @doc """
    Returns the configured `Xitdb.Ash.Store` module for `resource_or_dsl`, or `nil` if undeclared.
    """
    @spec store(resource_or_dsl()) :: module() | nil
    def store(resource_or_dsl) do
      resolve_store(resource_or_dsl, [])
    end

    @doc """
    Fetches `{:ok, store_mod}` when a `xitdb.store` (or `:default_store`) is configured, or `:error`.
    """
    @spec fetch_store(resource_or_dsl()) :: {:ok, module()} | :error
    def fetch_store(resource_or_dsl) do
      case store(resource_or_dsl) do
        store_mod when is_atom(store_mod) and not is_nil(store_mod) -> {:ok, store_mod}
        _ -> :error
      end
    end

    @doc """
    Returns the configured `Xitdb.Ash.Store` module for `resource_or_dsl`, raising `ArgumentError` if undeclared.
    """
    @spec store!(resource_or_dsl()) :: module()
    def store!(resource_or_dsl) do
      case fetch_store(resource_or_dsl) do
        {:ok, store_mod} ->
          store_mod

        :error ->
          raise ArgumentError, "Resource #{inspect(resource_or_dsl)} does not declare a store"
      end
    end

    @doc """
    Returns the primary Xitdb collection atom for `resource_or_dsl`, or `nil` if undeclared.
    """
    @spec collection(resource_or_dsl()) :: atom() | nil
    def collection(resource) when is_atom(resource) do
      fetch_persisted_or_compute(
        resource,
        :__xitdb_collection__,
        :xitdb_collection,
        &collection_from_dsl/1
      )
    end

    def collection(dsl_state), do: collection_from_dsl(dsl_state)

    defp collection_from_dsl(resource_or_dsl) do
      case Extension.fetch_opt(resource_or_dsl, [:xitdb], :collection) do
        {:ok, col} when is_atom(col) and not is_nil(col) -> col
        _ -> nil
      end
    end

    @doc """
    Fetches `{:ok, collection}` when `xitdb.collection` is configured, or `:error`.
    """
    @spec fetch_collection(resource_or_dsl()) :: {:ok, atom()} | :error
    def fetch_collection(resource_or_dsl) do
      case collection(resource_or_dsl) do
        col when is_atom(col) and not is_nil(col) -> {:ok, col}
        _ -> :error
      end
    end

    @doc """
    Returns the primary Xitdb collection atom for `resource_or_dsl`, raising `ArgumentError` if undeclared.
    """
    @spec collection!(resource_or_dsl()) :: atom()
    def collection!(resource_or_dsl) do
      case fetch_collection(resource_or_dsl) do
        {:ok, col} ->
          col

        :error ->
          raise ArgumentError,
                "Resource #{inspect(resource_or_dsl)} does not declare a collection"
      end
    end

    @doc """
    Returns steward-editable field atoms declared on `resource_or_dsl`.
    """
    @spec editable_fields(resource_or_dsl()) :: [atom()]
    def editable_fields(resource_or_dsl) do
      Extension.get_opt(resource_or_dsl, [:xitdb], :editable_fields, [])
    end

    @doc """
    Returns passthrough field atoms declared on `resource_or_dsl`.
    """
    @spec passthru_fields(resource_or_dsl()) :: [atom()]
    def passthru_fields(resource_or_dsl) do
      Extension.get_opt(resource_or_dsl, [:xitdb], :passthru_fields, [])
    end

    @doc """
    Returns attributes configured as `:counted_hash_set` slots on `resource_or_dsl`.
    """
    @spec counted_set_fields(resource_or_dsl()) :: [atom()]
    def counted_set_fields(resource_or_dsl) do
      Extension.get_opt(resource_or_dsl, [:xitdb], :counted_set_fields, [])
    end

    @doc """
    Returns whether `belongs_to` foreign keys are indexed automatically on `resource_or_dsl`.
    """
    @spec index_relationships?(resource_or_dsl()) :: boolean()
    def index_relationships?(resource_or_dsl) do
      Extension.get_opt(resource_or_dsl, [:xitdb], :index_relationships?, true)
    end

    @doc """
    Returns the `%Xitdb.Ash.NestedIn{}` subtree plan if `resource_or_dsl` uses DataLayer
    co-located nesting (`:xitdb_nesting_plan`), or `nil`.

    Note: Uses `:xitdb_nesting_plan` so it never collides with `Xitdb.Ash.Resource`'s
    `:xitdb_nested_in` list (`nested_mappings/1`).
    """
    @spec nested_in(resource_or_dsl()) :: NestedIn.t() | nil
    def nested_in(resource_or_dsl) do
      case Extension.get_persisted(resource_or_dsl, :xitdb_nesting_plan, :__not_persisted__) do
        :__not_persisted__ ->
          resource_or_dsl
          |> Extension.get_entities([:xitdb])
          |> Enum.find(fn
            %NestedIn{parent_collection: pc} when not is_nil(pc) -> true
            _ -> false
          end)
          |> case do
            %NestedIn{} = n -> %NestedIn{n | __identifier__: nil, __spark_metadata__: nil}
            nil -> nil
          end

        persisted ->
          persisted
      end
    end

    @doc """
    Returns all explicit and auto-generated `%Xitdb.Ash.Index{}` definitions for `resource_or_dsl`.
    """
    @spec indexes(resource_or_dsl()) :: [Index.t()]
    def indexes(resource_or_dsl) do
      case Extension.get_persisted(resource_or_dsl, :xitdb_indexes, :__not_persisted__) do
        :__not_persisted__ ->
          for %Index{} = idx <- Extension.get_entities(resource_or_dsl, [:xitdb]) do
            %Index{idx | __identifier__: nil, __spark_metadata__: nil}
          end

        persisted ->
          persisted
      end
    end

    @doc """
    Returns secondary indexes whose leading column is `field`, ordered from narrowest
    (single-column `[field]`) to widest composite index for the Stage 1 query planner.
    """
    @spec indexes_for_field(resource_or_dsl(), atom()) :: [Index.t()]
    def indexes_for_field(resource_or_dsl, field) when is_atom(field) do
      resource_or_dsl
      |> indexes()
      |> Enum.filter(fn %Index{fields: [leading | _]} -> leading == field end)
      |> Enum.sort_by(fn %Index{fields: fields} -> length(fields) end)
    end

    @doc """
    Returns all `%Xitdb.Ash.SearchField{}` definitions for `resource_or_dsl`.
    """
    @spec search_fields(resource_or_dsl()) :: [SearchField.t()]
    def search_fields(resource_or_dsl) do
      case Extension.get_persisted(resource_or_dsl, :xitdb_search_fields, :__not_persisted__) do
        :__not_persisted__ ->
          for %SearchField{} = sf <- Extension.get_entities(resource_or_dsl, [:xitdb]) do
            %SearchField{sf | __identifier__: nil, __spark_metadata__: nil}
          end

        persisted ->
          persisted
      end
    end

    @doc """
    Returns outgoing `%Xitdb.Ash.Reference{}` foreign-key rules declared on `resource_or_dsl`.
    """
    @spec references(resource_or_dsl()) :: [Reference.t()]
    def references(resource_or_dsl) do
      case Extension.get_persisted(resource_or_dsl, :xitdb_references, :__not_persisted__) do
        :__not_persisted__ ->
          for %Reference{} = ref <- Extension.get_entities(resource_or_dsl, [:xitdb, :references]) do
            %Reference{ref | __identifier__: nil, __spark_metadata__: nil}
          end

        persisted ->
          persisted
      end
    end

    # ==========================================================================
    # v1.0.2 MDM Sync-Projection & Companion Pair Helpers (100% Preserved)
    # ==========================================================================

    @doc """
    Returns the deduplicated list of editable and computed Xitdb field names as strings
    for one or more `Xitdb.Ash.Resource` modules, applying any configured `field_aliases`.
    """
    @spec editable_field_strings(Ash.Resource.t() | [Ash.Resource.t()]) :: [String.t()]
    def editable_field_strings([resource]), do: editable_field_strings(resource)

    def editable_field_strings([a, b]) when is_atom(a) and is_atom(b) do
      cached_pair(:editable_field_strings, a, b, fn ->
        Enum.uniq(editable_field_strings(a) ++ editable_field_strings(b))
      end)
    end

    def editable_field_strings(resources) when is_list(resources) do
      resources
      |> Enum.flat_map(&editable_field_strings/1)
      |> Enum.uniq()
    end

    def editable_field_strings(resource) when is_atom(resource) do
      fetch_persisted_or_compute(
        resource,
        :__xitdb_editable_field_strings__,
        :xitdb_editable_field_strings,
        &compute_editable_field_strings/1
      )
    end

    def editable_field_strings(dsl_state), do: compute_editable_field_strings(dsl_state)

    @doc false
    def compute_editable_field_strings(resource_or_dsl) do
      aliases = Extension.get_opt(resource_or_dsl, [:xitdb], :field_aliases, [])
      editable = Extension.get_opt(resource_or_dsl, [:xitdb], :editable_fields, [])
      computed = Extension.get_opt(resource_or_dsl, [:xitdb], :computed_xitdb_fields, [])

      (editable ++ computed)
      |> Enum.map(fn attr -> to_string(Keyword.get(aliases, attr, attr)) end)
      |> Enum.uniq()
    end

    @doc """
    Returns the deduplicated list of Xitdb slot atoms (`[:id | editable ++ passthru]`)
    for one or more `Xitdb.Ash.Resource` modules, applying any configured `field_aliases`.
    """
    @spec pull_fields(Ash.Resource.t() | [Ash.Resource.t()]) :: [atom()]
    def pull_fields([resource]), do: pull_fields(resource)

    def pull_fields([a, b]) when is_atom(a) and is_atom(b) do
      cached_pair(:pull_fields, a, b, fn ->
        Enum.uniq(pull_fields(a) ++ pull_fields(b))
      end)
    end

    def pull_fields(resources) when is_list(resources) do
      resources
      |> Enum.flat_map(&pull_fields/1)
      |> Enum.uniq()
    end

    def pull_fields(resource) when is_atom(resource) do
      fetch_persisted_or_compute(
        resource,
        :__xitdb_pull_fields__,
        :xitdb_pull_fields,
        &compute_pull_fields/1
      )
    end

    def pull_fields(dsl_state), do: compute_pull_fields(dsl_state)

    @doc false
    def compute_pull_fields(resource_or_dsl) do
      aliases = Extension.get_opt(resource_or_dsl, [:xitdb], :field_aliases, [])
      editable = Extension.get_opt(resource_or_dsl, [:xitdb], :editable_fields, [])
      passthru = Extension.get_opt(resource_or_dsl, [:xitdb], :passthru_fields, [])

      ([:id] ++ editable ++ passthru)
      |> Enum.map(&Keyword.get(aliases, &1, &1))
      |> Enum.uniq()
    end

    @doc """
    Compiles a structural `Xitdb.Pull` pattern string for one or more `Xitdb.Ash.Resource` modules.
    """
    @spec pull_pattern_for(Ash.Resource.t() | [Ash.Resource.t()]) :: String.t()
    def pull_pattern_for([resource]), do: pull_pattern_for(resource)

    def pull_pattern_for([a, b] = pair) when is_atom(a) and is_atom(b) do
      cached_pair(:pull_pattern, a, b, fn ->
        pair |> pull_fields() |> Pull.compile!()
      end)
    end

    def pull_pattern_for(resource) when is_atom(resource) do
      fetch_persisted_or_compute(
        resource,
        :__xitdb_pull_pattern__,
        :xitdb_pull_pattern,
        &(&1 |> pull_fields() |> Pull.compile!())
      )
    end

    def pull_pattern_for(resources) do
      resources
      |> pull_fields()
      |> Pull.compile!()
    end

    @doc """
    Returns the MDM `nested_in` declarations (`Xitdb.Ash.NestedIn` structs) of a resource,
    or `[]` for resources stored in their own top-level collection.
    """
    @spec nested_mappings(resource_or_dsl()) :: [NestedIn.t()]
    def nested_mappings(resource) when is_atom(resource) do
      fetch_persisted_or_compute(
        resource,
        :__xitdb_nested_in__,
        :xitdb_nested_in,
        &compute_nested_mappings/1
      )
    end

    def nested_mappings(dsl_state), do: compute_nested_mappings(dsl_state)

    @doc false
    def compute_nested_mappings(resource_or_dsl) do
      for %NestedIn{parent: parent} = mapping <- Extension.get_entities(resource_or_dsl, [:xitdb]),
          not is_nil(parent) do
        %NestedIn{mapping | __identifier__: nil, __spark_metadata__: nil}
      end
    end

    @doc "Returns `true` when the resource is stored inside a parent entity."
    @spec nested?(resource_or_dsl()) :: boolean()
    def nested?(resource_or_dsl) do
      nested_in(resource_or_dsl) != nil or nested_mappings(resource_or_dsl) != []
    end

    @doc """
    Filters `resources` down to those nested in `parent`, returning
    `{resource, %Xitdb.Ash.NestedIn{}}` pairs.
    """
    @spec nested_under([Ash.Resource.t()], Ash.Resource.t()) ::
            [{Ash.Resource.t(), NestedIn.t()}]
    def nested_under(resources, parent) when is_list(resources) and is_atom(parent) do
      for resource <- resources,
          %NestedIn{parent: ^parent} = mapping <- nested_mappings(resource) do
        {resource, mapping}
      end
    end

    @doc """
    Returns every Xitdb path (a list of string keys from the root) where `record` is stored.
    """
    @spec entity_paths(Ash.Resource.t(), map()) :: [[String.t()]]
    def entity_paths(resource, record) when is_atom(resource) and is_map(record) do
      case nested_mappings(resource) do
        [] ->
          with {:ok, col} <- fetch_collection(resource),
               id when not is_nil(id) and id != "" <- fetch_record_value(record, :id) do
            [[to_string(col), to_string(id)]]
          else
            _ -> []
          end

        mappings ->
          Enum.flat_map(mappings, &nested_entity_path(&1, record))
      end
    end

    defp nested_entity_path(%NestedIn{} = mapping, record) do
      parent_collection = collection(mapping.parent)
      parent_id = fetch_record_value(record, mapping.parent_key)

      cond do
        is_nil(parent_collection) ->
          raise ArgumentError,
                "#{inspect(mapping.parent)} has no top-level `collection`; `nested_in` parents must be top-level resources."

        blank?(parent_id) ->
          []

        mapping.cardinality == :one ->
          [[to_string(parent_collection), to_string(parent_id), to_string(mapping.as)]]

        true ->
          case fetch_record_value(record, mapping.key) do
            entry_key when is_nil(entry_key) or entry_key == "" ->
              []

            entry_key ->
              [
                [
                  to_string(parent_collection),
                  to_string(parent_id),
                  to_string(mapping.as),
                  to_string(entry_key)
                ]
              ]
          end
      end
    end

    defp fetch_record_value(_record, nil), do: nil

    defp fetch_record_value(record, key) when is_atom(key) do
      case Map.get(record, key) do
        nil -> Map.get(record, Atom.to_string(key))
        val -> val
      end
    end

    defp blank?(nil), do: true
    defp blank?(""), do: true
    defp blank?(_), do: false

    @doc """
    Resolves the target Xitdb store server from `context[:xitdb_store]`, keyword `opts[:store]`,
    the resource's `xitdb.store` option, or `Application.get_env(:xitdb, :default_store)`.
    """
    @spec resolve_store(resource_or_dsl(), map() | keyword()) :: GenServer.server() | nil
    def resolve_store(_resource, %{xitdb_store: store}) when not is_nil(store), do: store

    def resolve_store(resource, opts) when is_list(opts) do
      Keyword.get_lazy(opts, :store, fn -> default_store(resource) end)
    end

    def resolve_store(resource, _), do: default_store(resource)

    @doc """
    Resolves the `Ash.Resource.Change` module for locking/unlocking fields from the
    resource's `xitdb.lock_change` option or `Application.get_env(:xitdb, :default_lock_change)`.
    """
    @spec resolve_lock_change(resource_or_dsl()) :: module() | nil
    def resolve_lock_change(resource) when is_atom(resource) do
      resolve_option_with_env(
        resource,
        :__xitdb_lock_change__,
        :xitdb_lock_change,
        &Extension.fetch_opt(&1, [:xitdb], :lock_change),
        :default_lock_change
      )
    end

    def resolve_lock_change(dsl_state) do
      case Extension.fetch_opt(dsl_state, [:xitdb], :lock_change) do
        {:ok, mod} when not is_nil(mod) -> mod
        _ -> Application.get_env(:xitdb, :default_lock_change)
      end
    end

    defp default_store(resource) when is_atom(resource) do
      resolve_option_with_env(
        resource,
        :__xitdb_store__,
        :xitdb_store,
        &Extension.fetch_opt(&1, [:xitdb], :store),
        :default_store
      )
    end

    defp default_store(dsl_state) do
      case Extension.fetch_opt(dsl_state, [:xitdb], :store) do
        {:ok, store} when not is_nil(store) -> store
        _ -> Application.get_env(:xitdb, :default_store)
      end
    end

    defp fetch_persisted_or_compute(resource, callback, persisted_key, compute_fun) do
      if Code.ensure_loaded?(resource) and function_exported?(resource, callback, 0) do
        apply(resource, callback, [])
      else
        case Extension.get_persisted(resource, persisted_key, :__not_persisted__) do
          :__not_persisted__ -> compute_fun.(resource)
          cached -> cached
        end
      end
    end

    defp resolve_option_with_env(resource, callback, persisted_key, dsl_fetcher, env_key) do
      configured =
        fetch_persisted_or_compute(resource, callback, persisted_key, fn res ->
          case dsl_fetcher.(res) do
            {:ok, val} -> val
            _ -> nil
          end
        end)

      configured || Application.get_env(:xitdb, env_key)
    end

    defp cached_pair(kind, a, b, compute_fun) do
      key = {__MODULE__, :pair, kind, a, b}

      case :persistent_term.get(key, :__miss__) do
        :__miss__ ->
          val = compute_fun.()

          if Code.ensure_loaded?(a) and function_exported?(a, :__xitdb_pull_fields__, 0) and
               Code.ensure_loaded?(b) and function_exported?(b, :__xitdb_pull_fields__, 0) do
            :persistent_term.put(key, val)
          end

          val

        cached ->
          cached
      end
    end

    @doc false
    def __purge_pair_cache__(module) when is_atom(module) do
      for {{__MODULE__, :pair, _kind, a, b} = key, _val} <- :persistent_term.get(),
          a == module or b == module do
        :persistent_term.erase(key)
      end

      :ok
    end
  end
end
```

---

## 7. Self-Contained Wave 1 Bootstrap Baselines (`Snapshot` & `Search`)

Because `master` (`v1.0.2`) does not yet include `lib/xitdb/ash/store/snapshot.ex` or `lib/xitdb/ash/search.ex` (referenced by `TestSearchProfile` and `Xitdb.Ash.DataLayer`), Wave 1 includes their complete self-contained baseline implementations below so applying Wave 1 directly onto `master` has zero missing module dependencies.

### 7.1 `lib/xitdb/ash/store/snapshot.ex`

```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Store.Snapshot do
    @moduledoc false

    alias Xitdb.Ash.TestSandbox

    @type reverse_fk :: %{
            :source_resource => module(),
            :source_collection => atom(),
            :source_attribute => atom(),
            :destination_attribute => atom(),
            :on_delete => :delete | :nilify | :restrict,
            optional(:nested?) => boolean()
          }

    @type reverse_fk_map :: %{optional(module()) => [reverse_fk()]}

    @uncommitted_moment -1

    @doc """
    Publishes `{base_db, atomics_ref, reverse_fks}` to `:persistent_term` once at store boot.
    """
    @spec put_base(module(), term(), keyword()) :: :ok
    def put_base(store, base_db, opts \\ []) when is_atom(store) and is_list(opts) do
      initial_moment = Keyword.get(opts, :moment, @uncommitted_moment)
      reverse_fks = Keyword.get(opts, :reverse_fks, %{})

      atomics = :atomics.new(1, signed: true)
      :ok = :atomics.put(atomics, 1, initial_moment)
      :persistent_term.put(pt_key(store), {base_db, atomics, reverse_fks})
    end

    @doc """
    Replaces `base_db` after a background `.xit` file compaction while preserving `reverse_fks`.
    """
    @spec swap_compacted_base(module(), term(), integer()) :: :ok
    def swap_compacted_base(store, compacted_db, moment)
        when is_atom(store) and is_integer(moment) and moment >= @uncommitted_moment do
      {_old_db, atomics, reverse_fks} = fetch_slot!(store)
      :ok = :atomics.put(atomics, 1, moment)
      :persistent_term.put(pt_key(store), {compacted_db, atomics, reverse_fks})
    end

    @doc """
    Advances the published snapshot moment in ~5ns with zero heap allocation or global GC.
    """
    @spec advance_moment(module(), non_neg_integer()) :: :ok
    def advance_moment(store, moment)
        when is_atom(store) and is_integer(moment) and moment >= 0 do
      {_base_db, atomics, _reverse_fks} = fetch_slot!(store)
      :atomics.put(atomics, 1, moment)
    end

    @doc """
    Returns the latest committed integer moment, or `-1` before the first write commit.
    """
    @spec current_moment(module()) :: integer()
    def current_moment(store) when is_atom(store) do
      {_base_db, atomics, _reverse_fks} = fetch_slot!(store)
      :atomics.get(atomics, 1)
    end

    @doc """
    Resolves the active database handle in 3 lock-free tiers:
    1. Caller's active transaction working handle (`{:xitdb_tx_db, store}`).
    2. Caller or `$callers` isolated `TestSandbox` CoW handle.
    3. Latest committed `Xitdb.as_of/2` moment from `{base_db, atomics}`.
    """
    @spec current_db(module()) :: term()
    def current_db(store) when is_atom(store) do
      case Process.get({:xitdb_tx_db, store}) do
        nil -> sandbox_or_committed_db(store)
        tx_db -> tx_db
      end
    end

    @doc """
    Returns the latest committed `%Xitdb{}` snapshot directly, bypassing tx/sandbox overrides.
    """
    @spec committed_db(module()) :: term()
    def committed_db(store) when is_atom(store) do
      {base_db, atomics, _reverse_fks} = fetch_slot!(store)

      case :atomics.get(atomics, 1) do
        @uncommitted_moment -> base_db
        moment -> Xitdb.as_of(base_db, moment)
      end
    end

    @doc """
    Returns incoming same-store foreign-key rules targeting `resource`.
    """
    @spec reverse_fks(module(), module()) :: [reverse_fk()]
    def reverse_fks(store, resource) when is_atom(store) and is_atom(resource) do
      {_base_db, _atomics, reverse_fks} = fetch_slot!(store)
      Map.get(reverse_fks, resource, [])
    end

    @doc """
    Removes the `:persistent_term` entry when stopping dynamically named stores in tests.
    """
    @spec erase(module()) :: boolean()
    def erase(store) when is_atom(store) do
      :persistent_term.erase(pt_key(store))
    end

    defp sandbox_or_committed_db(store) do
      if Code.ensure_loaded?(TestSandbox) and function_exported?(TestSandbox, :checkout_db, 1) do
        case apply(TestSandbox, :checkout_db, [store]) do
          {:ok, sandbox_db} -> sandbox_db
          :none -> committed_db(store)
        end
      else
        committed_db(store)
      end
    end

    defp fetch_slot!(store) do
      case :persistent_term.get(pt_key(store), nil) do
        nil ->
          raise ArgumentError,
                "Xitdb.Ash.Store #{inspect(store)} is not started or has no initialized Snapshot"

        slot ->
          slot
      end
    end

    defp pt_key(store), do: {__MODULE__, store}
  end
end
```

### 7.2 `lib/xitdb/ash/search.ex`

```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Search do
    @moduledoc """
    Transactional in-Xitdb BM25 and B+Tree prefix search for `Xitdb.Ash.DataLayer` resources.

    Maintains inverted postings directly inside `idx.search.<collection>` on the resource's
    configured `.xit` store so search queries, `Ash.read` hydrations, `Xitdb.as_of/2`
    time-travel, and `Xitdb.Ash.TestSandbox` checkouts observe the exact same snapshot.

    ## Telemetry

    * `[:xitdb, :ash, :search, :start | :stop | :exception]` — emitted by `query/3`,
      carrying `%{resource: module(), collection: atom(), result_count: non_neg_integer(), status: :ok}`.
    """

    require Ash.Expr
    require Ash.Query
    require Ash.Sort

    alias Xitdb.Ash.Info
    alias Xitdb.Ash.Search.Storage

    @weight_scale 100
    @exact_match_boost 1.25

    @query_schema NimbleOptions.new!(
                    limit: [
                      type: :pos_integer,
                      default: 50,
                      doc: "Maximum number of ranked hits to return."
                    ],
                    match: [
                      type: {:in, [:all, :any]},
                      default: :all,
                      doc: "Whether documents must match `:all` query tokens or `:any` token."
                    ],
                    prefix?: [
                      type: :boolean,
                      default: true,
                      doc:
                        "Enables B+Tree prefix expansion on tokens meeting `:min_prefix_length`."
                    ],
                    min_prefix_length: [
                      type: :pos_integer,
                      default: 3,
                      doc: "Minimum character length required before prefix-scanning a token."
                    ],
                    max_prefix_expansions: [
                      type: :pos_integer,
                      default: 64,
                      doc: "Maximum B+Tree terms scanned per prefix token."
                    ],
                    k1: [
                      type: :float,
                      default: 1.2,
                      doc: "BM25 term-frequency saturation parameter."
                    ],
                    b: [
                      type: :float,
                      default: 0.75,
                      doc: "BM25 document-length normalization parameter."
                    ],
                    tenant: [
                      type: :any,
                      default: nil,
                      doc: "Optional tenant scope for `:context`-multitenant collections."
                    ],
                    db: [
                      type: :any,
                      default: nil,
                      doc: "Explicit `%Xitdb{}` handle; defaults to `Snapshot.current_db/1`."
                    ]
                  )

    @type doc_key :: String.t()
    @type hit :: {id :: integer() | String.t(), score :: float()}

    @doc """
    Searches `resource`'s `idx.search.<collection>` index and returns ranked `{id, score}` hits.

    ## Options
    #{NimbleOptions.docs(@query_schema)}
    """
    @spec query(module(), String.t() | nil, keyword()) :: [hit()]
    def query(resource, query_text, opts \\ []) when is_atom(resource) and is_list(opts) do
      opts = NimbleOptions.validate!(opts, @query_schema)
      tokens = query_text |> tokenize() |> Enum.uniq()

      if tokens == [] do
        []
      else
        execute_ranked_query(resource, tokens, opts)
      end
    end

    @doc """
    Convenience wrapper around `query/3` returning only ranked primary keys.
    """
    @spec ids(module(), String.t() | nil, keyword()) :: [integer() | String.t()]
    def ids(resource, query_text, opts \\ []) do
      resource
      |> query(query_text, opts)
      |> Enum.map(&elem(&1, 0))
    end

    @doc """
    Applies deterministic BM25 rank ordering to an `Ash.Query` filtered by `ranked_ids`.
    """
    @spec sort_by_rank(Ash.Query.t(), [integer() | String.t()]) :: Ash.Query.t()
    def sort_by_rank(%Ash.Query{} = ash_query, []), do: ash_query

    def sort_by_rank(%Ash.Query{} = ash_query, ranked_ids) when is_list(ranked_ids) do
      max_rank = length(ranked_ids)

      rank_expr =
        Enum.reduce(Enum.with_index(ranked_ids), Ash.Expr.expr(^max_rank), fn {id, rank}, acc ->
          Ash.Expr.expr(if(id == ^id, ^rank, ^acc))
        end)

      Ash.Query.sort(ash_query, [{Ash.Sort.expr_sort(^rank_expr), :asc}])
    end

    @doc """
    Reads a raw attribute from another collection on the same working `%Xitdb{}` handle
    for cross-entity `search_field` `resolver:` callbacks (e.g., `Profile` -> `Organization`).
    """
    @spec lookup_field(term(), atom(), term(), String.t() | atom(), term()) :: term()
    def lookup_field(db, collection, id, attr_key, tenant \\ nil)
    def lookup_field(_db, _collection, nil, _attr_key, _tenant), do: nil

    def lookup_field(db, collection, id, attr_key, tenant)
        when is_atom(collection) and (is_binary(attr_key) or is_atom(attr_key)) do
      col_str =
        if is_nil(tenant),
          do: Atom.to_string(collection),
          else: "t:#{encode_doc_key(tenant)}:#{collection}"

      Storage.read_entity_field(db, col_str, encode_doc_key(id), attr_key)
    end

    @doc """
    Tokenizes UTF-8 strings or `%Ash.CiString{}` values into normalized lowercase terms,
    copying slices so retained index keys never pin large source binaries.
    """
    @spec tokenize(String.t() | Ash.CiString.t() | nil) :: [String.t()]
    def tokenize(nil), do: []
    def tokenize(%Ash.CiString{} = ci), do: ci |> Ash.CiString.value() |> tokenize()

    def tokenize(text) when is_binary(text) do
      text
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
      |> Enum.map(&:binary.copy/1)
    end

    @doc """
    Incrementally updates `idx.search.<collection>` for `record` inside a write transaction.
    No-ops when `resource` declares zero `search_field` entities.
    """
    @spec index_record(term(), module(), struct(), term()) :: term()
    def index_record(db, resource, %_{} = record, tenant \\ nil) when is_atom(resource) do
      case Info.search_fields(resource) do
        [] ->
          db

        search_fields ->
          effective_tenant = tenant || Ash.Resource.get_metadata(record, :tenant)
          collection = resolve_collection_name(resource, effective_tenant)
          pk_attr = resource |> Ash.Resource.Info.primary_key() |> hd()
          doc_key = record |> Map.fetch!(pk_attr) |> encode_doc_key()
          new_terms = extract_weighted_terms(record, search_fields, db)
          apply_doc_diff(db, collection, doc_key, new_terms)
      end
    end

    @doc """
    Re-indexes a list of dependent structs in one working `%Xitdb{}` transaction
    (for example, re-indexing `Profile` records when their parent `Organization` updates).
    """
    @spec reindex_records(term(), module(), Enumerable.t(), term()) :: term()
    def reindex_records(db, resource, records, tenant \\ nil) when is_atom(resource) do
      Enum.reduce(records, db, fn record, acc_db ->
        index_record(acc_db, resource, record, tenant)
      end)
    end

    @doc """
    Removes `doc_id` from `idx.search.<collection>` inside a `destroy` transaction.
    """
    @spec remove_record(term(), module(), term(), term()) :: term()
    def remove_record(db, resource, doc_id, tenant \\ nil) when is_atom(resource) do
      case Info.search_fields(resource) do
        [] ->
          db

        _fields ->
          collection = resolve_collection_name(resource, tenant)
          apply_doc_diff(db, collection, encode_doc_key(doc_id), %{})
      end
    end

    # -- Internal Query & BM25 Execution --

    defp execute_ranked_query(resource, tokens, opts) do
      collection_atom = Info.collection!(resource)
      collection = resolve_collection_name(resource, opts[:tenant])
      meta = %{resource: resource, collection: collection_atom}

      :telemetry.span([:xitdb, :ash, :search], meta, fn ->
        db = opts[:db] || resolve_active_db(resource)
        hits = score_collection(db, collection, tokens, opts, pk_type(resource))

        {hits,
         meta
         |> Map.put(:result_count, length(hits))
         |> Map.put(:status, :ok)}
      end)
    end

    defp resolve_active_db(resource) do
      store = Info.store!(resource)

      if Code.ensure_loaded?(Xitdb.Ash.Store.Snapshot) do
        Xitdb.Ash.Store.Snapshot.current_db(store)
      else
        raise ArgumentError, "No database handle provided and Snapshot module is not loaded"
      end
    end

    defp score_collection(db, collection, tokens, opts, pk_kind) do
      %{doc_count: doc_count, total_len: total_len} = Storage.read_corpus_stats(db, collection)

      if doc_count <= 0 or total_len <= 0 do
        []
      else
        avg_dl = total_len / doc_count / @weight_scale
        token_postings = Enum.map(tokens, &collect_token_postings(db, collection, &1, opts))
        candidate_keys = resolve_candidate_keys(token_postings, opts[:match])

        score_candidates(
          db,
          collection,
          candidate_keys,
          token_postings,
          doc_count,
          avg_dl,
          opts,
          pk_kind
        )
      end
    end

    defp collect_token_postings(db, collection, token, opts) do
      exact_postings = Storage.lookup_term(db, collection, token)

      prefix_postings =
        if opts[:prefix?] and String.length(token) >= opts[:min_prefix_length] do
          Storage.scan_prefix(db, collection, token, opts[:max_prefix_expansions])
        else
          []
        end

      merged =
        Enum.reduce(prefix_postings, %{}, fn {matched_term, postings}, acc ->
          multiplier = if matched_term == token, do: @exact_match_boost, else: 1.0

          Enum.reduce(postings, acc, fn {doc_key, scaled_tf}, inner ->
            tf = scaled_tf / @weight_scale * multiplier
            Map.update(inner, doc_key, tf, &(&1 + tf))
          end)
        end)

      if prefix_postings == [] do
        Map.new(exact_postings, fn {doc_key, scaled_tf} ->
          {doc_key, scaled_tf / @weight_scale * @exact_match_boost}
        end)
      else
        merged
      end
    end

    defp resolve_candidate_keys([], _mode), do: MapSet.new()

    defp resolve_candidate_keys([first | rest], :all) do
      Enum.reduce(rest, MapSet.new(Map.keys(first)), fn postings, acc ->
        if MapSet.size(acc) == 0 do
          acc
        else
          MapSet.intersection(acc, MapSet.new(Map.keys(postings)))
        end
      end)
    end

    defp resolve_candidate_keys(token_postings, :any) do
      Enum.reduce(token_postings, MapSet.new(), fn postings, acc ->
        Enum.reduce(Map.keys(postings), acc, &MapSet.put(&2, &1))
      end)
    end

    defp score_candidates(
           db,
           collection,
           candidate_keys,
           token_postings,
           doc_count,
           avg_dl,
           opts,
           pk_kind
         ) do
      k1 = opts[:k1]
      b = opts[:b]

      idfs =
        Enum.map(token_postings, fn postings ->
          df = map_size(postings)
          :math.log(1.0 + (doc_count - df + 0.5) / (df + 0.5))
        end)

      weighted_tokens = Enum.zip(token_postings, idfs)

      candidate_keys
      |> Enum.reduce([], fn doc_key, acc ->
        doc_len = Storage.read_doc_len(db, collection, doc_key) / @weight_scale
        norm = k1 * (1.0 - b + b * (doc_len / max(avg_dl, 1.0e-6)))

        score =
          Enum.reduce(weighted_tokens, 0.0, fn {postings, idf}, sum ->
            case Map.fetch(postings, doc_key) do
              {:ok, tf} when tf > 0.0 -> sum + idf * (tf * (k1 + 1.0)) / (tf + norm)
              _ -> sum
            end
          end)

        if score > 0.0 do
          [{decode_doc_key(doc_key, pk_kind), score} | acc]
        else
          acc
        end
      end)
      |> Enum.sort_by(fn {id, score} -> {-score, id} end)
      |> Enum.take(opts[:limit])
    end

    # -- Internal Indexing & Diff Calculation --

    defp extract_weighted_terms(record, search_fields, db) do
      Enum.reduce(search_fields, %{}, fn %{field: field, boost: boost, resolver: resolver}, acc ->
        weight = max(1, round(boost * @weight_scale))

        raw_value =
          case resolver do
            fun when is_function(fun, 2) -> fun.(record, db)
            nil -> Map.get(record, field)
          end

        raw_value
        |> extract_tokens()
        |> Enum.reduce(acc, fn token, term_acc ->
          Map.update(term_acc, token, weight, &(&1 + weight))
        end)
      end)
    end

    defp extract_tokens(values) when is_list(values) do
      Enum.flat_map(values, &extract_tokens/1)
    end

    defp extract_tokens(value) when is_binary(value) or is_struct(value, Ash.CiString) do
      tokenize(value)
    end

    defp extract_tokens(value)
         when is_atom(value) and not is_nil(value) and not is_boolean(value) do
      value |> Atom.to_string() |> tokenize()
    end

    defp extract_tokens(_other), do: []

    defp apply_doc_diff(db, collection, doc_key, new_terms) do
      %{len: old_len, terms: old_terms} = Storage.read_doc(db, collection, doc_key)
      new_len = Enum.reduce(new_terms, 0, fn {_term, weight}, sum -> sum + weight end)

      if old_terms == new_terms do
        db
      else
        was_indexed? = old_len > 0
        now_indexed? = new_len > 0

        doc_count_delta =
          cond do
            not was_indexed? and now_indexed? -> 1
            was_indexed? and not now_indexed? -> -1
            true -> 0
          end

        len_delta = new_len - old_len
        term_ops = compute_term_ops(old_terms, new_terms)

        Storage.apply_diff(db, collection, doc_key, %{
          doc_count_delta: doc_count_delta,
          len_delta: len_delta,
          new_doc: if(now_indexed?, do: %{len: new_len, terms: new_terms}, else: :delete),
          term_ops: term_ops
        })
      end
    end

    defp compute_term_ops(old_terms, new_terms) do
      deletes_and_updates =
        Enum.reduce(old_terms, [], fn {term, old_w}, acc ->
          case Map.fetch(new_terms, term) do
            {:ok, ^old_w} -> acc
            {:ok, new_w} -> [{:put, term, new_w} | acc]
            :error -> [{:delete, term} | acc]
          end
        end)

      Enum.reduce(new_terms, deletes_and_updates, fn {term, new_w}, acc ->
        if Map.has_key?(old_terms, term) do
          acc
        else
          [{:put, term, new_w} | acc]
        end
      end)
    end

    defp pk_type(resource) do
      pk_name = resource |> Ash.Resource.Info.primary_key() |> hd()
      attr = Ash.Resource.Info.attribute(resource, pk_name)

      if attr && attr.type in [:integer, Ash.Type.Integer], do: :integer, else: :string
    end

    defp resolve_collection_name(resource, tenant) do
      if Code.ensure_loaded?(Xitdb.Ash.Codec) and
           function_exported?(Xitdb.Ash.Codec, :scoped_collection, 2) do
        Xitdb.Ash.Codec.scoped_collection(resource, tenant)
      else
        resource |> Info.collection!() |> Atom.to_string()
      end
    end

    defp encode_doc_key(id) when is_integer(id), do: Integer.to_string(id)
    defp encode_doc_key(id) when is_binary(id), do: id
    defp encode_doc_key(%Ash.CiString{} = ci), do: ci |> Ash.CiString.value() |> String.downcase()
    defp encode_doc_key(id), do: to_string(id)

    defp decode_doc_key(key, :integer), do: String.to_integer(key)
    defp decode_doc_key(key, :string), do: key
  end

  defmodule Xitdb.Ash.Search.RankCalculation do
    @moduledoc false
    use Ash.Resource.Calculation

    @impl true
    def calculate(records, opts, _context) do
      ranks = Keyword.fetch!(opts, :ranks)
      default = Keyword.fetch!(opts, :default)

      Enum.map(records, fn record ->
        Map.get(ranks, record.id, default)
      end)
    end
  end

  defmodule Xitdb.Ash.Search.Storage do
    @moduledoc false
    alias Xitdb.TxCompiler

    @spec read_entity_field(term(), String.t(), String.t(), String.t() | atom()) :: term()
    def read_entity_field(db, collection, doc_key, attr_key) do
      attr_str = to_string(attr_key)

      with root when not is_nil(root) <- root_cursor(db),
           col when not is_nil(col) <- root[collection],
           entity when not is_nil(entity) <- col[doc_key] do
        entity[attr_str] || entity[attr_key]
      else
        _ -> nil
      end
    end

    @spec read_corpus_stats(term(), String.t()) :: %{
            doc_count: non_neg_integer(),
            total_len: non_neg_integer()
          }
    def read_corpus_stats(db, collection) do
      case get_in_search(db, collection, "meta") do
        nil -> %{doc_count: 0, total_len: 0}
        meta -> %{doc_count: meta["doc_count"] || 0, total_len: meta["total_len"] || 0}
      end
    end

    @spec read_doc(term(), String.t(), String.t()) :: %{
            len: non_neg_integer(),
            terms: %{optional(String.t()) => pos_integer()}
          }
    def read_doc(db, collection, doc_key) do
      with docs when not is_nil(docs) <- get_in_search(db, collection, "docs"),
           doc when not is_nil(doc) <- docs[doc_key] do
        terms =
          case doc["terms"] do
            nil -> %{}
            raw_terms when is_map(raw_terms) and not is_struct(raw_terms) -> raw_terms
            %Xitdb.Cursor{} = terms_cur -> Map.new(terms_cur)
            _ -> %{}
          end

        %{len: doc["len"] || 0, terms: terms}
      else
        _ -> %{len: 0, terms: %{}}
      end
    end

    @spec read_doc_len(term(), String.t(), String.t()) :: non_neg_integer()
    def read_doc_len(db, collection, doc_key) do
      with docs when not is_nil(docs) <- get_in_search(db, collection, "docs"),
           doc when not is_nil(doc) <- docs[doc_key] do
        doc["len"] || 0
      else
        _ -> 0
      end
    end

    @spec lookup_term(term(), String.t(), String.t()) :: [{String.t(), pos_integer()}]
    def lookup_term(db, collection, term) do
      with terms when not is_nil(terms) <- get_in_search(db, collection, "terms"),
           postings when not is_nil(postings) <- terms[term] do
        Enum.to_list(postings)
      else
        _ -> []
      end
    end

    @spec scan_prefix(term(), String.t(), String.t(), pos_integer()) :: [
            {String.t(), [{String.t(), pos_integer()}]}
          ]
    def scan_prefix(db, collection, prefix, limit) do
      case get_in_search(db, collection, "terms") do
        nil ->
          []

        %Xitdb.Cursor{} = terms ->
          case Xitdb.NIF.nif_slot_count(terms.db_ref, terms.tag_id, terms.value) do
            {:ok, total_count} when total_count > 0 ->
              start_idx = find_prefix_start_index(terms, prefix, 0, total_count)
              stream_prefix_from(terms, prefix, start_idx, limit)

            _ ->
              []
          end
      end
    end

    defp find_prefix_start_index(terms, prefix, low, high) when low < high do
      mid = div(low + high, 2)

      case Xitdb.NIF.nif_slot_entries(terms.db_ref, terms.tag_id, terms.value, mid, 1) do
        {:ok, [{key, _}]} ->
          if key < prefix do
            find_prefix_start_index(terms, prefix, mid + 1, high)
          else
            find_prefix_start_index(terms, prefix, low, mid)
          end

        _ ->
          low
      end
    end

    defp find_prefix_start_index(_terms, _prefix, low, _high), do: low

    defp stream_prefix_from(terms, prefix, start_idx, limit) do
      Stream.unfold(start_idx, fn idx ->
        case Xitdb.NIF.nif_slot_entries(
               terms.db_ref,
               terms.tag_id,
               terms.value,
               idx,
               min(limit, 32)
             ) do
          {:ok, []} ->
            nil

          {:ok, chunk} ->
            {chunk, idx + length(chunk)}

          _ ->
            nil
        end
      end)
      |> Stream.flat_map(& &1)
      |> Stream.take_while(fn {term, _} -> String.starts_with?(term, prefix) end)
      |> Stream.take(limit)
      |> Enum.map(fn {term, raw_postings} ->
        postings =
          case raw_postings do
            {:cursor, _tag, _tag_id, _val, _full} = c_tuple ->
              terms.db_ref
              |> Xitdb.Cursor.from_nif_tuple(c_tuple, terms.moment)
              |> Enum.to_list()

            %Xitdb.Cursor{} = cur ->
              Enum.to_list(cur)

            list when is_list(list) ->
              list
          end

        {term, postings}
      end)
    end

    @spec apply_diff(term(), String.t(), String.t(), map()) :: term()
    def apply_diff(db, collection, doc_key, diff) do
      col_str = TxCompiler.format_key(collection)
      doc_str = TxCompiler.format_key(doc_key)

      meta_prefix = ".idx.search." <> col_str <> ".meta"
      docs_prefix = ".idx.search." <> col_str <> ".docs"
      terms_prefix = ".idx.search." <> col_str <> ".terms"

      %{doc_count: cur_doc_count, total_len: cur_total_len} = read_corpus_stats(db, collection)
      new_doc_count = max(0, cur_doc_count + diff.doc_count_delta)
      new_total_len = max(0, cur_total_len + diff.len_delta)

      meta_ops = [
        {:put, meta_prefix <> ".doc_count", new_doc_count},
        {:put, meta_prefix <> ".total_len", new_total_len}
      ]

      doc_path = docs_prefix <> "." <> doc_str

      doc_ops =
        case diff.new_doc do
          :delete ->
            [{:rm, doc_path}]

          %{len: len, terms: doc_terms} ->
            put_terms =
              Enum.map(doc_terms, fn {term, weight} ->
                {:put, doc_path <> ".terms." <> TxCompiler.format_key(term), weight}
              end)

            [
              {:put, doc_path <> ".len", len},
              {:reset_col, doc_path <> ".terms", "hash_map"} | put_terms
            ]
        end

      term_ops =
        Enum.flat_map(diff.term_ops, fn
          {:put, term, weight} ->
            term_str = TxCompiler.format_key(term)
            [{:put, terms_prefix <> "$" <> term_str <> "." <> doc_str, weight}]

          {:delete, term} ->
            term_str = TxCompiler.format_key(term)
            postings = lookup_term(db, collection, term)

            if length(postings) <= 1 do
              [{:rm, terms_prefix <> "$" <> term_str}]
            else
              [{:rm, terms_prefix <> "$" <> term_str <> "." <> doc_str}]
            end
        end)

        ops = meta_ops ++ doc_ops ++ term_ops

      case db do
        {%Xitdb{} = raw_db, moment} when is_integer(moment) ->
          {:ok, new_db} = Xitdb.transact_ops(raw_db, ops, base_moment: moment)
          {new_db, Xitdb.moment_count(new_db) - 1}

        %Xitdb{} = raw_db ->
          {:ok, new_db} = Xitdb.transact_ops(raw_db, ops)
          new_db
      end
    end

    @doc false
    def root_cursor({%Xitdb{} = db, moment}) when is_integer(moment), do: Xitdb.as_of(db, moment)
    def root_cursor(%Xitdb.Cursor{} = cursor), do: cursor
    def root_cursor(%Xitdb{} = db), do: Xitdb.db(db)
    def root_cursor(_), do: nil

    defp get_in_search(db, collection, slot) do
      with %Xitdb.Cursor{} = root <- root_cursor(db),
           %Xitdb.Cursor{} = idx <- root["idx"],
           %Xitdb.Cursor{} = search <- idx["search"],
           %Xitdb.Cursor{} = col <- search[collection] do
        col[slot]
      else
        _ -> nil
      end
    end
  end
end
```

---

## 8. Verification Suite (`test/xitdb/ash/dsl_test.exs`)

```elixir
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
      uuid_primary_key :id
      attribute :title, :string, public?: true
      attribute :status, :atom, default: :draft, public?: true
      attribute :tags, {:array, :string}, default: [], public?: true
      create_timestamp :inserted_at
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
      uuid_primary_key :id
      attribute :title, :string, public?: true
    end

    relationships do
      belongs_to :event, Event, allow_nil?: false, attribute_type: :uuid
    end
  end

  test "BuildIndexPlan persists indexes, nesting plan, search fields, references, and tx_for hooks" do
    assert Info.store!(Event) == StoreA
    assert Info.collection!(Event) == :events
    assert Info.counted_set_fields(Event) == [:tags]
    assert [%SearchField{field: :title, boost: 2.5}] = Info.search_fields(Event)

    assert [
             %Index{fields: [:status], name: nil},
             %Index{fields: [:status, :inserted_at], name: :idx_status_recent}
           ] = Info.indexes_for_field(Event, :status)

    assert Event.__xitdb_indexes__() == [{:events, :status, "attr_status"}]

    assert %NestedIn{parent_collection: :events, foreign_key: :event_id, path: :sessions} =
             Info.nested_in(Session)

    assert [%Index{fields: [:event_id], name: nil}] = Info.indexes(Session)
    assert [%Reference{relationship: :event, on_delete: :delete}] = Info.references(Session)
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

  test "rejects SQL fragment(...) in calculations, relationship filters, and policies" do
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
  end

  test "rejects unknown reference names, non-nullable :nilify, and cross-store cascades" do
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
  end
end
```
