# Implementation Plan: Track 12 — Six-Stage Query Execution Engine

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_query_engine_20261111`
> - **Wave:** Wave 2
> - **Specification:** [`./spec.md`](./spec.md)
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Done When:** Complete test suite passes with zero warnings, verifying all six pipeline stages, `:context` / `:attribute` tenant pushdown, batched & unrelated aggregates (`parent/1` + `join_filters`), relational calculations, and pagination.

---

## Phase 1: Query Struct & Shaping Helpers

- [ ] Task: Define `%Xitdb.Ash.Query{}` struct in `lib/xitdb/ash/query.ex`
- [ ] Task: Implement shaping functions matching `Ash.DataLayer` callback arities (delegated from `Xitdb.Ash.DataLayer`)
    - [ ] `new/2` (`resource_to_query/2`)
    - [ ] `filter/3`, `sort/3`, `distinct/3`, `distinct_sort/3`
    - [ ] `limit/3`, `offset/3`, `select/3`
    - [ ] `set_context/3`, `set_tenant/3`
    - [ ] `add_aggregate/3`, `add_aggregates/3`, `add_calculation/4`, `add_calculations/3`

---

## Phase 2: Tenant-Aware Narrow & Hydrate Pipeline (Stages 1 & 2)

- [ ] Task: Implement Stage 1 Narrow (`stage1_narrow/3` & `plan_narrowing/4`)
    - [ ] Thread `query.tenant` into all `Indexer` calls (`fetch_cursor/4`, `all_cursors/3`, `lookup_by_identity/5`, `lookup_secondary_eq/5`, `scan_secondary_range/5`, `nested_cursors_for_parent/4`)
    - [ ] Exact PK seek (`resolve_pk_candidates/4`)
    - [ ] Unique identity seek (`try_unique_identity_lookup/4`) inferring `effective_tenant` from `eq_map[tenant_attr]` when `query.tenant == nil` on `:attribute`-multitenant resources
    - [ ] `nested_in` parent jump via `nested_cursors_for_parent/4`
    - [ ] Secondary index B+Tree equality and composite prefix + range intersection
    - [ ] Fallback cursor enumeration via `all_cursors/3`
- [ ] Task: Implement Stage 2 Hydrate
    - [ ] Call `Codec.from_cursor/3` and enforce `:attribute` tenant matching

---

## Phase 3: Filtering, Batched/Unrelated Aggregates, Calculations & Pagination (Stages 3–6)

- [ ] Task: Implement Stage 3 Pre-Filter (`stage3_prefilter/2`)
- [ ] Task: Implement Stage 4 Enrich & Filter (`stage4_enrich_and_filter/5`)
    - [ ] Batched related aggregates (`compute_batched_related_aggregate/4`) grouping hops by key to avoid `O(N * M)` scans
    - [ ] `parent/1` (`parent_stack`) and `join_filters` support on relationship hops and aggregate subqueries
    - [ ] Unrelated aggregates (`related?: false` or cross-resource `agg.resource`) querying `agg.resource`'s own `Store.current_db/1`
    - [ ] Per-record expression and module calculations (`attach_calculations/3`), hydrating and evaluating via `Ash.Expr.eval_hydrated/2` when `Ash.Expr.eval/2` returns `:unknown`
    - [ ] Residual `Ash.Filter.Runtime.filter_matches/4` evaluation
- [ ] Task: Implement Stage 5 Order & Slice (`distinct`, `Ash.Actions.Sort.runtime_sort/3`, `offset`, `limit`)
- [ ] Task: Implement Stage 6 Project (`select` masking with `%Ash.NotLoaded{}`)
- [ ] Task: Implement `execute_aggregates/4` for query-level aggregate queries

---

## Phase 4: Verification & Test Suite

- [ ] Task: Write ExUnit test suite in `test/xitdb/ash/query_test.exs`
    - [ ] Point queries, `:attribute` & `:context` tenant identity/index lookups, composite range filters
    - [ ] Batched related aggregates, `parent/1` + `join_filters`, and unrelated aggregates
    - [ ] Relational expression calculations (`exists/2` across stores) and module calculation sorts
    - [ ] Pagination and `select` projection correctness
- [ ] Task: Confirm `mix precommit` passes with zero warnings
