# Track Specification: `odin-xitdb` History/Selector Parity, Release Pipeline & `elixir/xitdb` Sync

> [!IMPORTANT]
> **Track Metadata**
> - **Track ID:** `odin_xitdb_history_and_release_sync_20261115`
> - **Type:** Feature + Release Engineering + Submodule Sync
> - **Target Repositories:** `/home/pauli/projects/odin/xitdb` (`odin-xitdb`) and `/home/pauli/projects/elixir/xitdb` (`elixir/xitdb`)
> - **Submodule Boundary:** Do **not** modify `native/xitdb-odin/` directly inside `elixir/xitdb`. All upstream Odin engine changes must land cleanly on `odin-xitdb` `master` (released and tagged/pushed if requested) before bumping the `native/xitdb-odin` submodule pointer in `elixir/xitdb`.
> - **Primary Files (`odin-xitdb`):** `xitdb/xitdb.odin`, `xitdb/cursor.odin`, `xitdb/dsl.odin`, `tests/`, `benchmarks/{bench_xitdb.odin,bench_xitdb.zig,compare_1v1.py,README.md}`, `README.md`, `AGENTS.md`, `usage-rules.md`, `docs/*.md`
> - **Primary Files (`elixir/xitdb`):** `native/xitdb-odin`, `native/xitdb_nif.odin`, `benchmarks/{bench_elixir.exs,bench_client.odin,README.md}`
> - **Done When:** `odin-xitdb` has merged upstream parity + `history_of` / stack-buffered selector optimizations, passes 3-layer ATDD specs and zero-leak `odin test tests`, passes Odin-vs-Zig 1v1 benchmarks and docs updates on `master`, and `elixir/xitdb` bumps `native/xitdb-odin`, deduplicates overlapping NIF helpers, verifies v1/v2 header compatibility, and passes `odin check`, `mix precommit`, and the Elixir-vs-Odin 1v1 benchmark suite.

---

## 1. Context & Problem Statement

During the `elixir/xitdb` benchmark optimization pass on `b9e57a998e69`, the Elixir client achieved `46.2 µs` (`0.68x NIF`) on `#18 Time-Travel: history_of(db, selector) (100 moments)` — outperforming Raw Odin (`67.7 µs`) because the Elixir NIF implemented specialized optimizations that have not yet landed in `odin-xitdb` itself:

1. **Sequential iterator + pre-hashed `history_of` traversal:** `xitdb/dsl.odin` still scans moments via per-moment `array_list_get_cursor` and unhashed `read_steps_cursor` + `hash_map_get_cursor` calls (300–600 SHA-1 digests across 100 moments).
2. **Stack-buffered selector parsing:** `parse_steps` and `parse_selector` in `xitdb/dsl.odin` always allocate dynamically rather than using a `[16]Path_Step` stack fast path for typical selector depths.
3. **Slot-only KV iteration:** Several internal iteration sites call `cursor_read_kv_pair` (which allocates 20-byte SHA-1 hashes on `context.temp_allocator`) even when only key/value slots are needed and `cursor_read_kv_pair_slots` already exists.
4. **Pending upstream parity release in `odin-xitdb`:** `/home/pauli/projects/odin/xitdb` currently has branch `feat/upstream-parity-89da8e7` (`80ea2f0` ahead of `master` `be1b53c`) with Zig upstream `89da8e7` parity commits (including v2 root header `FILE_SIZE_START` aligned `file_size`, interrupted-commit & replication recovery, short-key `Sorted_Set` reader fix, and unwritten `Array_List` element counting), alongside worktrees/branches (`feat-lock-free-cursors`, `feat-reverse-iterator`) that have not yet been integrated and released to `master`.

Just implementing the Odin optimization in `xitdb/dsl.odin` is insufficient for an `odin-xitdb` release: `odin-xitdb` requires full parity verification against Zig `xitdb`, 3-layer ATDD coverage, leak-checked `odin test tests`, Odin-vs-Zig 1v1 benchmark regeneration, documentation updates, and a downstream synchronization pass in `elixir/xitdb` (updating `native/xitdb-odin`, deduplicating NIF code against upstream `xitdb`, verifying v1/v2 database header handling in `native/xitdb_nif.odin`, and re-running Elixir-vs-Odin 1v1 benchmarks).

---

## 2. Scope & Phases

### Phase 1: Finalize Upstream Zig `89da8e7` Parity in `odin-xitdb`
- Audit `feat/upstream-parity-89da8e7` (`80ea2f0` vs. `master` `be1b53c`) in `/home/pauli/projects/odin/xitdb` across wire-format changes (v2 root header `FILE_SIZE_START`, recovery semantics, `Sorted_Set` short-key reading, unwritten `Array_List` element counts).
- Verify all upstream parity tests pass with zero allocator leaks (`Tracking_Allocator` in `odin test tests`).
- Check whether any companion pending tracks (`lock_free_cursors_vmem_20261106`, `reverse_iterators_20261106`) conflict or should remain cleanly separated before merging `feat/upstream-parity-89da8e7`.

