# Xitdb Elixir Client Usage Rules

`Xitdb` is an idiomatic Elixir client and Odin NIF wrapper for `xitdb`—an embeddable, immutable, append-only database with persistent structural sharing (`Hash_Map`, `Counted_Hash_Map`, `Sorted_Map`, `Array_List`, `Linked_Array_List`, and sets).

---

## 1. Core Architecture & Lazy `%Xitdb.Cursor{}` Navigation

1. **Default to Lazy `Access` Navigation (`db["users"]["alice"]["name"]`)**:
   - Reading from `Xitdb` (`Xitdb.db(db)`, `Xitdb.as_of(db, moment)`, or `db["users"]`) returns a lazy `%Xitdb.Cursor{}` holding only the NIF database reference and 9-byte `Slot` coordinates (`tag`, `tag_id`, `value`).
   - Cursors are **pure, immutable Elixir values**. Pass them freely across BEAM processes (`Task.async_stream/3`, GenServers, ETS, Phoenix LiveView assigns) without locks or copying underlying subtrees.
   - Navigating to a scalar (`string`, `integer`, `float`, `boolean`, or `{:tagged, tag, bytes}`) unwraps and returns the native Elixir value directly; navigating to a nested container returns another `%Xitdb.Cursor{}` in `O(1)` heap space.
2. **Use `Xitdb.at/1` Instead of `Access.at/1` on Lazy List Cursors**:
   - Elixir's built-in `Access.at/1` guards `is_list(data)` and raises on structs. When navigating `Array_List` or `Linked_Array_List` cursors with `get_in/2` or `put_in/3`, either pass integer keys directly in the path list (`get_in(root, ["users", "alice", "roles", 1])`) or use `Xitdb.at(1)`.
3. **Never Eagerly Materialize Large Subtrees Unless Needed**:
   - Never call `Xitdb.materialize(db)` on the entire database root in hot paths. Prefer lazy navigation (`cursor["key"]`, `cursor[0]`), `Xitdb.pull/2` projections, `Enum.count/1`, `Enum.member?/2`, `Enum.slice/2`, or `Stream` pipelines, or navigate to the leaf entity first (`user = db["users"][id]`) before calling `Xitdb.materialize(user)`.
4. **Understand the `~150–250 ns` NIF Boundary Cost Model**:
   - Each RW-locked NIF crossing (`enif_get_resource` + `enif_rwlock_rlock` + `resolve_slot_coord` + `enif_make_*`) carries a fixed `~150–250 ns` overhead (`~155–199 ns` `O(1)` `Enum.count/1`; `~340–580 ns` single-hop lookups).
   - Use lazy `Access` (`cursor[key]`) for shallow 1–2 hop reads or when passing `%Xitdb.Cursor{}` handles across functions/processes.
   - Use `Xitdb.select!/2` for deep 3+ hop scalar reads (`~1.99–2.08 µs`): prefer compile-time `Xitdb.DSL.path_steps/1` (`use Xitdb.DSL`) over string `path(...)` when interpolating runtime variables in hot `select/2`, `select!/2`, and `history_of/2` loops (eliminates Elixir string formatting and Odin selector parsing via C `decode_steps_term_buf`; `Xitdb.DSL.tx` blocks already compile bare path expressions directly), use `~x` for static literal paths, and use `Xitdb.pull!/2` (`~6.28–6.49 µs`) when reading multiple fields or bounded slices from the same entity in a single NIF call.
   - For `Sorted_Map` B+Tree prefix/range scans whose values are child containers, `Xitdb.NIF.nif_sorted_map_seek/7` with `decode_children: true` (`Xitdb.Ash.Search.Storage.scan_prefix/5`) fuses B+Tree traversal and bounded child container decoding inside Odin in 1 NIF crossing, while `decode_children: false` (`Xitdb.Ash.Search.Storage.scan_prefix_cursors/4` and `Xitdb.Ash.Indexer.Storage.stream_index_from/4`) returns lazy `%Xitdb.Cursor{}` handles.
   - Inside `Xitdb.transact/3`, `put_in/3` stages virtual write cursors in `tx_mode` without intermediate read NIF hops (`~13.9–14.2 µs` for a 3-hop commit); prefer `Xitdb.DSL.tx` (`put users[id].field, val`) or map `Xitdb.transact/3` in write-heavy loops to avoid Elixir struct/closure staging overhead as well.

