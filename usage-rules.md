# Xitdb Elixir Client Usage Rules

`Xitdb` is an idiomatic Elixir client and Odin NIF wrapper for `xitdb`—an embeddable, immutable, append-only database with persistent structural sharing (`Hash_Map`, `Counted_Hash_Map`, `Sorted_Map`, `Array_List`, `Linked_Array_List`, and sets).

---

## 1. Core Architecture & Lazy `%Xitdb.Cursor{}` Navigation

1. **Default to Lazy `Access` Navigation (`db["users"]["alice"]["name"]`)**:
   - Reading from `Xitdb` (`Xitdb.db(db)`, `Xitdb.as_of(db, moment)`, or `db["users"]`) returns a lazy `%Xitdb.Cursor{}` holding only the NIF database reference and 9-byte `Slot` coordinates (`tag`, `tag_id`, `value`).
   - Cursors are **pure, immutable Elixir values**. Pass them freely across BEAM processes (`Task.async_stream/3`, GenServers, ETS, Phoenix LiveView assigns) without locks or copying underlying subtrees.
   - Navigating to a scalar (`string`, `integer`, `float`, `boolean`, or `{:tagged, tag, bytes}`) unwraps and returns the native Elixir value directly; navigating to a nested container returns another `%Xitdb.Cursor{}` in $O(1)$ heap space.
2. **Use `Xitdb.at/1` Instead of `Access.at/1` on Lazy List Cursors**:
   - Elixir's built-in `Access.at/1` guards `is_list(data)` and raises on structs. When navigating `Array_List` or `Linked_Array_List` cursors with `get_in/2` or `put_in/3`, either pass integer keys directly in the path list (`get_in(root, ["users", "alice", "roles", 1])`) or use `Xitdb.at(1)`.
3. **Never Eagerly Materialize Large Subtrees Unless Needed**:
   - Never call `Xitdb.materialize(db)` on the entire database root in hot paths. Prefer lazy navigation (`cursor["key"]`, `cursor[0]`), `Xitdb.pull/2` projections, `Enum.count/1`, `Enum.member?/2`, `Enum.slice/2`, or `Stream` pipelines, or navigate to the leaf entity first (`user = db["users"][id]`) before calling `Xitdb.materialize(user)`.

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

By default, plain Elixir maps (`%{}`) are stored as `:hash_map` (`Tag.Hash_Map`), plain lists (`[]`) as `:array_list` (`Tag.Array_List`), and `%MapSet{}` as `:counted_hash_set`. Use wrapper constructors on `Xitdb` when you need $O(1)$ counts, lexicographical B+Tree ordering, or $O(\log N)$ list insertions/removals:

| Constructor | Selector Sigil | Backing Structure | Best For |
| :--- | :--- | :--- | :--- |
| `Xitdb.hash_map(map)` | `.key` | 16-way HAMT | General key-value maps |
| `Xitdb.counted_map(map)` | `#key` | 16-way HAMT + count header | Maps needing $O(1)$ `Enum.count/1` |
| `Xitdb.sorted_map(map)` | `$key` | Lexicographical B+Tree | Ordered iteration, range slices, secondary indexes |
| `Xitdb.array_list(list)` | `[i]` | 16-way Radix Trie | Append-heavy lists and random index reads |
| `Xitdb.linked_list(list)` | `[[i]]` | Count-augmented B-Tree | Queues/lists needing $O(\log N)$ `insert`, `rm`, and `slice` |
| `Xitdb.hash_set(enum)` | `%member` | 16-way HAMT set | Uncounted string membership sets |
| `Xitdb.counted_set(enum)` | `#%member` | 16-way HAMT set + count | Sets needing $O(1)$ `Enum.count/1` and `Enum.member?/2` |
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

`%Xitdb.Cursor{}` implements `Enumerable` with native data-structure fast paths (`Enum.count/1` in $O(1)$, `Enum.member?/2` in $O(1)$ / $O(\log_{16} N)$, `Enum.slice/2` in $O(\log N + K)$):

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

### Path Selectors (`path/1` and `~x`)

```elixir
use Xitdb.DSL

# Dynamic path with collection-type modifiers (# for counted, $ for sorted, [[i]] for linked list)
selector = path(org.counted(:departments)[dept_id].sorted(:directory)[user_id].todos[[0]])
todo = Xitdb.select!(db, selector)

# Static compile-time validated sigil
todo = Xitdb.select!(db, ~x|.users["101"].todos[1]|)
```

