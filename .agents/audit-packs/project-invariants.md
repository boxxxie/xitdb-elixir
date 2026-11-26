# Project Domain & Architecture Invariants

## 1. High-Signal Domain Invariants (Scout Focus)
- **No success-shaped fallbacks (`Xitdb.Fallback`):** Flag ad-hoc `rescue`/`catch` blocks returning `:ok`, `nil`, or `[]`, `_ -> :ok` catch-alls, or silent defaults bypassing `Xitdb.Fallback.run/2,3` or `Xitdb.Fallback.try_run/3,4`. Zero fallbacks are allowed on write, transaction (`Xitdb.transact/3`, `Xitdb.TxCompiler`, `Xitdb.DSL.tx`), NIF, lock/lease-fencing, compaction, or `Xitdb.Ash.Mutator` paths.
- **Single-writer & immutable CoW invariants:** Never mutate `%Xitdb{}` outside `Xitdb.transact/3` or `tx`; concurrent writers must serialize through `Xitdb.Ash.Store` or a single owner `GenServer`.
- **Odin NIF memory & bounds safety:** Every `proc "c"` NIF entrypoint in `native/xitdb_nif.odin` using `context.temp_allocator` must initialize `context = runtime.default_context()` and call `defer free_all(context.temp_allocator)`. Parsers/decoders for compressed/columnar/NIF payloads must enforce explicit length/depth bounds before allocating.
- **Integer bounds:** Xitdb `Tag.Uint` rejects values `> max(i64)`; full `u64` requires `Xitdb.Ash.Types.UnsignedInteger` or `{:tagged, "u8", <<n::unsigned-big-64>>}`.

## 2. Project False-Positive Kill List (Do NOT Flag)
- **Allowlisted boundary modules in `.credo.exs`:** Do NOT flag intentional exception-to-`{:error, %Xitdb.Error{}}` or low-level `:zlib`/ETS/`GenServer`/protocol boundaries in `lib/xitdb/fallback.ex`, `lib/xitdb.ex`, `lib/xitdb/pull.ex`, `lib/xitdb/cursor.ex`, `lib/xitdb/compression.ex`, `lib/xitdb/dsl/tx_rewriter.ex`, `lib/xitdb/ash/store.ex`, `lib/xitdb/ash/test_sandbox.ex`, and `lib/xitdb/ash/types/ranged_unit.ex`.
- **Observe-and-reraise telemetry/cleanup spans:** Do NOT flag `rescue`/`catch` blocks whose every clause terminates in `reraise` or `:erlang.raise/3` (e.g. `lib/xitdb/ash/mutator.ex`).
- **Caller-owned Odin arenas:** Do NOT flag procedures in `native/xitdb-odin/` that allocate into an explicit caller-owned allocator/arena.

## 3. Repo Anchor Symbols
- **Elixir / Ash:** `Xitdb`, `Xitdb.Cursor`, `Xitdb.Fallback`, `Xitdb.Compression`, `Xitdb.Ash.Store`, `Xitdb.Ash.DataLayer`, `Xitdb.Ash.Mutator`, `Xitdb.Ash.Query`.
- **Odin NIF:** `native/xitdb_nif.odin`, `native/nif_entry.c`, `native/xitdb-odin/xitdb`.

## 4. Repo Test & Build Notes
- **Verification:** `odin check native -no-entry-point -collection:xitdb=native/xitdb-odin/xitdb`, `mix precommit` (includes `credo --strict`), `MIX_ENV=prod mix compile --warnings-as-errors`.
