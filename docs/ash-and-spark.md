# Ash & Spark Integration (`Xitdb.Ash.Resource`, `Xitdb.Ash.Info`, `tx_for`)

When using `Xitdb` alongside [`Ash`](https://hexdocs.pm/ash) (for example, as an immutable Master Data Management (MDM) engine, audit graph, or secondary projection store), `Xitdb` provides a declarative [`Spark`](https://hexdocs.pm/spark) DSL extension (`Xitdb.Ash.Resource`), zero-allocation introspection helpers (`Xitdb.Ash.Info`), a compile-time projection/index verifier (`Xitdb.Ash.Verifiers.VerifySyncProjection`), and resource-aware transaction macros (`tx_for/3,4` and `tx_for!/3,4`).

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
| `collection` | `atom()` | *(required)* | Primary `Xitdb` collection storing entities (`:organizations`, `:people`, `:events`). |
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

---

## 2. Compile-Time Transformer & Verifier Guarantees

### 1. `Xitdb.Ash.Transformers.WireChanges`
At compile time, `WireChanges`:
- Automatically attaches `{lock_change_mod, op: :lock}` to `lock_action` and `{lock_change_mod, op: :unlock}` to `unlock_action` (idempotently skipping any action that already declares `lock_change_mod` or does not exist on the resource).
- Precomputes and compiles literal module callbacks (`__xitdb_editable_field_strings__/0`, `__xitdb_pull_fields__/0`, `__xitdb_pull_pattern__/0`, `__xitdb_collection__/0`, `__xitdb_indexes__/0`, `__xitdb_store__/0`, `__xitdb_lock_change__/0`, plus pre-merged companion pair lookups) directly onto the resource module so runtime `Xitdb.Ash.Info` lookups run in **$O(1)$ (~30 ns)** with zero heap allocations.

### 2. `Xitdb.Ash.Verifiers.VerifySyncProjection`
At compile time, `VerifySyncProjection` verifies three invariants and raises a `Spark.Error.DslError` if any fails:
1. **Attribute existence**: Every field listed in `editable_fields` or `passthru_fields` must exist as an attribute on the `Ash.Resource`.
2. **No silent sync drops**: Every attribute accepted by `sync_update_action` (that is not in `ignored_sync_attributes`) must be declared in either `editable_fields` or `passthru_fields`.
3. **Index coverage**: Every key in `indexes` must match a projected slot name (`editable_fields` or `passthru_fields` after applying `field_aliases`) or an entry in `computed_xitdb_fields`.

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
