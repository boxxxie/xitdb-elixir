# Implementation Plan: Track 5 — Client Bugfixes, Range Semantics, Deadlock Elimination & Cursor Deduplication

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `client_fixes_and_dedup_20261111`
> - **Split Tracks:**
>   - **Track 5A (`[Wave 1]` — MVP Prerequisites & Client Fixes):** `mix.exs` Test Setup, Selector/Datalog `@` & `\` Escaping, `^sel_len` Pins, `WireChanges` Deadlock Removal + Atomic `:persistent_term` Cache, `O(1)` Op Staging, `tx_mode: false` Integer Resolution & `MapSet.size/1` Opacity Fix
>   - **Track 5B (`[Wave 4]` — Deferred Core Client Cleanup):** Inclusive `Xitdb.Pull` Range Semantics, `Cursor` `fetch/2` Deduplication, Stepped `Enumerable.slice/1` & `PreviewTag` Inspect Polish
> - **Conductor Patch & Scope Note:** `wave1_mvp_prereqs_and_schema.patch` packages the Conductor specifications, execution plans, and complete self-contained reference implementations/diffs for Wave 1 execution (Tracks 5A and 8).
> - **Specification:** [`./spec.md`](./spec.md)
> - **Master Reference Document:** [`./reference.md`](./reference.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Done When:** All specified phases are implemented, verified by their respective test suites, and `mix precommit` passes with zero warnings.

---

# Part 1: Track 5A (Wave 1 — MVP Cutover Critical Path)

## Phase 0: Wave 1 `mix.exs` Test Environment Setup

- [x] Task: Configure `cli/0` and `:stream_data` in `mix.exs`
    - [x] Ensure `def cli, do: [preferred_envs: [precommit: :test]]` is present on `Xitdb.MixProject`
    - [x] Configure `{:stream_data, "~> 1.1", only: [:dev, :test]}` in `deps/0` so Wave 1 and Wave 2 (Track 11A `Codec` property checks) have `StreamData` immediately available

---

## Phase 1: Selector & Datalog Escaping + Bitstring Pinning (Step 1)

- [x] Task: Implement byte-level escaping and expand special characters in `TxCompiler`
    - [x] Add `@escapable_chars` and expand `@special_chars` with `"@"`, `"\\"`, and `"\r"` in `lib/xitdb/tx_compiler.ex`
    - [x] Implement `TxCompiler.encode_quoted/1` and tail-recursive `escape_bytes/2` helper
    - [x] Update `TxCompiler.format_key/1` to wrap non-bare keys using `encode_quoted/1` (required for email keys in `AshAuthentication`)
- [x] Task: Align Datalog literals, bracket pins, and set eviction in `DSL`
    - [x] Route `[[^idx]]` (`[{:^, _, [pinned_expr]}]`) in `compile_datalog_bracket_step/2` (`lib/xitdb/dsl.ex`) through `Xitdb.DSL.__format_datalog_bracket_pin__([unquote(pinned_expr)])` and support literal atoms/strings via `encode_quoted/1`
    - [x] Update `__format_datalog_literal__/1` and `__format_datalog_bracket_pin__/1` in `lib/xitdb/dsl.ex` (handling `idx`, `[idx]`, binaries, and non-nil/non-boolean atoms)
    - [x] Pin `^sel_len` and add set member delimiters `?%` and `?^` in `deleted_child_path?/3`
- [x] Task: Add test suite and verify Step 1
    - [x] Create `test/xitdb/selector_escaping_test.exs` covering quotes, backslashes, `@`, newlines, interpolation syntax, pinned Datalog variables, and `[[^idx]]` linked-list pins
    - [x] Run `mix test test/xitdb/selector_escaping_test.exs` and verify Green

---

## Phase 3: Remove `WireChanges` Deadlocks, Atomic Pair Cache & Fix Parallel `tx_for` (Step 3)

- [x] Task: Refactor `Xitdb.Ash.Transformers.WireChanges`
    - [x] Remove `Code.ensure_compiled(companion)` and companion pair callback generation from `WireChanges.transform/1`
    - [x] Invalidate companion cache via `Xitdb.Ash.Info.__purge_pair_cache__/1` on transformer execution
    - [x] Inject `_ = Application.compile_env(:xitdb, :default_lock_change)` into resource body when `lock_change` is omitted
    - [x] Ensure strict struct match on `%Ash.Resource.Actions.Update{}` when injecting lock change
- [x] Task: Implement atomic race-free companion pair cache in `Xitdb.Ash.Info`
    - [x] Implement `cached_pair/4` in `lib/xitdb/ash/info.ex` using independent per-pair `:persistent_term` keys `{__MODULE__, :pair, kind, a, b}` (avoiding any shared `{__MODULE__, :pairs}` map read-modify-write race)
    - [x] Implement `__purge_pair_cache__/1` scanning `:persistent_term.get/0` only during module recompilation to erase `{__MODULE__, :pair, _kind, a, b}` entries referencing `module`
    - [x] Replace `pair_lookup/3` calls in `editable_field_strings/1`, `pull_fields/1`, and `pull_pattern_for/1`
    - [x] Enforce pattern matching on `%Xitdb.Ash.NestedIn{}` in `compute_nested_mappings/1`
- [x] Task: Make `tx_for` schema resolution parallel-safe in `lib/xitdb/dsl.ex`
    - [x] Replace `Code.ensure_loaded?/1` with `Code.ensure_compiled/1` in `extract_schema_indexes!/2`
    - [x] Pass caller `file` and `line` on all raised `CompileError` exceptions
- [x] Task: Sync documentation and verify Step 3
    - [x] Update `docs/ash-and-spark.md` describing `:persistent_term` pair caching (using inline `` `O(1)` `` code spans, zero `$...$` math)
    - [x] Create `test/xitdb/ash/companion_and_tx_for_test.exs` testing mutual companion resources and `tx_for` error reporting
    - [x] Run `mix test test/xitdb/ash/companion_and_tx_for_test.exs` and verify Green

---

## Phase 4A: O(1) Op Staging, `MapSet.size/1` Opacity, Integer `fetch/2` Resolution & `%Xitdb{}` Guard (Step 4 MVP)

- [x] Task: Optimize op staging to `O(1)`, fix `MapSet` opacity & integer `fetch/2`, and guard `%Xitdb{}` mutations
    - [x] Prepend staged operations in reverse order (`[op | staged_ops]`, `:lists.reverse(new_ops, staged_ops)`) across `Cursor.get_and_update/3`, `Cursor.pop/2`, `Xitdb.insert_at/4`, `Xitdb.delete_at/3`, and `Xitdb.fork/3`
    - [x] Reverse staged ops once on commit (`:lists.reverse(ops)`) in `Xitdb.transact/3`, and verify `lib/xitdb/dsl.ex` (`tx` / `tx_for`) does not read or mutate `Cursor.staged_ops` (preserving forward execution order across both APIs)
    - [x] Ensure `Cursor.fetch(%Cursor{}, key) when is_integer(key)` calls `ensure_resolved(cursor)` before `NIF.nif_slot_get_index/4` even when `tx_mode: false` (`Xitdb.as_of(db, 0)[0]`)
    - [x] Replace `map_size(cursor.deleted_paths.map) == 0` with `MapSet.size(deleted) == 0` in `lib/xitdb/cursor.ex` so Elixir 1.19/1.20 `--warnings-as-errors` passes cleanly in Wave 1
    - [x] Raise `ArgumentError` on `Access.get_and_update/3` and `Access.pop/2` on `%Xitdb{}` directly
- [x] Task: Verify Phase 4A operations
    - [x] Test reverse-list `O(1)` op prepending and commit ordering in both `Xitdb.transact/3` and `Xitdb.DSL.tx/3`
    - [x] Test `Xitdb.as_of(db, 0)[0]` integer resolution on `tx_mode: false` root cursors and confirm zero `MapSet` opacity warnings under `mix compile --warnings-as-errors`
    - [x] Test that direct mutation on `%Xitdb{}` raises `ArgumentError`

---

# Part 2: Track 5B (Wave 4 — Deferred Core Client Cleanup)

## Phase 2: Inclusive `Range` Semantics & Validation in `Xitdb.Pull` (Step 2)

- [ ] Task: Update `Xitdb.Pull` range and slice translation
    - [ ] Add `is_slice_spec/1` guard in `lib/xitdb/pull.ex`
    - [ ] Refactor `compile_entry!/1` clauses to delegate slice formatting to `format_slice_spec!/1` while preserving `and nested != []` guards so `[profile: []]` and `[team: {0..2, []}]` deterministically raise `ArgumentError`
    - [ ] Translate inclusive ranges `first..last//1` to `[first..last + 1]` in `format_slice_spec!/1`
    - [ ] Validate non-negative offsets and limits, rejecting descending or stepped ranges with `ArgumentError`
