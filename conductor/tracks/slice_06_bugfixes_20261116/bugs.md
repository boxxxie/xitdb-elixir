---
worktree: 06-bench-baseline-and-docs
branch: chore/06-bench-baseline-and-docs
head_sha: c08a2a5
slice_base_sha: 7b8e1f7
upstream_branch: feat/05-bench-27-28-and-guardrails
bug_count: 7
severities:
  critical: 0
  high: 5
  medium: 2
  low: 0
---

# Bug Reference — `06-bench-baseline-and-docs` (`chore/06-bench-baseline-and-docs`)

| ID | Severity | Category | Primary Files | Summary |
| :--- | :--- | :--- | :--- | :--- |
| `BUG-06-01` | `high` | `docs-baseline` | `docs/access-and-enumerable.md` | Documents nonexistent `Xitdb.Ash.Search.scan_prefix/5`, `scan_prefix_cursors/4`, and 5-arity `from_compact_slot/5` |
| `BUG-06-02` | `high` | `docs-baseline` | `docs/access-and-enumerable.md`, `usage-rules.md`, `lib/xitdb.ex`, `lib/xitdb/dsl/tx_rewriter.ex` | Misstates `path_steps/1` term shape and C function name, omits `Xitdb.path_steps/1`, and recommends unsupported `tx` `insert path_steps(...)` |
| `BUG-06-03` | `medium` | `docs-baseline` | `docs/transaction-dsl.md` | Falsely claims `put_in/3` crosses the NIF boundary on every hop and raises on missing intermediate maps |
| `BUG-06-04` | `high` | `docs-baseline` | `benchmarks/README.md`, `benchmarks/*.jsonl` | Stale `-dirty` baselines fail `--require-clean`, all 28 NIF source links are off by up to 596 lines, and deleted SHAs remain rendered |
| `BUG-06-05` | `medium` | `docs-baseline` | `benchmarks/slices/*.md`, `benchmarks/compare_1v1.py` | Six slice docs omit `!`/`?` Elixir functions (`select!`, `member?`, `pull!`, `info!`) and `lib/xitdb/nif.ex` |
| `BUG-06-06` | `high` | `cursor-semantics` | `native/xitdb_nif.odin`, `lib/xitdb/cursor.ex`, `lib/xitdb.ex` | Regressions in `2796eb9`/`c08a2a5`/`687a2c2`: `.users#alice["a.b"]` rewrite, explicit `{__tx}` pull blocked, torn root snapshots, `inspect` crash |
| `BUG-06-07` | `high` | `cross-slice-conflict` | `lib/xitdb.ex`, `lib/xitdb/cursor.ex`, `lib/xitdb/ash/*`, `native/xitdb_nif.odin`, `benchmarks/bench_client.odin` | Misplaced code patches diverge from Slices 01–05 and leave upstream critical/high bugs unfixed here |

---

## Likely Bugs

### `BUG-06-01`: `docs/access-and-enumerable.md` documents nonexistent public `Xitdb.Ash.Search` functions and wrong `from_compact_slot` arity
- **Severity:** `high` | **Confidence:** `high` | **Category:** `docs-baseline` | **Scope:** `this-slice`
- **Introduced In:** `da1b118`
- **Files:** `docs/access-and-enumerable.md:195-196`, `lib/xitdb/ash/search.ex:713`, `lib/xitdb/ash/search.ex:745`, `lib/xitdb/cursor.ex:244`
- **Symbols:** `Xitdb.Ash.Search.Storage.scan_prefix/5`, `Xitdb.Ash.Search.Storage.scan_prefix_cursors/4`, `Xitdb.Cursor.from_compact_slot/4`
- **Verify With:** `mix docs`

**Explanation:** Lines 195–196 document `Xitdb.Ash.Search.scan_prefix/5` and `Xitdb.Ash.Search.scan_prefix_cursors/4`, neither of which exists on `Xitdb.Ash.Search` (both live on `@moduledoc false` internal `Xitdb.Ash.Search.Storage`, so calling them raises `UndefinedFunctionError`). Line 196 also cites `from_compact_slot/5`, whereas `Xitdb.Cursor.from_compact_slot/4` is 4-arity (`@doc false`).