---

## 2. Database Lifecycle

```elixir
# In-memory database
{:ok, db} = Xitdb.open(backend: :memory)

# File-backed database (:buffered_file is recommended for disk workloads)
{:ok, db} = Xitdb.open(backend: :buffered_file, path: "/path/to/data.xit", hash: :sha1)

# Synchronize buffered writes and close
:ok = Xitdb.sync(db)
:ok = Xitdb.close(db)

# Compact historical moments into a new file keeping only the latest moment
{:ok, compacted_db} = Xitdb.compact(db, path: "/path/to/data.compacted.xit")
```

---

## 3. Choosing Collection Types (`Xitdb.Collection`)

By default, plain Elixir maps (`%{}`) are stored as `:hash_map` (`Tag.Hash_Map`), plain lists (`[]`) as `:array_list` (`Tag.Array_List`), and `%MapSet{}` as `:counted_hash_set`. Use wrapper constructors on `Xitdb` when you need `O(1)` counts, lexicographical B+Tree ordering, or `O(log N)` list insertions/removals:

| Constructor | Selector Sigil | Backing Structure | Best For |
| :--- | :--- | :--- | :--- |
| `Xitdb.hash_map(map)` | `.key` | 16-way HAMT | General key-value maps |
| `Xitdb.counted_map(map)` | `#key` | 16-way HAMT + count header | Maps needing `O(1)` `Enum.count/1` |
| `Xitdb.sorted_map(map)` | `$key` | Lexicographical B+Tree | Ordered iteration, range slices, secondary indexes |
| `Xitdb.array_list(list)` | `[i]` | 16-way Radix Trie | Append-heavy lists and random index reads |
| `Xitdb.linked_list(list)` | `[[i]]` | Count-augmented B-Tree | Queues/lists needing `O(log N)` `insert`, `rm`, and `slice` |
| `Xitdb.hash_set(enum)` | `%member` | 16-way HAMT set | Uncounted string membership sets |
| `Xitdb.counted_set(enum)` | `#%member` | 16-way HAMT set + count | Sets needing `O(1)` `Enum.count/1` and `Enum.member?/2` |
| `Xitdb.sorted_set(enum)` | `^member` | Lexicographical B+Tree set | Ordered unique tags/badges |

---

## 4. Writing Data & Transactions

### 1. Declarative Macro DSL (`Xitdb.DSL.tx` / `Xitdb.tx`) — Preferred for Targeted Mutations

Use `use Xitdb.DSL` (or `require Xitdb` and `Xitdb.tx/2,3`) to compile deep path writes and native collection operations into a single atomic NIF batch with **zero intermediate NIF reads** and automatic creation of missing intermediate maps:

```elixir
use Xitdb.DSL

{:ok, db} =
  tx db, doc: "promote alice", instant: 1_712_000_000_000 do
    meta "author", "system"
    put users[id].role, "admin"
    put users[id].flags.set_member("staff")
    put users[new_id].profile.city, "Tokyo"
    append users[id].audit_log, "promoted"
    insert users[id].todos[[0]], "urgent-task"
    slice users[id].todos, 0..9
    fork users[id], backups[id]
    rm users[id].temp_token
    update users[id].login_count, 0, &(&1 + 1)
    savepoint()
  end
```

