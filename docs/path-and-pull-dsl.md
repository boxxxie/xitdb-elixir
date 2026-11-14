# Path Selector & Structural Pull DSL (`path/1`, `pull/2`, `pull_pattern/1`, `~x`)

While `Xitdb`'s [`Access` implementation](access-and-enumerable.md) (`db["users"]["alice"]["name"]`) is ideal for interactive exploration and passing lazy `%Xitdb.Cursor{}` handles around, it resolves one 9-byte `Slot` per path segment across the NIF boundary.

When you already know the target path—or when you want to project multiple attributes and bounded list slices in a single NIF call—`Xitdb.DSL.path/1`, `~x`, and `Xitdb.Pull` give you single-call execution with compile-time validation and safe variable interpolation.

---

## 1. Path Selector Macro (`path/1`) & Sigil (`~x`)

Import the DSL with `use Xitdb.DSL` (or call `Xitdb.path/1` after `require Xitdb`):

```elixir
use Xitdb.DSL

# 1. Static paths fold into a single binary literal at compile time:
path(users.alice.profile.city)
# => ".users.alice.profile.city"

# 2. Static ~x sigil validates the selector prefix at compile time:
~x|.users["user.101"].todos[2]|
# => ".users[\"user.101\"].todos[2]"

# 3. Dynamic bracket expressions safely interpolate and escape runtime variables:
user_id = "user.101"
todo_idx = 2

path(users[user_id].todos[todo_idx])
# => ".users.[\"user.101\"].todos[2]"
```

### Root Syntax Forms

Because Elixir's parser does not allow a bare unary leading dot (`.users`), `path/1` supports five equivalent root forms:

| Form | Example | Compiled Selector |
| :--- | :--- | :--- |
| Bare identifier | `path(users[id].role)` | `".users..."` |
| Explicit `root` / `_` | `path(root.users[id].role)` / `path(_.users[id].role)` | `".users..."` |
| Atom root | `path(:users[id].role)` | `".users..."` |
| Step-list syntax | `path([:users, id, :role])` | `".users..."` |
| Pinned selector prefix (`^`) | `path(^base_sel.profile.city)` | `base_sel <> ".profile.city"` |

### Automatic Special-Character Key Escaping

If a dynamic runtime key is empty or contains special selector characters (`.`, `[`, `]`, `#`, `$`, `%`, `^`, quotes, or whitespace), `path/1` automatically wraps the key in bracket-quoted `["..."]` notation so keys with dots or sigils never corrupt path parsing:

```elixir
email = "alice.liddell@acme.io"

path(accounts[email].balance)
# => ".accounts.[\"alice.liddell@acme.io\"].balance"

path(sorted("email->id")[email])
# => "$[\"email->id\"].[\"alice.liddell@acme.io\"]"
```

---

## 2. Typed Collection Modifiers

`xitdb` distinguishes collection types in selector strings using step sigils (`.` for `Hash_Map`, `#` for `Counted_Hash_Map`, `$` for `Sorted_Map`, `[i]` for `Array_List`, `[[i]]` for `Linked_Array_List`, `%` / `#%` / `^` for sets).

`path/1` lets you express these collection tags either as chained macro modifiers or as typed step tuples in a list:

| Collection Kind | Selector Sigil | Chained `path/1` Syntax | Step-List `path/1` Syntax | Compiled Output |
| :--- | :--- | :--- | :--- | :--- |
| `Hash_Map` | `.key` | `users[id]` or `users.alice` | `[:users, id]` | `".users.alice"` |
| `Counted_Hash_Map` | `#key` | `org.counted(:departments)[dept_id]`<br>or `org.departments[counted(dept_id)]` | `[:org, :departments, {:counted, dept_id}]` | `".org.departments#eng"` |
| `Sorted_Map` | `$key` | `eng.sorted(:directory)[emp_id]`<br>or `eng.directory[sorted(emp_id)]` | `[:eng, :directory, {:sorted, emp_id}]` | `".eng.directory$101"` |
| `Array_List` | `[idx]` | `items[0]` or `items.array(0)` | `[:items, 0]` or `[:items, {:array, 0}]` | `".items[0]"` |
| `Linked_Array_List` | `[[idx]]` | `todos[[2]]` or `todos.linked(2)` | `[:todos, [2]]` or `[:todos, {:linked, 2}]` | `".todos[[2]]"` |
| `Hash_Set` | `%member` | `flags.set_member("active")` | `[:flags, {:set_member, "active"}]` | `".flags%active"` |
| `Counted_Hash_Set` | `#%member` | `flags.counted_set_member("active")` | `[:flags, {:counted_set_member, "active"}]` | `".flags#%active"` |
| `Sorted_Set` | `^member` | `tags.sorted_set_member("elixir")` | `[:tags, {:sorted_set_member, "elixir"}]` | `".tags^elixir"` |
| Historical Moment | `@moment` | `at_moment(0, users[id].role)` | — | `"@0.users.alice.role"` |

