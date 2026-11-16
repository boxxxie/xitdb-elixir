# Datalog & Graph Queries

`Xitdb` includes a built-in Datalog engine for expressive declarative queries right against your stored maps, lists, sets, and sorted indexes:

- Pattern matching and equijoins across multiple collections
- Automatic `O(log N)` prefix and lower-bound range seeks on `:sorted_map` and `:sorted_set` indexes
- Negation (`not`) and key-existence checks
- Grouped and global aggregations (`count`, `sum`, `min`, `max`)
- Cycle-safe recursive graph reachability (`reach/3,4`)
- Cross-moment historical joins and full-history queries (`at_moment/2`)

Write queries in native Elixir syntax with `query/2,3` or `datalog/1` (supporting runtime variable pinning with `^var`), or use the compile-time validated `~q` sigil (`~q"find ?name where ..."`).

---

## 1. Basic Usage

```elixir
use Xitdb.DSL

prefix = "da"
min_salary = 115

{:ok, %{vars: ["?name", "?salary"], rows: rows}} =
  query db do
    find {name, salary}

    where [
      sorted("username->id")[name] == id,
      starts_with(name, ^prefix),
      users[id].salary == salary,
      salary >= ^min_salary,
      not users[id].flags.set_member("suspended")
    ]
  end
```

To inspect or reuse a compiled Datalog query string without running it right away, use `datalog/1`:

```elixir
q =
  datalog do
    find {name, salary}
    where [
      users[id].username == name,
      users[id].salary == salary
    ]
  end

# When `use Xitdb.DSL` is active, `query/2,3` and `query!/2,3` accept both
# `do ... end` blocks AND compiled query strings / `~q` sigils:
Xitdb.query!(db, q)
query!(db, ~q"find ?name where .users[?id].username = ?name")
```

---

## 2. Logic Variables vs. Pinned Runtime Values (`^var`)

Inside `find` and `where`:
- **Bare identifiers** (`id`, `name`, `salary`, `u`, `m`) become Datalog logic variables (`?id`, `?name`, `?salary`, `?u`, `?m`).
- **Pinned expressions** (`^min_salary`, `^prefix`, `^(user.dept)`) evaluate the Elixir expression at runtime and safely bind the value into the query.
- **Literals** (`"eng"`, `100`, `true`, `:active`) compile directly into the query.

---

## 3. Entity Bindings (`from` / `<-`) & Multi-Collection Joins

Instead of repeating `users[id].field` on every line, bind an entity variable to a collection with any of four equivalent forms:

1. **In-clause generator (`u <- users`):** inside `where [...]`
2. **Top-level `from u in users`** (or `from u <- users`)
3. **Top-level `from users`** (binds the first variable in `find` to `users`)
4. **Option `query(db, from: :users) do ... end`**

### Multi-Collection Equijoins

Sharing a logic variable across two collections joins them automatically:

```elixir
{:ok, %{rows: rows}} =
  query db do
    find {emp_name, dept_name, budget}

    where [
      u <- users,
      u.name == emp_name,
      u.dept_id == dept_id,
      counted(:departments)[dept_id].title == dept_name,
      counted(:departments)[dept_id].budget == budget,
      budget >= 250_000
    ]
  end
```

---

## 4. Aggregations (`count`, `sum`, `min`, `max`)

Any non-aggregated variable in `find` acts as the grouping key. When all items in `find` are aggregations (for example `find {min(salary), max(salary), count(u)}`), the engine returns a single global summary row.

```elixir
excluded_flag = "suspended"

{:ok, res} =
  query db do
    find {dept, count(u), sum(salary)}
    from u in users

    where [
      u.dept == dept,
      u.salary == salary,
      not u.flags.set_member(^excluded_flag)
    ]
  end
```

This compiles to:

```text
find ?dept, count(?u), sum(?salary)
where
  .users[?u].dept = ?dept
  .users[?u].salary = ?salary
  not .users[?u].flags%"suspended"
```

---

## 5. Recursive Graph Traversal (`reach/3` and `reach/4`)

