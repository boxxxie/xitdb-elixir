# Specification: Track 15 — Ash DataLayer Phase 1 Verification Suite (Pattern D/E Properties & 4-Layer ATDD Workflows)

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_phase1_verification_suite_20261111`
> - **Primary Modules Under Test:** `lib/xitdb/ash/codec.ex`, `lib/xitdb/ash/indexer.ex`, `lib/xitdb/ash/search.ex`, `lib/xitdb/ash/store.ex`, `lib/xitdb/ash/query.ex`, `lib/xitdb/ash/mutator.ex`, `lib/xitdb/ash/data_layer.ex`, `lib/xitdb/ash/test_sandbox.ex`
> - **Test Suite Structure:**
>   - Test Config & Harness: `xitdb/mix.exs`, `test/test_helper.exs`, `test/support/ash_case.ex`, `test/support/ash_test_domain.ex`
>   - Pattern D/E (Properties & Invariants): `test/xitdb/ash/codec_properties_test.exs`, `test/xitdb/ash/indexer_and_search_properties_test.exs`
>   - 4-Layer ATDD: `test/support/drivers/workspace_driver.ex` (Layer 3), `test/support/dsl/workspace_dsl.ex` (Layer 2), `test/features/ash_data_layer_workflows_test.exs` (Layer 1)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Done When:** Complete end-to-end multi-store dual-resource verification suite passes 100% on `async: true` with zero compiler warnings under `mix do format --check-formatted + compile --warnings-as-errors + test`.

---

## 1. Goal & Architecture Overview

Track 15 establishes the definitive Phase 1 verification infrastructure for the pure `Xitdb.Ash.DataLayer` implementation in `elixir/xitdb`. Rather than monolithic test scripts, the verification architecture splits cleanly into two complementary, rigorous methodologies:

1. **Pattern D/E (`ExUnitProperties` + Direct `ExUnit`):** Focuses on low-level binary mathematical invariants, serialization bounds, B+Tree indexing state machines, BM25 corpus drift prevention, and compile-time Spark AST verifiers.
2. **4-Layer ATDD (`FeatureScenario` -> DSL -> Protocol Driver -> SUT):** Focuses on end-to-end business workflows and framework integration, verifying `Ash.Policy.Authorizer`, field policies, cross-store relationships/aggregates, partial identities (`where: expr(...)`), nested transaction savepoint rollbacks, BM25 rank propagation across entity joins, and `AshPhoenix.Form` validation workflows.

Additionally, this suite verifies the Ash 3 atomic validation rules implemented in prerequisite track [`ash_mutator_and_cascades_20261111`](../ash_mutator_and_cascades_20261111/index.md) (`build_updated_record/4` evaluating `changeset.atomics` against pre-update `current_record` **before** running `verify_atomic_validations/4` with `{:_atomic_ref, field}` post-record substitution and `Ash.Filter.Runtime.filter_matches/4` `:unknown` fallback across both 2-tuple and 3-tuple failure condition shapes in `lib/xitdb/ash/mutator.ex`), re-entrant `{db, moment}` caller-transaction safety in `Xitdb.Ash.Store.mutate/3` across both sandbox and non-sandbox modes, and `Xitdb.compact!/1` sandbox clone cleanup on re-entrant `Xitdb.Ash.TestSandbox.checkout/2`.

---

## 2. Component Details

### 2.1 Test Config, Sandbox & Dual-Store Topology (`test/support/`)

- **Dependencies & Aliases (`mix.exs`):**
  - Add `{:ash_phoenix, "~> 2.1", only: :test}` for verifying form validation workflows.
  - Add `{:stream_data, "~> 1.1", only: [:dev, :test]}` for property testing.
  - Ensure `elixirc_paths(:test)` loads `["lib", "test/support"]`.
  - Configure `cli: [preferred_envs: [precommit: :test]]` and ensure `aliases/0` defines `precommit: ["format --check-formatted", "compile --warnings-as-errors", "test"]`.
- **Test Helper (`test/test_helper.exs`):**
  - Initializes `Xitdb.Ash.TestSandbox` (verifying `TestSandbox.checkout/2` closes and cleans up any prior per-owner isolated sandbox clone via `checkin/2` on re-checkout so `StreamData` property loops never leak unclosed NIF handles).
  - Starts two in-memory store instances: `Xitdb.TestSupport.MdmStore` and `Xitdb.TestSupport.AppStore`.
- **Harness (`test/support/ash_case.ex`):**
  - `Xitdb.FeatureScenario`: Defines `scenario/2` macro compiling `@given`, `@upon`, `@whenever`, and `@then` steps into a clean piped AST while preserving step line metadata for precise error attribution.
  - `Xitdb.AshCase`: `ExUnit.CaseTemplate` checking out sandbox locks for `[MdmStore, AppStore]` with `async: true` support.
- **Dual-Store Domain (`test/support/ash_test_domain.ex`):**
  - `MdmStore`: Manages Master Data Management resources (`Organization`, `MemberProfile`, `Event`, `AgendaSession`, `TableTalkSeat`), including re-entrant `Store.mutate/3` inside `Organization.rename_and_reindex`'s `after_action` hook (reusing `Process.get({:xitdb_tx_state, store})` `{db, moment}` working snapshots in both sandbox and non-sandbox modes without self-deadlocking).
  - `AppStore`: Manages application data (`DirectMessage`).
  - Resources demonstrate:
    - Custom validations (`NoConsumerEmailDomain` scoped with `where: [changing(:email)]` and implementing a real `^atomic_ref(:email)` failure expression in `atomic/3`, tested on both `create` and atomic `update` actions).
    - BM25 search fields with custom dynamic resolvers (`firm_name`, `firm_mandate`).
    - Secondary B+Tree indexes (`[:visibility, :role]`, `[:recipient_id, :archived?]`).
    - `nested_in :events` sub-collections with `_parent` pointers.
    - Partial identities with `where: expr(status == :confirmed)`.
    - Cross-store `belongs_to` relationships and cross-store aggregate counts.
    - Fine-grained `policies` and `field_policies`.

---

### 2.2 Pattern D & E: Properties & Storage Invariants

1. **`test/xitdb/ash/codec_properties_test.exs`:**
   - Property 1: `encode_i64_be/1` signed integer ordering across `[-2^63, 2^63-1]`.
   - Property 2: `encode_f64_be/1` IEEE-754 ordering and `-0.0/+0.0` normalization.
   - Property 3: `encode_decimal_key/1` scale invariance (`60.0 == 60.000`) and ordering.
   - Property 4: Composite secondary index keys escaping interior NUL bytes (`\0`) without collision.
   - Property 5: Tenant-scoped composite identity keys preventing cross-boundary or cross-tenant collision.

2. **`test/xitdb/ash/indexer_and_search_properties_test.exs`:**
   - Property 1: BM25 corpus stats (`doc_count`, `total_len`) invariant: never drifts under arbitrary sequences of upsert and delete operations (closing prior `:memory` handles cleanly across re-entrant `TestSandbox.checkout([MdmStore])` iterations). Complete deletion resets corpus stats to 0.
   - Invariant Test 2 & 3: Destroying an `Event` cascades and completely purges nested `AgendaSession` records from `_parent` locators, identities, and BM25 term indexes, and releases the `on_delete: :restrict` foreign key constraint on the event's `other_org` organizer so `MdmDomain.destroy_organization!(other_org)` subsequently succeeds.
   - Invariant Test 4: Compile-time verifier `VerifyNoSqlFragments` raises `DslError` when `fragment(...)` expressions are used in calculations (compiled alongside a throwaway `Domain#{uid}` so Ash 3 domain-inclusion checks never mask the verifier error).
   - Invariant Test 5: Compile-time verifier `VerifyCrossStoreReferences` raises `DslError` when cross-store relationships configure cascading `on_delete` rules (compiled alongside a throwaway `Domain#{uid}`).

