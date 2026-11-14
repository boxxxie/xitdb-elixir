# Implementation Plan: Domain Datatypes, Struct Encoding & Order-Preserving Range Keys

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `domain_datatypes_and_range_keys_20261114`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Done When:** All 4-layer ATDD scenarios, `StreamData` property tests, Ash `Query` range-scan tests, and `mix precommit` pass with zero warnings.

---

## Phase 1: Public Order-Preserving Key Codecs (`Xitdb.Key`)

- [ ] Task: Write Red-First property and ATDD tests for `Xitdb.Key`
    - [ ] Add `test/xitdb/key_test.exs` with `StreamData` property tests verifying `<, <=, ==, >=, >` order preservation for `encode_u64_be/1` (including `0`, `2^63 - 1`, `2^63`, `2^64 - 1`), `encode_i64_be/1`, `encode_f64_be/1`, `encode_decimal_key/1`, and `encode_fixed_decimal64_be/2`
    - [ ] Add 4-layer ATDD scenario in `test/features/enumerable_collections_spec.exs` (wired through `ClientDSL` / `ClientDriver`) verifying `:sorted_map` range seeks with `Xitdb.Key`
- [ ] Task: Implement `Xitdb.Key` in `lib/xitdb/key.ex` and delegate from `Xitdb.Ash.Codec`
    - [ ] Implement `encode_i64_be/1`, `decode_i64_be/1`, `encode_u64_be/1`, `decode_u64_be/1`, `encode_f64_be/1`, `encode_decimal_key/1`, and `encode_fixed_decimal64_be/2`
    - [ ] Update `lib/xitdb/ash/codec.ex` so `Xitdb.Ash.Codec` delegates `encode_i64_be/1`, `decode_i64_be/1`, `encode_f64_be/1`, and `encode_decimal_key/1` to `Xitdb.Key`

---

## Phase 2: `Xitdb.Encoder` Protocol & `Xitdb.TxCompiler` Struct Encoding

- [ ] Task: Write Red-First ATDD scenarios for `Xitdb.Encoder`
    - [ ] Add scenarios in `test/features/transactions_and_time_travel_spec.exs` and `test/features/macro_dsl_spec.exs` (via `ClientDSL` / `ClientDriver`) writing `%Decimal{}`, `%Date{}`, `%Time{}`, `%DateTime{}`, `%NaiveDateTime{}`, and a custom struct implementing `Xitdb.Encoder` through `Xitdb.transact/3`, `tx/2`, and `put_in/3`
- [ ] Task: Implement `Xitdb.Encoder` (`lib/xitdb/encoder.ex`) and integrate into `Xitdb.TxCompiler`
    - [ ] Define `defprotocol Xitdb.Encoder` (`encode/1`) and built-in implementations for `%Decimal{}`, `%Date{}`, `%Time{}`, `%DateTime{}`, and `%NaiveDateTime{}`
    - [ ] Update `Xitdb.TxCompiler.compile_node_acc/4` in `lib/xitdb/tx_compiler.ex` to check `Xitdb.Encoder.impl_for/1` on non-`Collection`/non-`MapSet` structs and recursively compile the encoded result

---

## Phase 3: `Xitdb.Ash.Codec` Unsigned 64-Bit & Custom Index Key Hooks

- [ ] Task: Write Red-First tests for `:unsigned_integer` and custom `Ash.Type` index hooks
    - [ ] Add unit and property tests in `test/xitdb/ash/codec_test.exs` and `test/xitdb/ash/codec_properties_test.exs` covering `:unsigned_integer` (`> max(i64)`), `{:tagged, tag, payload}` attribute round-trips, and custom `Ash.Type` `xitdb_index_key/2` hooks
    - [ ] Add Ash `Query` range-scan tests (`>`, `<`, `>=`, `<=`) in `test/xitdb/ash/query_test.exs` for `:unsigned_integer` and custom-indexed `Ash.Type`s
- [ ] Task: Extend `Xitdb.Ash.Codec` in `lib/xitdb/ash/codec.ex`
    - [ ] Add `:unsigned_integer` to `@canonical_kinds`, `dump_attribute/2`, `load_attribute/2`, `encode_typed_scalar/2` (`Xitdb.Key.encode_u64_be/1`), and `fixed_width_kind?/1`
    - [ ] Support `{:tagged, <<a, b>>, binary}` values in `dump_attribute/2` and `load_attribute/2`
    - [ ] Check optional `xitdb_index_key/2` and `xitdb_fixed_width?/1` callbacks on custom `Ash.Type` modules in `encode_attr_scalar/2` and `encode_composite_component/2`

---

## Phase 4: Built-in `FixedDecimal64` & `RangedUnit` `Ash.Type`s

- [ ] Task: Write Red-First tests for `FixedDecimal64` and `RangedUnit`
    - [ ] Create `test/xitdb/ash/types_test.exs` testing `FixedDecimal64` in both `:integer` and `:tagged` representations (signed `i64` and unsigned `u64 > max(i64)`) with Ash `Query` range filters (`>`, `<`, `>=`, `<=`)
    - [ ] Test `RangedUnit` round-tripping, `to_indexed_fields/2` decomposition (`*_min_d64`, `*_max_d64`, `*_bound`, `*_unit`), and interval overlap queries
- [ ] Task: Implement `Xitdb.Ash.Types.FixedDecimal64` and `Xitdb.Ash.Types.RangedUnit`
    - [ ] Implement `lib/xitdb/ash/types/fixed_decimal64.ex` with `scale:`, `signed?:`, and `representation: :integer | :tagged` constraints plus `xitdb_index_key/2` and `xitdb_fixed_width?/1`
    - [ ] Implement `lib/xitdb/ash/types/ranged_unit.ex` with `%RangedUnit{}` struct, `Ash.Type` callbacks, `to_indexed_fields/2`, and `overlaps?/2`

---

## Phase 5: Documentation & Final Verification

- [ ] Task: Update documentation and verify full suite
    - [ ] Update `docs/collections-and-indexing.md`, `docs/ash-and-spark.md`, and `usage-rules.md` covering `Xitdb.Key`, `Xitdb.Encoder`, `:unsigned_integer`, `FixedDecimal64`, `RangedUnit`, and the `native/xitdb-odin` Datalog comparison boundary
    - [ ] Run `mix precommit` (`mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`) and confirm zero warnings and all tests passing