- [ ] Task: Sync documentation, doctests, and guides
    - [ ] Update doctests in `lib/xitdb/pull.ex` and `lib/xitdb.ex`
    - [ ] Update Pull pattern reference table and examples in `docs/path-and-pull-dsl.md`
- [ ] Task: Add test suite and verify Step 2
    - [ ] Create `test/xitdb/pull_compile_test.exs` covering inclusive bounds, zero-length slices, and invalid/empty nested patterns (`Pull.compile/1` and `Pull.compile!/1`)
    - [ ] Verify existing test assertions in the test suite for pull range bounds
    - [ ] Run `mix test test/xitdb/pull_compile_test.exs` and verify Green

---

## Phase 4B: Cursor Internal Deduplication, Stepped Slices & Inspect Polish (Step 4 Deferred)

- [ ] Task: Deduplicate cursor construction and `fetch/2` in `lib/xitdb/cursor.ex`
    - [ ] Extract `from_nif_tuple/4`, `unwrap_nif_value/4`, `nif_slot_get/2` (resolving `tag_id: -1` before integer index lookups), and `lookup_staged/2`
    - [ ] Consolidate read and transaction `fetch/2` clauses
- [ ] Task: Fix stepped `Enumerable.slice/1` and atom creation in `Inspect`
    - [ ] Calculate exact slice span `(length - 1) * step + 1` in `Enumerable.slice/1`
    - [ ] Filter raw items via `Enum.take_every/2` before cursor wrapping; handle `length <= 0` slices immediately
    - [ ] Create `Xitdb.Cursor.PreviewTag` struct to avoid dynamic atom creation in `Inspect.Xitdb.Cursor`
    - [ ] Implement `try_resolve/1` to format unresolved cursors (`#Xitdb.Cursor<unresolved (...)>`) without crashing
- [ ] Task: Add test suite and run full precommit verification
    - [ ] Create `test/xitdb/cursor_refactor_test.exs` testing access pipeline, unresolved root integer indexing, stepped slicing, and preview inspect
    - [ ] Run `mix test test/xitdb/cursor_refactor_test.exs` and verify Green
    - [ ] Run full project verification: `mix precommit` (`mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`)
