# Reference: Track 17 — Unified Formatter Exports (`.formatter.exs`), Package `usage-rules.md` & Hex Packaging (`mix.exs`)

> [!IMPORTANT]
> **Track Reference Metadata:**
> - **Track ID:** `formatter_exports_and_usage_rules_20261112`
> - **Prerequisites:** All Wave 1–4 tracks + [`ash_phase1_verification_suite_20261111`](../ash_phase1_verification_suite_20261111/index.md) + [`doc_fixes_and_operational_guides_20261112`](../doc_fixes_and_operational_guides_20261112/index.md)
> - **Parent Track:** [`remaining_improvements_20261112`](../remaining_improvements_20261112/index.md) (Step 3)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Target Files:**
>   - [`.formatter.exs`](../../../.formatter.exs)
>   - [`usage-rules.md`](../../../usage-rules.md)
>   - [`mix.exs`](../../../mix.exs)

---

## 1. Overview & Architectural Motivation

Track 17 finalizes downstream formatter exports, unified LLM/developer usage guidelines, and source-only Hex packaging:

* **Unified exported formatter rules (`.formatter.exs`):** Exports the complete union of `Xitdb.DSL` macros, `Xitdb.Ash.Resource` MDM options, and `Xitdb.Ash.DataLayer` options (`index`, `index_relationships?`, `counted_set_fields`, `reference`, `search_field`) so consumer projects only need `import_deps: [:xitdb]`, while keeping ATDD test-only `scenario: 2` in local `locals_without_parens` (`exported_locals ++ [scenario: 2]`).

* **Unified downstream LLM & developer rules (`usage-rules.md`):** Preserves both core client rules and full `Xitdb.Ash.DataLayer` (`Store`, `TestSandbox`, `Search`) + `Xitdb.Ash.Resource` (hybrid MDM sync projection) rules—explicitly distinguishing `DataLayer`'s co-located `collection` + `nested_in :parent_col, foreign_key: ..., path: ...` from `Xitdb.Ash.Resource`'s mutually exclusive `collection` vs `nested_in ParentMod, as: ...`, and replacing any `$O(...)` LaTeX math with inline code spans.

* **Hex tarball safety & Track 15 dependency alignment (`mix.exs`):** Preserves Track 15's `deps/0` (`>= 3.37.2` / `>= 1.1.1`, `:telemetry`, `:ash_phoenix`, `:simple_sat`, `:stream_data`) and `precommit` alias, includes `CHANGELOG.md`, `usage-rules.md`, and `.formatter.exs` in `package()[:files]`, and explicitly lists `native/` source files rather than `priv` so local host-compiled `.so`/`.dylib` NIF binaries never enter the published Hex tarball.

---

## 2. Complete Code & Configuration Changes

### 2.1 `.formatter.exs`

