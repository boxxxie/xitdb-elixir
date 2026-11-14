# Specification: Track 13 — Atomic Mutator, Monotonic Sequences & Foreign-Key Cascades

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_mutator_and_cascades_20261111`
> - **Wave:** Wave 2
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Module:** `lib/xitdb/ash/mutator.ex`
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Done When:** Complete unit, property, and integration test suite passes with zero warnings, verifying single-commit atomic mutations, tenant-scoped monotonic sequences, duplicate-PK prevention, optimistic locking, relational `:unknown` atomic policy/validation enforcement, pre-update vs. post-update expression semantics, primary-key-safe upserts across all Ash 3 `upsert_fields` shapes, and foreign-key cascades.

---

## 1. Goal & Architecture

All database mutations in `Xitdb.Ash.DataLayer` run inside the store's exclusive single-writer lease (`Xitdb.Ash.Store.mutate/3` operating on `{db, moment}` working snapshots). `Xitdb.Ash.Mutator` orchestrates record creation, updates, upserts, deletes, monotonic sequences, Ash 3 atomic policies/validations, and same-store cascading foreign-key rules:

1. **Mutation Lifecycle & Single-Commit Atomicity:**
   - Implements `create/2`, `bulk_create/3`, `update/2`, `update_query/4`, `upsert/4`, `destroy/2`, and `destroy_query/4`.
   - Stages sequence counter updates (`Sequences.plan_pk/4`), entity cursor writes/deletes, unique identity checks, secondary index updates, and incremental BM25 search posting diffs (`Indexer.plan_put_ops/5` / `Indexer.plan_delete_ops/4`) into a single `Xitdb.transact_ops(db, ops, base_moment: moment)` NIF commit per single-record mutation—and a single NIF commit per `bulk_create` batch with intra-batch PK, sequence, and unique-identity conflict tracking.
2. **Tenant-Scoped Monotonic Sequences (`meta.sequences`):**
   - Automatically increments `meta.sequences[scoped_collection]` for generated integer primary keys without issuing a separate transaction commit.
   - Rejects duplicate primary keys on `create/2` and `bulk_create/3` with clear `Ash.Error.Changes.InvalidChanges` conflict errors.
   - Automatically advances the sequence high-water mark `max(current_seq, explicit_id)` when explicit integer primary keys are provided.
3. **Race-Free Atomic Policy, Validation & Pre/Post-Update Expression Enforcement:**
   - Evaluates `changeset.filter` (row-level `FilterCheck` write policies, optimistic locks, and atomic claim filters) against the pre-update `current_record` via `Ash.Filter.Runtime.filter_matches/4` (`authorize?: false`).
   - Evaluates all `{field, expr}` entries in `changeset.atomics` against the **pre-update** `current_record` snapshot (substituting any `{:_atomic_ref, f}` nodes with `Map.get(Map.merge(current_record, allowed_attrs), f)`, hydrating via `Ash.Filter.hydrate_refs/2` + `Ash.Expr.eval_hydrated/2` when `Ash.Expr.eval/2` returns `:unknown`, and failing explicitly rather than clobbering fields with `nil` if an expression remains `:unknown`).
   - Evaluates `changeset.atomic_validations` (both 2-tuple `{failure_expr, error_expr}` and 3-tuple `{fields, failure_expr, error_expr}` forms) by substituting `{:_atomic_ref, f}` against `post_record` while evaluating bare `%Ash.Query.Ref{}` nodes against `current_record` (for updates/upserts/destroys) or `post_record` (for creates). Whenever `Ash.Expr.eval/2` returns `:unknown` (for example, relational or cross-store `exists(organization.profiles, ...)` write policies), `Mutator` hydrates and evaluates via `Ash.Filter.Runtime.filter_matches/4` / `Ash.Expr.eval_hydrated/2`—**never** mapping `:unknown` to `{:ok, nil}`.
4. **Upsert Primary-Key Safety & Complete Ash 3 `upsert_fields` Support:**
   - Resolves existing targets by `%Ash.Resource.Identity{}`, identity name atom, primary key, or `upsert_keys` scoped to `changeset.tenant` (honoring `identity.where` via `Ash.Filter.Runtime.filter_matches/4`).
   - Supports every Ash 3 `upsert_fields` shape (`nil`, `:replace_all`, `{:replace, fields}`, `{:replace_all_except, except}`, and explicit field lists), **always** subtracting `Ash.Resource.Info.primary_key(resource)` so generated UUIDs on create changesets never overwrite an existing record's primary key.
5. **Same-Store Foreign-Key Cascades (`Store.reverse_fks/2`):**
   - Enforces canonical reverse reference rules (`%{source_resource, source_collection, source_attribute, destination_attribute, on_delete, nested?}`) targeting the record being destroyed:
     - `:restrict`: Rejects destroy if dependent child records exist (`count_referencing_children/4 > 0`).
     - `:nilify`: Updates dependent foreign key attributes to `nil` and refreshes child indexes.
     - `:delete`: Recursively destroys dependent records with cycle protection (`visited` `MapSet`).
6. **Synchronous Index & Search Invariance:**
   - Synchronously updates secondary B+Tree indexes, unique identities, and BM25 inverted/forward postings (`idx.search.<scoped_col>`) in the same commit.

---

## 2. Technical Invariants

- **Single Atomic Commit per Mutation / Batch:** Single-record `create/2`, `update/2`, `upsert/4`, and non-cascading `destroy/2` each execute exactly **1** `Xitdb.transact_ops(db, ops, base_moment: moment)` call; `bulk_create/3` executes **1** `Xitdb.transact_ops/3` call per batch while enforcing intra-batch PK and unique-identity invariants in memory; multi-step `update_query/4`, `destroy_query/4`, and recursive cascades advance `{db, moment}` cleanly inside `Store.mutate/3` so any error rolls back to the pre-call moment (`Store` / `Backend.reconcile_tip/2`).
- **Zero `:unknown` Policy Bypasses:** `:unknown` from `Ash.Expr.eval/2` on boolean filters or `atomic_validations` always delegates to `Ash.Filter.Runtime.filter_matches/4` (which loads referenced relationships—even across `MDM.Store` and `AppStore`—with `authorize?: false`) and never defaults to `nil`/`false` without runtime evaluation.
- **Zero Hallucinated Storage Calls:** `Sequences` reads `root["meta"]["sequences"][scoped_col]` via `%Xitdb.Cursor{}` `Access` and emits real `TxCompiler` `:init_col` / `:put` ops.

---

## 3. Acceptance Criteria

1. Sequential `create` and `bulk_create` calls generate strictly monotonic integer IDs without extra transaction commits, gaps, or collisions, and explicit integer IDs advance the high-water mark.
2. Relational atomic write policies and validations (e.g. `exists(organization.profiles, user_id == ^actor(:id))`) evaluate accurately instead of bypassing on `:unknown`.
3. State-transition validations (`expr(status != :pending)` on pre-update `current_record`) and post-update value validations (`atomic_ref(:email)` on `post_record`), as well as swap atomics (`a = b, b = a`), all evaluate with exact Ash 3 semantics.
4. Upserting onto an existing record with `uuid_primary_key :id` preserves `existing_record.id` across `upsert_fields: nil`, `:replace_all`, `{:replace, ...}`, `{:replace_all_except, ...}`, and `[...]`.
5. Destroying a record enforces `:restrict`, `:nilify`, and `:delete` cascades across same-store collections while keeping secondary and BM25 search indexes 100% consistent.
