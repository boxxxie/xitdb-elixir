# Specification: Track 8 — Key Codec & Secondary B+Tree Indexer

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_codec_and_indexer_20261111`
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Modules:** `lib/xitdb/ash/codec.ex`, `lib/xitdb/ash/indexer.ex`
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Done When:** Complete unit, property, and integration tests pass with zero warnings, verifying order-preserving key encoding, collision-free composite identities, `_parent` locators, and recursive nested-index cleanup.

---

## 1. Goal & Architecture

In `Xitdb.Ash.DataLayer`, fast point queries, range scans, and unique identity checks rely on deterministic lexicographical ordering inside `:sorted_map` B+Tree indexes.

`Xitdb.Ash.Codec` and `Xitdb.Ash.Indexer` implement:
1. **Order-Preserving Binary B+Tree Keys (`Xitdb.Ash.Codec`):**
   - **Signed 64-Bit Integers & Timestamps:** Two's-complement sign bit is flipped (`bxor(msb, 0x80)`) into an 8-byte big-endian binary so unsigned byte comparison matches signed numerical and chronological ordering across all valid 64-bit values (`-9_223_372_036_854_775_808` to `9_223_372_036_854_775_807`).
   - **Floats & Decimals:** IEEE-754 64-bit floats normalize `-0.0` to `+0.0` and invert negative bit patterns. `Decimal` keys normalize trailing zeroes (`60.0 == 60.00`) and encode scale exponents in sign-flipped binary.
   - **Dates & Times:** `:date` and `:time` use standard ISO-8601 strings.
   - **Case-Insensitive Strings (`Ash.Type.CiString`):** Original casing is preserved in entity cursors, while index keys are lowercased.
2. **Collision-Free Composite & Multitenant Keys (`Xitdb.Ash.Codec`):**
   - **Identities:** Encoded with presence tags (`@null_tag 0x00`, `@value_tag 0x01`) and 32-bit length headers (`<<len::unsigned-big-32, part::binary>>`), prefixed by tenant scope, honoring `identity.nils_distinct?`.
   - **Secondary Indexes:** Interior `0x00` bytes in variable-width fields are escaped to `<<0x00, 0xFF>>` and terminated with `<<0x00, 0x00>>`, ensuring composite multi-column range scans remain collision-free and lexicographically monotonic.
3. **Subtree Co-Location & Index Maintenance (`Xitdb.Ash.Indexer`):**
   - **`nested_in` Entities:** Co-located under `root[parent_col][parent_id][path]` with `idx.<col>._parent[pk_key] => parent_doc_id` maintained for `O(log N)` primary key lookups.
   - **Reparenting:** On foreign-key update, old parent subtree slots are purged before inserting into the new parent subtree.
   - **Recursive Cleanup:** When a parent record is deleted, `purge_nested_children/4` navigates all child subtrees using reverse-FK rules and deletes child `_parent`, secondary, identity, and BM25 search entries before purging the parent entity cursor.
   - **B+Tree Range Scans:** `scan_secondary_range/4` constructs lower-bound seek keys, skips `nil` tags, and scans within upper-bound predicate limits.

---

## 2. Technical Invariants

- **Lexicographical Monotonicity:** For all values `a, b`, `encode_scalar_key(attr, a) < encode_scalar_key(attr, b)` if and only if `a < b`.
- **Identity Null Semantics:** When `identity.nils_distinct?` is `true`, any `nil` key component returns `:skip` (matching SQL `UNIQUE` null semantics).
- **Index Symmetry:** Every mutation plans exact deletions for obsolete keys and insertions for new keys in one transactional pass.
- **Subtree Integrity:** A child entity cannot be inserted if its `nested_in` parent entity does not exist in `root[parent_col][parent_doc_id]`.

---

## 3. Acceptance Criteria

1. Property tests with `StreamData` verify that negative, zero, and positive 64-bit integers and microsecond datetimes sort in exact order under binary comparison.
2. Composite identity keys with variable-length strings (`{"ab", "cd"}` vs `{"a", "bcd"}`) never produce key collisions.
3. Secondary index range scans (`scan_secondary_range/4`) return correct `MapSet` of doc IDs for open, closed, and bounded range specs.
4. Parent entity deletion recursively purges all nested child indexes.