### Datomic-Style Pull Projections (`Xitdb.pull/2`)

Prefer `Xitdb.pull/2` with a structural list pattern over `Xitdb.materialize/1` when you only need a subset of fields or a bounded list slice:

```elixir
{:ok, user_card} =
  Xitdb.pull(root["users"]["101"], [
    :username,
    :age,
    todos: 0..2,
    profile: [:city]
  ])
```

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
```

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
      reach(id, :manager_id, mgr, users)
    ]
  end
```

- **Transitive Graph Reachability**: Use `reach(from, :edge_field, to)` or `reach(from, :edge_field, to, collection)` in `where` for cycle-safe recursive graph traversal.
- **Cross-Moment Joins**: Wrap any path expression in `at_moment(moment_or_var, path)` (e.g. `at_moment(0, users[id].salary) == old_salary` or `at_moment(m, users[id].role) == role`) to join across historical moments within a single query.
- **Path Existence & Absence**: Use bare paths (`users[id].mfa_secret`) or negated bare paths (`not users[id].deleted_at`) to filter by key presence without binding a variable.

---

## 8. Ash & Spark Integration (`Xitdb.Ash.Resource`, `Xitdb.Ash.Info`, `tx_for`)

When `:ash` and `:spark` are loaded, `Xitdb` provides a declarative Spark DSL extension (`Xitdb.Ash.Resource`), compile-time/runtime introspection (`Xitdb.Ash.Info`), a compile-time projection/index verifier (`Xitdb.Ash.Verifiers.VerifySyncProjection`), and automatic secondary index injection (`tx_for` / `tx_for!`):

```elixir
defmodule MyApp.Accounts.Organization do
  use Ash.Resource,
    domain: MyApp.Accounts,
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
end
```

- **Prefer `tx_for/3,4` and `tx_for!/3,4` over manual `index_on` repetition**:
  `tx_for(db, Organization, doc: "...") do ... end` automatically injects all `index_on` declarations configured on `Organization` (or a list of resources/schemas) so secondary B+Tree indexes never drift on write or `rm`.
- **Use `Xitdb.Ash.Info` for Pull Projections & Field Lists**:
  Use `Xitdb.Ash.Info.pull_fields(Resource)`, `Xitdb.Ash.Info.pull_pattern_for(Resource)`, `Xitdb.Ash.Info.editable_field_strings(Resource)`, and `Xitdb.Ash.Info.resolve_store(Resource, context_or_opts)` instead of hardcoding field lists across engines and reconcilers.

---

## 9. Reference Guides (`docs/`)

- [`docs/access-and-enumerable.md`](docs/access-and-enumerable.md) — Lazy 9-byte `Slot` cursors, `Access`, `Enumerable` fast paths, and `Stream` pagination.
- [`docs/collections-and-indexing.md`](docs/collections-and-indexing.md) — Persistent data structure selection (`hash_map`, `counted_map`, `sorted_map`, `array_list`, `linked_list`, sets) and secondary B+Tree indexing (`index_on`).
- [`docs/time-travel-and-storage.md`](docs/time-travel-and-storage.md) — Snapshots (`as_of/2`), structural diffs (`diff_moments/3`), attribute history (`history_of/2`), storage backends, and compaction.
- [`docs/path-and-pull-dsl.md`](docs/path-and-pull-dsl.md) — `path/1`, `~x`, typed collection modifiers, wildcard scans, and structural `Xitdb.pull/2` projections.
- [`docs/transaction-dsl.md`](docs/transaction-dsl.md) — Declarative `tx/2,3` and `tx_for/3,4` blocks, collection operations, metadata (`doc`, `instant`, `meta`), savepoints, and rollback.
- [`docs/datalog-dsl.md`](docs/datalog-dsl.md) — Declarative `query/2,3` and `datalog/1` blocks, `^var` pinning, `reach`, `at_moment`, predicates, and aggregations.
- [`docs/ash-and-spark.md`](docs/ash-and-spark.md) — `Xitdb.Ash.Resource` Spark DSL extension, `Xitdb.Ash.Info` introspection, `VerifySyncProjection` verifier, and `tx_for` / `tx_for!`.
