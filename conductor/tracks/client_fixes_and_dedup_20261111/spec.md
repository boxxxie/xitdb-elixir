# Specification: Track 5 — Client Bugfixes, Range Semantics, Deadlock Elimination & Cursor Deduplication

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `client_fixes_and_dedup_20261111`
> - **Execution Waves:**
>   - **Track 5A (`[Wave 1]` — MVP Prerequisites & Client Fixes):** Wave 1 `mix.exs` setup, Step 1 (`@`/`\` escaping + `^sel_len` bitstring pins), Step 3 (`WireChanges` deadlock elimination + atomic `:persistent_term` pair cache + parallel-safe `tx_for`), and Step 4A (`O(1)` `staged_ops` prepending across all callers, `Cursor.fetch/2` integer resolution when `tx_mode: false`, `MapSet.size/1` opacity fix, and direct `%Xitdb{}` mutation guard)
>   - **Track 5B (`[Wave 4]` — Deferred Core Client Cleanup):** Step 2 (`Xitdb.Pull` inclusive range semantics & slice validation) and Step 4B (`Cursor` internal deduplication, stepped `Enumerable.slice/1`, and atom-free `PreviewTag` inspect)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Area:** `mix.exs`, `lib/xitdb/tx_compiler.ex`, `lib/xitdb/dsl.ex`, `lib/xitdb/pull.ex`, `lib/xitdb/cursor.ex`, `lib/xitdb.ex`, `lib/xitdb/ash/*`
> - **Conductor Patch & Scope Note:** `wave1_mvp_prereqs_and_schema.patch` packages the Conductor specifications, execution plans, and complete self-contained reference implementations/diffs for Wave 1 execution (Tracks 5A and 8) against the `master` (`v1.0.2`) baseline.
> - **Reference Documents:**
>   - Master Reference: [`./reference.md`](./reference.md)
>   - Step 1: [`./references/step1_selector_and_datalog_escaping.md`](./references/step1_selector_and_datalog_escaping.md)
>   - Step 2: [`./references/step2_pull_range_semantics.md`](./references/step2_pull_range_semantics.md)
>   - Step 3: [`./references/step3_wirechanges_deadlock_elimination.md`](./references/step3_wirechanges_deadlock_elimination.md)
>   - Step 4: [`./references/step4_cursor_dedup_and_staging.md`](./references/step4_cursor_dedup_and_staging.md)

---

## 1. Goal & Architectural Motivation

While `elixir/xitdb` provides an expressive, idiomatic Elixir client over the native Odin transactional engine, production usage and compatibility testing under Elixir 1.19/1.20 and Ash 3 identified several edge-case defects, compilation hazards, and redundant code paths:

1. **Unescaped Special Characters & Elixir String Interpolation Mangling:**
   `TxCompiler.format_key/1` used `~s(["#{key}"])` and `inspect/1` for escaping selector keys and Datalog literals. This mangled keys containing string interpolation syntax (`#{...}`) into `\#{...}` and failed to quote characters like `@`, `\`, and `\r`. Furthermore, `deleted_child_path?/3` lacked Elixir 1.20 bitstring pin syntax (`^sel_len`) and omitted set delimiters (`?%`, `?^`), causing set element invalidation under deleted parent paths to miss staged updates.

2. **Pull Range Inconsistency (Inclusive vs Exclusive):**
   Elixir's idiomatic ranges (`first..last`) are inclusive, matching `Enum.slice/2` and `Xitdb.DSL.slice`. However, `Xitdb.Pull` passed `last` directly into Odin's half-open `[first..last]` syntax, cutting off the final element. `Xitdb.Pull` also lacked centralized validation for slice arguments, allowing negative limits or stepped ranges to bypass checks.

3. **Cyclic Compilation Deadlocks in `Xitdb.Ash.Transformers.WireChanges`:**
   Mutual companion resource definitions (`User <-> Profile`) resulted in compile-time deadlocks because `WireChanges` invoked `Code.ensure_compiled(companion)` within the Spark transformer phase. In addition, `tx_for` in `Xitdb.DSL` used `Code.ensure_loaded?/1`, which can return `false` prematurely when modules are compiling concurrently under `mix compile`. Compile-time application environment reads were also unrecorded, causing cache staleness.

4. **Cursor Code Duplication, Unresolved Integer Lookups, `MapSet` Opacity & Sub-optimal Staging:**
   `Xitdb.Cursor` failed to call `ensure_resolved/1` before `nif_slot_get_index` when `tx_mode: false` on unresolved root cursors (`Xitdb.as_of(db, 0)[0]`, passing `tag_id: -1` to the NIF), directly inspected private `MapSet.map` fields (`map_size(cursor.deleted_paths.map)`—violating Elixir 1.19/1.20 opacity under `--warnings-as-errors`), appended `staged_ops` in `O(N)` rather than `O(1)` prepending, contained repetitive `fetch/2` clauses, created dynamic atoms during `Inspect`, and over-fetched elements on stepped `Enumerable.slice/1`.

---

## 2. Functional Requirements by Wave & Step

### Wave 1 Setup (`mix.exs` Test Environment Readiness — Track 5A)
- Ensure `mix.exs` declares `def cli, do: [preferred_envs: [precommit: :test]]` so `mix precommit` compiles and executes in `:test` without manual `MIX_ENV=test`.
- Ensure `:stream_data` is available in `:dev` and `:test` (`{:stream_data, "~> 1.1", only: [:dev, :test]}`) so property-based invariant checks in Wave 1 and Wave 2 (Track 11A `Codec` round-trip properties) run out of the box.

### Step 1 (Wave 1 — Track 5A): Selector & Datalog Escaping + Bitstring Pinning
- **Binary-safe quote escaping:** Implement `TxCompiler.encode_quoted/1` using a tail-recursive byte scanner (`escape_bytes/2`) that escapes `\`, `"`, `\n`, `\r`, and `\t` without producing `\#{` interpolation artifacts.
- **Special character recognition:** Expand `@special_chars` in `TxCompiler` to include `"@"`, `"\\"`, and `"\r"`.
- **Datalog literal & bracket formatting:**
  - Route string literals and string keys in Datalog bracket pins through `TxCompiler.encode_quoted/1`.
  - Route pinned linked-list indices (`todos[[^idx]]`) through `Xitdb.DSL.__format_datalog_bracket_pin__([idx])` so `__format_datalog_bracket_pin__([idx]) when is_integer(idx)` is actively exercised without dead clauses, and add atom bracket step support.
  - Correctly serialize booleans and numbers; guard against `nil` values emitting `"\"nil\""`.
- **Set member invalidation & bitstring pinning:**
  - In `Xitdb.DSL.deleted_child_path?/3`, pin `^sel_len` in the binary match pattern (`<<^selector::binary-size(^sel_len), sep, _rest::binary>>`).
  - Add `?%` and `?^` delimiters to the separator match list.

### Step 3 (Wave 1 — Track 5A): Remove `WireChanges` Deadlocks, Atomic Pair Cache & Fix `tx_for` Parallel Compilation
- **Remove compile-time companion compilation:** Remove `Code.ensure_compiled(companion)` and generated companion pair callbacks from `WireChanges.transform/1`.
- **Atomic race-free `:persistent_term` pair cache:** Implement `cached_pair/4` in `Xitdb.Ash.Info` using independent per-pair keys `{__MODULE__, :pair, kind, a, b}` (with zero shared `{__MODULE__, :pairs}` registry map read-modify-write races under concurrent readers), scanning `:persistent_term.get/0` only inside `__purge_pair_cache__/1` during module recompilation.
- **Type-safe struct updates:** Use explicit struct pattern matches (`%Xitdb.Ash.NestedIn{}` and `%Ash.Resource.Actions.Update{}`) before updating structs.
- **Application env tracking:** Inject `_ = Application.compile_env(:xitdb, :default_lock_change)` into resource bodies when `lock_change` is omitted.
- **Parallel-safe schema resolution:** Replace `Code.ensure_loaded?/1` with `Code.ensure_compiled/1` in `extract_schema_indexes!/2` (`lib/xitdb/dsl.ex`) and provide caller `file` and `line` metadata on `CompileError`.

### Step 4A (Wave 1 — Track 5A): O(1) Op Staging, Unresolved Integer `fetch/2` Fix, `MapSet` Opacity & `%Xitdb{}` Mutation Guard
- **O(1) op staging across all callers:** Prepend staged operations in reverse order (`[op | staged_ops]` and `:lists.reverse(new_ops, staged_ops)`) across `Cursor.get_and_update/3`, `Cursor.pop/2`, `Xitdb.insert_at/4`, `Xitdb.delete_at/3`, and `Xitdb.fork/3`, reversing once on commit via `:lists.reverse(ops)` in `Xitdb.transact/3`. Verify `lib/xitdb/dsl.ex` remains completely decoupled from `Cursor.staged_ops` (it maintains its own process-dictionary `state.ops` and `state.index_ops`, which already prepend in `O(1)` and reverse in `__commit_tx_state__/1`).
- **Integer index resolution when `tx_mode: false`:** Ensure `Cursor.fetch(%Cursor{}, key) when is_integer(key)` always calls `ensure_resolved(cursor)` before invoking `NIF.nif_slot_get_index/4` even when `tx_mode: false`, so `Xitdb.as_of(db, 0)[0]` on a root list or moment cursor never passes `tag_id: -1` to `nif_slot_get_index`.
- **Opaque `MapSet` compliance in Wave 1:** Replace every `map_size(cursor.deleted_paths.map) == 0` check in `lib/xitdb/cursor.ex` with `MapSet.size(deleted) == 0` immediately in Track 5A so Elixir 1.19/1.20 `mix compile --warnings-as-errors` never fails on `MapSet` opacity in Wave 1.
- **`%Xitdb{}` mutation protection:** Raise `ArgumentError` with a descriptive message if `put_in`/`update_in`/`pop_in` is invoked directly on `%Xitdb{}` outside `Xitdb.transact/3` or `Xitdb.DSL.tx/3`.

### Step 2 (Wave 4 — Track 5B): Inclusive `Range` Semantics & Validation in `Xitdb.Pull`
- **Range translation:** Translate Elixir inclusive ranges `first..last//1` to Odin wire format `[first..last + 1]`.
- **Slice & non-empty nested list validation:** Introduce `format_slice_spec!/1` with `is_slice_spec` guard and preserve `nested != []` guards on nested list clauses:
  - Enforce non-negative, ascending, step-1 ranges (`first >= 0 and last >= first`).
  - Enforce non-negative integer `offset` and `limit` for `{:slice, offset, limit}` tuples.
  - Reject negative, descending, stepped, or empty nested patterns (`[profile: []]`, `[team: {0..2, []}]`) deterministically with `ArgumentError` in `Pull.compile!/1` (wrapped in `{:error, %Xitdb.Error{reason: :invalid_pull_pattern}}` by `Pull.compile/1`).
- **Doc & Guide Sync:** Update doctests and pattern tables in `lib/xitdb/pull.ex`, `lib/xitdb.ex`, and `docs/path-and-pull-dsl.md`.

### Step 4B (Wave 4 — Track 5B): Deduplicate `Xitdb.Cursor`, Stepped `Enum.slice` & Atom-Free `Inspect`
- **Deduplicate cursor construction:** Consolidate `fetch/2` and cursor tuple unwrapping via helper functions `from_nif_tuple/4`, `unwrap_nif_value/4`, `nif_slot_get/2`, and `lookup_staged/2`.
- **Stepped slicing:** Compute exact slice span `(length - 1) * step + 1`, apply `Enum.take_every/2` prior to wrapping, and short-circuit `length <= 0` slices.
- **Atom-free `Inspect`:** Implement `Xitdb.Cursor.PreviewTag` to format preview child tags (`<hash_map>`) without dynamic atom generation (`:"<#{tag}>"`). Handle unresolved cursors gracefully with `#Xitdb.Cursor<unresolved (...)>`.

---

## 3. Acceptance Criteria

1. **Wave 1 `mix.exs` Verification:** `mix precommit` runs automatically in `:test` env with `:stream_data` loaded.
2. **Step 1 Verification:** `Xitdb.SelectorEscapingTest` passes, confirming correct escaping of quotes, backslashes, `@`, newlines, `#{...}` interpolation strings, Datalog literals, and `todos[[^idx]]` linked-list pins.
3. **Step 2 Verification:** `Xitdb.PullCompileTest` passes and doctests succeed, verifying inclusive `[first..last + 1]` translation and `ArgumentError` / `:invalid_pull_pattern` handling for invalid slices and `[profile: []]`.
4. **Step 3 Verification:** `Xitdb.Ash.CompanionAndTxForTest` passes, verifying mutual companion resources compile without deadlock using atomic per-pair `:persistent_term` keys and `tx_for` reports clear compile errors with caller line numbers.
5. **Step 4 Verification:** `Xitdb.CursorRefactorTest` passes, confirming read-your-own-writes ordering across `Cursor` and `DSL.tx`, `Xitdb.as_of(db, 0)[0]` integer resolution, zero `MapSet` opacity warnings, stepped slicing, atom-free preview rendering, and direct mutation guarding.
6. **Quality Verification:** Full test suite passes (`mix test`), formatting is clean (`mix format --check-formatted`), and compilation succeeds with zero warnings (`mix compile --warnings-as-errors`).
