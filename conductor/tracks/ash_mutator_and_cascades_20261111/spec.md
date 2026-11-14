# Specification: Track 10 — Atomic Mutator, Monotonic Sequences & Foreign-Key Cascades

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_mutator_and_cascades_20261111`
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Module:** `lib/xitdb/ash/mutator.ex`
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Done When:** Complete unit, property, and integration test suite passes with zero warnings, verifying atomic mutations, monotonic sequences, duplicate-PK prevention, optimistic locking, atomic validations, and foreign-key cascades.

---

## 1. Goal & Architecture

All database mutations in `Xitdb.Ash.DataLayer` run inside the store's exclusive single-writer lease (`Xitdb.Ash.Store.mutate/3` or `Xitdb.Ash.Store.transact/3`). `Xitdb.Ash.Mutator` orchestrates record creation, updates, deletes, sequences, atomic policies, and cascading foreign-key rules in a single atomic transaction:

1. **Mutation Lifecycle:**
   - Implements `create/2`, `bulk_create/3`, `update/2`, `update_query/4`, `upsert/4`, `destroy/2`, and `destroy_query/4`.
2. **Monotonic Sequences (`meta.sequences`):**
   - Automatically increments `meta.sequences[collection]` for generated integer primary keys.
   - Rejects duplicate primary keys on `create/2` with clear conflict errors.
   - Automatically advances sequence high-water mark `max(current_seq, explicit_id)` when explicit primary keys are provided.
3. **Race-Free Atomic Policy & Validation Enforcement:**
   - Before applying updates or destroys, hydrates target records and evaluates `changeset.filter` (`FilterCheck` write policies and optimistic locks).
   - Evaluates `changeset.atomic_validations`.
   - Evaluates `changeset.atomics` via `Ash.Expr.eval/2`.
4. **Foreign-Key Cascades (`references`):**
   - Enforces reverse reference rules targeting the record being destroyed:
     - `:restrict`: Raises error if dependent child records exist.
     - `:nilify`: Updates dependent foreign key attributes to `nil`.
     - `:delete`: Recursively destroys dependent records.
5. **Synchronous Index & Search Invariance:**
   - Synchronously updates secondary indexes (`Xitdb.Ash.Indexer`) and full-text inverted postings (`Xitdb.Ash.Search.index_record` / `Xitdb.Ash.Search.remove_record`) in the exact same write transaction.

---

## 2. Technical Invariants

- **Single Atomic Commit:** All entity writes, sequence increments, secondary index updates, BM25 posting updates, and reverse FK cascades must commit in a single NIF transaction batch via `Xitdb.transact/2`.
- **Identity Uniqueness:** Unique identity collisions must raise `Ash.Error.Changes.InvalidChanges` prior to commit.
- **Fail-Safe Rollback:** If any validation, policy check, or FK constraint fails, the entire transaction rolls back cleanly without advancing the store moment.

---

## 3. Acceptance Criteria

1. Sequential `create` calls generate strictly monotonic integer IDs without gaps or collisions.
2. An update violating optimistic locks or `changeset.filter` policies fails atomically with `Ash.Error.Changes.StaleRecord`.
3. Destroying a record with `:delete` cascade removes all dependent child records across collections on the same store.
4. Destroying a record with `:restrict` cascade fails if dependent records exist.
5. Search postings and secondary indexes stay in 100% sync across create, update, and destroy.
