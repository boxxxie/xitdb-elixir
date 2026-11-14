# Implementation Plan: Track 15 — Ash DataLayer Phase 1 Verification Suite

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_phase1_verification_suite_20261111`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Done When:** All property invariants and 4-layer ATDD scenarios pass with zero compiler warnings under `mix do format --check-formatted + compile --warnings-as-errors + test`.

---

## Phase 1: Mutator/Sandbox Pre-Checks, Dependencies & Support Infrastructure

- [x] Task: Verify and align `Mutator`, `Store`, and `TestSandbox` invariants
    - [x] Verify `lib/xitdb/ash/mutator.ex` (`build_updated_record/4` and `verify_atomic_validations/4`) evaluates `changeset.atomics` against pre-update `current_record` first, substitutes `{:_atomic_ref, field}` against `post_record`, and falls back to `Ash.Filter.Runtime.filter_matches/4` when `Ash.Expr.eval/2` returns `:unknown`
    - [x] Verify `Xitdb.Ash.Store.mutate/3` detects active `{db, moment}` caller transactions via `in_transaction?/1` (`{:xitdb_tx_state, store}`) in both sandbox and non-sandbox modes so `after_action` hooks (`Organization.rename_and_reindex`) never self-deadlock
    - [x] Verify `Xitdb.Ash.TestSandbox.checkout/2` (`checkin/2` / `Coordinator.terminate/2`) clones baseline state via `Xitdb.compact!/1` and closes isolated `:memory` `%Xitdb{}` handles on re-checkout so `StreamData` property loops never leak unclosed NIF handles
- [x] Task: Update `mix.exs`
    - [x] Add `{:ash_phoenix, "~> 2.1", only: :test}`, preserve Track 14's `{:simple_sat, "~> 0.1", only: :test}`, and keep `{:stream_data, "~> 1.1", optional: true}` (matching `ash`'s dependency requirement)
    - [x] Configure `elixirc_paths(:test)` to include `["lib", "test/support"]`
    - [x] Configure `cli: [preferred_envs: [precommit: :test]]` and define `aliases/0` with `precommit: ["format --check-formatted", "compile --warnings-as-errors", "test"]`
- [x] Task: Update `test/test_helper.exs`
    - [x] Initialize `Xitdb.Ash.TestSandbox.init()`
    - [x] Start in-memory dual stores (`MdmStore`, `AppStore`) with corresponding domains
- [x] Task: Implement `test/support/ash_case.ex`
    - [x] Define `Xitdb.FeatureScenario` with `scenario/2` macro and step line attribution
    - [x] Define `Xitdb.AshCase` ExUnit CaseTemplate with `TestSandbox.checkout/2`
- [x] Task: Implement `test/support/ash_test_domain.ex`
    - [x] Define stores: `MdmStore` and `AppStore`
    - [x] Define validation: `NoConsumerEmailDomain` with `validate/3` and pure `^atomic_ref(:email)` `atomic/3` expression, scoped via `where: [changing(:email)]` on `MemberProfile`
    - [x] Define resources: `Organization`, `MemberProfile` (including atomic `:change_email` update action), `Event`, `AgendaSession`, `TableTalkSeat`, `DirectMessage`
    - [x] Define domains: `MdmDomain` and `AppDomain` with full code interfaces

---

## Phase 2: Pattern D & E Properties & Storage Invariant Suites

- [x] Task: Implement `test/xitdb/ash/codec_properties_test.exs`
    - [x] Property: `encode_i64_be/1` signed ordering across 64-bit boundaries
    - [x] Property: `encode_f64_be/1` IEEE-754 ordering and `-0.0/+0.0` normalization
    - [x] Property: `encode_decimal_key/1` scale invariance and decimal ordering
    - [x] Property: Composite secondary index keys escaping interior NUL bytes
    - [x] Property: Tenant-scoped composite identity keys collision prevention
- [x] Task: Implement `test/xitdb/ash/indexer_and_search_properties_test.exs`
    - [x] Property: BM25 corpus stats (`doc_count`, `total_len`) invariant under upsert/delete streams without NIF handle leaks on re-checkout
    - [x] Invariant: Event deletion purges nested `AgendaSession` locators, identities, and search indexes, and releases `on_delete: :restrict` on `other_org` so `MdmDomain.destroy_organization!(other_org)` succeeds
    - [x] Invariant: `VerifyNoSqlFragments` rejects SQL fragment calculations at compile time (paired with throwaway `Domain#{uid}` inside `Code.compile_string`)
    - [x] Invariant: `VerifyCrossStoreReferences` rejects cross-store cascading deletes at compile time (paired with throwaway `Domain#{uid}` inside `Code.compile_string`)

