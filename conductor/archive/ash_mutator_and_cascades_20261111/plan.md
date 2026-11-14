# Implementation Plan: Track 13 — Atomic Mutator, Monotonic Sequences & Foreign-Key Cascades

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_mutator_and_cascades_20261111`
> - **Wave:** Wave 2
> - **Specification:** [`./spec.md`](./spec.md)
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Done When:** Complete test suite passes with zero warnings, verifying single-commit op batching (`Indexer.plan_put_ops/5` + `Sequences.plan_pk/4`), duplicate-PK and intra-batch identity checks, relational `:unknown` policy/validation evaluation via `Ash.Filter.Runtime.filter_matches/4`, pre-update vs. post-update `atomics` / `atomic_validations`, PK-safe upserts across all Ash 3 `upsert_fields` shapes, `:context` multitenancy scoping, BM25 posting diffs, and same-store cascading deletes/restrictions.

---

## Phase 1: Staged Sequence Generator & Single-Commit Create / Bulk Create

- [x] Task: Implement pure-op sequence planner `Xitdb.Ash.Mutator.Sequences` over `root["meta"]["sequences"][scoped_collection]`
    - [x] Read current high-water mark via `%Xitdb.Cursor{}` `Access` (`Xitdb.as_of(db, moment)`) with zero hallucinated `Xitdb.Map.*` calls
    - [x] Stage `{:init_col, ...}` / `{:put, ...}` ops in memory (`plan_pk/4`) for generated integer PKs and explicit high-water mark advances
    - [x] Thread sequence counters and seen PK / unique identity `MapSet`s across `bulk_create/3` chunks so an entire batch commits in **1** `Xitdb.transact_ops(db, ops, base_moment: moment)` call
- [x] Task: Implement `create/2` and `bulk_create/3` in `Xitdb.Ash.Mutator`
    - [x] Evaluate `changeset.create_atomics` and `changeset.atomic_validations`
    - [x] Reject duplicate PKs and intra-batch unique identity collisions with `Ash.Error.Changes.InvalidChanges`
    - [x] Stage entity cursor, identity, secondary index, and BM25 search posting ops via `Indexer.plan_put_ops/5` and commit atomically on `{db, moment}`

---

## Phase 2: Atomic Updates, Pre/Post-Update Semantics & `:unknown` Policy Hydration

- [x] Task: Implement `update/2` and `update_query/4` over `{db, moment}` working snapshots
    - [x] Hydrate target records scoped by `changeset.tenant` (`:attribute` and `:context` multitenancy)
    - [x] Enforce `changeset.filter` (`FilterCheck` write policies, optimistic locks, and `AshOban` atomic claim filters) via `Ash.Filter.Runtime.filter_matches/4` (`authorize?: false`)
    - [x] Evaluate all `{field, expr}` in `changeset.atomics` against pre-update `current_record` (resolving `{:_atomic_ref, f}` against `Map.merge(current_record, allowed_attrs)`, hydrating `:unknown` via `Ash.Filter.hydrate_refs/2` + `Ash.Expr.eval_hydrated/2`, and returning an error if still `:unknown`)
    - [x] Enforce `changeset.atomic_validations` (both 2-tuple and 3-tuple forms) by substituting `{:_atomic_ref, f}` with `Map.get(post_record, f)` while evaluating bare `%Ash.Query.Ref{}` against `current_record`, delegating `:unknown` boolean conditions (such as cross-store `exists/2` policies) to `Ash.Filter.Runtime.filter_matches/4`
    - [x] Commit updates via `Indexer.plan_put_ops/5` + `Sequences.plan_pk/4` in a single `Xitdb.transact_ops/3` batch

---

## Phase 3: Primary-Key-Safe Upserts Across All Ash 3 `upsert_fields` Shapes

- [x] Task: Implement `upsert/4` and bulk upsert mode in `Xitdb.Ash.Mutator`
    - [x] Resolve conflict target via `%Ash.Resource.Identity{}`, identity name atom, primary key, or `upsert_keys` using `Indexer.lookup_by_identity/5` and `Ash.Filter.Runtime.filter_matches/4` for `identity.where`
    - [x] Expand all Ash 3 `upsert_fields` variants (`nil`, `:replace_all`, `{:replace, fields}`, `{:replace_all_except, except}`, and field lists) while unconditionally excluding `Ash.Resource.Info.primary_key(resource)` so `existing_record` primary keys are never overwritten
    - [x] Tag `:upsert_action` metadata (`:create` or `:update`) and `update_default` attributes accurately

---

## Phase 4: Destroy Actions, Reverse FK Cascades & Verification Suite

- [x] Task: Implement `destroy/2` and `destroy_query/4` enforcing `Store.reverse_fks/2` rules (`%{source_resource, source_collection, source_attribute, destination_attribute, on_delete, nested?}`)
    - [x] `:restrict`: Check `count_referencing_children/4` (passing `tenant`) and return `Ash.Error.Changes.InvalidChanges` when `> 0`
    - [x] `:nilify`: Clear dependent foreign keys and update child secondary/search indexes
    - [x] `:delete`: Recursively cascade deletes with cycle detection (`visited` `MapSet`), removing entity cursors, secondary/identity entries, and BM25 postings via `Indexer.delete_record/4` / `Indexer.plan_delete_ops/4`
- [x] Task: Write ExUnit test suite in `test/xitdb/ash/mutator_test.exs`
    - [x] Single-commit `moment_count` verification for `create`, `update`, `upsert`, `destroy`, and `bulk_create`
    - [x] Cross-store `exists/2` atomic write policy enforcement (`:unknown` hydration regression test)
    - [x] Pre-update vs. post-update `atomics` (field swap `a = b, b = a`) and `atomic_validations`
    - [x] Upsert PK preservation across `:replace_all`, `{:replace, ...}`, `{:replace_all_except, ...}`, and `nil`
    - [x] `:context` multitenancy isolation and cascading `:restrict` / `:nilify` / `:delete` rules
- [x] Task: Confirm `mix precommit` passes with zero warnings