- **Important Elixir syntax rule**: Never start a path expression with a bare leading dot (`.users[id]`). Start with the bare root identifier (`users[id]`), `root.users[id]`, `_.users[id]`, or `:users[id]`.
- For set member additions inside `tx`, use 1-arity `put path.set_member(val)` (or `counted_set_member`/`sorted_set_member`).
- For read-modify-write updates with a fallback when the path does not yet exist, use 3-arity `update path, default, fun`.
- To roll back from inside a `tx` block, call `abort :reason`.
- **Never mutate `%Xitdb{}` directly** outside `Xitdb.transact/3` or `tx` (`put_in(db["a"], 1)` raises `ArgumentError`).
- **Single-writer concurrency**: Concurrent readers are lock-free, while read-modify-write transactions (`update` in `tx` and `Xitdb.transact/3` callbacks) must serialize through `Xitdb.Ash.Store` or a single owner `GenServer`.

### 2. Top-Level Map Transactions (`Xitdb.transact/3`)

When seeding or replacing whole subtrees from an Elixir map:

```elixir
{:ok, db} =
  Xitdb.transact(
    db,
    %{
      "users" => %{"alice" => %{"role" => "admin"}},
      "queue" => Xitdb.linked_list(["job-1", "job-2"])
    },
    doc: "initial seed",
    index_rules: [{:index_on, "users", "username", "username->id"}]
  )
```

### 3. Cursor `Access` Transactions (`put_in` / `update_in` / `pop_in`)

When mutating existing paths via a root `%Xitdb.Cursor{}` callback:

```elixir
{:ok, db} =
  Xitdb.transact(db, fn root ->
    {_, root} = pop_in(root["users"]["alice"]["temp_token"])

    root
    |> put_in(["users", "alice", "role"], "staff")
    |> update_in(["users", "alice", "logins"], &(&1 + 1))
    |> Xitdb.insert_at(["queue"], 1, "job-1.5")
  end)
```

---

## 5. Reading, Selecting & Pulling Data

### Lazy `Access` & `Enumerable` Fast Paths

`%Xitdb.Cursor{}` implements `Enumerable` with native data-structure fast paths (`Enum.count/1` in `O(1)`, `Enum.member?/2` in `O(1)` / `O(log_16 N)`, `Enum.slice/2` in `O(log N + K)`):

```elixir
root = Xitdb.db(db)

# O(1) / O(log N) lazy navigation
name = root["users"]["alice"]["name"]
last_role = root["users"]["alice"]["roles"][-1]

# Native collection pushdowns via Enumerable
count = Enum.count(root["counted_users"])
has_perm? = Enum.member?(root["permissions"], "deploy")
page = Enum.slice(root["linked_queue"], 10..19)
top_two = root["leaderboard"] |> Stream.take(2) |> Enum.to_list()
```

### Path Selectors (`path/1`, `path_steps/1`, and `~x`)

```elixir
use Xitdb.DSL

# Dynamic path with collection-type modifiers (# for counted, $ for sorted, [[i]] for linked list)
selector = path(org.counted(:departments)[dept_id].sorted(:directory)[user_id].todos[[0]])
todo = Xitdb.select!(db, selector)

# Pre-tokenized step list for hot loops with dynamic keys (avoids selector string formatting & parsing)
steps = path_steps(org.counted(:departments)[dept_id].sorted(:directory)[user_id].todos[[0]])
todo = Xitdb.select!(db, steps)

# Static compile-time validated sigil
todo = Xitdb.select!(db, ~x|.users["101"].todos[1]|)
```

- Prefer `Xitdb.DSL.path_steps/1` over string `path/1` when interpolating runtime variables in `select/2`, `select!/2`, or `history_of/2` (`tx` blocks already compile bare path expressions directly); keep `path/1` when you need a string selector and `~x` for static literals.
- `Xitdb.select/2` only accepts `%Xitdb{}` or a root snapshot cursor (`Xitdb.db/1`, `Xitdb.as_of/2`), never a nested child cursor (`db["users"]`).

### Datomic-Style Pull Projections (`Xitdb.pull/2`)

