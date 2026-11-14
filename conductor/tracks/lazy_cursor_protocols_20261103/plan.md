# Implementation Plan: `lazy_cursor_protocols_20261103`

## Phase 1: `%Xitdb.Cursor{}` Struct & `Access` Behaviour
- [x] Task: Define `%Xitdb.Cursor{}` and implement `@behaviour Access` (`fetch/2`, `get_and_update/3`, `pop/2`).
- [x] Task: Support staged write-mutation paths when `put_in/3`, `update_in/3`, or `pop_in/2` is invoked inside `Xitdb.transact/2`.

## Phase 2: `Enumerable`, `Inspect`, and Collection Wrappers
- [x] Task: Implement `Enumerable` (`count/1`, `member?/2`, `slice/1`, `reduce/3`) for `%Xitdb.Cursor{}`.
- [x] Task: Implement `Inspect` for `%Xitdb.Cursor{}` and `Xitdb.Collection` wrapper structs (`counted_map`, `sorted_map`, `linked_list`, sets).
