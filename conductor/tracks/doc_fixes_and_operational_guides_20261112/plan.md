# Implementation Plan: Track 16 — Documentation Alignment, Operational Guides & Unified `Xitdb.Ash` Reference Contracts

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `doc_fixes_and_operational_guides_20261112`
> - **Prerequisites:** Wave 1–4 tracks + [`ash_phase1_verification_suite_20261111`](../ash_phase1_verification_suite_20261111/index.md)
> - **Specification:** [`./spec.md`](./spec.md)
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Wave 4 Reconciliation Note:** In Phase 4 (`docs/ash-and-spark.md`), document first-class `use Xitdb.Ash.Store`, `Xitdb.Ash.DataLayer`, and `Xitdb.Ash.TestSandbox` alongside `Xitdb.Ash.Resource` (`lock_change` / MDM sync projection) rather than teaching a hand-rolled `MyApp.MDM.Store` `GenServer`.
> - **Done When:** All 4 documentation guides are updated according to the specification, code examples are tested and verified, markdown conforms to GitHub-flavored styling without LaTeX math mode, and `mix format --check-formatted` passes.

---

## Phase 1: Path & Selector Documentation Updates (`docs/path-and-pull-dsl.md`)

- [ ] Task: Correct `path(sorted("email->id")[email])` Example
    - [ ] Update output from `"$[\"email->id\"].[\"alice.liddell@acme.io\"]"` to `".email->id$[\"alice.liddell@acme.io\"]"`
    - [ ] Verify alignment with `Xitdb.DSL.PathCompiler` step formatting rules

- [ ] Task: Add Root Snapshot Cursor Clarification for `Xitdb.select/2`
    - [ ] Add explicit note explaining that `Xitdb.select/2` and `select!/2` require `%Xitdb{}` or a root cursor (`Xitdb.db/1`, `Xitdb.as_of/2`)
    - [ ] Clarify that child sub-cursors (`db["users"]`) should use `Access` syntax or `Xitdb.pull/2`

---

## Phase 2: Storage Engine & Hash Algorithm Selection (`docs/time-travel-and-storage.md`)

- [ ] Task: Document Backend Trade-offs
    - [ ] Add `### Choosing a Backend & Hash Algorithm` section under Section 1
    - [ ] Detail use cases for `:memory` (ephemeral/tests), `:buffered_file` (production batching), and `:file` (unbuffered POSIX I/O)

- [ ] Task: Document Hash Algorithm Choices
    - [ ] Contrast `:sha1` (default, fast, compact digests) vs `:sha256` (SHA-2 policy compliance)
    - [ ] Emphasize persistence invariant: reopening files requires matching `:hash` configuration
    - [ ] Replace any remaining `$O(...)` LaTeX math blocks in `docs/time-travel-and-storage.md` with inline code spans

---

## Phase 3: Concurrency Architecture & Options (`docs/transaction-dsl.md`)

- [ ] Task: Document `:index_rules` in Transaction Options
    - [ ] Add `:index_rules` specification to Section 4 option definitions

- [ ] Task: Document Concurrency Model (Lock-Free Reads & Single-Writer Serialization)
    - [ ] Add Section 5 explaining Odin `ErlNifRWLock` read scalability across processes
    - [ ] Explain why read-modify-write transactions must be serialized to avoid TOCTOU races
    - [ ] Provide copy-pasteable `MyApp.Store` `GenServer` pattern for non-Ash apps (`handle/0` returning `%Xitdb{}`, `db/0` returning `%Xitdb.Cursor{}`, `write/1`, and `terminate/2`), and point Ash apps to `Xitdb.Ash.Store`

---

## Phase 4: Unified `Xitdb.Ash` Reference Contracts (`docs/ash-and-spark.md`)

- [ ] Task: Document First-Class `Xitdb.Ash.Store`, `Xitdb.Ash.DataLayer` & `Xitdb.Ash.TestSandbox`
    - [ ] Add Section 5 (`## 5. Store Supervision (`Xitdb.Ash.Store`), `DataLayer`, `TestSandbox` & `lock_change` Contracts`)
    - [ ] Show `defmodule MyApp.MDM.Store, do: use Xitdb.Ash.Store`, supervision tree setup, lock-free reads (`MyApp.MDM.Store.current_db()`), serialized MDM `tx_for!` mutations via `Xitdb.Ash.Store.mutate/3`, pure `data_layer: Xitdb.Ash.DataLayer` usage, and `Xitdb.Ash.TestSandbox.checkout/2`

- [ ] Task: Provide Reference `MyApp.MDM.Changes.ModifyLockedFields` & Atomicity Guidance
    - [ ] Provide `Ash.Resource.Change` implementation supporting `:lock` and `:unlock` and validating against `Xitdb.Ash.Info.editable_field_strings/1`
    - [ ] Explicitly note that `lock_action` and `unlock_action` must set `require_atomic? false` because `ModifyLockedFields` reads `Ash.Changeset.get_data(changeset, :locked_fields)` inside `change/3` without an `atomic/3` callback (and `WireChanges` does not toggle `require_atomic?` automatically)
    - [ ] Replace any remaining `$O(...)` LaTeX math blocks in `docs/ash-and-spark.md` with inline code spans

---

## Phase 5: Verification & Format Validation

- [ ] Task: Verify Markdown, Inline-Code Math & Link Integrity Across All 7 `docs/*.md` Guides
    - [ ] Replace remaining `$O(...)` / `$\le 8$` LaTeX math blocks in `docs/access-and-enumerable.md`, `docs/collections-and-indexing.md`, and `docs/datalog-dsl.md` with inline code spans (`` `O(1)` ``, `` `O(log N)` ``, `` `O(log_16 N)` ``, `` `<= 8` ``)
    - [ ] Verify that all internal markdown links resolve correctly
    - [ ] Ensure zero raw LaTeX math blocks (`$...$`) remain in any `docs/*.md` guide
    - [ ] Run `mix format --check-formatted`
