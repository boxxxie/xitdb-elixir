# Specification: Integrate `ExFuzz` Coverage-Guided Fuzz Testing

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ex_fuzz_coverage_fuzzing_20261118`
> - **Type:** `chore`
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Files:** `mix.exs`, `test/fuzz/*.exs`, `test/fixtures/fuzz/**`, `lib/xitdb/ash/search.ex`, `lib/xitdb/selector.ex`, `lib/xitdb/sigils.ex`, `lib/xitdb/pull.ex`, `lib/xitdb/ash/codec.ex`
> - **Done When:** `{:ex_fuzz, "~> 0.1.0", only: [:dev, :test]}` is configured in `mix.exs`, all three fuzz target groups (Core Parsers/Codecs, NIF Boundary & Search Parity, and Bytecode-Driven Stateful Cursor/Tx) execute cleanly under `mix fuzz`, uncovered Elixir crashes/inconsistencies are fixed with saved regression inputs in `test/fixtures/fuzz/`, and `mix precommit` passes with zero warnings.

---

## 1. Goal & Motivation

[`xitdb-elixir`](../../../mix.exs) already validates structured domain invariants with `StreamData` (`ExUnitProperties`) across [`client_roundtrip_properties_test.exs`](../../../test/features/client_roundtrip_properties_test.exs), [`macro_dsl_properties_test.exs`](../../../test/features/macro_dsl_properties_test.exs), [`codec_properties_test.exs`](../../../test/xitdb/ash/codec_properties_test.exs), and [`indexer_and_search_properties_test.exs`](../../../test/xitdb/ash/indexer_and_search_properties_test.exs). Those property generators sample clean `:printable` / `:alphanumeric` strings for ~35–100 blind iterations without branch coverage feedback.

Adding coverage-guided fuzz testing via Hex [`ex_fuzz`](https://hex.pm/packages/ex_fuzz) (`~> 0.1.0`, `:dev` and `:test` only) provides:
1. **BEAM clause-coverage feedback** (`ExFuzz.Instrument` + LibAFL havoc mutation) to drive Elixir parsers, escapers, tokenizers, and state-machine interpreters into unhandled edge cases—including invalid UTF-8, embedded NUL bytes, unbalanced quoting/brackets, and adversarial transaction sequences.
2. **Automatic regression persistence:** Crashing/failing inputs discovered during `mix fuzz` campaigns are written to `test/fixtures/fuzz/` and replayed deterministically during normal `mix test` / `mix precommit`, while `mix fuzz` itself is only invoked on demand.

As an immediate example already visible by inspection, [`Xitdb.Ash.Search.tokenize/1`](../../../lib/xitdb/ash/search.ex#L186-L192) pipes raw binaries directly from `:unicode.characters_to_nfc_binary/1` (which returns `{:error, ...}` or `{:incomplete, ...}` on malformed UTF-8) into `String.downcase/1`, raising `FunctionClauseError`.

---

## 2. Scope & Architecture Constraints

### 2.1 Dependency & Package Hygiene
- Add `{:ex_fuzz, "~> 0.1.0", only: [:dev, :test]}` to `deps/0` in `mix.exs` using the Hex release (precompiled NIFs via `RustlerPrecompiled`, avoiding a mandatory `:rustler` build dependency in `xitdb`).
- Keep `ex_fuzz` out of `:prod` and out of the published Hex `package/0` runtime dependencies.
- Keep `test/fixtures/fuzz/` committed as regression seeds (matching `xitdb`'s `test_load_filters: [~r/_(test|spec)\.exs$/]` so extensionless seed files are loaded only by `ExFuzz`), while `_build/ex_fuzz/` (coverage corpus cache and `erl_crash.dump`) remains git-ignored via `/_build/` in `.gitignore`.
- Verify compatibility with `xitdb`'s OTP runtime (OTP 28 currently, and OTP 29 if [`elixir_1_20_upgrade_20261118`](../elixir_1_20_upgrade_20261118/spec.md) lands concurrently) and `test/test_helper.exs` (`Xitdb.Cursor.register_beam_tracer/0`, `Xitdb.Ash.TestSandbox`).

### 2.2 Known `ExFuzz` Boundaries (Explicit Guardrails)
- **Single input generator (`data <- binary()`):** `ExFuzz` only generates raw binaries (`<= 4096` bytes by default). Structured/multi-argument targets decode or split `data` deterministically inside the fuzz block.
- **BEAM-only instrumentation:** `ExFuzz.Instrument` rewrites BEAM `:debug_info` forms and does **not** instrument native Odin code inside `priv/xitdb_nif.so`. Furthermore, if a raw NIF call triggers a `SIGSEGV`, `ExFuzz.Coordinator` terminates with `{:node_down, {:exit_status, 139}}` and writes `_build/ex_fuzz/erl_crash.dump` without saving the offending input via `ExFuzz.Corpus`. Native Odin fuzzing remains out of scope for `ex_fuzz`.

---

## 3. Functional Requirements

### 3.1 Group 1: Core Elixir Parsers, Escapers & Codecs (`test/fuzz/parsers_and_codecs_fuzz_test.exs`)
All targets run with `async: true` and curated `:seeds`:
1. **`Xitdb.Selector` & `Xitdb.Sigils`:**
   - Fuzz `Selector.parse_selector_steps(data, true)` and `Selector.normalize_root_or_steps(data)` — must either return normalized steps or raise `ArgumentError` (never `FunctionClauseError`, `MatchError`, or hang).
   - Verify round-trip escaping: for any valid UTF-8 string key `k` (or arbitrary non-nil/non-boolean binary key), `Selector.format_step(:hash_map, k) |> Selector.parse_selector_steps()` returns `[{:hash_map, k}]`.
   - Fuzz `Sigils.validate_selector!/1` and `Sigils.validate_datalog!/1` — must only return canonical trimmed strings or raise `ArgumentError`, and delimiter validation must remain consistent with `Selector.parse_selector_steps/2`.
2. **`Xitdb.Pull`:**
   - Fuzz `Pull.compile(data)` and `Pull.split_wildcard_plan(data)` — must cleanly return `{:ok, _}` / plan tuples or `{:error, %Xitdb.Error{}}` / `ArgumentError` without unexpected exceptions or hangs.
3. **`Xitdb.Ash.Search.tokenize/1`:**
   - Fuzz `Search.tokenize(data)` across arbitrary byte sequences (invalid UTF-8, NUL bytes, combining marks, punctuation) — must return a list of normalized binary tokens without raising `FunctionClauseError` or retaining oversized binary references.
4. **`Xitdb.Ash.Codec` Binary Key Escaping & Doc ID Round-Trips:**
   - Fuzz `Codec.encode_doc_id/1` + `Codec.decode_doc_id/2` across `:string`, `:ci_string`, `:uuid`, and `:integer` PK test resources.
   - Split `data` into `(bin_a, bin_b)` and fuzz `Codec.encode_index_key/2` on composite `[:string, :integer]` / `[:binary, :integer]` attributes (`escape_null_terminated/1`), asserting strict lexicographic order preservation and zero collisions across interior `0x00`/`0xFF` bytes.

### 3.2 Group 2: NIF Boundary & `:nif` vs `:elixir` Search Backend Parity (`test/fuzz/nif_boundary_and_search_fuzz_test.exs`)
1. **NIF Boundary Safety (`Xitdb.select/2`, `Xitdb.pull/3`, `Xitdb.query/3`, `Xitdb.history_of/2`, `Xitdb.transact_ops/2`):**
   - Fuzz string/binary arguments against a small seeded `:memory` database (closed in `after`) to ensure Elixir validation and the NIF boundary return `{:ok, _}` or `{:error, %Xitdb.Error{}}` (or `ArgumentError` from Elixir validators) without unhandled Erlang/Elixir crashes, timeouts, or VM segfaults.
2. **BM25 Search Backend Parity (`backend: :nif` vs `backend: :elixir`):**
   - Split `data` into document text payloads and a query string, index into an isolated Ash/Xitdb `:memory` store (or `TestSandbox` checkout), and assert `Search.query(Resource, query_text, backend: :nif, ...)` and `Search.query(Resource, query_text, backend: :elixir, ...)` agree on matched IDs and score ordering across arbitrary tokenization edge cases.

### 3.3 Group 3: Bytecode-Driven Stateful `Cursor` / `Tx` Fuzzing (`test/fuzz/cursor_state_machine_fuzz_test.exs`)
- Interpret `data <- binary()` as a bounded sequence of bytecode operations against an in-memory `%Xitdb{}` (and periodic `:file` / `compact/2` branches) paired with a pure Elixir reference model (`%{moments: [map_state, ...]}`):
  - Map/list mutations (`put`, `update_in`, `pop_in`, `rm`, `merge_map`, `append`, `insert_at`, `delete_at`, `slice`).
  - Historical reads (`Xitdb.as_of/2`), `Xitdb.select/2`, `Xitdb.pull(db, "*")`, `Xitdb.diff_moments/3`, `Xitdb.materialize/1`, and `Xitdb.compact/2`.
- Assert after transactions and across historical moments that lazy `Access` lookups, `select`, `pull`, and `materialize` match the Elixir oracle.

### 3.4 Bug Remediation & Campaign Verification
- Run bounded `mix fuzz` campaigns (`--max-time` / `--max-runs`) on every fuzz test.
- Fix any Elixir parser, tokenizer, codec, or cursor bugs uncovered during the initial fuzz runs (starting with `Xitdb.Ash.Search.tokenize/1` on malformed UTF-8) and keep failing inputs (or fixed regression seeds) verified in `test/fixtures/fuzz/` so `mix test` and `mix precommit` pass 100% green.

---

## 4. Acceptance Criteria

1. `mix.exs` includes `{:ex_fuzz, "~> 0.1.0", only: [:dev, :test]}` and configures `:ex_fuzz` cleanly without affecting `:prod` or Hex package artifacts.
2. All three fuzz test files exist under `test/fuzz/*_fuzz_test.exs` with curated `:seeds` and execute cleanly under `mix test --only fuzz` and `mix fuzz <file>:<line> --max-runs ...`.
3. Bounded `mix fuzz` campaigns complete across every target without unfixed Elixir crashes, hangs, or parity mismatches; all uncovered Elixir bugs (including non-UTF-8 handling in `Xitdb.Ash.Search.tokenize/1`) are fixed with regression tests/seeds in `test/fixtures/fuzz/`.
4. `mix precommit` (`mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`) passes with zero warnings and zero failures.
5. `AGENTS.md` / `README.md` (or `docs/`) briefly documents how to run `mix fuzz` campaigns locally.

---

## 5. Out of Scope

- Native Odin coverage-guided fuzzing (`libFuzzer`/`AFL++`) inside `native/xitdb_nif.odin` or `native/xitdb-odin/xitdb/*.odin` (`native/xitdb-odin` remains read-only).
- Replacing existing `StreamData` (`ExUnitProperties`) suites.
- Long-running continuous fuzzing in GitHub Actions PR checks (PR CI runs `mix test` / `mix precommit`, which replays `:seeds` and `test/fixtures/fuzz/`).
