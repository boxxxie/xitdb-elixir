# Specification: Domain Datatypes, Struct Encoding & Order-Preserving Range Keys

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `domain_datatypes_and_range_keys_20261114`
> - **Type:** Feature
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Submodule Boundary:** `native/xitdb-odin` stays untouched (Elixir client + Ash layer only)
> - **Primary Modules:** `lib/xitdb/key.ex`, `lib/xitdb/encoder.ex`, `lib/xitdb/tx_compiler.ex`, `lib/xitdb/ash/codec.ex`, `lib/xitdb/ash/types/fixed_decimal64.ex`, `lib/xitdb/ash/types/ranged_unit.ex`
> - **Done When:** All 4-layer ATDD scenarios, `StreamData` order-preservation property tests, Ash `Query` range-scan tests, and `mix precommit` pass with zero warnings.

---

## 1. Goal & Motivation

`xitdb` stores values in fixed 9-byte `Slot`s (`Uint`, `Int`, `Float`, `Short_Bytes`, `Bytes`, and 8 container tags) plus 2-byte `format_tag` payloads (`{:tagged, <<a, b>>, binary}`). Supporting rich domain datatypes—such as Bragi's `Decimal_64` (fixed-scale `i64`/`u64` with embedded decimal precision), `u64` values exceeding `max(i64)` (`9_223_372_036_854_775_807`), `Ranged_Unit` intervals, and Elixir structs like `%Decimal{}`—requires:

1. Exposing public order-preserving binary key encoders (`Xitdb.Key`) for `:sorted_map` range scans and Ash B+Tree indexes, including full unsigned 64-bit (`encode_u64_be/1`).
2. Allowing Elixir structs to encode directly into `xitdb`-compatible values during `Xitdb.transact/3`, `tx`/`tx!` DSL writes, and `put_in`/`update_in` cursor edits via `Xitdb.Encoder`.
3. Extending `Xitdb.Ash.Codec` for `:unsigned_integer`, `{:tagged, tag, payload}` round-tripping, and custom `Ash.Type` index-key hooks so `<`, `<=`, `>=`, `>` range queries never silently degrade to `:erlang.term_to_binary/2`.
4. Providing built-in `FixedDecimal64` (supporting both native integer slots and `{:tagged, "d6", ...}` representations) and `RangedUnit` decomposition helpers.

---

## 2. Functional Requirements

### 2.1 Public Order-Preserving Key Codec (`Xitdb.Key`)
- Create `lib/xitdb/key.ex` exposing:
  - `encode_i64_be/1` and `decode_i64_be/1`
  - `encode_u64_be/1` and `decode_u64_be/1` (full unsigned 64-bit `0..18_446_744_073_709_551_615`)
  - `encode_f64_be/1`
  - `encode_decimal_key/1`
  - `encode_fixed_decimal64_be/2` (accepts integer or `%Decimal{}` + options `[scale: 10_000, signed?: true]`)
- Update `Xitdb.Ash.Codec` (`lib/xitdb/ash/codec.ex`) to delegate its existing public key functions (`encode_i64_be/1`, `decode_i64_be/1`, `encode_f64_be/1`, `encode_decimal_key/1`) to `Xitdb.Key` so existing callers and tests remain 100% backwards-compatible.

### 2.2 `Xitdb.Encoder` Protocol & `Xitdb.TxCompiler` Integration
- Define `defprotocol Xitdb.Encoder` in `lib/xitdb/encoder.ex` with `@spec encode(t()) :: term()`:
  - Implementations return any `xitdb`-writeable value: native scalar, `{:tagged, <<a, b>>, binary}`, list, plain map, `%Xitdb.Collection{}`, or `%MapSet{}`.
- Provide built-in implementations for:
  - `%Decimal{}` → `{:tagged, "dc", Decimal.to_string(dec, :normal)}` (when `Decimal` is loaded)
  - `%Date{}` → `{:tagged, "dt", Date.to_iso8601(d)}`
  - `%Time{}` → `{:tagged, "tm", Time.to_iso8601(t)}`
  - `%DateTime{}` → `{:tagged, "ts", <<DateTime.to_unix(dt, :microsecond)::signed-big-64>>}`
  - `%NaiveDateTime{}` → `{:tagged, "nt", NaiveDateTime.to_iso8601(ndt)}`
- Update `Xitdb.TxCompiler.compile_node_acc/4` (`lib/xitdb/tx_compiler.ex`) so any struct other than `%Xitdb.Collection{}` and `%MapSet{}` checks `Xitdb.Encoder.impl_for(struct)` and recursively compiles the encoded term. Unimplemented structs continue to raise/error clearly rather than passing raw structs to the NIF.

