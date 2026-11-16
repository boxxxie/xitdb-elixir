# Path Selectors & Pull Projections

While [`Access` navigation](access-and-enumerable.md) (`db["users"]["alice"]["name"]`) is great for interactive exploration and passing lazy cursors around, you often want to:

1. **Pull a shaped subgraph in one step** (`Xitdb.pull/2`)—grabbing specific fields, nested maps, and bounded list slices without converting large collections into Elixir maps.
2. **Address a deep path in one call** (`Xitdb.select/2`)—using `path/1`, `path_steps/1`, or the `~x` sigil with safe variable interpolation and automatic escaping for keys that contain dots, spaces, or special characters.

---

## 1. Structural Pull Projections (`Xitdb.pull/2` & `pull_pattern/1`)

`Xitdb.pull/2` and `Xitdb.pull!/2` extract an exact subset of fields and list slices from any `%Xitdb.Cursor{}` or `%Xitdb{}` handle using a structured Elixir keyword/list pattern (or raw `xitdb` Pull string):

```elixir
Xitdb.pull!(user_cursor, [
  :username,
  :age,
  todos: 0..1,
  profile: [:city, :tier]
])
# => %{
#   "username" => "dan",
#   "age" => 29,
#   "todos" => ["design schema", "write specs"],
#   "profile" => %{"city" => "Montreal", "tier" => "pro"}
# }
```

### Supported Pull Pattern Entries

| Pattern Entry | Compiled Pull Syntax | Description |
| :--- | :--- | :--- |
| `:field` or `"field"` | `field` | Projects a single key |
| `:*` or `"*"` | `*` | Wildcard: projects all keys on the map |
| `field: first..last` | `field[first..(last + 1)]` | Projects an inclusive Elixir range `first..last` (matching `Enum.slice/2`) of a list |
| `field: {:slice, offset, limit}` | `field[offset..(offset + limit)]` | Projects `limit` items starting at `offset` (matching `Enum.slice(list, offset, limit)`) |
| `field: [:a, :b]` | `field{a, b}` | Recursively projects nested map attributes |
| `field: {0..4, [:a, :b]}` | `field[0..5]{a, b}` | Slices a list of maps by inclusive range and projects nested attributes on each element |
| `field: {{:slice, offset, limit}, [:a, :b]}` | `field[offset..(offset + limit)]{a, b}` | Slices `limit` maps starting at `offset` and projects nested attributes on each element |

### Practical Pull Recipes

#### Recipe 1: Wildcard `:*` + Bounded List Slice
When an entity has many scalar attributes alongside an unbounded append-only list (such as `audit_log`), combine `:*` with a slice to project every field while bounding the list:

```elixir
Xitdb.pull!(user_cursor, [
  :*,
  audit_log: {:slice, 0, 5}
])
```

#### Recipe 2: Paginating a List of Nested Entities
Slice a list of nested maps (such as `team` members) and project only the fields your UI needs:

```elixir
page_offset = 10
page_size = 5

Xitdb.pull!(account_cursor, [
  :email,
  team: {{:slice, page_offset, page_size}, [:username, profile: [:city, :tier]]}
])
```

#### Recipe 3: Pre-Compiling Static Patterns (`pull_pattern/1`)
For static patterns used inside hot loops, wrap the pattern in `pull_pattern/1` so `Xitdb.Pull.compile!/1` runs once at compile time:

```elixir
use Xitdb.DSL

@user_card pull_pattern([:username, :age, todos: 0..2, profile: [:city]])
# Compiled at compile time to "{username, age, todos[0..3], profile{city}}"

Xitdb.pull!(user_cursor, @user_card)
```

---

## 2. Path Selectors (`path/1`, `path_steps/1` & `~x`)

Import the DSL with `use Xitdb.DSL` (or call `Xitdb.path/1` after `require Xitdb`):

```elixir
use Xitdb.DSL

# 1. Static path (folded into a binary literal at compile time)
path(users.alice.profile.city)
# => ".users.alice.profile.city"

# 2. Static ~x sigil (validated at compile time)
~x|.users["user.101"].todos[2]|
# => ".users[\"user.101\"].todos[2]"

# 3. Dynamic runtime interpolation
user_id = "user.101"
todo_idx = 2

path(users[user_id].todos[todo_idx])
# => ".users.[\"user.101\"].todos[2]"

# 4. Pre-tokenized path_steps/1 for dynamic paths in hot loops
steps = path_steps(users[user_id].todos[todo_idx])
Xitdb.select!(db, steps)
```

### Root Syntax Forms