- Prefer `Xitdb.pull/2` with a structural list pattern over `Xitdb.materialize/1` when you only need a subset of fields or a bounded list slice:

```elixir
{:ok, user_card} =
  Xitdb.pull(root["users"]["101"], [
    :username,
    :age,
    todos: 0..2,
    profile: [:city]
  ])
```

### Order-Preserving Range Keys & Struct Encoding (`Xitdb.Key`, `Xitdb.Encoder`)

- Use `Xitdb.Key` (`encode_i64_be/1`, `encode_u64_be/1`, `encode_f64_be/1`, `encode_decimal_key/1`, `encode_fixed_decimal64_be/2`) when storing numeric or `> max(i64)` range keys in `:sorted_map` collections, and scan bounded windows lazily via `Xitdb.Key.stream_range/2` in `O(log N + K)`.
- Implement `defimpl Xitdb.Encoder, for: MyStruct` for domain structs written inside `Xitdb.transact/3`, `put_in/3`, `Xitdb.insert_at/4`, or `Xitdb.DSL.tx` blocks (`Decimal`, `Date`, `Time`, `DateTime`, `NaiveDateTime`, and `Xitdb.Ash.Types.RangedUnit` are built in). Remember Xitdb native `Tag.Uint` rejects raw integers exceeding signed `max(i64)`; use `Xitdb.Ash.Types.UnsignedInteger` or `{:tagged, "u8", <<n::unsigned-big-64>>}` for full `u64` values, and prefer `Ash.Query` over native Datalog `<`/`>` for `:tagged` or `> max(i64)` range scans.

---

## 6. Time-Travel, Diffs & History

```elixir
# Pin a zero-cost immutable snapshot to historical moment 0
v0 = Xitdb.as_of(db, 0)
old_val = v0["config"]["version"]

# Compute structural diff between two moments (skips identical 9-byte Slots in O(1))
{:ok, changes} = Xitdb.diff_moments(db, 0, 2)

# Inspect the historical lineage of a specific path across all moments
{:ok, lineage} = Xitdb.history_of(db, path(config.version))

# Compact obsolete moments & garbage-collect orphaned __blobs, __dicts, and __col_pages without re-inflating live tags
{:ok, compacted} = Xitdb.compact(db, path: "/var/data/store.compacted.xit")
```

- Use `Xitdb.Compression.Dictionary.train_and_put/4` + `{:compressed, bin, opts}` / `transact(db, term, compress: [...])` or `Xitdb.Columnar.put_rows/4` (`row_group_size: 128`) for repetitive HTML/text payloads; use `Ash.Query.select/2` or `Xitdb.pull/2` omitting compressed columns to achieve `0` page decompressions on metadata scans.

---

## 7. Datalog Queries (`Xitdb.DSL.query` & `~q`)

Use the `query/2,3` or `datalog/1` macro when binding runtime Elixir variables with `^`, or `~q` for static query strings:

```elixir
use Xitdb.DSL

prefix = "da"
min_salary = 115

{:ok, %{vars: vars, rows: rows}} =
  query db do
    find {name, salary}

    where [
      sorted("username->id")[name] == id,
      starts_with(name, ^prefix),
      users[id].salary == salary,
      salary >= ^min_salary,
      not users[id].flags.set_member("suspended"),
      reach(id, mgr, users[id].manager_id == mgr)
    ]
  end
```

- **Transitive Graph Reachability**: Use `reach(from, to, [depth,] edge_clause)` in `where` for cycle-safe recursive graph traversal where `from` and `to` are logic variables referenced inside `edge_clause` (e.g., `reach(id, mgr, users[id].manager_id == mgr)`).
- **Cross-Moment Joins**: Wrap any path expression in `at_moment(moment_or_var, path)` (e.g. `at_moment(0, users[id].salary) == old_salary` or `at_moment(m, users[id].role) == role`) to join across historical moments within a single query.
- **Path Existence & Absence**: Use bare paths (`users[id].mfa_secret`) or negated bare paths (`not users[id].deleted_at`) to filter by key presence without binding a variable.