```elixir
dsl_locals_without_parens = [
  # Transaction blocks
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
  # Transaction operations
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
  # Datalog blocks & clauses
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
  # Xitdb.Ash.Resource (hybrid MDM projection) options
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

### 2.2 `usage-rules.md` Diff (Unifying `DataLayer` + `Resource` & Stripping LaTeX Math)

````diff
diff --git a/usage-rules.md b/usage-rules.md
--- a/usage-rules.md
+++ b/usage-rules.md
@@ -9,7 +9,7 @@
 1. **Default to Lazy `Access` Navigation (`db["users"]["alice"]["name"]`)**:
    - Reading from `Xitdb` (`Xitdb.db(db)`, `Xitdb.as_of(db, moment)`, or `db["users"]`) returns a lazy `%Xitdb.Cursor{}` holding only the NIF database reference and 9-byte `Slot` coordinates (`tag`, `tag_id`, `value`).
    - Cursors are **pure, immutable Elixir values**. Pass them freely across BEAM processes (`Task.async_stream/3`, GenServers, ETS, Phoenix LiveView assigns) without locks or copying underlying subtrees.
-   - Navigating to a scalar (`string`, `integer`, `float`, `boolean`, or `{:tagged, tag, bytes}`) unwraps and returns the native Elixir value directly; navigating to a nested container returns another `%Xitdb.Cursor{}` in $O(1)$ heap space.
+   - Navigating to a scalar (`string`, `integer`, `float`, `boolean`, or `{:tagged, tag, bytes}`) unwraps and returns the native Elixir value directly; navigating to a nested container returns another `%Xitdb.Cursor{}` in `O(1)` heap space.
 2. **Use `Xitdb.at/1` Instead of `Access.at/1` on Lazy List Cursors**:
    - Elixir's built-in `Access.at/1` guards `is_list(data)` and raises on structs. When navigating `Array_List` or `Linked_Array_List` cursors with `get_in/2` or `put_in/3`, either pass integer keys directly in the path list (`get_in(root, ["users", "alice", "roles", 1])`) or use `Xitdb.at(1)`.
 3. **Never Eagerly Materialize Large Subtrees Unless Needed**:
@@ -38,17 +38,17 @@
 
 ## 3. Choosing Collection Types (`Xitdb.Collection`)
 
-By default, plain Elixir maps (`%{}`) are stored as `:hash_map` (`Tag.Hash_Map`), plain lists (`[]`) as `:array_list` (`Tag.Array_List`), and `%MapSet{}` as `:counted_hash_set`. Use wrapper constructors on `Xitdb` when you need $O(1)$ counts, lexicographical B+Tree ordering, or $O(\log N)$ list insertions/removals:
+By default, plain Elixir maps (`%{}`) are stored as `:hash_map` (`Tag.Hash_Map`), plain lists (`[]`) as `:array_list` (`Tag.Array_List`), and `%MapSet{}` as `:counted_hash_set`. Use wrapper constructors on `Xitdb` when you need `O(1)` counts, lexicographical B+Tree ordering, or `O(log N)` list insertions/removals:
 
 | Constructor | Selector Sigil | Backing Structure | Best For |
 | :--- | :--- | :--- | :--- |
 | `Xitdb.hash_map(map)` | `.key` | 16-way HAMT | General key-value maps |
-| `Xitdb.counted_map(map)` | `#key` | 16-way HAMT + count header | Maps needing $O(1)$ `Enum.count/1` |
+| `Xitdb.counted_map(map)` | `#key` | 16-way HAMT + count header | Maps needing `O(1)` `Enum.count/1` |
 | `Xitdb.sorted_map(map)` | `$key` | Lexicographical B+Tree | Ordered iteration, range slices, secondary indexes |
 | `Xitdb.array_list(list)` | `[i]` | 16-way Radix Trie | Append-heavy lists and random index reads |
-| `Xitdb.linked_list(list)` | `[[i]]` | Count-augmented B-Tree | Queues/lists needing $O(\log N)$ `insert`, `rm`, and `slice` |
+| `Xitdb.linked_list(list)` | `[[i]]` | Count-augmented B-Tree | Queues/lists needing `O(log N)` `insert`, `rm`, and `slice` |
 | `Xitdb.hash_set(enum)` | `%member` | 16-way HAMT set | Uncounted string membership sets |
-| `Xitdb.counted_set(enum)` | `#%member` | 16-way HAMT set + count | Sets needing $O(1)$ `Enum.count/1` and `Enum.member?/2` |
+| `Xitdb.counted_set(enum)` | `#%member` | 16-way HAMT set + count | Sets needing `O(1)` `Enum.count/1` and `Enum.member?/2` |
 | `Xitdb.sorted_set(enum)` | `^member` | Lexicographical B+Tree set | Ordered unique tags/badges |
 
 ---
@@ -82,6 +82,8 @@
 - For set member additions inside `tx`, use 1-arity `put path.set_member(val)` (or `counted_set_member`/`sorted_set_member`).
 - For read-modify-write updates with a fallback when the path does not yet exist, use 3-arity `update path, default, fun`.
 - To roll back from inside a `tx` block, call `abort :reason`.
+- **Never mutate `%Xitdb{}` directly** outside `Xitdb.transact/3` or `tx` (`put_in(db["a"], 1)` raises `ArgumentError`).
+- **Single-writer concurrency**: Concurrent readers are lock-free, while read-modify-write transactions (`update` in `tx` and `Xitdb.transact/3` callbacks) must serialize through `Xitdb.Ash.Store` or a single owner `GenServer`.
 
 ### 2. Top-Level Map Transactions (`Xitdb.transact/3`)
 
@@ -122,7 +124,7 @@
 
 ### Lazy `Access` & `Enumerable` Fast Paths
 
-`%Xitdb.Cursor{}` implements `Enumerable` with native data-structure fast paths (`Enum.count/1` in $O(1)$, `Enum.member?/2` in $O(1)$ / $O(\log_{16} N)$, `Enum.slice/2` in $O(\log N + K)$):
+`%Xitdb.Cursor{}` implements `Enumerable` with native data-structure fast paths (`Enum.count/1` in `O(1)`, `Enum.member?/2` in `O(1)` / `O(log_16 N)`, `Enum.slice/2` in `O(log N + K)`):
 
 ```elixir
 root = Xitdb.db(db)
@@ -150,6 +152,8 @@
 # Static compile-time validated sigil
 todo = Xitdb.select!(db, ~x|.users["101"].todos[1]|)
 ```
