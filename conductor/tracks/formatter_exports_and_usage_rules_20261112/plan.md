# Implementation Plan: Track 17 — Unified Formatter Exports (`.formatter.exs`), Package `usage-rules.md` & Hex Packaging Verification

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `formatter_exports_and_usage_rules_20261112`
> - **Prerequisites:** All Wave 1–4 tracks + [`ash_phase1_verification_suite_20261111`](../ash_phase1_verification_suite_20261111/index.md) + [`doc_fixes_and_operational_guides_20261112`](../doc_fixes_and_operational_guides_20261112/index.md)
> - **Specification:** [`./spec.md`](./spec.md)
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Wave 4 Unification Note:**
>   1. Export the **union** of `Xitdb.DSL` macros, `Xitdb.Ash.Resource` MDM options, and `Xitdb.Ash.DataLayer` options (`index`, `index_relationships?`, `counted_set_fields`, `reference`, `search_field`) via `exported_locals`, while keeping test-only `scenario: 2` **internal** (`locals_without_parens: exported_locals ++ [scenario: 2]`, `export: [locals_without_parens: exported_locals]`).
>   2. Unify `usage-rules.md` across core client, `Xitdb.Ash.DataLayer` (`Store`, `TestSandbox`, `Search`, where `collection` + `nested_in` co-exist), and `Xitdb.Ash.Resource` (hybrid MDM sync projection, where `collection` vs `nested_in` are exclusive), replacing any `$O(...)` LaTeX math with inline code spans.
>   3. Keep `mix.exs` `deps/0` aligned with Track 15 and exclude `priv` from `package()[:files]` so compiled `.so`/`.dylib` NIF binaries never enter the Hex tarball.
> - **Done When:** `.formatter.exs` exports `exported_locals` while keeping `scenario: 2` local-only, `usage-rules.md` covers core client + `DataLayer` + `Resource` without LaTeX math blocks, `mix.exs` passes Hex file/dependency checks, and `mix precommit` succeeds.

---

## Phase 1: Formatter Exports Configuration (`.formatter.exs`)

- [ ] Task: Group and Export Unified DSL & Spark `locals_without_parens` in `.formatter.exs`
    - [ ] Define `dsl_locals_without_parens` covering `tx`, `tx!`, `tx_for` (`2, 3, 4`), `tx_for!` (`2, 3, 4`), all mutation ops (`put`, `update`, `rm`, `append`, `insert`, `slice`, `fork`, `index_on`, `init_col`, `reset_col`, `meta`, `instant`, `abort`), and Datalog clauses (`datalog`, `query`, `query!`, `find` (`1..4`), `from`, `where`)
    - [ ] Define `spark_locals_without_parens` covering the union of `Xitdb.Ash.DataLayer` and `Xitdb.Ash.Resource` options (`store`, `collection`, `nested_in`, `index`, `index_relationships?`, `counted_set_fields`, `search_field`, `reference`, `merge_redirect_collection`, `locked_ids_set`, `companion_resource`, `editable_fields`, `passthru_fields`, `computed_xitdb_fields`, `field_aliases`, `indexes`, `sync_update_action`, `ignored_sync_attributes`, `lock_action`, `unlock_action`, `lock_change`)
    - [ ] Bind `exported_locals = dsl_locals_without_parens ++ spark_locals_without_parens`
    - [ ] Set `locals_without_parens: exported_locals ++ [scenario: 2]` and `export: [locals_without_parens: exported_locals]` with `inputs: ["{mix,.formatter}.exs", "{config,lib,test,benchmarks}/**/*.{ex,exs}"]`
    - [ ] Run `mix format --check-formatted` to verify all codebase, benchmark, and Track 15 ATDD `scenario` files remain cleanly formatted

---

## Phase 2: Unified Package Usage Rules Guide (`usage-rules.md`)

- [ ] Task: Align Core Client Mental Models & Strip LaTeX Math Blocks
    - [ ] Replace all `$O(1)$` / `$O(\log N)$` LaTeX math blocks in `usage-rules.md` with inline code spans (`` `O(1)` ``, `` `O(log N)` ``)
    - [ ] Ensure lazy cursor vs scalar leaf mechanics, `Xitdb.at/1` vs `Access.at/1`, root-anchored `Xitdb.select/2`, inclusive `Pull` ranges, `tx`/`tx!` auto-vivification, collection constructors, `^` Datalog pinning, and single-writer concurrency are clearly documented

- [ ] Task: Unify `Xitdb.Ash.DataLayer` & `Xitdb.Ash.Resource` Rules
    - [ ] Document `Xitdb.Ash.DataLayer` rules (`use Xitdb.Ash.Store`, `Xitdb.Ash.TestSandbox.checkout/2`, `Xitdb.Ash.Search`, zero SQL `fragment(...)` / zero `mix ash.codegen`, same-store `references` cascades vs cross-store reads, atomic `atomic/3` validations, `after_transaction` Oban jobs, and `collection` + `nested_in :events, foreign_key: ..., path: ...` co-location)
    - [ ] Document `Xitdb.Ash.Resource` (hybrid MDM extension) rules (`collection` vs `nested_in ParentMod, as: ...` mutual exclusivity on MDM-only resources, `VerifySyncProjection` `sync_update_action` coverage, `require_atomic? false` on `lock_action`/`unlock_action`, `Xitdb.Ash.Info.pull_pattern_for/1`, and `tx_for!`)

---

## Phase 3: Packaging & Hex Tarball Audit (`mix.exs`)

- [ ] Task: Verify `deps/0`, `cli/0` & `aliases/0` Preserve Track 15 Configuration
    - [ ] Keep `:ash` (`~> 3.37 and >= 3.37.2`, `optional: true`), `:spark` (`~> 2.2`, `optional: true`), `:nimble_options` (`~> 1.1 and >= 1.1.1`), `:telemetry` (`~> 1.3`), `:ash_phoenix` (`~> 2.1`, `only: :test`), `:simple_sat` (`~> 0.1`, `only: :test`), `:stream_data` (`~> 1.1`, `only: [:dev, :test]`), and `:ex_doc` (`~> 0.35`, `only: :dev, runtime: false`)
    - [ ] Keep `cli/0` (`preferred_envs: [precommit: :test]`) and `aliases/0` (`precommit`)

- [ ] Task: Audit Source-Only `package()[:files]` & `docs()[:extras]`
    - [ ] Verify `package()[:files]` includes `lib`, `docs`, `native/nif_entry.c`, `native/xitdb_nif.odin`, `native/xitdb-odin/xitdb`, `.formatter.exs`, `mix.exs`, `README.md`, `CHANGELOG.md`, `usage-rules.md`, and `LICENSE`—and **excludes `priv`** so compiled `.so`/`.dylib` NIF binaries are never bundled
    - [ ] Verify `docs()[:extras]` registers `README.md`, `usage-rules.md`, all `docs/*.md` guides, `CHANGELOG.md`, and `LICENSE`

---

## Phase 4: Verification & Precommit Suite

- [ ] Task: Run Full Verification Gate
    - [ ] Execute `mix precommit` (`mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`)
    - [ ] Optionally run `mix hex.build --unpack` dry run to confirm zero `.so`/`.dylib` artifacts in tarball