---

## 3. Composing & Splicing Selectors (`^prefix`)

You can build reusable base selectors and splice them into deeper paths using the pin operator (`^`):

```elixir
use Xitdb.DSL

dept_path = path(org.counted(:departments)[dept_id])
# => ".org.departments#eng"

emp_todo_path = path(^dept_path.sorted(:directory)[emp_id].todos[[0]])
# => ".org.departments#eng.directory$101.todos[[0]]"
```

### Where `path/1` Selectors Can Be Used

Compiled selectors work across all `Xitdb` read, history, and mutation APIs:

```elixir
# 1. Single-call selection against the latest moment or a historical moment:
todo = Xitdb.select!(db, path(users[id].todos[[0]]))
v0_role = Xitdb.select!(db, path(at_moment(0, users[id].role)))

# 2. Inspecting the temporal lineage of a path across all commits:
{:ok, lineage} = Xitdb.history_of(db, path(users[id].role))

# 3. Staging list insertions, deletions, or subtree forks inside Xitdb.transact/2:
{:ok, db} =
  Xitdb.transact(db, fn root ->
    root
    |> Xitdb.insert_at(path(users[id].todos), 0, "ship docs")
    |> Xitdb.delete_at(path(users[id].todos), 3)
    |> Xitdb.fork(path(users[id]), path(backups[id]))
  end)
```

---

## 4. Structural Pull Patterns (`Xitdb.pull/2` & `pull_pattern/1`)

`Xitdb.pull/2` and `Xitdb.pull!/2` accept either a raw `xitdb` Pull string or a **structured Elixir keyword/list pattern** compiled by `Xitdb.Pull`:

```elixir
# Structured Pull pattern list (no string concatenation needed):
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
| `field: first..last` | `field[first..(last + 1)]` | Projects an inclusive Elixir range `first..last` (matching `Enum.slice/2`) of a list (`Array_List` or `Linked_Array_List`) |
| `field: {:slice, offset, limit}` | `field[offset..(offset + limit)]` | Projects `limit` items starting at `offset` (matches `Enum.slice(list, offset, limit)`) |
| `field: [:a, :b]` | `field{a, b}` | Recursively projects nested map attributes |
| `field: {0..4, [:a, :b]}` | `field[0..5]{a, b}` | Slices a list of maps by inclusive range and projects nested attributes on each element |
| `field: {{:slice, offset, limit}, [:a, :b]}` | `field[offset..(offset + limit)]{a, b}` | Slices `limit` maps starting at `offset` and projects nested attributes on each element |

### Practical Pull Recipes

#### Recipe 1: Wildcard `:*` + Bounded List Slice
When an entity has many scalar fields plus a large append-only list (such as `audit_log`), combine `:*` with a slice to project all attributes while bounding the list:

```elixir
Xitdb.pull!(user_cursor, [
  :*,
  audit_log: {:slice, 0, 5}
])
```

#### Recipe 2: Paginating a List of Nested Entities
When an organization or user record contains a list of nested maps (such as `team` members), slice the list and select only the needed nested fields in one NIF call:

```elixir
page_offset = 10
page_size = 5

Xitdb.pull!(account_cursor, [
  :email,
  team: {{:slice, page_offset, page_size}, [:username, profile: [:city, :tier]]}
])
```

#### Recipe 3: Zero-Overhead Compile-Time Patterns (`pull_pattern/1`)
If your Pull pattern is a static literal used in a hot loop, wrap it in `pull_pattern/1` so `Xitdb.Pull.compile!/1` runs once at compile time:

```elixir
use Xitdb.DSL

@user_card pull_pattern([:username, :age, todos: 0..2, profile: [:city]])
# Compiled at compile time to "{username, age, todos[0..3], profile{city}}"

Xitdb.pull!(user_cursor, @user_card)
```