---

## 8. Ash & Spark Integration (`Xitdb.Ash.DataLayer`, `Xitdb.Ash.Dsl`, `Xitdb.Ash.Search`)

`Xitdb.Ash.DataLayer` is a native, lock-free Ash Framework 3.37.2+ storage and BM25 search engine backed by immutable copy-on-write `.xit` files.

### Resource Configuration (`xitdb do ... end`)

Configure persistent Ash resources with `data_layer: Xitdb.Ash.DataLayer`:

```elixir
defmodule MyApp.Accounts.Profile do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: Xitdb.Ash.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  xitdb do
    store MyApp.MDM.Store
    collection :profiles

    # Explicit composite or single-attribute B+Tree (:sorted_map) secondary indexes
    # Note: belongs_to foreign keys are indexed automatically when index_relationships? is true
    index [:status, :inserted_at]

    # Transactional in-Xitdb BM25 + prefix search fields
    search_field :full_name, boost: 3.0
    search_field :headline, boost: 1.5

    search_field :firm_name,
      boost: 2.0,
      resolver: fn profile, db ->
        Xitdb.Ash.Search.lookup_field(db, :organizations, profile.organization_id, "name")
      end

    # Transparent compression (`mode: :value` or batch `:row_group` columnar pages on `Ash.bulk_create!`)
    compress [:headline], mode: :value, codec: :zstd, intern_above: 4096

    # Same-store incoming/outgoing foreign key actions (:nothing | :delete | :nilify | :restrict)
    references do
      reference :user, on_delete: :delete
      reference :organization, on_delete: :nilify
    end
  end
end
```

For `Xitdb.Ash.DataLayer` child entities co-located inside a parent entity's subtree for 9-byte `fork` snapshots, declare **both** `collection` (for `meta.sequences` and `idx.<collection>._parent` locators) and `nested_in`:

```elixir
xitdb do
  store MyApp.MDM.Store
  collection :agenda_sessions
  nested_in :events, foreign_key: :event_id, path: :sessions, cardinality: :many
end
```

### Strict DO / DON'T Rules

#### 1. Zero SQL Fragments or Codegen Migrations
- **DON'T** use `fragment(...)` (`Ash.Query.Function.Fragment`) in calculations, policies, validations, or identities. `VerifyNoSqlFragments` rejects SQL fragments at compile time.
- **DO** write portable `Ash.Expr` expressions (`expr(if(is_nil(location_city), location_name, location_city))`) or `Ash.Resource.Calculation` modules.
- **DON'T** run `mix ash.codegen` or `mix ash.migrate` for `Xitdb.Ash.DataLayer` resources. Schema, sequences, and B+Tree indexes evolve transactionally without DDL migrations or `priv/resource_snapshots`.

#### 2. Store Boundaries & Cross-Store Relationships
- **DO** read relationships (`belongs_to`, `has_many`, `many_to_many`, `exists(...)`) freely across distinct `.xit` stores (`MDM.Store` and `AppStore`); Ash resolves cross-store associations via batched `id in ^ids` queries.
- **DON'T** configure `references` with `on_delete: :delete | :nilify | :restrict` across two different `store` modules. `VerifyCrossStoreReferences` rejects cross-store FK cascades at compile time.
- **DO** use `Ash.Signals` or `Ash.Changeset.after_action/2` hooks to clean up dependent records living in another `.xit` store.

#### 3. Atomic Mutations, Policies & Validation Modules
- **DO** keep `update` and `destroy` actions atomic by default (`require_atomic? true`). `Xitdb.Ash.DataLayer` enforces row-level `FilterCheck` write policies (`changeset.filter`), `changeset.atomic_validations`, and `changeset.atomics` race-free inside its single-writer lease.
- **DO** implement the `atomic/3` callback on custom `Ash.Resource.Change` and `Ash.Resource.Validation` modules instead of opting into `require_atomic? false` unnecessarily.
- **DON'T** mutate Ash-managed collections via raw `Xitdb` cursor writes outside `Xitdb.Ash.DataLayer` unless also maintaining `meta.sequences`, `idx.<collection>.*`, and `idx.search.<collection>.*`.

