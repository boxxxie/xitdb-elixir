# Specification: Track 17 — Unified Formatter Exports (`.formatter.exs`), Package `usage-rules.md` & Hex Packaging Verification

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `formatter_exports_and_usage_rules_20261112`
> - **Prerequisites:** All Wave 1–4 tracks + [`ash_phase1_verification_suite_20261111`](../ash_phase1_verification_suite_20261111/index.md) + [`doc_fixes_and_operational_guides_20261112`](../doc_fixes_and_operational_guides_20261112/index.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Area:** `.formatter.exs`, `usage-rules.md`, `mix.exs`
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Wave 4 Unification Guardrail:** Export the **union** of `Xitdb.DSL` macros, `Xitdb.Ash.Resource` MDM options, and `Xitdb.Ash.DataLayer` options (`index`, `index_relationships?`, `counted_set_fields`, `reference`, `search_field`) while keeping test-only `scenario: 2` in local `locals_without_parens` only (excluded from `export:`); unify `usage-rules.md` across both `Xitdb.Ash.Resource` (MDM) and `Xitdb.Ash.DataLayer` (`Store`, `TestSandbox`, `Search`); and preserve Track 15's dependency versions and source-only Hex `files:` list in `mix.exs`.
> - **Done When:**
>   - `.formatter.exs` sets `locals_without_parens: exported_locals ++ [scenario: 2]` and `export: [locals_without_parens: exported_locals]` covering all `Xitdb.DSL`, `Xitdb.Ash.Resource`, and `Xitdb.Ash.DataLayer` options so consumer projects need only add `import_deps: [:xitdb]` and local `scenario "..." do` blocks format cleanly.
>   - `usage-rules.md` documents concise, unified LLM and developer guidelines covering lazy cursor semantics, `Xitdb.at/1` vs `Access.at/1`, hot-path DSL preferences, collection selection, Datalog `^` pinning, single-writer concurrency, canonical examples, and **both** `Xitdb.Ash.DataLayer` (`Store`, `TestSandbox`, `Search`, where `collection` + `nested_in` co-exist) and `Xitdb.Ash.Resource` (MDM sync projections, where `collection` vs `nested_in` are mutually exclusive) without any raw `$O(...)` LaTeX math blocks.
>   - `mix.exs` preserves Track 15's `deps/0` (`>= 3.37.2` / `>= 1.1.1`, `:telemetry`, `:ash_phoenix`, `:stream_data`) and `precommit` alias, bundles source-only files (including `CHANGELOG.md`, `usage-rules.md`, `.formatter.exs`, and native C/Odin sources—**never** `priv/`, so host-compiled `.so`/`.dylib` NIF binaries cannot leak into the Hex tarball) in `package()[:files]`, lists `usage-rules.md`, `CHANGELOG.md`, and `docs/*.md` in `docs()[:extras]`, and marks `:ash` and `:spark` as optional dependencies.
>   - `mix precommit` (`mix do format --check-formatted + compile --warnings-as-errors + test`) succeeds with zero errors and zero warnings.

---

## 1. Goal & Architectural Motivation

As `xitdb` matures toward downstream package distribution and adoption across external Elixir codebases, three developer experience and distribution guarantees must be locked in:

1. **Downstream Formatter Hygiene (`.formatter.exs`):**
   Applications consuming `xitdb` via Hex dependencies should not have their `tx`, `query`, `xitdb do ... end` MDM blocks, or `Xitdb.Ash.DataLayer` resource blocks wrapped in unwanted parentheses when running `mix format`. Exporting the full union of `locals_without_parens` lets consuming applications simply add `import_deps: [:xitdb]`, while keeping repository-internal ATDD macros (`scenario: 2`) scoped to local `locals_without_parens`.

2. **Unified Downstream LLM & Developer Guardrails (`usage-rules.md`):**
   A single authoritative operational guide at the package root instructs both human developers and LLM coding assistants on:
   - Lazy cursor mechanics (`%Xitdb.Cursor{}` vs. scalars) and `O(1)` inline code formatting (zero `$O(...)` LaTeX math).
   - Why `Xitdb.at/1` must be used instead of `Access.at/1`.
   - Preferring `Xitdb.DSL` (`path`, `pull`, `tx`) over multi-hop `Access` in hot paths.
   - Explicit collection wrappers (`counted_map`, `sorted_map`, `linked_list`, `counted_set`).
   - Pinning runtime variables with `^` in Datalog queries.
   - Lock-free reads vs. single-writer serialization (`Xitdb.Ash.Store` or owner `GenServer`).
   - Clear distinction between **`Xitdb.Ash.DataLayer`** (native `.xit` persistence with `Store`, `TestSandbox`, `Search`, `index`, `references`, and co-located `collection` + `nested_in :parent_col, foreign_key: ..., path: ...`) and **`Xitdb.Ash.Resource`** (hybrid MDM projection onto external data layers, where `collection` and `nested_in ParentMod, as: ...` are mutually exclusive and `VerifySyncProjection` audits `sync_update_action`).

3. **Hex Tarball Safety & ExDoc Extras Completeness (`mix.exs`):**
   Ensure `package()[:files]` includes `.formatter.exs`, `usage-rules.md`, `CHANGELOG.md`, `README.md`, `LICENSE`, `mix.exs`, `lib`, `docs`, and explicit `native/` C/Odin sources—explicitly excluding `priv` so local host-compiled `priv/xitdb_nif.so` / `.dylib` artifacts are never bundled into published Hex tarballs—while preserving Track 15's test dependencies and `precommit` alias.

---

## 2. Technical Invariants & Requirements

### 1. Formatter Configuration (`.formatter.exs`)
- Partition `dsl_locals_without_parens` and `spark_locals_without_parens` into `exported_locals`:
  - **DSL Transaction Blocks & Ops:** `tx: [2, 3]`, `tx!: [2, 3]`, `tx_for: [2, 3, 4]`, `tx_for!: [2, 3, 4]`, `put: [1, 2]`, `update: [2, 3]`, `rm: 1`, `append: 2`, `insert: [2, 3]`, `slice: [2, 3]`, `fork: 2`, `index_on: 3`, `init_col: 2`, `reset_col: 2`, `meta: 2`, `instant: 1`, `abort: 1`.
  - **DSL Datalog Blocks & Clauses:** `datalog: 1`, `query: [2, 3]`, `query!: [2, 3]`, `find: [1, 2, 3, 4]`, `from: 1`, `where: 1`.
  - **Spark DSL Options (Union of `Xitdb.Ash.Resource` & `Xitdb.Ash.DataLayer`):** `store: 1`, `collection: 1`, `nested_in: [1, 2]`, `index: [1, 2]`, `index_relationships?: 1`, `counted_set_fields: 1`, `search_field: [1, 2]`, `reference: [1, 2]`, `merge_redirect_collection: 1`, `locked_ids_set: 1`, `companion_resource: 1`, `editable_fields: 1`, `passthru_fields: 1`, `computed_xitdb_fields: 1`, `field_aliases: 1`, `indexes: 1`, `sync_update_action: 1`, `ignored_sync_attributes: 1`, `lock_action: 1`, `unlock_action: 1`, `lock_change: 1`.
- Set:
  - `inputs: ["{mix,.formatter}.exs", "{config,lib,test,benchmarks}/**/*.{ex,exs}"]`
  - `locals_without_parens: exported_locals ++ [scenario: 2]`
  - `export: [locals_without_parens: exported_locals]`

### 2. Package Usage Rules (`usage-rules.md`)
- Resides at workspace root (`usage-rules.md`) using inline code spans (`O(1)`, `O(log N)`) with zero `$...$` math blocks.
- Covers:
  1. Core mental models & lazy `%Xitdb.Cursor{}` navigation (`Xitdb.at/1` vs `Access.at/1`, root-anchored `Xitdb.select/2`, inclusive `Pull` ranges, `tx` auto-vivification, collection constructors, `^` Datalog pinning, single-writer serialization).
  2. Canonical `tx!`, `tx_for!`, and `query` examples.
  3. **`Xitdb.Ash.DataLayer` rules:** `use Xitdb.Ash.Store`, `Xitdb.Ash.TestSandbox.checkout/2`, `Xitdb.Ash.Search` (`ids/3`, `sort_by_rank/2`, `reindex_records/3`), zero SQL `fragment(...)` / zero `mix ash.codegen`, same-store `references` cascades vs. cross-store reads, atomic mutations/validations (`atomic/3`), `after_transaction` Oban enqueuing, and `nested_in :parent_collection, foreign_key: ..., path: ..., cardinality: ...` co-existing alongside `collection :child_collection` (for `meta.sequences` and `idx.<child_collection>._parent`).
  4. **`Xitdb.Ash.Resource` (Hybrid MDM Extension) rules:** `extensions: [Xitdb.Ash.Resource]` on external data layers (`AshPostgres`), where `collection :name` and `nested_in ParentMod, as: :slot, parent_key: :fk, key: :k` are mutually exclusive, `VerifySyncProjection` enforces `sync_update_action` field coverage, `lock_action` / `unlock_action` set `require_atomic? false` when `lock_change` uses `change/3`, and `Xitdb.Ash.Info.pull_pattern_for/1` + `tx_for!` drive projections and index maintenance.

### 3. Packaging & Hex Verification (`mix.exs`)
- Preserve Track 15's `deps/0` (`{:ash, "~> 3.37 and >= 3.37.2", optional: true}`, `{:spark, "~> 2.2", optional: true}`, `{:nimble_options, "~> 1.1 and >= 1.1.1"}`, `{:telemetry, "~> 1.3"}`, `{:ash_phoenix, "~> 2.1", only: :test}`, `{:stream_data, "~> 1.1", only: [:dev, :test]}`, `{:ex_doc, "~> 0.35", only: :dev, runtime: false}`).
- Preserve `cli/0` (`preferred_envs: [precommit: :test]`) and `aliases/0` (`precommit`).
- Ensure `package()[:files]` lists `~w(lib docs native/nif_entry.c native/xitdb_nif.odin native/xitdb-odin/xitdb .formatter.exs mix.exs README.md CHANGELOG.md usage-rules.md LICENSE)`—including `CHANGELOG.md` and excluding `priv` so host-compiled `.so`/`.dylib` binaries are never packaged.
- Ensure `docs()[:extras]` registers `README.md`, `usage-rules.md`, all 7 guides in `docs/*.md`, `CHANGELOG.md`, and `LICENSE`.

---

## 3. Formatting & Code Quality Invariants

- **Zero Format Violations:** `mix format --check-formatted` must pass across all files (including Track 15 `scenario` specs).
- **Zero Compiler Warnings:** `mix compile --warnings-as-errors` must pass cleanly.
- **Full Test Suite:** `mix precommit` must run with all property and ATDD tests passing.