Because Elixir's parser does not allow a bare unary leading dot (`.users`), `path/1` and `path_steps/1` support five equivalent root forms:

| Form | Example | Compiled Selector |
| :--- | :--- | :--- |
| Bare identifier | `path(users[id].role)` | `".users..."` |
| Explicit `root` / `_` | `path(root.users[id].role)` / `path(_.users[id].role)` | `".users..."` |
| Atom root | `path(:users[id].role)` | `".users..."` |
| Step-list syntax | `path([:users, id, :role])` | `".users..."` |
| Pinned selector prefix (`^`) | `path(^base_sel.profile.city)` | `base_sel <> ".profile.city"` |

### Automatic Special-Character Key Escaping

If a runtime key is empty or contains special selector characters (`.`, `[`, `]`, `#`, `$`, `%`, `^`, quotes, or whitespace), `path/1` automatically quotes it in `["..."]` notation so emails, URLs, or arbitrary strings never corrupt selector parsing:

```elixir
email = "alice.liddell@acme.io"

path(accounts[email].balance)
# => ".accounts.[\"alice.liddell@acme.io\"].balance"

path(sorted("email->id")[email])
# => ".email->id$[\"alice.liddell@acme.io\"]"
```

---

## 3. Collection Step Modifiers & Splicing (`^prefix`)

When targeting explicit collection types, `path/1` lets you specify collection modifiers either as chained calls or step tuples:

| Collection Kind | Selector Sigil | Chained `path/1` Syntax | Step-List `path/1` Syntax | Compiled Output |
| :--- | :--- | :--- | :--- | :--- |
| `:hash_map` | `.key` | `users[id]` or `users.alice` | `[:users, id]` | `".users.alice"` |
| `:counted_hash_map` | `#key` | `org.counted(:departments)[dept_id]`<br>or `org.departments[counted(dept_id)]` | `[:org, :departments, {:counted, dept_id}]` | `".org.departments#eng"` |
| `:sorted_map` | `$key` | `eng.sorted(:directory)[emp_id]`<br>or `eng.directory[sorted(emp_id)]` | `[:eng, :directory, {:sorted, emp_id}]` | `".eng.directory$101"` |
| `:array_list` | `[idx]` | `items[0]` or `items.array(0)` | `[:items, 0]` or `[:items, {:array, 0}]` | `".items[0]"` |
| `:linked_array_list` | `[[idx]]` | `todos[[2]]` or `todos.linked(2)` | `[:todos, [2]]` or `[:todos, {:linked, 2}]` | `".todos[[2]]"` |
| `:hash_set` | `%member` | `flags.set_member("active")` | `[:flags, {:set_member, "active"}]` | `".flags%active"` |
| `:counted_hash_set` | `#%member` | `flags.counted_set_member("active")` | `[:flags, {:counted_set_member, "active"}]` | `".flags#%active"` |
| `:sorted_set` | `^member` | `tags.sorted_set_member("elixir")` | `[:tags, {:sorted_set_member, "elixir"}]` | `".tags^elixir"` |
| Historical Moment | `@moment` | `at_moment(0, users[id].role)` | — | `"@0.users.alice.role"` |

### Composing Selectors & Where They Work

Build reusable base selectors and splice them into deeper paths with the pin operator (`^`):

```elixir
use Xitdb.DSL

dept_path = path(org.counted(:departments)[dept_id])
# => ".org.departments#eng"

emp_todo_path = path(^dept_path.sorted(:directory)[emp_id].todos[[0]])
# => ".org.departments#eng.directory$101.todos[[0]]"
```

Compiled selectors work across `select/2`, `history_of/2`, and transaction list/fork helpers:

```elixir
# 1. Root-anchored selection against `%Xitdb{}` or a root snapshot (`Xitdb.db/1`, `Xitdb.as_of/2`)
todo = Xitdb.select!(db, path_steps(users[id].todos[[0]]))
v0_role = Xitdb.select!(db, path(at_moment(0, users[id].role)))
# Note: `select/2` only accepts `%Xitdb{}` or a root snapshot cursor; use `Access` or `Xitdb.pull/2` on child cursors.

# 2. Temporal lineage of a path across all commits
{:ok, lineage} = Xitdb.history_of(db, path(users[id].role))

# 3. Staging list insertions, deletions, or subtree forks inside Xitdb.transact/2
{:ok, db} =
  Xitdb.transact(db, fn root ->
    root
    |> Xitdb.insert_at(path(users[id].todos), 0, "ship docs")
    |> Xitdb.delete_at(path(users[id].todos), 3)
    |> Xitdb.fork(path(users[id]), path(backups[id]))
  end)
```
