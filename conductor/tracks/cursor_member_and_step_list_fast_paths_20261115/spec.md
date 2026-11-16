# Specification: Direct `Enumerable.Xitdb.Cursor` Fast-Path Heads & Batch C Step-List Unpacking for `path_steps/1`

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `cursor_member_and_step_list_fast_paths_20261115`
> - **Type:** Chore / Performance Optimization
> - **Target Repository:** `elixir/xitdb`
> - **Submodule Boundary:** `native/xitdb-odin` stays 100% untouched (zero API or wire divergence)
> - **Primary Files:** `lib/xitdb/cursor.ex`, `lib/xitdb.ex`, `native/nif_entry.c`, `native/xitdb_nif.odin`, `test/xitdb/cursor_refactor_test.exs`, `test/xitdb/dsl/path_compiler_test.exs`, `benchmarks/README.md`, `benchmarks/slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md`, `benchmarks/slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md`, `benchmarks/slices/28_dsl_pre_tokenized_path_steps_select_path_steps_users_id_name.md`
> - **Done When:** `Enumerable.Xitdb.Cursor.member?/2` and `count/1` match resolved read cursors directly in function heads, `decode_selector_term_buf` and `decode_steps_term_buf` use a single C shim call (`nif_unpack_step_list`) to unpack step lists, `Xitdb.select/2` / `select!/2` / `do_select/3` / `do_select!/3` are inlined, `odin check` + `mix precommit` pass with 0 warnings, and benchmarks `#6`, `#7`, and `#28` reflect the gains.

---

## 1. Goal & Motivation

Two high-frequency sub-microsecond / single-call read paths still pay avoidable wrapper and C-FFI hop overhead in `run-1794747522`:

1. **`Enumerable.Xitdb.Cursor.member?/2` (`#7`, `803 ns` vs. `262 ns` Odin = `+541 ns`) and `count/1` (`#6`, `189 ns`):**
   In `lib/xitdb/cursor.ex`, `member?/2` and `count/1` lack direct function-head clauses for `%Cursor{tx_mode: false, root: false, tag_id: tag_id, db_ref: db_ref, value: val}` when `tag_id in [11, 13, 15]` (`:hash_set`, `:counted_hash_set`, `:sorted_set`) or `tag_id > 0`. Every call branches on `tx_mode`, invokes `Cursor.ensure_resolved/1`, unpacks `{nid, nval}`, and re-wraps `{:ok, bool}` (`member?/2` also lacks a direct non-binary guard checking `NIF.nif_info(db_ref)`).
2. **`Xitdb.select!(db, path_steps(...))` (`#28`, `2.08 µs` vs. `645 ns` Odin and `#2` at `2.06 µs`):**
   Even after eliminating duplicate head-cell decoding (`path_steps_and_select_fast_path_20261115`), `#28` is no faster than string-parsed `select!/2` (`#2`) because `decode_selector_term_buf` in `native/xitdb_nif.odin` still makes **14 separate Odin <-> C FFI calls** to walk a 3-element step list (`nif_is_binary`, `nif_is_list`, `nif_get_list_cell` x4, `nif_get_tuple`, `nif_is_binary` x3, `nif_inspect_binary` x3, `nif_is_empty_list`) vs. a single `nif_inspect_binary` call for string selectors, and `Xitdb.select/2` / `select!/2` / `do_select/3` / `do_select!/3` are not `@compile {:inline, ...}` (with `select!/2` still delegating through `select/2`). Replacing the Odin loop on the ≤16-step fast path (plus up to 1 leading `{:at_moment, m}` slot = `[17]Nif_Raw_Step` in `decode_selector_term_buf`) with `nif_unpack_step_list` in `native/nif_entry.c` supersedes `path_steps_and_select_fast_path_20261115`'s head-decode path for flat short lists while preserving the Odin step-by-step parser as the fallback.

---

## 2. Architectural Invariants & API Alignment

1. **Zero `odin-xitdb` Divergence:** `native/xitdb-odin/` stays completely untouched.
2. **Identical `Enumerable` Protocol Semantics:** Virtual/unresolved `tx_mode` cursors, root cursors, missing/nil cursors, and non-set membership checks fall back to the existing clauses with identical results.
3. **Full Step-List Encoding Fidelity:** `nif_unpack_step_list` in `native/nif_entry.c` preserves support for plain binaries, integers, typed `{tag, val}` key/index tuples (such as `{:key, key}`, `{:at_moment, m}`, etc.), empty lists, and proper-list termination validation (returning `-3` for improper lists -> `"invalid_selector"`), falling back cleanly to `decode_steps_list_buf` when list length exceeds the fixed stack batch (`16` steps in `decode_steps_term_buf`, or `17` raw entries in `decode_selector_term_buf`).

---

## 3. Functional Requirements

- Add direct fast-path function heads to `Enumerable.Xitdb.Cursor.member?/2` (`NIF.nif_slot_contains/4` for binaries, `NIF.nif_info/1` health check for non-binaries) and `Enumerable.Xitdb.Cursor.count/1` (`NIF.nif_slot_count/3`) in `lib/xitdb/cursor.ex` for resolved non-`tx_mode`, non-`root` cursors.
- Add `nif_unpack_step_list` in `native/nif_entry.c` and bind it from `decode_steps_term_buf` and `decode_selector_term_buf` (`convert_raw_steps_buf`) in `native/xitdb_nif.odin` so up to 16 selector steps (or leading `{:at_moment, m}` + 16 steps) unpack in one C FFI call (benefiting `odin_nif_select`, `odin_nif_history_of`, and `odin_nif_transact`).
- Add `do_select!/3` and `@compile {:inline, select: 2, select!: 2, do_select: 3, do_select!: 3}` in `lib/xitdb.ex` to eliminate wrapper hops and redundant `{:ok, ...}` wrap/unwrap allocation on `select!/2`.

---

## 4. Technical Invariants

1. **C/Odin Memory Safety:** Batch unpacking writes only caller-provided fixed-capacity stack buffers and validates `enif_get_list_cell` / binary bounds safely.
2. **Zero Warnings & Clean Formatting:** `odin check` and `mix precommit` pass with 0 warnings.
3. **Benchmark Validation:** Refresh `#6`, `#7`, and `#28` via `./benchmarks/compare_1v1.py --runs 5 --warmup 1` and `./benchmarks/update_readme.sh`.
