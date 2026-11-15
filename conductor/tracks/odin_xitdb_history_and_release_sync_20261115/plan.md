# Implementation Plan: `odin-xitdb` History/Selector Parity, Release Pipeline & `elixir/xitdb` Sync

> [!IMPORTANT]
> - **Track ID:** `odin_xitdb_history_and_release_sync_20261115`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Execution Boundary:** Phases 1–3 execute in `/home/pauli/projects/odin/xitdb`; Phase 4 executes in `/home/pauli/projects/elixir/xitdb` only after Phase 3 lands on `odin-xitdb` `master`.

---

## Phase 1: Finalize Upstream Zig `89da8e7` Parity in `odin-xitdb`

- [ ] **1.1** Audit branch `feat/upstream-parity-89da8e7` (`be1b53c..80ea2f0`) in `/home/pauli/projects/odin/xitdb`
  - Inspect commits (`66394ba`, `0a0581f`, `734759b`, `06776c9`, `0cf2184`, `bc474c2`, `f2f08fa`, `80ea2f0`) covering v2 root header (`FILE_SIZE_START` aligned `file_size`), interrupted-commit & replication recovery, short-key `Sorted_Set` reader fix, and unwritten `Array_List` element counts.
  - Confirm status of open worktrees/branches (`feat-lock-free-cursors`, `feat-reverse-iterator`, `feat/lua`) so parity release scope stays cleanly decoupled.
- [ ] **1.2** Verify upstream parity test coverage and wire compatibility
  - Run `odin check xitdb`, `odin check cmd/xit`, `odin check tests`, and `odin test tests` on `feat/upstream-parity-89da8e7`.
  - Confirm zero leaks under `Tracking_Allocator` and verify v1-to-v2 database upgrade/read behavior and CLI (`cmd/xit`) commands.

---

## Phase 2: Implement `history_of` Pre-Hashed Traversal, Stack-Buffered Selectors & Slot-Only KV Reads in `odin-xitdb`

- [ ] **2.1** Add stack-buffered path & selector parsing to `xitdb/dsl.odin`
  - Add stack-backed parsing helpers (e.g. `[16]Path_Step` fixed buffer with automatic overflow fallback to slice allocation when step count exceeds 16).
  - Preserve existing API signatures while routing hot internal DSL calls (`read_steps_cursor`, `tx`, `history_of`, `query_prefix`) through the stack buffer.
- [ ] **2.2** Optimize `history_of` in `xitdb/dsl.odin` with pre-hashed step traversal and sequential iterator scanning
  - Pre-hash path keys and `"__tx"` / `"doc"` / `"tx_instant"` field keys once before iterating moments.
  - Replace per-moment `array_list_get_cursor` descents with `cursor_iterator` / `cursor_iterator_next` over the top-level moments list and traverse pre-hashed steps directly via `read_prehashed_steps_slot` / `Prehashed_Step`.
  - Export clean reusable pre-hashed traversal APIs in `xitdb` so downstream consumers (such as `elixir/xitdb`'s NIF) do not duplicate internal `hash_map_get_slot` / slot-tag logic.
- [ ] **2.3** Migrate key/value iteration sites in `odin-xitdb` to `cursor_read_kv_pair_slots`
  - Audit all `cursor_read_kv_pair` call sites across `xitdb/*.odin` and switch slot-only consumers to `cursor_read_kv_pair_slots` to avoid allocating unused 20-byte SHA-1 hashes.

---

## Phase 3: `odin-xitdb` Release Pipeline (3-Layer ATDD, Zero-Leak Tests, Zig-vs-Odin Benchmarks & Docs)

- [ ] **3.1** Add 3-layer ATDD specifications in `/home/pauli/projects/odin/xitdb/tests/`
  - Add/update Layer 1 feature specs (`tests/features/`) and Layer 2/3 DSL + driver helpers (`tests/dsl/`, `tests/drivers/`) testing:
    - `history_of` parity across multi-moment mutations, empty moments, and key overwrites/deletes.
    - Selectors with `0`, `<= 16`, and `> 16` steps (testing stack-buffer overflow handling).
    - v1 vs. v2 root header compatibility and recovery paths under `Tracking_Allocator`.
- [ ] **3.2** Run full verification & Odin-vs-Zig 1v1 benchmark suite in `odin-xitdb`
  - Verify `odin check xitdb`, `odin check cmd/xit`, `odin check tests`, and `odin test tests` pass with 0 leaks.
  - Run `benchmarks/compare_1v1.py` and `benchmarks/update_readme.sh` (Odin vs. Zig baseline) and verify `#18 history_of` and selector benchmarks against Zig.
- [ ] **3.3** Update `odin-xitdb` documentation and prepare `master` release
  - Update `README.md`, `docs/CORE_API.md`, `docs/DSL.md`, `usage-rules.md`, `AGENTS.md`, and `benchmarks/README.md` with new v2 header behavior, `history_of`/selector performance notes, and any new exported DSL helpers (keeping all Markdown free of underscores in `$...$` math blocks).
  - Merge finalized parity + optimization branch into `odin-xitdb` `master` (pushing / tagging only with explicit user confirmation).

---

## Phase 4: Synchronize `elixir/xitdb` Submodule, Deduplicate NIF Helpers & Refresh 1v1 Benchmarks

- [ ] **4.1** Bump `native/xitdb-odin` submodule to the released `odin-xitdb` `master` commit
  - Update `native/xitdb-odin` pointer in `/home/pauli/projects/elixir/xitdb` and inspect upstream diff for NIF impact (v2 header fields, compaction, cursor/DSL exports).
- [ ] **4.2** Deduplicate `native/xitdb_nif.odin` against upstream `odin-xitdb` and verify v1/v2 compatibility
  - Replace duplicated internal helpers (such as `read_prehashed_steps_slot` / step digest setup) in `native/xitdb_nif.odin` with calls to the new `odin-xitdb` library procedures where BEAM term construction remains optimal.
  - Verify v2 header fields (`FILE_SIZE_START` aligned `file_size`, `odin_nif_compact`, `odin_nif_info`, recovery/sync) work seamlessly with `elixir/xitdb` snapshots, transactions, and 4-layer ATDD specs.
- [ ] **4.3** Refresh Raw Odin client benchmark (`benchmarks/bench_client.odin`) & run full verification
  - Ensure `benchmarks/bench_client.odin` exercises the released `odin-xitdb` `history_of` / stack-buffered selector API directly for an apples-to-apples 1v1 comparison.
  - Run `odin check native -no-entry-point -collection:xitdb=native/xitdb-odin/xitdb`, `odin check benchmarks -collection:xitdb=native/xitdb-odin/xitdb`, `mix precommit`, and `./benchmarks/compare_1v1.py --runs 5 --warmup 1 && ./benchmarks/update_readme.sh`.
