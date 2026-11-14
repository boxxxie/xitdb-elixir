# Implementation Plan: Track 11 — Key Codec & Secondary B+Tree Indexer

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_codec_and_indexer_20261111`
> - **Split Tracks:**
>   - **Track 11A (Wave 2 — MVP Critical Path):** Key Codec, `:context` Tenant Scoping, Single-Commit Operation Staging & Flat Top-Level Secondary B+Tree Indexer
>   - **Track 11B (Wave 3 — Deferred Physical Nesting):** `nested_in` Subtree Storage, Reparenting & Recursive Index Purging
> - **Specification:** [`./spec.md`](./spec.md)
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Done When:** Complete test suite passes with zero warnings, verifying order-preserving binary keys, `Decimal` exponent calculation before zero stripping, `:utc_datetime` truncation, fixed-width `:date`/`:time` keys, `counted_set_fields` round-tripping, `:context` multitenancy isolation, prefix-accurate composite range scans, and single-commit BM25 token diffing.

---

# Part 1: Track 11A (Wave 2 — MVP Cutover Critical Path)

## Phase 1: Key Encoding & Codec Routines (`Xitdb.Ash.Codec`)

- [x] Task: Implement `Xitdb.Ash.Codec` in `lib/xitdb/ash/codec.ex`
    - [x] Sign-flipped 64-bit integer encoding (`encode_i64_be/1`) and decoding (`decode_i64_be/1`)
    - [x] IEEE-754 64-bit float order-preserving encoding (`encode_f64_be/1`) with `-0.0` normalization
    - [x] Canonical scale-normalized `Decimal` key encoding (`encode_decimal_key/1`) computing `exp10 = length(raw_digits) + dec.exp` *before* stripping trailing zeros, guarding `coef == 0`, and converting floats via `Decimal.from_float/1`
    - [x] Sign-flipped UTC datetime encoding truncating `:utc_datetime` to `:second` in both `dump_attribute/2` and `encode_typed_scalar/2` while preserving `:microsecond` for `:utc_datetime_usec` and `:datetime`
    - [x] Fixed-width 8-byte `:date` (`Date.to_gregorian_days/1`), `:time` (second-truncated microseconds since midnight), and `:time_usec` keys via `encode_i64_be/1`, registered in `fixed_width_kind?/1`
    - [x] `Ash.Type.CiString` casing preservation in entity maps and lowercase normalization in index keys and `encode_doc_id/1`
    - [x] `counted_set_fields` support in `to_cursor_map/2` (`Xitdb.counted_set/1`) and `from_cursor/3` (converting set cursors back into lists for `{:array, _}` attributes)
    - [x] `:context` multitenancy collection scoping (`scoped_collection/2`) and struct-safe `resolve_identity_tenant/4` (`Map.get(record, tenant_attr) || tenant`)
    - [x] Composite secondary index key encoding with null escaping (`<<0x00, 0xFF>>`) and null termination, plus length-prefixed composite identity keys (`encode_identity_key/4`)

---

## Phase 2: Flat Top-Level Index Maintenance & Single-Commit Staging (`Xitdb.Ash.Indexer`)

- [x] Task: Implement `Xitdb.Ash.Indexer` flat operations in `lib/xitdb/ash/indexer.ex`
    - [x] Pure transaction operation planners (`plan_put_ops/5` and `plan_delete_ops/4`) plus convenience wrappers (`put_record/6` and `delete_record/5` accepting `base_moment`) so `Mutator` batches sequence + entity + identity + secondary B+Tree + BM25 search updates in **one** `Xitdb.transact_ops/3` commit
    - [x] Incremental BM25 `idx.search.<scoped_collection>` op generation (`plan_search_ops/5`) cleaning up removed/updated tokens atomically in the same commit
    - [x] Unique identity index operations (`plan_identity_ops/5`, `lookup_by_identity/5`) honoring `where:` conditions, `nils_distinct?`, and `tenant`
    - [x] Secondary index operations (`plan_secondary_ops/3`, `lookup_secondary_eq/5`, `count_by_attribute/5`)
    - [x] Prefix-accurate B+Tree range scanning (`scan_secondary_range/5`) fixing `:inclusive` upper bounds (`key <= bound_key or binary_starts_with?(key, bound_key)`) and `:exclusive` lower bounds (`key > bound_key and not binary_starts_with?(key, bound_key)`) on partial composite prefixes
    - [x] Tenant-aware point fetch (`fetch_cursor/4`) and full iteration (`all_cursors/3`) with `:ci_string`-safe `encode_pk_doc_id/2`

---

## Phase 3: Real-API Storage Adapter (`Xitdb.Ash.Indexer.Storage`)

- [x] Task: Implement `Xitdb.Ash.Indexer.Storage` using 100% real `Xitdb` primitives
    - [x] Root cursor resolution (`%Xitdb.Cursor{}`, `%Xitdb{}` via `Xitdb.db/1`, and `{%Xitdb{}, moment}` via `Xitdb.as_of/2`)
    - [x] Order-preserving lowercase hex key encoding (`Base.encode16(key, case: :lower)`) for `:sorted_map` B+Tree slots so arbitrary binary keys are 100% selector-safe
    - [x] Binary-search B+Tree seek and chunked streaming via `Xitdb.NIF.nif_slot_count/3` and `Xitdb.NIF.nif_slot_entries/5` (`stream_index_from/4`)
    - [x] Low-level `TxCompiler` + `{:put, ...}` / `{:rm, ...}` / `{:init_col, ...}` op compilation (`compile_put_ops/7`, `compile_delete_ops/6`)

---

## Phase 4: Track 11A Test Suites & Verification

- [x] Task: Implement `test/xitdb/ash/codec_test.exs`
    - [x] Property & unit tests verifying `encode_i64_be/1`, `:date`, `:time`, `:utc_datetime` (second-truncated), and `:utc_datetime_usec` preserve `<, <=, ==, >=, >` order
    - [x] Property & unit tests verifying `encode_f64_be/1` and `encode_decimal_key/1` (`Decimal.new("60") == Decimal.new("60.0") == Decimal.new("60.000")`, negative decimals, zero, float inputs)
    - [x] Test verifying `counted_set_fields` round-trip `{:array, :string}` attributes via `:counted_hash_set`
    - [x] Test verifying composite identity length prefixing, `:attribute` nil-struct-field fallback, and `:context` multitenancy isolation
- [x] Task: Implement `test/xitdb/ash/indexer_test.exs` (flat entity scope)
    - [x] Test top-level entity CRUD lifecycle in single-moment commits
    - [x] Test composite secondary index partial-prefix `:inclusive` upper and `:exclusive` lower range scans
    - [x] Test BM25 search token cleanup on entity update and delete
- [x] Task: Compile cleanly (`mix compile --warnings-as-errors`) and pass Track 11A unit/property/format checks (full `mix precommit` runs at Wave 2/3 integration milestones)

---

# Part 2: Track 11B (Wave 3 — Deferred Physical Subtree Nesting)

## Phase 5: `nested_in` Physical Subtree Storage & Hierarchy

- [ ] Task: Implement `nested_in` location planning & hierarchy navigation
    - [ ] `plan_entity_location/5` with `_parent` B+Tree path routing
    - [ ] `fetch_nested_cursor/6` inside parent document entity map
    - [ ] Deduplicated `all_cursors/3` (`Stream.map(&elem(&1, 1)) |> Stream.uniq()`) eliminating `K^2` duplicate scans
    - [ ] Parent-jump collection lookups (`nested_cursors_for_parent/4`)

---

## Phase 6: Subtree Reparenting & Recursive Index Purging

- [ ] Task: Implement subtree reparenting and recursive cleanup
    - [ ] Reparenting cleanup when parent foreign key changes
    - [ ] Single-op-list recursive child index purging (`plan_purge_nested_children_ops/4`) before parent deletion

---

## Phase 7: Track 11B Verification Suite

- [ ] Task: Extend `test/xitdb/ash/indexer_test.exs` for nested documents
    - [ ] Test nested entity CRUD lifecycle, deduplicated `all_cursors/3`, and 9-byte `fork` isolation
    - [ ] Test recursive nested child cleanup on parent delete and reparenting across parents