### 2.3 `Xitdb.Ash.Codec` Extensions
- Add `:unsigned_integer` to `@canonical_kinds`, `dump_attribute/2`, `load_attribute/2`, `encode_typed_scalar/2` (using `Xitdb.Key.encode_u64_be/1`), and `fixed_width_kind?/1`.
- Support `{:tagged, <<a, b>>, binary}` values in `dump_attribute/2` and `load_attribute/2` when returned by custom `Ash.Type.dump_to_embedded/3` / `Ash.Type.cast_stored/3`.
- Update `encode_attr_scalar/2` and `encode_composite_component/2` to check an optional `xitdb_index_key/2` callback (and optional `xitdb_fixed_width?/1` callback) on custom `Ash.Type` modules before falling back to `storage_type/2` or `:erlang.term_to_binary/2`.

### 2.4 Built-in `FixedDecimal64` & `RangedUnit` `Ash.Type`s
- **`Xitdb.Ash.Types.FixedDecimal64`** (`lib/xitdb/ash/types/fixed_decimal64.ex`):
  - Custom `Ash.Type` with constraints:
    - `scale:` positive integer power of 10 (default `10_000`, matching Bragi's `Decimal_64`)
    - `signed?:` boolean (default `true`; when `false`, supports full unsigned `u64` range `0..18_446_744_073_709_551_615`)
    - `representation:` `:integer | :tagged` (default `:integer` for native `Uint`/`Int` slots; `:tagged` stores `{:tagged, "d6", <<val::signed-big-64>>}` or `<<val::unsigned-big-64>>`)
  - Implements `xitdb_index_key/2` and `xitdb_fixed_width?/1` returning an 8-byte order-preserving binary (`encode_i64_be/1` or `encode_u64_be/1`) regardless of whether `representation` is `:integer` or `:tagged`.
- **`Xitdb.Ash.Types.RangedUnit`** (`lib/xitdb/ash/types/ranged_unit.ex`):
  - Struct (`min_val`, `max_val`, `bound_kind`, `dimension`, `currency`) + `Ash.Type` storing a compact map in the entity document.
  - Exposes `to_indexed_fields/2` to decompose a `%RangedUnit{}` into `%{min_d64: ..., max_d64: ..., bound: ..., unit: ...}` (for resources indexing `<prefix>_min_d64` / `<prefix>_max_d64` for interval overlap queries) and `overlaps?/2` helper.

---

## 3. Technical Invariants

1. **Exact Lexicographical Monotonicity:** For all valid `a, b` in `u64`, `i64`, `f64`, `Decimal`, and `FixedDecimal64`, `key(a) < key(b)` if and only if `a < b`.
2. **Backwards Compatibility:** Existing `Xitdb.Ash.Codec` function signatures, B+Tree hex key encodings, and `TxCompiler` behavior for plain maps, lists, `%MapSet{}`, and `%Xitdb.Collection{}` remain unchanged.
3. **Submodule Isolation:** No modifications to `native/xitdb-odin/`.

---

## 4. Out of Scope

- Modifying `_compare_pull_values/2` in `native/xitdb-odin/xitdb/dsl.odin` for native Datalog `<`, `>`, `<=`, `>=` comparisons on `{:tagged, <<a, b>>, binary}` payloads or `u64` values exceeding `max(i64)`. (Datalog `<, >, <=, >=` continues to operate natively on un-tagged `i64`/`f64`/`string` fields; Ash `Query` + `Indexer.scan_secondary_range/5` handle both `u64` and `:tagged` `FixedDecimal64` in Elixir.)

---

## 5. Acceptance Criteria

1. `StreamData` property tests confirm `Xitdb.Key` preserves exact `<, <=, ==, >=, >` order across negative, zero, positive, and `> max(i64)` values.
2. 4-layer ATDD scenarios verify `:sorted_map` range seeks with `Xitdb.Key` and struct writes via `Xitdb.Encoder` across `Xitdb.transact/3`, `tx` DSL, and `put_in/3`.
3. Ash `Query` range queries (`>`, `<`, `>=`, `<=`) return exact results for `:unsigned_integer` (`> max(i64)`), `:integer`-backed `FixedDecimal64`, `:tagged`-backed `FixedDecimal64`, and decomposed `RangedUnit` bounds.
4. `mix precommit` passes with zero warnings and clean formatting.
