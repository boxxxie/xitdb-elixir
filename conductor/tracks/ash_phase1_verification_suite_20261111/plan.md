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

- [ ] Task: Verify and align `Mutator`, `Store`, and `TestSandbox` invariants
    - [ ] Verify `lib/xitdb/ash/mutator.ex` (`build_updated_record/4` and `verify_atomic_validations/4`) evaluates `changeset.atomics` against pre-update `current_record` first, substitutes `{:_atomic_ref, field}` against `post_record`, and falls back to `Ash.Filter.Runtime.filter_matches/4` when `Ash.Expr.eval/2` returns `:unknown`
    - [ ] Verify `Xitdb.Ash.Store.mutate/3` detects active `{db, moment}` caller transactions via `in_transaction?/1` (`{:xitdb_tx_state, store}`) in both sandbox and non-sandbox modes so `after_action` hooks (`Organization.rename_and_reindex`) never self-deadlock
    - [ ] Verify `Xitdb.Ash.TestSandbox.checkout/2` (`checkin/2` / `Coordinator.terminate/2`) clones baseline state via `Xitdb.compact!/1` and closes isolated `:memory` `%Xitdb{}` handles on re-checkout so `StreamData` property loops never leak unclosed NIF handles
- [ ] Task: Update `mix.exs`
    - [ ] Add `{:ash_phoenix, "~> 2.1", only: :test}`, preserve Track 14's `{:simple_sat, "~> 0.1", only: :test}`, and `{:stream_data, "~> 1.1", only: [:dev, :test]}`
    - [ ] Configure `elixirc_paths(:test)` to include `["lib", "test/support"]`
    - [ ] Configure `cli: [preferred_envs: [precommit: :test]]` and define `aliases/0` with `precommit: ["format --check-formatted", "compile --warnings-as-errors", "test"]`
- [ ] Task: Update `test/test_helper.exs`
    - [ ] Initialize `Xitdb.Ash.TestSandbox.init()`
    - [ ] Start in-memory dual stores (`MdmStore`, `AppStore`) with corresponding domains
- [ ] Task: Implement `test/support/ash_case.ex`
    - [ ] Define `Xitdb.FeatureScenario` with `scenario/2` macro and step line attribution
    - [ ] Define `Xitdb.AshCase` ExUnit CaseTemplate with `TestSandbox.checkout/2`
- [ ] Task: Implement `test/support/ash_test_domain.ex`
    - [ ] Define stores: `MdmStore` and `AppStore`
    - [ ] Define validation: `NoConsumerEmailDomain` with `validate/3` and pure `^atomic_ref(:email)` `atomic/3` expression, scoped via `where: [changing(:email)]` on `MemberProfile`
    - [ ] Define resources: `Organization`, `MemberProfile` (including atomic `:change_email` update action), `Event`, `AgendaSession`, `TableTalkSeat`, `DirectMessage`
    - [ ] Define domains: `MdmDomain` and `AppDomain` with full code interfaces

---

## Phase 2: Pattern D & E Properties & Storage Invariant Suites

- [ ] Task: Implement `test/xitdb/ash/codec_properties_test.exs`
    - [ ] Property: `encode_i64_be/1` signed ordering across 64-bit boundaries
    - [ ] Property: `encode_f64_be/1` IEEE-754 ordering and `-0.0/+0.0` normalization
    - [ ] Property: `encode_decimal_key/1` scale invariance and decimal ordering
    - [ ] Property: Composite secondary index keys escaping interior NUL bytes
    - [ ] Property: Tenant-scoped composite identity keys collision prevention
- [ ] Task: Implement `test/xitdb/ash/indexer_and_search_properties_test.exs`
    - [ ] Property: BM25 corpus stats (`doc_count`, `total_len`) invariant under upsert/delete streams without NIF handle leaks on re-checkout
    - [ ] Invariant: Event deletion purges nested `AgendaSession` locators, identities, and search indexes, and releases `on_delete: :restrict` on `other_org` so `MdmDomain.destroy_organization!(other_org)` succeeds
    - [ ] Invariant: `VerifyNoSqlFragments` rejects SQL fragment calculations at compile time (paired with throwaway `Domain#{uid}` inside `Code.compile_string`)
    - [ ] Invariant: `VerifyCrossStoreReferences` rejects cross-store cascading deletes at compile time (paired with throwaway `Domain#{uid}` inside `Code.compile_string`)

---

## Phase 3: 4-Layer ATDD Protocol Driver & DSL

- [ ] Task: Implement Layer 3 Protocol Driver in `test/support/drivers/workspace_driver.ex`
    - [ ] Encapsulate organization, member, and atomic `change_member_email/3` domain code interfaces
    - [ ] Encapsulate `confirmed_seat_numbers/1` using `Ash.Query.filter(session_id == ^session_id and status == :confirmed)`
    - [ ] Encapsulate search query wrapper with `Search.ids/3` and `Search.sort_by_rank/2`
    - [ ] Encapsulate bulk archive and prune operations
    - [ ] Encapsulate savepoint nested transaction execution (`Store.transact/3`)
    - [ ] Encapsulate `AshPhoenix.Form` create/update workflows
- [ ] Task: Implement Layer 2 Domain-Specific Language in `test/support/dsl/workspace_dsl.ex`
    - [ ] Define `%World{}` struct tracking test ID, resources, and execution results
    - [ ] Implement `@given` steps (`firm`, `member`, `direct_message`, `conference_event`, `confirmed_seat`)
    - [ ] Implement `@upon` steps (`updating_profile_headline`, `changing_member_email`, `viewing_profile_counter`, `cancelling_and_reassigning_seat`, `attempting_duplicate_seat`, `reserving_with_aborted_nested_savepoint`, `renaming_firm`, `searching_directory`, `archiving_and_pruning_inbox`, `submitting_membership_form`)
    - [ ] Implement `@then` assertion macros with `line: __CALLER__.line` attribution, delegating `confirmed_seats_for_session/3` to `WorkspaceDriver.confirmed_seat_numbers/1` and asserting `expected_field` against `error.errors` in `action_fails_with_invalid_field/3`

---

## Phase 4: Layer 1 Executable Specifications

- [ ] Task: Implement `test/features/ash_data_layer_workflows_test.exs`
    - [ ] Scenario 1: Row-level read filters, field policies, and atomic write authorization
    - [ ] Scenario 2: Cross-store exists filters, calculations, atomic counters, and bulk inbox pruning (verifying pre-prune `sent_messages: 2` and `["Elena Rostova"]` before pruning, then `0` and `[]` after pruning)
    - [ ] Scenario 3: Nested sessions, portable expression calculations, partial seat identities, and savepoint rollbacks
    - [ ] Scenario 4: In-Xitdb BM25 + prefix search resolves firm mandates onto profiles without denormalized columns (using `"Boreal Credit Partners"` for deterministic boost ranking)
    - [ ] Scenario 5: `AshPhoenix.Form` and atomic `:change_email` updates enforce corporate-domain validation (`NoConsumerEmailDomain.validate/3` + `atomic/3`) and persist valid corporate emails

---

## Phase 5: Verification & CI Readiness

- [ ] Task: Run full verification suite
    - [ ] Format check: `mix format --check-formatted`
    - [ ] Compile check: `mix compile --warnings-as-errors`
    - [ ] Property tests: `mix test test/xitdb/ash/*_properties_test.exs`
    - [ ] ATDD feature tests: `mix test test/features/ash_data_layer_workflows_test.exs --trace`
    - [ ] Full precommit verification: `mix precommit`
