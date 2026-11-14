# Declarative Datalog Query DSL (`datalog/1`, `query/2,3`, `query!/2,3`, `~q`)

`Xitdb` includes a native structural and temporal Datalog engine in Odin that supports:
- Pattern unification across maps, counted maps, sorted maps, lists, and sets
- Automatic `O(log N)` B+Tree secondary index prefix and range pushdown
- Negated clauses (`not`) and key existence checks
- Cycle-safe BFS transitive graph traversal (`reach/3,4`)
- Cross-moment and full-history temporal queries (`at_moment/2`)
- Grouped and global aggregations (`count`, `sum`, `min`, `max`)

In addition to the compile-time validated `~q` sigil (`~q"find ?name where ..."`), `Xitdb.DSL` provides an Ecto/Datomic-style macro DSL (`datalog/1`, `query/2,3`, `query!/2,3`) so you can write queries in native Elixir syntax and safely pin runtime Elixir variables with `^var`.

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

If you want to inspect or reuse the compiled Datalog query string without immediately executing it, use `datalog/1`:

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

## 2. Logic Variables vs. Pinned Runtime Values (`^`)

Inside `find` and `where`:
- **Bare identifiers** (`id`, `name`, `salary`, `u`, `m`) are compiled as Datalog logic variables (`?id`, `?name`, `?salary`, `?u`, `?m`).
- **Pinned expressions** (`^min_salary`, `^prefix`, `^(user.dept)`) evaluate the Elixir expression at runtime and safely serialize the literal into the Datalog clause.
- **Literals** (`"eng"`, `100`, `true`, `:active`) are serialized directly at compile time.

---

## 3. Entity Generator Bindings (`<-` and `from`)

Instead of repeating `users[id].field` on every line, you can bind an entity variable to a collection using any of four equivalent forms:

1. **In-clause generator (`u <- users`)**: inside `where [...]`
2. **Top-level `from u in users`** (or `from u <- users`)
3. **Top-level `from users`** (binds the first variable in `find` to `users`)
4. **Option `query(db, from: :users) do ... end`**

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

## 4. Transitive Graph Traversal (`reach/3` and `reach/4`)

`xitdb`'s Datalog engine natively supports cycle-safe Breadth-First Search (BFS) transitive closure via `reach`:

- `reach(from_var, to_var, edge_clause)` — transitively steps `edge_clause` from `from_var` to all reachable `to_var` nodes.
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

## 5. Temporal Queries & Cross-Moment Joins (`at_moment/2`)

You can query historical data in two ways:

### A. Querying a Single Historical Snapshot (`moment: idx`)
Pass `moment: idx` to `query/3` (or pass a snapshot cursor from `Xitdb.as_of(db, idx)`):

```elixir
{:ok, v0_res} =
  query db, moment: 0 do
    find {id, role}
    where [users[id].role == role]
  end
```

### B. Per-Clause `at_moment(moment_or_var, path)`
Use `at_moment/2` inside `where` to compare state across different moments in a single query—or pass a **logic variable** `m` as the first argument to unify across **all committed moments** in the database:

```elixir
# 1. Cross-moment comparison (find everyone whose salary increased between moment 0 and moment 1):
{:ok, raises} =
  query db do
    find {id, old_salary, new_salary}

    where [
      at_moment(0, users[id].salary) == old_salary,
      at_moment(1, users[id].salary) == new_salary,
      new_salary > old_salary
    ]
  end

# 2. Temporal variable unification (bind `m` to every moment index and return Alice's salary timeline):
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

## 6. Supported Clauses, Predicates & Aggregations Reference

### `find` Projections & Aggregations
- Logic variables: `find {id, name, salary}` or `find [id, name]`
- Aggregations:
  - `count(var)`
  - `sum(var)`
  - `min(var)`
  - `max(var)`

Non-aggregated variables in `find` automatically act as the grouping key. If all items in `find` are aggregations (e.g. `find {min(salary), max(salary), count(u)}`), the engine computes a single global aggregate row.

### `where` Clauses
- **Attribute unification:** `users[id].dept == dept` or `u.dept == "eng"`
- **Key existence / non-existence:** `users[id].temp_token` or `not users[id].temp_token` (checks whether the path exists without binding a value)
- **Secondary `Sorted_Map` index lookup:** `sorted("username->id")[name] == id`
- **Counted map lookup:** `counted(:users)[id].age == age`
- **Array list / linked list unification:**
  - `users[id].roles[idx] == role` (binds `idx` to `0..N-1` and `role` to each element)
  - `users[id].todos[[idx]] == task` (`Linked_Array_List`)
  - `users[id].roles[^pinned_idx] == role` (point lookup at a pinned index)
- **Set membership:**
  - `u.flags.set_member("active")` (`%` `Hash_Set`)
  - `u.flags.counted_set_member("active")` (`#%` `Counted_Hash_Set`)
  - `u.tags.sorted_set_member("elixir")` (`^` `Sorted_Set`)
- **Comparisons:** `==`, `!=`, `>`, `>=`, `<`, `<=` (works between two logic variables like `new_salary > old_salary` or a variable and a literal/pinned value like `salary >= ^min_salary`)
- **String predicates & B+Tree Pushdown:**
  - `starts_with(var, "prefix")` — triggers an **`O(log N)` B+Tree prefix seek** when `var` is unified against a `Sorted_Map` (`sorted(...)`) or `Sorted_Set`!
  - `var >= "lower_bound"` / `var > "lower_bound"` — also triggers an **`O(log N)` B+Tree lower-bound seek** on `Sorted_Map` / `Sorted_Set` keys!
  - `contains(var, "substring")`
- **Negation:** `not <clause>` (e.g. `not u.flags.set_member("suspended")`, `not u.deleted_at`, or `not (u.role == "guest")`)

---

## 7. Multi-Collection Join Example

Logic variables shared across multiple collections automatically perform an equijoin:

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