#### 4. Oban & External Side Effects
- **DON'T** enqueue `Oban` jobs or broadcast `Phoenix.PubSub` events inside `before_action` hooks—workers may execute before the Xitdb writer lease commits and bumps the snapshot moment.
- **DO** enqueue `Oban` jobs inside `Ash.Changeset.after_transaction/2` (only on `{:ok, record}`), passing integer primary keys (`%{"user_id" => record.id}`).

### BM25 + Prefix Search (`Xitdb.Ash.Search`)

Query the transactional `idx.search.<collection>` B+Tree index and preserve BM25 ranking on the resulting `Ash.Query`:

```elixir
# Inside a Domain action or Preparation:
require Ash.Query

# Return `{id, score}` hits, or just ranked primary keys:
hits = Xitdb.Ash.Search.query(MyApp.Accounts.Profile, query_text, limit: 50)
ranked_ids = Xitdb.Ash.Search.ids(MyApp.Accounts.Profile, query_text, limit: 50)

Profile
|> Ash.Query.filter(id in ^ranked_ids)
|> Xitdb.Ash.Search.sort_by_rank(ranked_ids)
|> Ash.read!()
```

When a referenced parent entity changes a field used in a child's `search_field` `resolver:` (for example, `Organization.name` indexed onto `Profile`), call `Xitdb.Ash.Search.reindex_records(db_or_snapshot, ChildResource, records, tenant \\ nil)` in an `after_action` hook on the same store (setting `require_atomic? false` on the `:update` action, or using a `Change` module that implements `atomic/3`, so Ash 3 does not raise `Ash.Error.Framework.CanNotBeAtomic`):

```elixir
update :rename do
  require_atomic? false
  accept [:name]

  change after_action(fn _changeset, org, _ctx ->
           profiles = MyApp.Accounts.list_org_profiles!(org.id, authorize?: false)

           Xitdb.Ash.Store.mutate(MyApp.MDM.Store, fn snapshot ->
             {:ok, Xitdb.Ash.Search.reindex_records(snapshot, MyApp.Accounts.Profile, profiles), :ok}
           end)

           {:ok, org}
         end)
end
```

### Time-Travel Queries (`with_as_of/3`, `xitdb_moment`, `as_of:`)

Pin historical moments across `Ash.read`, `Ash.count`, aggregates, relationship loads, and BM25 search without touching the `Store` GenServer. Use `Store.with_as_of/3` or `context: %{shared: %{xitdb_moment: prev_moment}}` when loading relationships or calculations (Ash 3 only copies `context[:shared]` to child queries, dropping top-level `context[:xitdb_moment]`):

```elixir
# 1. Scoped historical block for all Ash reads, loads & BM25 searches on a store:
Xitdb.Ash.Store.with_as_of(MyApp.MDM.Store, prev_moment, fn ->
  Ash.read!(MyApp.Accounts.Profile, load: [:organization])
end)

# 2. Per-query Ash context (use `shared:` when loading relationships/calculations) or Search option:
Ash.read!(MyApp.Accounts.Profile, load: [:organization], context: %{shared: %{xitdb_moment: prev_moment}})
Xitdb.Ash.Search.ids(MyApp.Accounts.Profile, "northleaf", as_of: prev_moment)
```

### Concurrent Testing (`Xitdb.Ash.TestSandbox`)