**Fix Hint:** Reference the actual public search entrypoints (`Xitdb.Ash.Search.query/3` / `ids/3`) or internal `Xitdb.Ash.Search.Storage` accurately, and fix `from_compact_slot/5` to `from_compact_slot/4` (or describe compact cursor wrapping conceptually).

---

### `BUG-06-02`: Inaccurate `path_steps/1` documentation, missing `Xitdb.path_steps/1` re-export, and broken `tx` `insert path_steps(...)` example
- **Severity:** `high` | **Confidence:** `high` | **Category:** `docs-baseline` | **Scope:** `this-slice`
- **Introduced In:** `f768876` / `da1b118`
- **Files:** `docs/access-and-enumerable.md:188`, `docs/access-and-enumerable.md:209`, `usage-rules.md:20`, `usage-rules.md:166`, `lib/xitdb.ex:25-72`, `lib/xitdb/dsl/tx_rewriter.ex:375-393`
- **Symbols:** `Xitdb.DSL.PathCompiler.compile_steps/1`, `Xitdb.DSL.TxRewriter.split_insert_target!/2`, `Xitdb.history_of/2`
- **Verify With:** `mix test test/xitdb/dsl/path_compiler_test.exs`

**Explanation:** `docs/access-and-enumerable.md` and `usage-rules.md` contain four factual errors about `path_steps/1`: (1) `path_steps(users[id].name)` compiles to bare `["users", id, "name"]`, not 2-tuples `[{:hash_map, "users"}, ...]`; (2) `decode_steps_term_buf` is an Odin function (the C helper is `nif_unpack_step_list`); (3) `Xitdb.history_of/2` already accepts `path_steps/1` lists directly rather than requiring strings; and (4) `lib/xitdb.ex` omits `defmacro path_steps(expr)` alongside `path/1`, while `insert path_steps(todos[[0]]), "x"` inside `tx` raises `CompileError` in `TxRewriter.split_insert_target!/2`.

**Fix Hint:** Correct the compiled step-list example, C/Odin function names, and `history_of/2` note in `docs/access-and-enumerable.md` and `usage-rules.md`, add `defmacro path_steps(expr)` to `Xitdb` if `path_steps/1` is meant to mirror `path/1`, and either unwrap `path_steps(...)` in `TxRewriter` or stop recommending it inside `tx` `insert`.

---

### `BUG-06-03`: `docs/transaction-dsl.md` directly contradicts Slice 01 virtual write cursors
- **Severity:** `medium` | **Confidence:** `high` | **Category:** `docs-baseline` | **Scope:** `this-slice`
- **Introduced In:** `f768876`
- **Files:** `docs/transaction-dsl.md:5-6`
- **Symbols:** `Xitdb.Cursor.get_and_update/3`
- **Verify With:** `mix test test/xitdb/cursor_refactor_test.exs`

**Explanation:** `docs/transaction-dsl.md` states that `put_in(root["users"][id]["profile"]["city"], "NYC")` crosses the NIF boundary on every hop and raises if `root["users"][id]` does not yet exist. With Slice 01 virtual write cursors (`value: -2`), nested `put_in` executes zero NIF reads and stages missing intermediate maps automatically, contradicting `docs/access-and-enumerable.md` and `usage-rules.md`.

**Fix Hint:** Update `docs/transaction-dsl.md:5-6` to reflect virtual write cursors while noting why `tx` blocks remain faster when mutating multiple paths or calling collection ops like `append`/`fork`.

---

### `BUG-06-04`: Stale `-dirty` benchmark baselines fail `--require-clean`, shift all 28 NIF source links, and orphan Section 4 / doc latencies
- **Severity:** `high` | **Confidence:** `high` | **Category:** `docs-baseline` | **Scope:** `this-slice`
- **Introduced In:** `f768876` / `ef0d7e0`..`c08a2a5`
- **Files:** `benchmarks/odin.jsonl:1-28`, `benchmarks/elixir.jsonl:1-28`, `benchmarks/history.jsonl:1-156`, `benchmarks/README.md:71-77`, `benchmarks/README.md:114-141`, `benchmarks/README.md:213-280`, `docs/access-and-enumerable.md:180-200`, `usage-rules.md:18-22`
- **Symbols:** `compare_1v1.py`, `update_readme.sh`
- **Verify With:** `./benchmarks/compare_1v1.py --from-jsonl --require-clean`

