# Implementation Plan: Track 8 — Key Codec & Secondary B+Tree Indexer

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_codec_and_indexer_20261111`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Done When:** Complete test suite passes with zero warnings, verifying order-preserving binary keys, collision-free composite identities, `_parent` locators, and recursive nested-index cleanup.

---

## Phase 1: Key Encoding & Codec Routines

- [ ] Task: Implement `Xitdb.Ash.Codec` in `lib/xitdb/ash/codec.ex`
    - [ ] Sign-flipped 64-bit integer encoding (`encode_i64_be/1`) and decoding (`decode_i64_be/1`)
    - [ ] IEEE-754 64-bit float order-preserving encoding (`encode_f64_be/1`) with `-0.0` normalization
    - [ ] Canonical scale-normalized `Decimal` key encoding (`encode_decimal_key/1`)
    - [ ] Sign-flipped microsecond UTC datetime encoding
    - [ ] ISO-8601 date and time string encoding
    - [ ] `Ash.Type.CiString` casing preservation and lowercase index key generation
    - [ ] Composite secondary index key encoding with null escaping (`<<0x00, 0xFF>>`) and null termination
    - [ ] Length-prefixed composite identity keys with tenant prefixing (`encode_identity_key/4`)
    - [ ] Entity cursor serialization (`to_cursor_map/2`) and hydration (`from_cursor/3`)
    - [ ] Doc ID encoding (`encode_doc_id/1`) and decoding (`decode_doc_id/2`)

---

## Phase 2: Index Maintenance Engine (`Xitdb.Ash.Indexer`)

- [ ] Task: Implement `Xitdb.Ash.Indexer` in `lib/xitdb/ash/indexer.ex`
    - [ ] Entity location planning for top-level and `nested_in` entities (`plan_entity_location/4`)
    - [ ] Unique identity index operations (`plan_identity_ops/5`, `lookup_by_identity/5`)
    - [ ] Partial identities honoring `where:` conditions and `nils_distinct?`
    - [ ] Secondary index operations (`plan_secondary_ops/3`, `lookup_secondary_eq/4`)
    - [ ] Indexed count shortcuts (`count_by_attribute/4`)
    - [ ] B+Tree range scanning (`scan_secondary_range/4`) with prefix scoping and bound predicates
    - [ ] Point fetch (`fetch_cursor/3`), full iteration (`all_cursors/2`), and parent jumps (`nested_cursors_for_parent/3`)

---

## Phase 3: Recursive Subtree Cleanup & Storage Adapter

- [ ] Task: Implement `Xitdb.Ash.Indexer.Storage`
    - [ ] Top-level and nested entity cursor storage (`fetch_top_level_cursor/3`, `fetch_nested_cursor/6`)
    - [ ] B+Tree index operations (`lookup_unique/4`, `lookup_set/4`, `count_set/4`, `stream_index_from/4`)
    - [ ] Transactional atomic write and delete helpers (`apply_entity_and_indexes/6`, `delete_entity_and_indexes/5`)
- [ ] Task: Implement subtree reparenting and recursive cleanup
    - [ ] Reparenting cleanup when parent foreign key changes
    - [ ] Recursive child index purging (`purge_nested_children/4`) before parent deletion

---

## Phase 4: Test Suites & Verification

- [ ] Task: Implement `test/xitdb/ash/codec_test.exs`
    - [ ] Property test verifying `encode_i64_be/1` preserves `<, <=, ==, >=, >` order across `StreamData.integer()`
    - [ ] Property test verifying `encode_f64_be/1` preserves order for floats including `-0.0`
    - [ ] Test verifying Decimal scale normalization (`60.0 == 60.00`)
    - [ ] Test verifying composite identity length prefixing prevents boundary collision (`{"ab", "cd"}` vs `{"a", "bcd"}`)
    - [ ] Test verifying multitenant identity scoping and `nils_distinct?`
- [ ] Task: Implement `test/xitdb/ash/indexer_test.exs`
    - [ ] Test top-level and nested entity CRUD lifecycle
    - [ ] Test secondary index lookups and range scans over `:sorted_map`
    - [ ] Test unique identity collision detection and partial `where` filters
    - [ ] Test recursive nested child cleanup on parent delete
- [ ] Task: Run `mix precommit` and ensure zero warnings and clean formatting
