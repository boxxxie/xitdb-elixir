# Implementation Plan: Track 9 — Six-Stage Query Execution Engine

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_query_engine_20261111`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Done When:** Complete test suite passes with zero warnings, verifying all six pipeline stages, calculations, aggregates, and pagination.

---

## Phase 1: Query Struct & Shaping Callbacks

- [ ] Task: Define `%Xitdb.Ash.Query{}` struct in `lib/xitdb/ash/query.ex`
- [ ] Task: Implement shaping callbacks returning `{:ok, %Query{}}`
    - [ ] `resource_to_query/2`
    - [ ] `filter/2`, `sort/2`, `distinct/2`, `distinct_sort/2`
    - [ ] `limit/2`, `offset/2`, `select/2`
    - [ ] `set_context/2`, `set_tenant/2`, `add_aggregates/2`, `add_calculations/2`

---

## Phase 2: Narrow & Hydrate Pipeline (Stages 1 & 2)

- [ ] Task: Implement Stage 1 Narrow in `plan_narrowed_candidates/4`
    - [ ] Exact PK seek
    - [ ] `nested_in` parent jump via `nested_cursors_for_parent/3`
    - [ ] Unique identity seek via `lookup_by_identity/5`
    - [ ] Secondary index B+Tree intersection via `lookup_secondary_eq/4`
    - [ ] Fallback cursor enumeration via `all_cursors/2`
- [ ] Task: Implement Stage 2 Hydrate
    - [ ] Call `Codec.from_cursor/3` to decode `%Resource{}` structs

---

## Phase 3: Filtering, Calculation & Pagination (Stages 3–6)

- [ ] Task: Implement Stage 3 Pre-Filter
- [ ] Task: Implement Stage 4 Enrich & Filter
    - [ ] Evaluate collection and relationship aggregates (`:count`, `:exists`, `:first`, `:list`, `:sum`, `:min`, `:max`, `:avg`)
    - [ ] Evaluate per-record calculations via `Ash.Expr.eval/2`
    - [ ] Run `Ash.Filter.Runtime.filter_matches/4`
- [ ] Task: Implement Stage 5 Order & Slice (distinct, `Ash.Actions.Sort.runtime_sort/3`, offset, limit)
- [ ] Task: Implement Stage 6 Project (select masking)
- [ ] Task: Implement `execute_aggregates/4` for aggregate queries

---

## Phase 4: Verification & Test Suite

- [ ] Task: Write ExUnit test suite in `test/xitdb/ash/query_test.exs`
    - [ ] Point queries, range filters, composite indexes
    - [ ] Aggregates and calculation sorts
    - [ ] Pagination correctness
- [ ] Task: Confirm `mix precommit` passes with zero warnings