**Explanation:** Committed `odin.jsonl` and `elixir.jsonl` are stamped `"2d035bd8a9f7-dirty"` from before `ef0d7e0`..`c08a2a5` modified `#28` in `bench_client.odin` and ~600 lines across `native/xitdb_nif.odin`. Running `compare_1v1.py --from-jsonl --require-clean` exits with code `2` due to CV > 15% on `#5`, `#6`, and `#20`, every `[odin_nif_*]` and `#28` source line link in `benchmarks/README.md` is shifted (up to 596 lines off), and `ef0d7e0` pruned commits `8613b812837b` / `bdd61917a709` from `history.jsonl` while leaving Section 4 and prose latencies citing them.

**Fix Hint:** After rebasing onto clean Slices 01–05 with zero uncommitted edits, re-run `./benchmarks/compare_1v1.py --runs 5 --warmup 1 --require-clean`, regenerate slices (`--generate-slices`), re-run `./benchmarks/update_readme.sh`, and sync prose latency citations to the new baseline.

---

### `BUG-06-05`: Six benchmark slice files omit primary Elixir `!`/`?` functions and `lib/xitdb/nif.ex`
- **Severity:** `medium` | **Confidence:** `high` | **Category:** `docs-baseline` | **Scope:** `this-slice`
- **Introduced In:** `f768876` / `da1b118`
- **Files:** `benchmarks/slices/02_access_single_call_selector_select_users_id_name.md`, `benchmarks/slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md`, `benchmarks/slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md`, `benchmarks/slices/24_storage_buffered_file_transact_sync_50_commits.md`, `benchmarks/slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md`, `benchmarks/slices/28_access_pre_tokenized_path_steps_select_path_steps_users_id_name.md`, `benchmarks/compare_1v1.py:1025-1035`
- **Symbols:** `parse_elixir_lib_functions`, `extract_enclosing_procs`
- **Verify With:** `./benchmarks/compare_1v1.py --from-jsonl --generate-slices`

**Explanation:** In WT 06's un-rebased copy of `compare_1v1.py`, `parse_elixir_lib_functions()` uses trailing `\b` after `[a-zA-Z0-9_?!]*`, which fails to match `select!`, `member?`, `pull!`, and `info!` (leaving slice `#07` with zero Elixir functions) and omits `lib/xitdb/nif.ex` (`nif_bm25_search` missing from `#26`).

**Fix Hint:** Rebase onto Slice 05 (`86bdd17`) which fixes `!`/`?` matching, verify `"lib/xitdb/nif.ex"` is scanned by `parse_elixir_lib_functions()`, and regenerate `benchmarks/slices/*.md`.

---

### `BUG-06-06`: Regressions introduced by WT 06 code patches (`2796eb9`, `c08a2a5`, `687a2c2`) in `native/xitdb_nif.odin`, `cursor.ex`, and `lib/xitdb.ex`
- **Severity:** `high` | **Confidence:** `high` | **Category:** `cursor-semantics` | **Scope:** `cross-slice-conflict`
- **Introduced In:** `687a2c2` / `2796eb9` / `c08a2a5`
- **Files:** `native/xitdb_nif.odin:1948-1957`, `native/xitdb_nif.odin:5097-5122`, `native/xitdb_nif.odin:1233-1573`, `lib/xitdb/cursor.ex:1430-1666`, `lib/xitdb.ex:688-706`
- **Symbols:** `parse_escaped_steps_buf`, `nif_pull_cursor`, `odin_nif_slot_count`, `odin_nif_slot_slice`, `odin_nif_slot_entries`, `Xitdb.effective_moment/2`, `Xitdb.root_selector?/1`, `Inspect.Xitdb.Cursor.inspect/2`
- **Verify With:** `mix test test/xitdb/cursor_refactor_test.exs test/xitdb/nif_safety_test.exs`

