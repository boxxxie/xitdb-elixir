# Implementation Plan: Fast-Path Decoding for `path_steps/1` and `Xitdb.select/2`

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `path_steps_and_select_fast_path_20261115`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Target Repository:** `elixir/xitdb`
> - **Done When:** Single-pass head step decoding in `decode_selector_term_buf`, inline bracket step emission / fast-path in `path_steps/1`, scalar fast-path guard in `do_select/3`, and unit/ATDD tests are implemented; `odin check` and `mix precommit` pass with 0 warnings; and benchmarks `#2` & `#28` are refreshed.

---

## Phase 1: Single-Pass Selector Decoding in `odin_nif_select` & Scalar Guard in `do_select/3`

- [x] **1.1** Remove duplicate head `enif_get_list_cell` decode and scalar unwrap dispatch
  - Update `decode_selector_term_buf` in `native/xitdb_nif.odin` so non-`at_moment` `head_term` is decoded directly via `decode_one_step_term` and `tail_term` feeds the remaining steps loop
  - Add fast-path scalar guard in `do_select/3` inside `lib/xitdb.ex` for binaries, numbers, booleans, and `nil` (keeping special tuples/containers routed through `Cursor.unwrap_nif_value/4`)
  - Evaluate passing cached root slot coordinates for `select(%Cursor{root: true}, ...)` without breaking `:at_moment` overrides

---

## Phase 2: Optimize Dynamic Bracket Emission in `PathCompiler` / `Selector` & Test Coverage

- [x] **2.1** Reduce dynamic `normalize_bracket_step/1` overhead and verify selector edge cases
  - Audit `PathCompiler.extract_bracket_segment/2` (`lib/xitdb/dsl/path_compiler.ex`) and `Xitdb.Selector.normalize_bracket_step/1` (`lib/xitdb/selector.ex`) so plain binary/integer dynamic variables pass directly (or inline fast checks) without sacrificing atom/negative-index/wildcard normalization
  - Ensure `test/features/macro_dsl_spec.exs`, `test/xitdb/dsl/path_compiler_test.exs`, and `test/xitdb/selector_test.exs` cover `{:at_moment, m}` prefixes, dynamic integer/negative-index/atom/binary brackets, nested containers, and missing-key `{:error, :not_found}` cases
  - Run `odin check` and `mix precommit` with zero warnings

---

## Phase 3: Benchmark Verification & Slice Refresh

- [x] **3.1** Re-benchmark and update reports
  - Run `./benchmarks/compare_1v1.py --runs 5 --warmup 1` and `./benchmarks/update_readme.sh`
  - Verify improvements on `#2` and `#28` (`benchmarks/slices/28_dsl_pre_tokenized_path_steps_select_path_steps_users_id_name.md`)