+
+- `Xitdb.select/2` only accepts `%Xitdb{}` or a root snapshot cursor (`Xitdb.db/1`, `Xitdb.as_of/2`), never a nested child cursor (`db["users"]`).
 
 ### Datomic-Style Pull Projections (`Xitdb.pull/2`)
 
@@ -256,7 +260,7 @@
 end
 ```
 
-For child entities co-located inside a parent entity's subtree for 9-byte `fork` snapshots, declare `nested_in`:
+For `Xitdb.Ash.DataLayer` child entities co-located inside a parent entity's subtree for 9-byte `fork` snapshots, declare **both** `collection` (for `meta.sequences` and `idx.<collection>._parent` locators) and `nested_in`:
 
 ```elixir
 xitdb do
@@ -266,6 +270,13 @@
 end
 ```
 
+### Hybrid MDM Extension Rules (`extensions: [Xitdb.Ash.Resource]`)
+
+When attaching `Xitdb.Ash.Resource` as a secondary MDM sync extension onto an external data layer (such as `Ash.DataLayer.Postgres`):
+- Declare **either** top-level `collection :name` **or** `nested_in ParentResource, as: :slot, parent_key: :fk, key: :entry_key`—never both on an MDM-only `Xitdb.Ash.Resource`, and never declare `indexes` on MDM `nested_in` resources.
+- Every attribute accepted by `sync_update_action` (unless listed in `ignored_sync_attributes`) **must** appear in `editable_fields` or `passthru_fields`, or `VerifySyncProjection` raises a compile-time `Spark.Error.DslError`.
+- Set `require_atomic? false` on `lock_action` and `unlock_action` when your `lock_change` module implements `change/3` via `Ash.Changeset.get_data/2` without an `atomic/3` callback.
+
 ### Strict DO / DON'T Rules
 
 #### 1. Zero SQL Fragments or Codegen Migrations
````

---

## 3. Packaging & Hex Verification (`mix.exs`)

Verify `mix.exs` preserves Track 15's dependency constraints and `precommit` alias, marks `:ash` and `:spark` as `optional: true`, includes `CHANGELOG.md`, `usage-rules.md`, and `.formatter.exs` in `package()[:files]`, and lists explicit `native/` sources rather than `priv`:

```elixir
def cli do
  [
    preferred_envs: [precommit: :test]
  ]
end

defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_), do: ["lib"]

defp deps do
  [
    {:ash, "~> 3.37 and >= 3.37.2", optional: true},
    {:spark, "~> 2.2", optional: true},
    {:nimble_options, "~> 1.1 and >= 1.1.1"},
    {:telemetry, "~> 1.3"},
    {:ash_phoenix, "~> 2.1", only: :test},
    {:simple_sat, "~> 0.1", only: :test},
    {:stream_data, "~> 1.1", only: [:dev, :test]},
    {:ex_doc, "~> 0.35", only: :dev, runtime: false}
  ]
end

defp package do
  [
    # Explicitly list C/Odin sources under `native/` and omit `priv` so host-compiled
    # `priv/xitdb_nif.so` / `.dylib` binaries are never bundled into the Hex tarball.
    files:
      ~w(lib docs native/nif_entry.c native/xitdb_nif.odin native/xitdb-odin/xitdb .formatter.exs mix.exs README.md CHANGELOG.md usage-rules.md LICENSE),
    licenses: ["MIT"],
    links: %{
      "GitHub" => @source_url,
      "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
    }
  ]
end

defp docs do
  [
    main: "readme",
    extras: [
      "README.md",
      "usage-rules.md",
      "docs/access-and-enumerable.md",
      "docs/collections-and-indexing.md",
      "docs/time-travel-and-storage.md",
      "docs/path-and-pull-dsl.md",
      "docs/transaction-dsl.md",
      "docs/datalog-dsl.md",
      "docs/ash-and-spark.md",
      "CHANGELOG.md",
      "LICENSE"
    ],
    groups_for_extras: [
      "Core Concepts & Protocols": [
        "docs/access-and-enumerable.md",
        "docs/collections-and-indexing.md",
        "docs/time-travel-and-storage.md"
      ],
      "Macro DSLs & Query Languages": [
        "docs/path-and-pull-dsl.md",
        "docs/transaction-dsl.md",
        "docs/datalog-dsl.md",
        "docs/ash-and-spark.md"
      ]
    ],
    source_ref: "v#{@version}",
    source_url: @source_url
  ]
end

defp aliases do
  [
    precommit: [
      "format --check-formatted",
      "compile --warnings-as-errors",
      "test"
    ]
  ]
end
```

### Verification Commands

```bash
mix precommit
# For publishing verification (confirm zero compiled .so/.dylib files in tarball):
mix hex.build --unpack
```