**Explanation:** Three regressions were introduced by WT 06's own code commits: (1) `2796eb9` (`parse_escaped_steps_buf:1948-1957`) unconditionally sets `prev_was_sigil = true`, rewriting canonical `.users#alice["a.b"]` into `.users.alice#["a.b"]` and breaking nested `Hash_Map` reads/writes inside `Counted_Hash_Map`/`Sorted_Map`; (2) `c08a2a5` (`nif_pull_cursor:5097,5120`) blocks explicit `Xitdb.pull(db, "{__tx{doc}}")` and hides user `"__tx"` keys on non-`Hash_Map` roots, while `Xitdb.db(db)` root cursors drop their pinned slot on `Enum`/`materialize`/`pull` (tearing reads under concurrent commits) and crash `inspect(Xitdb.db(db))` after `Xitdb.close(db)` with unhandled `Xitdb.Error(:closed)`; (3) `effective_moment/2` and `root_selector?/1` (`687a2c2`) fail on leading whitespace `" @0"`.

**Fix Hint:** Gate sigil-to-bracket shifting strictly on root bare `#col["k"]` / `$col["k"]`, allow explicit `"__tx"` in `nif_pull_cursor` Pass 2, restrict `"__tx"` hiding to `.Hash_Map` moment roots, pin resolved `moment` in `as_of(db, -1)`, rescue `Xitdb.Error` in `Inspect`, and `String.trim_leading/1` before `@` matching—applying these cleanly in Slices 01–03 rather than WT 06.

---

### `BUG-06-07`: Misplaced cross-slice code commits in WT 06 leave upstream Slices 01–05 bugs unfixed and cause 3-way rebase conflicts
- **Severity:** `high` | **Confidence:** `high` | **Category:** `cross-slice-conflict` | **Scope:** `cross-slice-conflict`
- **Introduced In:** `ef0d7e0` / `687a2c2` / `2796eb9` / `c08a2a5`
- **Files:** `lib/xitdb/cursor.ex`, `lib/xitdb.ex`, `lib/xitdb/ash/indexer.ex`, `lib/xitdb/ash/search.ex`, `native/xitdb_nif.odin`, `native/nif_entry.c`, `benchmarks/bench_client.odin`, `test/xitdb/ash/search_nif_test.exs`, `test/xitdb/cursor_refactor_test.exs`, `test/xitdb/nif_safety_test.exs`
- **Symbols:** `Cursor.get_and_update/3`, `Indexer.Storage.stream_btree_from_key/2`, `Search.Storage.scan_prefix_cursors/4`, `slot_to_term`, `merge_node_into_cursor`, `odin_nif_transact`
- **Verify With:** `git log --oneline 7b8e1f7..HEAD`

**Explanation:** Commits `ef0d7e0`, `687a2c2`, `2796eb9`, and `c08a2a5` landed code fixes inside Slice 06 (`chore/06-bench-baseline-and-docs`) while Slices 01–05 received conflicting fixes. As a result, WT 06 still suffers from un-rebased upstream bugs (`2^D` `invoke_virtual_or_fallback` probing, unvalidated `tx_mode` integer/string keys, `:merge_map` failure on existing `Counted_Hash_Map`/`Sorted_Map`, missing `MAX_WRITE_DEPTH` stack-overflow guard, `0..15` & `slot.full` `.Bytes` header/EOF reads, normal-scheduler `nif_sorted_map_seek/7`, eager 7-arity `Indexer` B+Tree seek, and `6cef6c6` `path_steps` bounds/quote-hygiene omissions) and will 3-way conflict on rebase.

**Fix Hint:** Port the genuinely unique fixes from WT 06 (`resolve_list_key` + staged `[idx]` counts, pinned root snapshots / root `"__tx"` count-slice-entry adjustments, `ef0d7e0` `#28` loop parity) back into Slices 01–05, then drop code hunks from WT 06 when rebasing onto `feat/05-bench-27-28-and-guardrails`.

---

## Upstream Stack & Rebase Notes

- Worktree `06-bench-baseline-and-docs` is anchored at `7b8e1f7` (initial Slice 05 commit) and needs full reconciliation with `43a62d0` (Slice 01), `de134a7` (Slice 02), `6cef6c6` (Slice 03), `11ff6f3` + `2883a38` (Slice 04), and `86bdd17` (Slice 05).
- Once Slices 01–05 incorporate the valid fixes currently parked in `ef0d7e0..c08a2a5`, rebase `chore/06-bench-baseline-and-docs` to contain only documentation updates, regenerated slices, and clean benchmark baselines.
