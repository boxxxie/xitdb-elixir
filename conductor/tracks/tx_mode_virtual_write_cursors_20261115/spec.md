# Specification: Write-Only Virtual Path Staging in `tx_mode` `Access.get_and_update/3`

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `tx_mode_virtual_write_cursors_20261115`
> - **Type:** Chore / Performance Optimization
> - **Target Repository:** `elixir/xitdb`
> - **Submodule Boundary:** `native/xitdb-odin` stays 100% untouched (zero API or wire divergence)
> - **Primary Files:** `lib/xitdb/cursor.ex`, `native/xitdb_nif.odin`, `test/features/lazy_access_navigation_spec.exs`, `test/features/transactions_and_time_travel_spec.exs`, `test/xitdb/cursor_refactor_test.exs`, `benchmarks/README.md`, `benchmarks/slices/14_tx_incremental_put_in_nested_attribute_commit.md`
> - **Done When:** `Access.get_and_update/3` on `tx_mode: true` `%Xitdb.Cursor{}` avoids eager `nif_slot_get_key` / `nif_slot_get_index` reads along intermediate write hops (lazily materializing only when a callback inspects the old value, e.g. `update_in/3` or `get_and_update_in/3`), `put_in/3` and `pop_in/2` preserve 100% identical semantics on existing and new nested paths, `mix precommit` passes with zero warnings, and benchmark `#14` + slices are updated.

---

## 1. Goal & Motivation

In 1v1 benchmark `#14` (`Tx: Incremental put_in(root["users"]["alice"]["score"], v) + commit`), Elixir takes `12.31 µs` vs. Raw Odin's `3.61 µs` (`3.41x` Raw Odin, `+8.70 µs` gap).

When Elixir evaluates `put_in(r["users"]["alice"]["score"], i)` inside `Xitdb.transact/3`, `Kernel.put_in/3` traverses down via `Access.get_and_update/3` at each hop (`"users"`, `"alice"`, `"score"`). Today, `Xitdb.Cursor.get_and_update/3` calls `fetch(cursor, key)` at every level — executing **3 synchronous `nif_slot_get_key` NIF reads** just to obtain intermediate cursor values whose previous state is immediately ignored when staging `{:put, ".users.alice.score", i}`.

Eliminating those unnecessary intermediate NIF read crossings cuts `~3–4 µs` per `put_in/3` (`-25%` to `-30%`), bringing `#14` down from `~12.3 µs` toward `~8–9 µs`.

---

## 2. Architectural Invariants & API Alignment

1. **Zero `odin-xitdb` Divergence:** `native/xitdb-odin/` stays completely untouched.
2. **Exact `Access` & `Xitdb.transact` Semantics:**
   - `put_in(r["a"]["b"]["c"], v)` behaves identically whether `"a"` or `"b"` already exist or are newly materialized containers, and continues recording staged ops into the transaction buffer (`tx_ops` / `tx_id`).
   - `update_in(r["a"]["b"]["score"], fn old -> (old || 0) + 1 end)` and `get_and_update_in/3` still pass the true underlying `%Xitdb.Cursor{}` or decoded current value `old` whenever the user function reads or unwraps it (or via lazy resolution / `fetch` when `fun.(current)` inspects the value).
   - `pop_in/2` returns `{old_val, updated_cursor}` accurately.
   - Read-before-write inside a single transaction (`v = r["users"]["alice"]["score"]; put_in(r["users"]["alice"]["score"], v + 1)`) and multi-statement `put_in` chains remain 100% consistent.

---

## 3. Functional Requirements

- Analyze `Xitdb.Cursor.get_and_update/3` and `Kernel.put_in/3` interaction in `lib/xitdb/cursor.ex`: classify access callbacks (`classify_access_fun/1` -> `:blind_write | :traverse | :needs_current`) and advance virtual write cursors via `virtual_staged_cursor/4` (`value: -2`, accumulating `path_steps`), lazily resolving via `try_resolve/1` (`nif_select`) in `invoke_virtual_or_fallback/5` only if inspected (`Access.fetch/2`, `Enumerable`, `materialize/1`, or user read inside `update_in/3`).
- Ensure staged writes on virtual cursors feed `odin_nif_transact` / `adapt_steps_for_base_moment` (`native/xitdb_nif.odin`) cleanly with zero extra heap or map copying.
- Add comprehensive tests covering `put_in/3` (existing keys, missing intermediate keys, integer array indices, nested lists/maps), `update_in/3` (nil/existing/nested), `get_and_update_in/3`, and `pop_in/2` inside `Xitdb.transact/3` (`test/features/lazy_access_navigation_spec.exs`, `test/features/transactions_and_time_travel_spec.exs`, `test/xitdb/cursor_refactor_test.exs`).

---

## 4. Technical Invariants

1. **Submodule Isolation:** `native/xitdb-odin/` stays unmodified.
2. **Zero Warnings & Clean Formatting:** `mix precommit` and `odin check` pass with 0 warnings.
3. **Benchmark Validation:** Refresh `#14` via `./benchmarks/compare_1v1.py --runs 5 --warmup 1` and `./benchmarks/update_readme.sh`, targeting `#14` improvement from `~12.3 µs` (`3.41x`) toward `~8.5–9.0 µs`.