- **DO** call `Xitdb.Ash.TestSandbox.init()` once in `test/test_helper.exs` before `ExUnit.start()`.
- **DO** optionally pre-seed shared fixtures once via `Xitdb.Ash.TestSandbox.seed_template(MyApp.Store, fn db -> ... end)`, then check out isolated `:memory` stores per test in `DataCase` `setup` via `Xitdb.Ash.TestSandbox.checkout([MyApp.Store])` (with `checkin/2` or `ExUnit.Callbacks.on_exit/1`) and run tests with `async: true`. Use `Xitdb.Ash.TestSandbox.allow(MyApp.Store, self(), child_pid)` when spawned worker processes read/write the checked-out sandbox.
- **DO** generate unique values via `System.unique_integer([:positive])` for all `identities` in `Ash.Generator` fixtures.
- **DO** skip `Ecto.Adapters.SQL.Sandbox` for tests that only touch `Xitdb.Ash.DataLayer` resources.

### Introspection Helpers (`Xitdb.Ash.Info`)

- Use `Xitdb.Ash.Info.search_fields(Resource)`, `Xitdb.Ash.Info.indexes(Resource)`, `Xitdb.Ash.Info.counted_set_fields(Resource)`, and `Xitdb.Ash.Info.resolve_store(Resource, context_or_opts)` instead of hardcoding field lists or index maps.
- Use `Xitdb.Ash.Info.compression_configs(Resource)` and `Xitdb.Ash.Info.compression_for_field(Resource, field)` to inspect attribute compression rules (`:value` or `:row_group`).
- Use `Xitdb.Ash.Info.nested_in(Resource)` (and `Xitdb.Ash.Info.nested?(Resource)`) for `Xitdb.Ash.DataLayer` co-located subtrees (which support child secondary indexes).
- Use `tx_for(db, Resource) do ... end` (`Xitdb.Ash.Tx`) to automatically inject all `index_on` declarations configured on resources so secondary B+Tree indexes never drift on raw transactions.
- Use `Xitdb.Ash.Types.UnsignedInteger` (`0..2^64-1`), `Xitdb.Ash.Types.FixedDecimal64` (`scale:`, `signed?:`, `representation: :integer | :tagged`), `Xitdb.Ash.Types.RangedUnit` (`to_indexed_fields/2,3`, `overlaps?/2`), or custom `Ash.Type` modules implementing `xitdb_index_key/2` + `xitdb_fixed_width?/1` for order-preserving secondary B+Tree range queries.

---

## 9. Reference Guides (`docs/`)

- [`docs/access-and-enumerable.md`](docs/access-and-enumerable.md) — Reading and updating with `Access`, `Enum`, and `Stream`.
- [`docs/collections-and-indexing.md`](docs/collections-and-indexing.md) — Choosing persistent collection types and `index_on` secondary indexes.
- [`docs/time-travel-and-storage.md`](docs/time-travel-and-storage.md) — Snapshots (`as_of/2`), diffs (`diff_moments/3`), field history (`history_of/2`), storage backends, and compaction.
- [`docs/transaction-dsl.md`](docs/transaction-dsl.md) — Declarative `tx/2,3` and `tx_for/3,4` blocks, collection ops, metadata, savepoints, and rollback.
- [`docs/path-and-pull-dsl.md`](docs/path-and-pull-dsl.md) — `Xitdb.pull/2` projections, `pull_pattern/1`, `path/1`, `path_steps/1`, and `~x`.
- [`docs/datalog-dsl.md`](docs/datalog-dsl.md) — Declarative `query/2,3` and `datalog/1` blocks, `^var` pinning, `reach`, `at_moment`, predicates, and aggregations.
- [`docs/ash-and-spark.md`](docs/ash-and-spark.md) — `Xitdb.Ash.DataLayer`, `Xitdb.Ash.Dsl`, `Xitdb.Ash.Store`, `Xitdb.Ash.Search`, `Xitdb.Ash.Info` introspection, and `tx_for` / `tx_for!`.
- [`docs/architecture-and-internals.md`](docs/architecture-and-internals.md) — Storage layout, 9-byte `Slot` cursors, WAL-free crash safety, NIF boundary cost model, and single-writer supervision.