---

### 2.3 4-Layer ATDD Architecture

1. **Layer 3: Protocol Driver (`test/support/drivers/workspace_driver.ex`):**
   Encapsulates all domain code interfaces, `confirmed_seat_numbers/1` (`Ash.Query.filter(session_id == ^session_id and status == :confirmed)`), `Xitdb.Ash.Search.ids/3`, bulk queries (`bulk_update!`, `bulk_destroy!`), savepoint rollback transactions (`Store.transact`), atomic email-change updates (`change_member_email/3`), and `AshPhoenix.Form` operations.
2. **Layer 2: Domain-Specific Language (`test/support/dsl/workspace_dsl.ex`):**
   - Maintains an explicit `%World{}` state struct threading entity maps, test IDs, and query results (with zero direct Layer 4 domain queries or global scans leaked into Layer 2).
   - Auto-scopes domains and emails with unique test run IDs to prevent collisions in concurrent runs.
   - Implements `@given`, `@upon`, `@whenever`, and `@then` steps, asserting `expected_field` against `error.errors` (`e.field == expected_field or expected_field in List.wrap(Map.get(e, :fields))`) in `action_fails_with_invalid_field/3`.
   - Stretches ExUnit assertions through caller line stamps (`quote line: __CALLER__.line`) so test failure reports point directly to the failing step in the specification.
