# Implementation Plan: Track 10 — Atomic Mutator, Monotonic Sequences & Foreign-Key Cascades

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_mutator_and_cascades_20261111`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Done When:** Complete test suite passes with zero warnings, verifying sequences, duplicate-PK checks, atomic policies, optimistic locks, and cascading deletes/restrictions.

---

## Phase 1: Sequence Generator & Create Mutations

- [ ] Task: Implement sequence allocator in `meta.sequences`
    - [ ] Auto-increment on new records via `ensure_primary_key/4`
    - [ ] High-water mark advance on explicit IDs
    - [ ] Duplicate PK detection and rejection via `check_duplicate_pk/3`
- [ ] Task: Implement `create/2` and `bulk_create/3` in `Xitdb.Ash.Mutator`
    - [ ] Write entity slot, identities, secondary indexes, and BM25 postings via `Indexer.put_record/5`

---

## Phase 2: Atomic Updates & Policy Enforcement

- [ ] Task: Implement `update/2` and `update_query/4`
    - [ ] Hydrate target records
    - [ ] Enforce `changeset.filter` (`FilterCheck` write policies and optimistic locks) via `verify_changeset_filter/3`
    - [ ] Enforce `changeset.atomic_validations` via `verify_atomic_validations/3`
    - [ ] Evaluate `changeset.atomics` via `Ash.Expr.eval/2`
    - [ ] Apply diffs to identities, secondary indexes, and search terms

---

## Phase 3: Destroy Actions & Reverse FK Cascades

- [ ] Task: Implement `destroy/2` and `destroy_query/4`
- [ ] Task: Enforce reverse reference rules from `Store.reverse_fks/2`
    - [ ] `:restrict` check raising `InvalidChanges` if matching dependents exist
    - [ ] `:nilify` setting foreign key to `nil` on dependents via `nilify_children/5`
    - [ ] `:delete` recursively destroying dependents via `cascade_delete_children/4` in the same transaction
- [ ] Task: Remove search entries and clean up child indexes via `Indexer.delete_record/4`

---

## Phase 4: Upsert Actions & Verification

- [ ] Task: Implement `upsert/4` using `find_existing_record_for_upsert/6`
- [ ] Task: Write ExUnit test suite in `test/xitdb/ash/mutator_test.exs`
    - [ ] Sequences and duplicate PK checks
    - [ ] Atomic policies and validations
    - [ ] Cascading deletes and restrictions
- [ ] Task: Confirm `mix precommit` passes with zero warnings
