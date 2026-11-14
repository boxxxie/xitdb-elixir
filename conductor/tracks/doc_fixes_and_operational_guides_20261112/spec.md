# Specification: Track 16 — Documentation Alignment, Operational Guides & Unified `Xitdb.Ash` Reference Contracts

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `doc_fixes_and_operational_guides_20261112`
> - **Prerequisites:** Wave 1–4 tracks + [`ash_phase1_verification_suite_20261111`](../ash_phase1_verification_suite_20261111/index.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Area:** `docs/*.md` (`path-and-pull-dsl.md`, `time-travel-and-storage.md`, `transaction-dsl.md`, `ash-and-spark.md`, plus inline-code math cleanup across `access-and-enumerable.md`, `collections-and-indexing.md`, and `datalog-dsl.md`)
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Wave 4 Reconciliation Guardrail:** In `docs/ash-and-spark.md`, document first-class `use Xitdb.Ash.Store`, `Xitdb.Ash.DataLayer`, and `Xitdb.Ash.TestSandbox` alongside `Xitdb.Ash.Resource` (`lock_change` / MDM sync projection)—never teach users to hand-roll a duplicate `MyApp.MDM.Store` `GenServer`.
> - **Done When:**
>   - `docs/path-and-pull-dsl.md` reflects the accurate compiled selector `".email->id$[\"alice.liddell@acme.io\"]"` for `sorted/1` with dynamic keys, and clarifies that `Xitdb.select/2` expects a root snapshot cursor or `%Xitdb{}` handle.
>   - `docs/time-travel-and-storage.md` explicitly documents backend trade-offs (`:memory`, `:buffered_file`, `:file`) and hash algorithm selection (`:sha1` vs `:sha256`).
>   - `docs/transaction-dsl.md` documents `:index_rules` and formalizes the single-writer concurrency model for raw non-Ash read-modify-write transactions (`update` in `tx` and `transact/3` callbacks) while maintaining lock-free reads via `:persistent_term` (returning `%Xitdb{}` via `handle/0` and `%Xitdb.Cursor{}` via `db/0`).
>   - `docs/ash-and-spark.md` documents `use Xitdb.Ash.Store`, `Xitdb.Ash.DataLayer`, `Xitdb.Ash.TestSandbox`, and `MyApp.MDM.Changes.ModifyLockedFields` (explicitly noting that `lock_action` / `unlock_action` must set `require_atomic? false` because `ModifyLockedFields` reads `Ash.Changeset.get_data(changeset, :locked_fields)` inside `change/3`).
>   - All documentation files maintain clean markdown formatting, valid links, and inline code spans (no `$O(...)` LaTeX math mode).

---

## 1. Goal & Architectural Motivation

While the core codebase and tests for `xitdb` have matured, several key operational patterns and documentation examples require alignment to prevent developer misunderstandings and race conditions in consuming applications:

1. **Path DSL Output Discrepancy & Root Cursor Clarification:**
   In `docs/path-and-pull-dsl.md`, the documentation example for `path(sorted("email->id")[email])` displayed `"$[\"email->id\"].[\"alice.liddell@acme.io\"]"`. However, the path compiler actually emits `".email->id$[\"alice.liddell@acme.io\"]"` (a hash-map root step `.email->id` followed by a sorted-map key step `$[...]`). Furthermore, developers frequently attempt to pass child sub-cursors (`db["users"]`) to `Xitdb.select/2`, causing unexpected selector lookups because selectors are always root-anchored.

2. **Storage Engine Trade-offs:**
   `docs/time-travel-and-storage.md` listed `:buffered_file` in example snippets, but did not explain when to choose `:memory`, `:buffered_file`, or `:file`, nor how `:sha1` vs `:sha256` hashing algorithms impact node layout and compatibility across database lifecycles.

3. **Single-Writer Concurrency Architecture (Non-Ash Clients):**
   While Odin C-ABI `ErlNifRWLock` makes read operations completely lock-free across all BEAM processes, Elixir-level read-modify-write workflows (`update` in `tx` blocks and `Xitdb.transact/3` callbacks) read moment `N` before staging writes. Concurrent writers executing against the same `%Xitdb{}` handle could suffer Time-of-Check to Time-of-Use (TOCTOU) overwrite issues. Formalizing the single-writer `GenServer` pattern with `:persistent_term` (and pointing Ash users directly to `Xitdb.Ash.Store`) provides developers with a battle-tested concurrent architecture.

4. **Unified Ash Framework Reference Contracts (`Store`, `DataLayer`, `TestSandbox` & `lock_change`):**
   `docs/ash-and-spark.md` introduced the MDM `Organization` resource referencing `store MyApp.MDM.Store` and `lock_change MyApp.MDM.Changes.ModifyLockedFields` before `Xitdb.Ash.Store`, `Xitdb.Ash.DataLayer`, and `Xitdb.Ash.TestSandbox` shipped. Rather than asking adopters to hand-roll a bespoke `GenServer`, `docs/ash-and-spark.md` must document first-class `use Xitdb.Ash.Store` supervision (shared seamlessly by both pure `Xitdb.Ash.DataLayer` resources and hybrid `Xitdb.Ash.Resource` MDM `tx_for` workflows), `Xitdb.Ash.TestSandbox`, and `ModifyLockedFields` (including its `require_atomic? false` action requirement).

---

## 2. Technical Invariants & Requirements

### 1. `docs/path-and-pull-dsl.md`
- Replace `"$[\"email->id\"].[\"alice.liddell@acme.io\"]"` with `".email->id$[\"alice.liddell@acme.io\"]"`.
- Under section "Where `path/1` Selectors Can Be Used", add explicit clarification that `Xitdb.select/2` and `select!/2` operate strictly against `%Xitdb{}` handles or root snapshot cursors (`Xitdb.db/1`, `Xitdb.as_of/2`).
- Clarify that child sub-cursors (e.g. `db["users"]`) should use `Access` or `Xitdb.pull/2`.

### 2. `docs/time-travel-and-storage.md`
- Add section `### Choosing a Backend & Hash Algorithm` under Section 1 ("Storage Backends & File Formats").
- Contrast:
  - `:memory`: RAM-only buffer, 0 disk I/O, ideal for ExUnit tests and scratchpads.
  - `:buffered_file`: User-space node buffering before OS syscalls on commit or `sync/1`, optimal for production.
  - `:file`: Direct unbuffered OS file I/O, suited for CLI tools or memory-constrained environments with infrequent writes.
  - `:sha1` vs `:sha256`: Cryptographic digest selection for HAMT key hashing, highlighting the rule to reopen existing databases with matching hash settings.

### 3. `docs/transaction-dsl.md`
- Add `- :index_rules` (`[{:index_on, source_map, field, index_map}]`, default `[]`) to Section 4 ("Transaction Options").
- Add Section 5: `## 5. Concurrency Model: Lock-Free Reads & Single-Writer Serialization`.
- Detail the lock-free reader guarantees via `ErlNifRWLock` and immutable snapshots.
- Explain the TOCTOU risks of multiple BEAM processes running uncoordinated read-modify-write transactions against the same `%Xitdb{}` reference.
- Provide the copy-pasteable `MyApp.Store` `GenServer` module for standalone non-Ash apps (exposing `handle/0` returning `%Xitdb{}`, `db/0` returning `%Xitdb.Cursor{}`, `write/1`, and `terminate/2` cleanup), while cross-referencing `Xitdb.Ash.Store` for Ash applications.

### 4. `docs/ash-and-spark.md`
- Add Section 5: `## 5. Store Supervision (`Xitdb.Ash.Store`), `DataLayer`, `TestSandbox` & `lock_change` Contracts`.
- Document defining `MyApp.MDM.Store` with `use Xitdb.Ash.Store`, supervising `{MyApp.MDM.Store, path: ..., domains: [...]}`, reading lock-free snapshots (`MyApp.MDM.Store.current_db()`, `Xitdb.db(MyApp.MDM.Store.current_db())`), running `Xitdb.Ash.Store.mutate/3` / `transact/2` for MDM `tx_for` writes, using `data_layer: Xitdb.Ash.DataLayer` for pure-Xitdb resources, and isolating `async: true` ExUnit suites with `Xitdb.Ash.TestSandbox`.
- Provide `MyApp.MDM.Changes.ModifyLockedFields`: An `Ash.Resource.Change` module supporting `:lock` and `:unlock` actions, validating against `Xitdb.Ash.Info.editable_field_strings/1`, managing the `:locked_fields` attribute list, and explicitly noting that `lock_action` and `unlock_action` must declare `require_atomic? false` because `WireChanges` wires `ModifyLockedFields` without mutating action atomicity and `change/3` reads `Ash.Changeset.get_data(changeset, :locked_fields)` without an `atomic/3` callback.

---

## 3. Formatting & Code Quality Invariants

- **No LaTeX Math in Markdown:** Replace any `$O(...)` or math mode expressions in docs with inline code spans (e.g., `` `O(1)` ``).
- **GitHub Flavored Markdown:** Code blocks must be properly tagged with `elixir` syntax highlighting.
- **Link Integrity:** All internal doc links must resolve cleanly to existing files in `docs/` and `lib/`.