### Phase 2: Implement `history_of` Pre-Hashed Traversal, Stack-Buffered Selectors & Slot-Only KV Reads in `odin-xitdb`
- Pre-compute step SHA-1 digests and `"__tx"` / `"doc"` / `"tx_instant"` field hashes once in `xitdb/dsl.odin` `history_of` (and add a reusable pre-hashed step traversal helper such as `read_prehashed_steps_slot` / `Prehashed_Step`) so sequential moment scans via `cursor_iterator` / `cursor_iterator_next` avoid redundant `hash_key` recomputations and `array_list_get_cursor` tree re-descents.
- Add stack-buffered `[16]Path_Step` fast paths (`parse_steps_buf`, `parse_selector_buf`) to avoid heap/temp allocations on typical selectors while seamlessly spilling to dynamic arrays when `len > 16`.
- Audit `xitdb/dsl.odin` and `xitdb/*.odin` call sites using `cursor_read_kv_pair` where only `key_cur` / `val_cur` slots are inspected, migrating them to `cursor_read_kv_pair_slots`.

### Phase 3: `odin-xitdb` Release Pipeline (3-Layer ATDD, Zero-Leak Tests, Zig-vs-Odin Benchmarks & Docs)
- Add 3-layer ATDD behavioral specs in `tests/` (`tests/features/`, `tests/dsl/`, `tests/drivers/`) covering `history_of` parity, `> 16`-step selector overflow, v2 root header backward compatibility (reading v1 databases and writing/recovering v2 databases), and allocator hygiene.
- Verify `odin check xitdb`, `odin check cmd/xit`, `odin check tests`, and `odin test tests` report 0 failures and 0 memory leaks.
- Run `odin-xitdb`'s Odin-vs-Zig 1v1 benchmark suite (`benchmarks/compare_1v1.py`, `benchmarks/update_readme.sh`), verify CLI parity (`cmd/xit`), update `README.md` / `docs/*.md` / `usage-rules.md` / `AGENTS.md`, and merge/land the release on `odin-xitdb` `master` (respecting repository push/tag rules).

### Phase 4: Synchronize `elixir/xitdb` Submodule, Deduplicate NIF Helpers & Refresh 1v1 Benchmarks
- Bump `native/xitdb-odin` submodule in `elixir/xitdb` to the released `odin-xitdb` `master` commit.
- Deduplicate NIF helpers in `native/xitdb_nif.odin` (`read_prehashed_steps_slot`, `odin_nif_history_of`, stack selector helpers) to call exported upstream `xitdb` procedures directly wherever ABI/BEAM-term constraints allow.
- Verify v1/v2 database header compatibility, `odin_nif_compact`, replication/recovery paths, and zero `Tracking_Allocator` / `context.temp_allocator` leaks across `native/xitdb_nif.odin`.
- Update `benchmarks/bench_client.odin` so Raw Odin uses the new `odin-xitdb` API/optimizations rather than local workarounds, verify `odin check` + `mix precommit`, and regenerate `elixir/xitdb` `benchmarks/README.md` via `./benchmarks/compare_1v1.py --runs 5 --warmup 1 && ./benchmarks/update_readme.sh`.

---

## 3. Technical Invariants & Constraints

1. **Binary & Wire Compatibility:** Databases created under v1 or v2 header formats must remain readable; v2 `FILE_SIZE_START` aligned `file_size` and recovery behavior in `odin-xitdb` and `native/xitdb_nif.odin` must match `xit-vcs/xitdb` bit-for-bit.
2. **Memory Safety (`temp_allocator` & `Tracking_Allocator`):** Every NIF entrypoint in `native/xitdb_nif.odin` using `context.temp_allocator` keeps `defer free_all(context.temp_allocator)`, and all `odin test tests` specs run cleanly under `Tracking_Allocator` with zero leaks or bad frees.
3. **Architecture Boundaries:** All `odin-xitdb` specs follow the 3-layer ATDD architecture in `/home/pauli/projects/odin/xitdb/tests/`; all new `elixir/xitdb` behavioral tests follow the 4-layer ATDD architecture (`test/features/*_spec.exs`, `ClientDSL`, `ClientDriver`).
4. **Documentation & MathJax Rule:** All Markdown updates avoid underscores inside `$...$` or `$$...$$` LaTeX math spans (always use inline code spans such as `` `FILE_SIZE_START` `` or `` `O(log_16 N)` ``).
5. **Release Discipline:** Never push directly to `master` or create release tags without explicit user confirmation in the active turn.

---

## 4. Acceptance Criteria

- [ ] `feat/upstream-parity-89da8e7` audited and cleanly integrated into `odin-xitdb` `master` with zero regressions.
- [ ] `odin-xitdb` implements pre-hashed sequential `history_of`, stack-buffered `[16]Path_Step` selector parsing, and slot-only `cursor_read_kv_pair_slots` where appropriate.
- [ ] `odin check xitdb`, `odin check cmd/xit`, `odin check tests`, and `odin test tests` pass with 0 failures and 0 leaks; Odin-vs-Zig 1v1 benchmarks and docs updated in `odin-xitdb`.
- [ ] `elixir/xitdb` `native/xitdb-odin` bumped to `odin-xitdb` `master`, `native/xitdb_nif.odin` deduplicated and verified for v1/v2 compatibility, `odin check` + `mix precommit` green, and Elixir-vs-Odin 1v1 benchmarks (`benchmarks/README.md`) regenerated.
