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

- [x] Task: Define `%Xitdb.Ash.Query{}` struct in `lib/xitdb/ash/query.ex`
- [x] Task: Implement shaping functions matching `Ash.DataLayer` callback arities (delegated from `Xitdb.Ash.DataLayer`)
    - [x] `new/2` (`resource_to_query/2`)
    - [x] `filter/3`, `sort/3`, `distinct/3`, `distinct_sort/3`
    - [x] `limit/3`, `offset/3`, `select/3`
    - [x] `set_context/3`, `set_tenant/3`
    - [x] `add_aggregate/3`, `add_aggregates/3`, `add_calculation/4`, `add_calculations/3`

---

## Phase 2: Tenant-Aware Narrow & Hydrate Pipeline (Stages 1 & 2)

- [x] Task: Implement Stage 1 Narrow (`stage1_narrow/3` & `plan_narrowing/4`)
    - [x] Thread `query.tenant` into all `Indexer` calls (`fetch_cursor/4`, `all_cursors/3`, `lookup_by_identity/5`, `lookup_secondary_eq/5`, `scan_secondary_range/5`, `nested_cursors_for_parent/4`)
    - [x] Exact PK seek (`resolve_pk_candidates/4`)
    - [x] Unique identity seek (`try_unique_identity_lookup/4`) inferring `effective_tenant` from `eq_map[tenant_attr]` when `query.tenant == nil` on `:attribute`-multitenant resources
    - [x] `nested_in` parent jump via `nested_cursors_for_parent/4` _(completed in Track 11B)_
    - [x] Secondary index B+Tree equality and composite prefix + range intersection
    - [x] Fallback cursor enumeration via `all_cursors/3`
- [x] Task: Implement Stage 2 Hydrate
    - [x] Call `Codec.from_cursor/3` and enforce `:attribute` tenant matching

---

## Phase 3: Filtering, Batched/Unrelated Aggregates, Calculations & Pagination (Stages 3–6)

- [x] Task: Implement Stage 3 Pre-Filter (`stage3_prefilter/2`)
- [x] Task: Implement Stage 4 Enrich & Filter (`stage4_enrich_and_filter/5`)
    - [x] Batched related aggregates (`compute_batched_related_aggregate/4`) grouping hops by key to avoid `O(N * M)` scans
    - [x] `parent/1` (`parent_stack`) and `join_filters` support on relationship hops and aggregate subqueries
    - [x] Unrelated aggregates (`related?: false` or cross-resource `agg.resource`) querying `agg.resource`'s own `Store.current_db/1`
    - [x] Per-record expression and module calculations (`attach_calculations/3`), hydrating and evaluating via `Ash.Expr.eval_hydrated/2` when `Ash.Expr.eval/2` returns `:unknown`
    - [x] Residual `Ash.Filter.Runtime.filter_matches/4` evaluation
- [x] Task: Implement Stage 5 Order & Slice (`distinct`, `Ash.Actions.Sort.runtime_sort/3`, `offset`, `limit`)
- [x] Task: Implement Stage 6 Project (`select` masking with `%Ash.NotLoaded{}`)
- [x] Task: Implement `execute_aggregates/4` for query-level aggregate queries

---

## Phase 4: Verification & Test Suite

- [x] Task: Write ExUnit test suite in `test/xitdb/ash/query_test.exs`
    - [x] Point queries, `:attribute` & `:context` tenant identity/index lookups, composite range filters
    - [x] Batched related aggregates, `parent/1` + `join_filters`, and unrelated aggregates
    - [x] Relational expression calculations (`exists/2` across stores) and module calculation sorts
    - [x] Pagination and `select` projection correctness
- [x] Task: Confirm `mix precommit` passes with zero warnings _(completed across Wave 2 and Track 11B)_