3. **Layer 1: Executable Specifications (`test/features/ash_data_layer_workflows_test.exs`):**
   - **Scenario 1:** Row-level read filters, field policies (redacted compensation bands), and atomic write authorization enforce member privacy.
   - **Scenario 2:** Cross-store `exists(...)` filters, calculations, atomic counters, and bulk inbox pruning (asserting pre-prune `sent_messages: 2` and `["Elena Rostova"]` with `"Sofia Laurent"` as negative control *before* pruning, then `0` and `[]` *after* pruning).
   - **Scenario 3:** Nested sessions, portable expression calculations, partial seat identities, and savepoint rollbacks.
   - **Scenario 4:** In-Xitdb BM25 + prefix search resolves firm mandates onto profiles without denormalized columns (renaming Boreal to `"Boreal Credit Partners"` so `"infrastructure"` matches `headline` + `firm_mandate` on Claire vs. `firm_mandate`-only on Victor for deterministic ranking).
   - **Scenario 5:** `AshPhoenix.Form` corporate-domain validation on create **and** atomic `update` (`:change_email`) triggering `NoConsumerEmailDomain.atomic/3` failure and success paths.

---

## 3. Acceptance Criteria

- [ ] `mix.exs` compiles with test dependencies (`:ash_phoenix`, `:stream_data`), proper test `elixirc_paths`, `cli` `preferred_envs`, and `aliases/0` (`precommit`).
- [ ] `test/test_helper.exs` cleanly initializes the test sandbox and starts in-memory stores, and `TestSandbox` closes and cleans up isolated sandbox handles on re-checkout / `Coordinator.terminate/2`.
- [ ] `lib/xitdb/ash/mutator.ex` evaluates `changeset.atomics` against pre-update `current_record` **before** running `verify_atomic_validations/4` (with `{:_atomic_ref, field}` post-record substitution and `Ash.Filter.Runtime.filter_matches/4` `:unknown` fallback across both 2-tuple and 3-tuple atomic validations); `Store.mutate/3` is re-entrant over `{db, moment}` working snapshots across both sandbox and leased non-sandbox transactions.
- [ ] `test/xitdb/ash/codec_properties_test.exs` passes with 100+ property checks per test.
- [ ] `test/xitdb/ash/indexer_and_search_properties_test.exs` passes property and unit assertions with zero corpus drift, verified `:restrict` release on `other_org`, and isolated `Domain#{uid}` compile-time verifier tests.
- [ ] `test/features/ash_data_layer_workflows_test.exs` passes all 5 ATDD scenarios concurrently (`async: true`) with non-vacuous pre/post cross-store assertions, field-level invalid error checks, deterministic BM25 boost ordering, and atomic email validation coverage.
- [ ] Zero compiler warnings emitted under `mix compile --warnings-as-errors`.
- [ ] Formatted cleanly under `mix format --check-formatted`.