`Xitdb`'s Datalog engine supports cycle-safe Breadth-First Search (BFS) transitive graph traversal via `reach`:

- `reach(from_var, to_var, edge_clause)` — walks `edge_clause` transitively from `from_var` to every reachable `to_var`.
- `reach(from_var, to_var, depth_var, edge_clause)` — also binds `depth_var` to the integer hop count (`1` for direct neighbors, `2` for neighbors-of-neighbors, etc.).

```elixir
root_mgr = "alice"

{:ok, %{rows: rows}} =
  query db do
    find {report, depth}

    where [
      mgr == ^root_mgr,
      reach(mgr, report, depth, users[mgr].reports[idx] == report),
      not users[report].temp_token
    ]
  end
# => rows: [["bob", 1], ["carol", 1], ["dave", 2]]
```

---

## 6. Querying Across Time (`moment:` & `at_moment/2`)

### Querying a Single Historical Snapshot (`moment: idx`)
Pass `moment: idx` to `query/3` (or pass a cursor from `Xitdb.as_of(db, idx)`):

```elixir
{:ok, v0_res} =
  query db, moment: 0 do
    find {id, role}
    where [users[id].role == role]
  end
```

### Cross-Moment Joins & Full-History Scans (`at_moment/2`)
Wrap any path expression in `at_moment(moment_or_var, path)` inside `where` to compare values across different commits—or pass a **logic variable** `m` as the first argument to unify across **every committed moment** in the database:

```elixir
# 1. Cross-moment comparison (find everyone whose salary increased from moment 0 to moment 1)
{:ok, raises} =
  query db do
    find {id, old_salary, new_salary}

    where [
      at_moment(0, users[id].salary) == old_salary,
      at_moment(1, users[id].salary) == new_salary,
      new_salary > old_salary
    ]
  end

# 2. Temporal variable unification (bind `m` to every moment and return Alice's salary timeline)
{:ok, timeline} =
  query db do
    find {m, sal}

    where [
      at_moment(m, users["alice"].salary) == sal
    ]
  end
# => %{vars: ["?m", "?sal"], rows: [[0, 100], [1, 130]]}
```

---

## 7. Supported Clauses, Predicates & Aggregations Reference

### `find` Projections & Aggregations
- Logic variables: `find {id, name, salary}` or `find [id, name]`
- Aggregations: `count(var)`, `sum(var)`, `min(var)`, `max(var)`

### `where` Clauses
- **Attribute unification:** `users[id].dept == dept` or `u.dept == "eng"`
- **Key existence / non-existence:** `users[id].temp_token` or `not users[id].temp_token`
- **Secondary `:sorted_map` lookup:** `sorted("username->id")[name] == id`
- **Counted map lookup:** `counted(:users)[id].age == age`
- **List unification:**
  - `users[id].roles[idx] == role` (`Array_List`, binds `idx` to `0..N-1` and `role` to each element)
  - `users[id].todos[[idx]] == task` (`Linked_Array_List`)
  - `users[id].roles[^pinned_idx] == role` (point lookup at a pinned index)
- **Set membership:**
  - `u.flags.set_member("active")` (`Hash_Set`)
  - `u.flags.counted_set_member("active")` (`Counted_Hash_Set`)
  - `u.tags.sorted_set_member("elixir")` (`Sorted_Set`)
- **Comparisons:** `==`, `!=`, `>`, `>=`, `<`, `<=` (works between two logic variables like `new_salary > old_salary` or a variable and a literal/pinned value like `salary >= ^min_salary`)
- **String predicates & B+Tree seek optimization:**
  - `starts_with(var, "prefix")` — triggers an `O(log N)` B+Tree prefix seek when `var` is bound to a `:sorted_map` (`sorted(...)`) or `:sorted_set`
  - `var >= "lower_bound"` / `var > "lower_bound"` — also triggers an `O(log N)` B+Tree lower-bound seek on `:sorted_map` / `:sorted_set` keys
  - `contains(var, "substring")`
- **Negation:** `not <clause>` (for example `not u.flags.set_member("suspended")`, `not u.deleted_at`, or `not (u.role == "guest")`)
