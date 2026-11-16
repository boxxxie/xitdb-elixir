# Specification: Fast-Path Decoding for `path_steps/1` and `Xitdb.select/2`

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `path_steps_and_select_fast_path_20261115`
> - **Type:** Chore / Performance Optimization
> - **Target Repository:** `elixir/xitdb`
> - **Submodule Boundary:** `native/xitdb-odin` stays 100% untouched (zero API or wire divergence)
> - **Primary Files:** `native/xitdb_nif.odin`, `lib/xitdb.ex`, `lib/xitdb/dsl/path_compiler.ex`, `lib/xitdb/selector.ex`, `test/features/macro_dsl_spec.exs`, `test/xitdb/dsl/path_compiler_test.exs`, `test/xitdb/selector_test.exs`, `benchmarks/README.md`, `benchmarks/slices/02_access_single_call_selector_select_users_id_name.md`, `benchmarks/slices/28_dsl_pre_tokenized_path_steps_select_path_steps_users_id_name.md`
> - **Done When:** Duplicate head `enif_get_list_cell` decoding is eliminated in `decode_selector_term_buf`, dynamic bracket steps avoid unnecessary runtime normalization overhead, `do_select/3` fast-paths flat scalar returns without invoking `Cursor.unwrap_nif_value/4`, `select/2` on resolved snapshot cursors reuses the cached root slot when appropriate, `odin check` + `mix precommit` pass with zero warnings, and benchmarks `#2` & `#28` are refreshed.

---

## 1. Goal & Motivation

In 1v1 benchmark `#28` (`DSL: Pre-tokenized path_steps select(path_steps(users[id].name))`), Raw Odin takes `759 ns` while Elixir takes `2,464 ns` (`3.25x` Raw Odin, `+1,705 ns` overhead).

Three avoidable costs accumulate on this hot path (`lib/xitdb.ex`, `lib/xitdb/dsl/path_compiler.ex`, and `native/xitdb_nif.odin`):
1. **Duplicate head list-cell decode in NIF (`native/xitdb_nif.odin`):** `decode_selector_term_buf` calls `enif_get_list_cell` + `enif_get_tuple` on the head element to check for `{:at_moment, m}`. When the head is a normal step (e.g. `"users"`), `decode_selector_term_buf` discards `head_term` and delegates `term` to `decode_steps_list_buf`, which calls `enif_get_list_cell` on the first element a second time.
2. **Runtime remote dispatch per dynamic bracket step (`lib/xitdb/dsl/path_compiler.ex`):** `extract_bracket_segment/2` emits `Xitdb.Selector.normalize_bracket_step(uid)` even when `uid` is a binary or integer that `decode_one_step_term` in the NIF handles directly (`enif_inspect_binary` / `enif_get_int64`).
3. **Redundant `Cursor.unwrap_nif_value/4` dispatch (`lib/xitdb.ex`):** When `nif_select` returns a scalar binary/number/boolean/`nil`, `do_select/3` calls `Cursor.unwrap_nif_value(db_ref, raw, moment, [])` instead of returning `{:ok, raw}` directly via an inline guard clause. Additionally, calling `select/2` on a resolved snapshot cursor (`%Cursor{root: true, ...}`) can avoid re-reading `moment` from the root `Array_List` when appropriate.

---

## 2. Architectural Invariants & API Alignment

1. **Zero `odin-xitdb` Divergence:** `native/xitdb-odin/` stays completely untouched.
2. **Exact Semantic Compatibility:**
   - `path_steps/1`, `path/1`, `~x`, and `Xitdb.select/2,3` preserve exact semantics for strings, atoms, integers, negative indices, wildcards (`:*`), `:count`, `:all`, `:at_moment` prefixes, and `%Xitdb{}` / `%Xitdb.Cursor{}` inputs.
   - Non-binary/non-integer runtime bracket values (atoms, wildcards, negative indices, `{:index, i}`, etc.) continue normalizing identically.

---

## 3. Functional Requirements

- Refactor `decode_selector_term_buf` in `native/xitdb_nif.odin` so when `head_term` is not `{:at_moment, m}`, `head_term` is decoded directly as step `0` and `tail_term` is passed to `decode_steps_list_buf`.
  > **Note (Superseded on ≤16-step flat lists):** A follow-up track (`cursor_member_and_step_list_fast_paths_20261115`) later introduced `nif_unpack_step_list` in `native/nif_entry.c` to batch-unpack up to 16 flat steps in one C FFI call, while retaining this Odin step-by-step path as the fallback for longer or complex paths.
- Optimize `PathCompiler.extract_bracket_segment/2` (`lib/xitdb/dsl/path_compiler.ex`) / `Xitdb.Selector` (`lib/xitdb/selector.ex`) to inline fast guards or reduce remote call overhead on binary/integer bracket steps while keeping full support for atoms, `{:index, i}`, and wildcards.
- Add an inline scalar guard clause in `do_select/3` (`lib/xitdb.ex`) (`when is_binary(raw) or is_number(raw) or is_boolean(raw) or is_nil(raw)`) to bypass `Cursor.unwrap_nif_value/4`.
- Explore passing already-resolved snapshot root slot into `nif_select` (or `select/2` on `%Cursor{root: true}`) if clean and boundary-safe.
- Verify all path/selector specs and edge cases in `test/features/macro_dsl_spec.exs`, `test/xitdb/dsl/path_compiler_test.exs`, and `test/xitdb/selector_test.exs`.

---

## 4. Technical Invariants

1. **Submodule Isolation:** `native/xitdb-odin/` stays unmodified.
2. **Odin Temp Allocator Hygiene:** `odin_nif_select` retains `defer free_all(context.temp_allocator)`.
3. **Zero Warnings:** `odin check` (native + benchmarks) and `mix precommit` pass with 0 warnings.
4. **Benchmark Validation:** Refresh `#2` and `#28` via `./benchmarks/compare_1v1.py --runs 5 --warmup 1` and `./benchmarks/update_readme.sh`, targeting `#28` reduction from `~2.46 µs` toward `~1.5–1.7 µs` (`-30%` to `-35%`).
