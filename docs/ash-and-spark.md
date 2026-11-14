# Ash & Spark Integration (`Xitdb.Ash.DataLayer`, `Xitdb.Ash.Store`, `Xitdb.Ash.Search`, `Xitdb.Ash.Resource`)

`Xitdb` integrates with [`Ash`](https://hexdocs.pm/ash) in two complementary ways:

1. **Native Lock-Free Ash Storage & BM25 Search (`data_layer: Xitdb.Ash.DataLayer`):**
   Persist `Ash.Resource` entities directly in immutable copy-on-write `.xit` files managed by `Xitdb.Ash.Store`—with ~10ns lock-free `:persistent_term` snapshot reads, single/composite B+Tree secondary indexes (`index`), transactional Odin NIF BM25 + prefix search (`search_field` & `Xitdb.Ash.Search`), incoming/outgoing FK cascades (`references`), co-located parent subtrees (`nested_in`), historical time-travel (`Store.with_as_of/3`), and `async: true` sandboxes (`Xitdb.Ash.TestSandbox`).
2. **Hybrid MDM Sync Extension (`extensions: [Xitdb.Ash.Resource]`):**
   Attach a declarative [`Spark`](https://hexdocs.pm/spark) DSL extension onto resources backed by another data layer (such as `Ash.DataLayer.Postgres`) for Master Data Management (MDM) projections, survivorship field locks, zero-allocation introspection (`Xitdb.Ash.Info`), compile-time sync verification (`Xitdb.Ash.Verifiers.VerifySyncProjection`), and resource-aware transactions (`tx_for/3,4` and `tx_for!/3,4`).

---

## 1. Declaring `xitdb` on an `Ash.Resource`

Add `Xitdb.Ash.Resource` to `extensions:` in `use Ash.Resource` and configure the `xitdb do ... end` section:

```elixir
defmodule MyApp.Accounts.Organization do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: Ash.DataLayer.Postgres,
    extensions: [Xitdb.Ash.Resource]

  xitdb do
    store MyApp.MDM.Store
    collection :organizations
    merge_redirect_collection :org_merged_into
    locked_ids_set :locked_org_ids
    lock_change MyApp.MDM.Changes.ModifyLockedFields

    editable_fields [:name, :domain, :headquarters]
    passthru_fields [:creatio_id, :parent_organization_id]
    computed_xitdb_fields [:normalized_name, :activity_count]
    field_aliases parent_organization_id: :parent_org_id

    indexes(
      domain: "domain->org_id",
      normalized_name: "norm_name->org_id",
      creatio_id: "creatio_id->org_id"
    )
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :domain, :string, public?: true
    attribute :headquarters, :string, public?: true
    attribute :creatio_id, :string, public?: true
    attribute :parent_organization_id, :uuid, public?: true
    attribute :locked_fields, {:array, :string}, default: [], public?: true
    attribute :status, :atom, default: :active, public?: true
  end

  actions do
    defaults [:read, create: :*]

    update :mdm_sync_update do
      require_atomic? false

      accept [
        :name,
        :domain,
        :headquarters,
        :creatio_id,
        :parent_organization_id,
        :locked_fields,
        :status
      ]
    end

    update :lock_field do
      require_atomic? false
      argument :field, :string, allow_nil?: false
    end

    update :unlock_field do
      require_atomic? false
      argument :field, :string, allow_nil?: false
    end
  end
end
```

### `xitdb` Section Options Reference

| Option | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `collection` | `atom()` | *(required unless `nested_in` is declared)* | Primary `Xitdb` collection storing entities (`:organizations`, `:people`, `:events`). |
| `store` | `atom()` | `nil` | Default `Xitdb` Store GenServer name (overridable via `context[:xitdb_store]`, `opts[:store]`, or `config :xitdb, :default_store`). |
| `merge_redirect_collection` | `atom()` | `nil` | Sorted map storing `loser_id -> winner_id` merge redirects (`:org_merged_into`). |
| `locked_ids_set` | `atom()` | `nil` | Counted hash set tracking entity IDs with user-locked fields (`:locked_org_ids`). |
| `companion_resource` | `atom()` | `nil` | Optional companion `Ash.Resource` sharing the same `Xitdb` entity (e.g., `OrganizationProfile <-> Organization`). |
| `editable_fields` | `[atom()]` | `[]` | Canonical attributes subject to per-field survivorship locks and conflict detection. |
| `passthru_fields` | `[atom()]` | `[]` | Attributes projected into `Xitdb` without per-field conflict logging (e.g., `:creatio_id`). |
| `computed_xitdb_fields` | `[atom()]` | `[]` | Derived `Xitdb`-only fields maintained by the engine (e.g., `:normalized_name`, `:activity_count`). |
| `field_aliases` | `keyword()` | `[]` | Maps `Ash.Resource` attribute names to `Xitdb` slot names (`[parent_organization_id: :parent_org_id]`). |
| `indexes` | `keyword()` | `[]` | Secondary B+Tree index declarations (`[domain: "domain->org_id", ...]`). |
| `sync_update_action` | `atom()` | `:mdm_sync_update` | Ash update action invoked by reconciler projectors and audited at compile time. |
| `ignored_sync_attributes` | `[atom()]` | `[:locked_by_user, :locked_fields, :dirty_for_upstream_sync, :local_overrides, :status]` | Bookkeeping attributes accepted by `sync_update_action` that are not projected into `Xitdb`. |
| `lock_action` | `atom()` | `:lock_field` | Ash update action that locks a single field. |
| `unlock_action` | `atom()` | `:unlock_field` | Ash update action that unlocks a single field. |
| `lock_change` | `atom()` | `nil` | `Ash.Resource.Change` module wired into `lock_action` and `unlock_action` (defaults to `config :xitdb, :default_lock_change`). |

### Nested Sub-Collections (`nested_in`)

Some resources belong inside a parent entity rather than in a top-level collection: a person's
phone numbers, an organization's domains, an event's sessions. Declare them with `nested_in`
instead of `collection`. A resource may be nested in several parents:

```elixir
defmodule MyApp.Accounts.PhoneNumber do
  use Ash.Resource, extensions: [Xitdb.Ash.Resource]

  xitdb do
    nested_in MyApp.Accounts.User, as: :phones, parent_key: :user_id, key: :e164
    nested_in MyApp.Accounts.Organization, as: :phones, parent_key: :organization_id, key: :e164

    editable_fields [:number_type, :is_primary]
    passthru_fields [:e164, :user_id, :organization_id]
  end
end

defmodule MyApp.Events.Conference do
  use Ash.Resource, extensions: [Xitdb.Ash.Resource]

  xitdb do
    # A single map stored at events[event_id].conference
    nested_in MyApp.Events.Event, as: :conference, parent_key: :event_id, cardinality: :one
    editable_fields [:title, :edition_year]
    passthru_fields [:event_id]
  end
end
```

| `nested_in` option | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `parent` *(argument)* | `module()` | *(required)* | Parent `Xitdb.Ash.Resource`. It must declare a top-level `collection`; nesting is one level deep. |
| `as` | `atom()` | *(required)* | Slot name under the parent entity (`:phones`, `:sessions`). |
| `parent_key` | `atom()` | *(required)* | Attribute on this resource holding the parent entity id. |
| `key` | `atom()` | `nil` | Attribute whose value is the entry key inside the sub-collection. Required for `cardinality: :many`. |
| `cardinality` | `:one \| :many` | `:many` | `:many` stores a map of entries; `:one` stores a single map at the slot. |

Nested resources cannot declare secondary `indexes`. Use `Xitdb.Ash.Info.entity_paths/2` to
resolve where a record lives:

```elixir
XitdbInfo.entity_paths(PhoneNumber, %{user_id: 42, e164: "+14165550199"})
# => [["people", "42", "phones", "+14165550199"]]

XitdbInfo.nested_under([PhoneNumber, Conference], MyApp.Accounts.User)
# => [{PhoneNumber, %Xitdb.Ash.NestedIn{as: :phones, ...}}]
```

---

## 2. Compile-Time Transformer & Verifier Guarantees

### 1. `Xitdb.Ash.Transformers.WireChanges`
At compile time, `WireChanges`:
- Automatically attaches `{lock_change_mod, op: :lock}` to `lock_action` and `{lock_change_mod, op: :unlock}` to `unlock_action` (idempotently skipping any action that already declares `lock_change_mod` or does not exist on the resource).
- Precomputes and compiles literal module callbacks (`__xitdb_editable_field_strings__/0`, `__xitdb_pull_fields__/0`, `__xitdb_pull_pattern__/0`, `__xitdb_collection__/0`, `__xitdb_indexes__/0`, `__xitdb_store__/0`, `__xitdb_lock_change__/0`) directly onto the resource module—while caching merged `[Resource, CompanionResource]` pair projections in independent per-pair `:persistent_term` entries—so runtime `Xitdb.Ash.Info` lookups run in **`O(1)` (~30 ns)** with zero heap allocations and zero cyclic compilation deadlocks.

### 2. `Xitdb.Ash.Verifiers.VerifySyncProjection`
At compile time, `VerifySyncProjection` verifies four invariants and raises a `Spark.Error.DslError` if any fails:
1. **Attribute existence**: Every field listed in `editable_fields` or `passthru_fields` must exist as an attribute on the `Ash.Resource`.
2. **No silent sync drops**: Every attribute accepted by `sync_update_action` (that is not in `ignored_sync_attributes`) must be declared in either `editable_fields` or `passthru_fields`.
3. **Index coverage**: Every key in `indexes` must match a projected slot name (`editable_fields` or `passthru_fields` after applying `field_aliases`) or an entry in `computed_xitdb_fields`.
4. **Storage location**: The resource declares exactly one of `collection` or `nested_in`. Every `nested_in` `parent_key` and `key` must be an attribute, `cardinality: :many` declarations must name a `key`, and nested resources cannot declare `indexes`.

---

## 3. Introspection & Pull Projections (`Xitdb.Ash.Info`)

Use `Xitdb.Ash.Info` to query resource metadata or project `Xitdb` cursors with `Xitdb.pull/2` for a single resource or a `[Resource, CompanionResource]` list:

```elixir
alias Xitdb.Ash.Info, as: XitdbInfo
alias MyApp.Accounts.{Organization, OrganizationProfile}

# 1. Inspect collection & index metadata
XitdbInfo.xitdb_collection!(Organization)                # => :organizations
XitdbInfo.xitdb_merge_redirect_collection!(Organization) # => :org_merged_into
XitdbInfo.xitdb_locked_ids_set!(Organization)            # => :locked_org_ids

# 2. Editable + computed field strings (with field_aliases applied)
XitdbInfo.editable_field_strings(Organization)
# => ["name", "domain", "headquarters", "normalized_name", "activity_count"]

# 3. Precompiled Pull fields & Pull pattern string (single resource or companion pair)
XitdbInfo.pull_fields(Organization)
# => [:id, :name, :domain, :headquarters, :creatio_id, :parent_org_id]

pattern = XitdbInfo.pull_pattern_for([Organization, OrganizationProfile])
# => "{id, name, domain, headquarters, creatio_id, parent_org_id, website, industry, linkedin_url}"

org_map = Xitdb.pull!(db["organizations"][org_id], pattern)

# 4. Store resolution precedence: context[:xitdb_store] -> opts[:store] -> resource.store -> app env
store = XitdbInfo.resolve_store(Organization, context)
```

---

## 4. Automatic Secondary Index Transactions (`tx_for` & `tx_for!`)

Instead of repeating `index_on` rules in every transaction block, use `tx_for/3,4` or `tx_for!/3,4` (imported automatically by `use Xitdb.DSL`, or via `require Xitdb.Ash.Tx`).

`tx_for` resolves all `indexes` configured on the given `Ash.Resource` module(s) **at compile time** and prepends the corresponding `index_on(collection, field, index_name)` operations to the transaction batch:

```elixir
use Xitdb.DSL

db =
  tx_for! db, [Organization, OrganizationProfile], doc: "upsert organization 101" do
    put organizations["101"].id, "101"
    put organizations["101"].name, "Northleaf Capital"
    put organizations["101"].domain, "northleafcapital.com"
    put organizations["101"].normalized_name, "northleaf capital"
    put organizations["101"].creatio_id, "CRM-ORG-101"
    put organizations["101"].website, "https://northleafcapital.com"
  end

# Secondary B+Tree indexes are automatically populated (and evicted on `rm`):
db["domain->org_id"]["northleafcapital.com"] # => "101"
db["norm_name->org_id"]["northleaf capital"] # => "101"
db["creatio_id->org_id"]["CRM-ORG-101"]      # => "101"
```

### Using `tx_for` with Plain Elixir Schema Modules
You can also pass plain Elixir modules (without `Ash.Resource`) to `tx_for` by defining `__xitdb_indexes__/0` (returning `[{collection, field, index_name}]`, or `[{field, index_name}]` alongside `__xitdb_collection__/0`):

```elixir
defmodule MyApp.Catalog.ItemSchema do
  def __xitdb_collection__, do: :items
  def __xitdb_indexes__, do: [sku: "sku->item_id"]
end
```

---

## 5. Store Supervision (`Xitdb.Ash.Store`), `DataLayer`, `TestSandbox` & `lock_change` Contracts

Rather than hand-rolling a bespoke `GenServer`, use `Xitdb.Ash.Store` for both pure `Xitdb.Ash.DataLayer` resources and hybrid `Xitdb.Ash.Resource` MDM projections:

### 1. Defining & Supervising `MyApp.MDM.Store` (`use Xitdb.Ash.Store`)

`Xitdb.Ash.Store` publishes lock-free snapshots via `:persistent_term`, serializes writes with monitored caller-process writer leases, supports nested savepoints (`Store.transact/3`, `Store.rollback/2`), and integrates natively with `Xitdb.Ash.TestSandbox` for `async: true` ExUnit suites:

```elixir
defmodule MyApp.MDM.Store do
  use Xitdb.Ash.Store
end

# In MyApp.Application.start/2:
children = [
  {MyApp.MDM.Store,
   path: "/var/lib/myapp/mdm.xit",
   domains: [MyApp.Accounts]}
]

# Lock-free root snapshot cursor (`%Xitdb.Cursor{}` pinned to the latest committed moment):
root_cursor = MyApp.MDM.Store.root()

# Historical time-travel across `Ash.read`, `Ash.count`, and `Xitdb.Ash.Search`:
prev_moment = root_cursor.moment
prev_orgs = Ash.read!(MyApp.Accounts.Organization, context: %{xitdb_moment: prev_moment})
prev_hits = Xitdb.Ash.Search.ids(MyApp.Accounts.Organization, "northleaf", as_of: prev_moment)

MyApp.MDM.Store.with_as_of(prev_moment, fn ->
  # Every Ash read, aggregate, relationship load, and BM25 search inside this block
  # resolves against `prev_moment`.
  Ash.read!(MyApp.Accounts.Organization)
end)

# Serialized MDM `tx_for!` batch inside the store's writer lease (re-entrant inside transactions).
# `mutate/3` passes and expects `{db, moment}` working snapshots:
{:ok, :synced} =
  Xitdb.Ash.Store.mutate(MyApp.MDM.Store, fn {db, moment} ->
    next_db =
      tx_for! db, [MyApp.Accounts.Organization],
        base_moment: moment,
        doc: "sync org 101" do
        put organizations["101"].id, "101"
        put organizations["101"].domain, "northleaf.ca"
      end

    {:ok, {next_db, Xitdb.moment_count(next_db) - 1}, :synced}
  end)
```

For resources persisted directly in `.xit` files without Postgres, set `data_layer: Xitdb.Ash.DataLayer` (which automatically includes the `xitdb do ... end` DSL, secondary `index` / `search_field` / `references` entities, and `Store` transaction coordination) and isolate concurrent tests in `test_helper.exs` / `DataCase` via `Xitdb.Ash.TestSandbox.init()` and `Xitdb.Ash.TestSandbox.checkout([MyApp.MDM.Store])`.

```elixir
defmodule MyApp.Accounts.Profile do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: Xitdb.Ash.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  xitdb do
    store MyApp.MDM.Store
    collection :profiles

    # Explicit single-field or composite B+Tree (:sorted_map) secondary indexes
    # (belongs_to foreign keys are indexed automatically when index_relationships? is true)
    index [:status, :inserted_at]

    # Transactional in-Xitdb BM25 + B+Tree prefix search fields
    search_field :full_name, boost: 3.0
    search_field :headline, boost: 1.5

    search_field :firm_name,
      boost: 2.0,
      resolver: fn profile, db ->
        Xitdb.Ash.Search.lookup_field(db, :organizations, profile.organization_id, "name")
      end

    # Incoming/outgoing foreign-key cascade actions within the same store
    references do
      reference :organization, on_delete: :nilify
    end
  end
end
```

### 2. Reference `lock_change` Module (`MyApp.MDM.Changes.ModifyLockedFields`)

`WireChanges` attaches `{lock_change_mod, op: :lock}` to `lock_action` and `{lock_change_mod, op: :unlock}` to `unlock_action`.

> [!IMPORTANT]
> Because `ModifyLockedFields` inspects `Ash.Changeset.get_data(changeset, :locked_fields)` inside `change/3` without an `atomic/3` callback—and `WireChanges` preserves your action flags as written—both `lock_action` (`:lock_field`) and `unlock_action` (`:unlock_field`) **must** set `require_atomic? false` on the resource (as shown in Section 1).

```elixir
defmodule MyApp.MDM.Changes.ModifyLockedFields do
  use Ash.Resource.Change
  alias Xitdb.Ash.Info, as: XitdbInfo

  @impl true
  def change(changeset, opts, _context) do
    field = Ash.Changeset.get_argument(changeset, :field)
    allowed = XitdbInfo.editable_field_strings(changeset.resource)

    if field in allowed do
      current = Ash.Changeset.get_data(changeset, :locked_fields) || []

      updated =
        case Keyword.fetch!(opts, :op) do
          :lock -> Enum.uniq(current ++ [field])
          :unlock -> List.delete(current, field)
        end

      Ash.Changeset.force_change_attribute(changeset, :locked_fields, updated)
    else
      Ash.Changeset.add_error(changeset, field: :field, message: "is not an editable Xitdb field")
    end
  end
end
```
