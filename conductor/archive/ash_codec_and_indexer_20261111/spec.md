# Specification: Track 11 — Binary Key Codec (`Xitdb.Ash.Codec`) & Secondary B+Tree Indexer (`Xitdb.Ash.Indexer`)

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_codec_and_indexer_20261111`
> - **Wave:** Wave 2 (`Track 11A`: Key Codec & Flat Top-Level Secondary B+Tree Indexer) / Wave 3 (`Track 11B`: `nested_in` Physical Subtree Storage & Recursive Cleanup)
> - **Prerequisites:** [`ash_dsl_and_verifiers_20261111`](../ash_dsl_and_verifiers_20261111/index.md) (unified `Xitdb.Ash.{Index,Reference,SearchField,NestedIn}` structs and `lib/xitdb/ash/search.ex` baseline)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Modules:** `lib/xitdb/ash/codec.ex`, `lib/xitdb/ash/indexer.ex`
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Done When:** Complete unit, property, and integration tests pass with zero warnings, verifying order-preserving key encoding (including `Decimal` trailing-zero scale invariance, `:utc_datetime` second truncation, fixed-width 8-byte `:date` / `:time` / `:time_usec` keys, `counted_set_fields`, and `:context` multitenancy scoping), collision-free composite identities, prefix-aware composite range bounds, deduplicated `_parent` locators, single-commit operation staging with BM25 token diffing, and recursive nested-index cleanup.

---

## 1. Goal & Architecture

In `Xitdb.Ash.DataLayer`, fast point queries, range scans, and unique identity checks rely on deterministic lexicographical ordering inside `:sorted_map` B+Tree indexes backed strictly by real `Xitdb` cursor and transaction APIs (`Xitdb.as_of/2`, `Xitdb.Cursor`, `Xitdb.NIF.nif_slot_entries/5`, `Xitdb.TxCompiler`, `Xitdb.transact_ops/3`).

`Xitdb.Ash.Codec` and `Xitdb.Ash.Indexer` implement:
1. **Order-Preserving Binary B+Tree Keys (`Xitdb.Ash.Codec`):**
   - **Signed 64-Bit Integers & Timestamps:** Two's-complement sign bit is flipped (`bxor(msb, 0x80)`) into an 8-byte big-endian binary (`encode_i64_be/1`) so unsigned byte comparison matches signed numerical and chronological ordering across all valid 64-bit values (`-9_223_372_036_854_775_808` to `9_223_372_036_854_775_807`). `:utc_datetime` truncates to `:second` in both `dump_attribute/2` and `encode_typed_scalar/2`, while `:utc_datetime_usec` and `:datetime` preserve microsecond precision.
   - **Fixed-Width 8-Byte Dates & Times:** `:date` encodes `Date.to_gregorian_days(d)` via `encode_i64_be/1` (preserving exact chronological order even for negative BCE years); `:time` (truncated to `:second`) and `:time_usec` encode microseconds since midnight (`sec * 1_000_000 + usec`) via `encode_i64_be/1`. All three are registered in `fixed_width_kind?/1`.
   - **Floats & Decimals:** IEEE-754 64-bit floats normalize `-0.0` to `+0.0` and invert negative bit patterns. `Decimal` keys compute `exp10 = length(raw_digits) + dec.exp` *before* stripping trailing zeros (`60 == 60.0 == 60.000` -> `exp10 = 2, digits = [6]`), guard `coef == 0` (`<<0x80>>`), and convert float inputs via `Decimal.from_float/1`.
   - **Case-Insensitive Strings (`Ash.Type.CiString`) & `counted_set_fields`:** Original casing is preserved in entity cursors while index keys and doc IDs are lowercased. Array attributes listed in `Info.counted_set_fields(resource)` serialize as `Xitdb.counted_set/1` (`:counted_hash_set`) and hydrate back into Elixir lists.
2. **Collision-Free Composite & Multitenant Keys (`Xitdb.Ash.Codec`):**
   - **`:context` & `:attribute` Multitenancy:** `Codec.scoped_collection(resource, tenant)` namespaces `:context`-multitenant collections to `"t:#{encode_doc_id(tenant)}:#{collection}"`, while `resolve_identity_tenant/4` uses `Map.get(record, tenant_attr) || tenant` so `nil` struct attributes never shadow an explicit query/changeset `tenant`.
   - **Identities:** Encoded with presence tags (`@null_tag 0x00`, `@value_tag 0x01`) and 32-bit length headers (`<<len::unsigned-big-32, part::binary>>`), prefixed by tenant scope, honoring `identity.nils_distinct?`.
   - **Secondary Indexes & Hex-Safe B+Tree Keys:** Interior `0x00` bytes in variable-width fields are escaped to `<<0x00, 0xFF>>` and terminated with `<<0x00, 0x00>>`. Binary B+Tree keys are stored under lowercase hexadecimal (`Base.encode16(key, case: :lower)`), which is 100% ASCII-safe for `TxCompiler` selectors and strictly preserves unsigned byte lexicographical order (`a < b <=> hex(a) < hex(b)`).
3. **Single-Commit Staging, Prefix-Safe Range Scans & Subtree Maintenance (`Xitdb.Ash.Indexer`):**
   - **Single-Commit Staging (`plan_put_ops/5`, `plan_delete_ops/4`):** Compiles entity cursor writes, `_parent` locators, unique identities, secondary `:sorted_map` B+Tree diffs, and incremental BM25 `idx.search.<collection>` diffs (removing stale tokens on update/delete) into a single flat `ops` list so `Mutator` commits once per mutation (`base_moment: moment`).
   - **Composite Range Bound Accuracy (`scan_secondary_range/5`):** Partial composite bounds (`k < n` columns) include trailing column suffixes on `:inclusive` upper bounds (`key <= bound_key or binary_starts_with?(key, bound_key)`) and skip matching prefixes on `:exclusive` lower bounds (`key > bound_key and not binary_starts_with?(key, bound_key)`).
   - **Deduplicated `_parent` Subtree Iteration & Recursive Cleanup (Track 11B):** `all_cursors/3` deduplicates `parent_doc_id` (`Stream.uniq/1`) before scanning parent subtrees to avoid quadratic `K^2` duplicates, normalizes `:ci_string` primary keys in `cursor_matches_doc_id?/3`, and recursively purges child indexes before deleting a parent entity.

---

## 2. Technical Invariants

- **Lexicographical Monotonicity:** For all values `a, b`, `encode_scalar_key(attr, a) < encode_scalar_key(attr, b)` if and only if `a < b`.
- **Zero Hallucinated Core APIs:** `Indexer.Storage` exclusively calls real `Xitdb` APIs (`Xitdb.db/1`, `Xitdb.Cursor`, `Xitdb.NIF.nif_slot_count/3`, `Xitdb.NIF.nif_slot_entries/5`, `Xitdb.TxCompiler`, `Xitdb.transact_ops/3`).
- **Identity Null Semantics:** When `identity.nils_distinct?` is `true`, any `nil` key component returns `:skip` (matching SQL `UNIQUE` null semantics).
- **Single-Commit Atomicity:** Every entity write or delete produces a self-contained `ops` list covering entity data, unique identities, secondary B+Trees, and BM25 search postings.

---

## 3. Acceptance Criteria

1. Property tests with `StreamData` verify that negative, zero, and positive 64-bit integers, dates, times, microsecond/second datetimes, floats, and `Decimal` values (`60 == 60.0 == 60.000`) sort in exact order under binary comparison.
2. Composite identity keys with variable-length strings (`{"ab", "cd"}` vs `{"a", "bcd"}`) and `:attribute` / `:context` multitenancy never collide or leak across tenants.
3. Secondary index range scans (`scan_secondary_range/5`) return the exact `MapSet` of doc IDs for both full-key and partial-prefix composite bounds (`<=`, `<`, `>=`, `>`).
4. Updating or deleting a searchable record atomically removes obsolete BM25 posting tokens in the same `Xitdb.transact_ops/3` commit.
5. `all_cursors/3` on `nested_in` resources visits each parent subtree at most once (`O(K)` rather than `O(K^2)`), and parent deletion recursively purges all nested child indexes.