---

## Phase 3: 4-Layer ATDD Protocol Driver & DSL

- [x] Task: Implement Layer 3 Protocol Driver in `test/support/drivers/workspace_driver.ex`
    - [x] Encapsulate organization, member, and atomic `change_member_email/3` domain code interfaces
    - [x] Encapsulate `confirmed_seat_numbers/1` using `Ash.Query.filter(session_id == ^session_id and status == :confirmed)`
    - [x] Encapsulate search query wrapper with `Search.ids/3` and `Search.sort_by_rank/2`
    - [x] Encapsulate bulk archive and prune operations
    - [x] Encapsulate savepoint nested transaction execution (`Store.transact/3`)
    - [x] Encapsulate `AshPhoenix.Form` create/update workflows
- [x] Task: Implement Layer 2 Domain-Specific Language in `test/support/dsl/workspace_dsl.ex`
    - [x] Define `%World{}` struct tracking test ID, resources, and execution results
    - [x] Implement `@given` steps (`firm`, `member`, `direct_message`, `conference_event`, `confirmed_seat`)
    - [x] Implement `@upon` steps (`updating_profile_headline`, `changing_member_email`, `viewing_profile_counter`, `cancelling_and_reassigning_seat`, `attempting_duplicate_seat`, `reserving_with_aborted_nested_savepoint`, `renaming_firm`, `searching_directory`, `archiving_and_pruning_inbox`, `submitting_membership_form`)
    - [x] Implement `@then` assertion macros with `line: __CALLER__.line` attribution, delegating `confirmed_seats_for_session/3` to `WorkspaceDriver.confirmed_seat_numbers/1` and asserting `expected_field` against `error.errors` in `action_fails_with_invalid_field/3`

---

## Phase 4: Layer 1 Executable Specifications

- [x] Task: Implement `test/features/ash_data_layer_workflows_test.exs`
    - [x] Scenario 1: Row-level read filters, field policies, and atomic write authorization
    - [x] Scenario 2: Cross-store exists filters, calculations, atomic counters, and bulk inbox pruning (verifying pre-prune `sent_messages: 2` and `["Elena Rostova"]` before pruning, then `0` and `[]` after pruning)
    - [x] Scenario 3: Nested sessions, portable expression calculations, partial seat identities, and savepoint rollbacks
    - [x] Scenario 4: In-Xitdb BM25 + prefix search resolves firm mandates onto profiles without denormalized columns (using `"Boreal Credit Partners"` for deterministic boost ranking)
    - [x] Scenario 5: `AshPhoenix.Form` and atomic `:change_email` updates enforce corporate-domain validation (`NoConsumerEmailDomain.validate/3` + `atomic/3`) and persist valid corporate emails

---

## Phase 5: Verification & CI Readiness

- [x] Task: Run full verification suite
    - [x] Format check: `mix format --check-formatted`
    - [x] Compile check: `mix compile --warnings-as-errors`
    - [x] Property tests: `mix test test/xitdb/ash/*_properties_test.exs`
    - [x] ATDD feature tests: `mix test test/features/ash_data_layer_workflows_test.exs --trace`
    - [x] Full precommit verification: `mix precommit`
