# Reference: Wave 3 Native Odin NIF BM25 Pushdown (`Track 9`) & Physical `nested_in` Subtree Execution Guide (`Track 11B`)

> [!IMPORTANT]
> **Track Reference Metadata:**
> - **Associated Track:** [`nif_bm25_search_20261111`](./index.md) (`Wave 3`)
> - **Specification & Plan:** [`./spec.md`](./spec.md) · [`./plan.md`](./plan.md)
> - **Wave 3 Sibling Track (Track 11B):** [`../ash_codec_and_indexer_20261111/reference.md`](../ash_codec_and_indexer_20261111/reference.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Purpose:** Copy-paste-ready C-ABI shim, Odin NIF procedures (verified with `odin check`), Elixir `Xitdb.NIF` & `Xitdb.Ash.Search` `:backend` dispatcher, `StreamData` differential verification suite, and consolidated Wave 3 Track 11B physical `nested_in` execution guide.

---

## 1. Architectural Invariants Summary

1. **Docs-Only Planning Artifact + Dual-Track Wave 3 Coverage:**
   Wave 3 pairs **Track 9** (`nif_sorted_map_seek/5` + `nif_bm25_search/7`) with **Track 11B** (`nested_in` physical subtree storage, reparenting, parent-jump queries, and recursive child index purging). Keeping both tracks mapped in [`./plan.md`](./plan.md) and Section 6 below ensures zero Wave 3 items are overlooked even though Track 11B shares `../ash_codec_and_indexer_20261111/` with Wave 2's Track 11A.
2. **MVCC Snapshot & `TestSandbox` Isolation:**
   `nif_bm25_search/7` receives `(db_ref, root_tag_id, root_val_int)` from `Storage.root_cursor(db)`, resolving both historical moment cursors (`root_tag_id == -1`) and concrete root `Slot` cursors (`root_tag_id == 4`) under `nif_rwlock_rlock(handle.rwlock)`.
3. **Dirty CPU Scheduler + Valgrind-Clean `mem.Dynamic_Arena`:**
   Both `nif_sorted_map_seek/5` and `nif_bm25_search/7` run with `ERL_NIF_DIRTY_JOB_CPU_BOUND` and allocate all temporary maps, slices, and cloned `.Short_Bytes` keys from a per-call `mem.Dynamic_Arena` backed by `runtime.default_allocator()` (`defer mem.dynamic_arena_destroy(&arena)`), eliminating both heap leaks on early error paths and retained `@(thread_local)` `context.temp_allocator` blocks under Valgrind.
4. **IEEE-754 BM25 Parity & Deterministic Tie-Breaking:**
   Unscales `@weight_scale = 100` (`BM25_WEIGHT_SCALE :: 100.0`) across `total_len`, `docs[doc_key]["len"]`, and `terms[term][doc_key]`, computes non-negative Robertson–Spärck Jones IDF `ln(1.0 + (N - df + 0.5) / (df + 0.5))`, and enforces total order `(descending score, ascending raw UTF-8 doc_key bytes)` across both `:nif` and `:elixir` backends.

---

## 2. C-ABI Shim Additions (`native/nif_entry.c`)

Apply these three additions to `native/nif_entry.c`:

```c
// 1. Add extern declarations alongside odin_nif_compact (around line 28):
extern ERL_NIF_TERM odin_nif_sorted_map_seek(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM odin_nif_bm25_search(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);

// 2. Add O(1) map lookup helper alongside nif_is_map (around line 166):
int nif_get_map_value(ErlNifEnv* env, ERL_NIF_TERM map, ERL_NIF_TERM key, ERL_NIF_TERM* val_out) {
    return enif_get_map_value(env, map, key, val_out);
}

// 3. Register both Dirty CPU NIFs in nif_funcs[] (around line 237):
static ErlNifFunc nif_funcs[] = {
    {"nif_open",             3, odin_nif_open,             ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"nif_close",            1, odin_nif_close,            ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"nif_sync",             1, odin_nif_sync,             ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"nif_info",             1, odin_nif_info,             0},
    {"nif_moment_slot",      2, odin_nif_moment_slot,      0},
    {"nif_slot_get_key",     4, odin_nif_slot_get_key,     0},
    {"nif_slot_get_index",   4, odin_nif_slot_get_index,   0},
    {"nif_slot_count",       3, odin_nif_slot_count,       0},
    {"nif_slot_contains",    4, odin_nif_slot_contains,    0},
    {"nif_slot_slice",       5, odin_nif_slot_slice,       0},
    {"nif_slot_entries",     5, odin_nif_slot_entries,     0},
    {"nif_slot_materialize", 4, odin_nif_slot_materialize, 0},
    {"nif_transact",         4, odin_nif_transact,         ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"nif_select",           3, odin_nif_select,           0},
    {"nif_pull",             4, odin_nif_pull,             0},
    {"nif_diff_moments",     3, odin_nif_diff_moments,     0},
    {"nif_history_of",       2, odin_nif_history_of,       0},
    {"nif_query_datalog",    3, odin_nif_query_datalog,    0},
    {"nif_compact",          2, odin_nif_compact,          ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"nif_sorted_map_seek",  5, odin_nif_sorted_map_seek,  ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_bm25_search",      7, odin_nif_bm25_search,      ERL_NIF_DIRTY_JOB_CPU_BOUND}
};
```

> [!WARNING]
> Never add `enif_get_string` to `native/nif_entry.c`. `enif_get_string` expects Latin-1 charlists (`[0..255]`) and fails on Elixir UTF-8 binaries. Always inspect input binaries via `nif_inspect_binary` (`enif_inspect_binary`) and construct output binaries via `nif_make_binary_slice` (`enif_make_new_binary` + `memcpy`).

---

## 3. Odin NIF Implementation (`native/xitdb_nif.odin`)

Keep the Wave 3 procedures inside `native/xitdb_nif.odin` so Hex `package/0` (`mix.exs`) includes all native sources without altering tarball file lists.

### 3.1 Imports, Foreign Binding & Pre-Interned Atoms

```odin
// 1. Add core:math, core:mem, core:slice, core:unicode/utf8 to imports at top of native/xitdb_nif.odin:
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import xitdb "xitdb:."

// 2. Add nif_get_map_value inside `foreign _ { ... }`:
	nif_get_map_value :: proc(env: ErlNifEnv, map_term: ERL_NIF_TERM, key: ERL_NIF_TERM, val_out: ^ERL_NIF_TERM) -> c.int ---

// 3. Add global atoms & initialize them inside `odin_nif_init_atoms`:
ATOM_MATCH:                 ERL_NIF_TERM
ATOM_ALL:                   ERL_NIF_TERM
ATOM_ANY:                   ERL_NIF_TERM
ATOM_PREFIX:                ERL_NIF_TERM
ATOM_MIN_PREFIX_LENGTH:     ERL_NIF_TERM
ATOM_MAX_PREFIX_EXPANSIONS: ERL_NIF_TERM
ATOM_K1:                    ERL_NIF_TERM
ATOM_B:                     ERL_NIF_TERM
ATOM_EXACT_BOOST:           ERL_NIF_TERM
ATOM_PREFIX_WEIGHT:         ERL_NIF_TERM

// Inside odin_nif_init_atoms(env):
	ATOM_MATCH                 = make_atom(env, "match")
	ATOM_ALL                   = make_atom(env, "all")
	ATOM_ANY                   = make_atom(env, "any")
	ATOM_PREFIX                = make_atom(env, "prefix")
	ATOM_MIN_PREFIX_LENGTH     = make_atom(env, "min_prefix_length")
	ATOM_MAX_PREFIX_EXPANSIONS = make_atom(env, "max_prefix_expansions")
	ATOM_K1                    = make_atom(env, "k1")
	ATOM_B                     = make_atom(env, "b")
	ATOM_EXACT_BOOST           = make_atom(env, "exact_boost")
	ATOM_PREFIX_WEIGHT         = make_atom(env, "prefix_weight")
```

### 3.2 `odin_nif_sorted_map_seek` (Arity 5) & `odin_nif_bm25_search` (Arity 7)

Append to the end of `native/xitdb_nif.odin`:

```odin
// ============================================================================
// Wave 3: Direct B+Tree Prefix Seek & Native BM25 Pushdown NIFs
// ============================================================================

BM25_WEIGHT_SCALE :: 100.0

BM25_Match_Mode :: enum u8 {
	All = 0,
	Any = 1,
}

BM25_Opts :: struct {
	match_mode:            BM25_Match_Mode,
	prefix_enabled:        bool,
	min_prefix_length:     int,
	max_prefix_expansions: int,
	k1:                    f64,
	b:                     f64,
	exact_boost:           f64,
	prefix_weight:         f64,
}

BM25_Hit :: struct {
	doc_key: string,
	score:   f64,
}

// Strict total order: primary key descending `score` (f64), secondary key ascending `doc_key` raw UTF-8 bytes.
bm25_hit_better :: #force_inline proc(a, b: BM25_Hit) -> bool {
	if a.score != b.score {
		return a.score > b.score
	}
	return a.doc_key < b.doc_key
}

// Min-heap root predicate: keeps the worst of the current Top-K winners at `heap[0]`.
bm25_hit_worse :: #force_inline proc(a, b: BM25_Hit) -> bool {
	return bm25_hit_better(b, a)
}

bm25_heap_push :: proc(heap: ^[dynamic]BM25_Hit, item: BM25_Hit, k: int) {
	if len(heap^) < k {
		append(heap, item)
		idx := len(heap^) - 1
		for idx > 0 {
			parent := (idx - 1) / 2
			if bm25_hit_worse(heap[idx], heap[parent]) {
				heap[idx], heap[parent] = heap[parent], heap[idx]
				idx = parent
			} else {
				break
			}
		}
		return
	}

	if k > 0 && bm25_hit_better(item, heap[0]) {
		heap[0] = item
		n := len(heap^)
		idx := 0
		for {
			left := 2*idx + 1
			right := 2*idx + 2
			worst := idx
			if left < n && bm25_hit_worse(heap[left], heap[worst]) {
				worst = left
			}
			if right < n && bm25_hit_worse(heap[right], heap[worst]) {
				worst = right
			}
			if worst == idx {
				break
			}
			heap[idx], heap[worst] = heap[worst], heap[idx]
			idx = worst
		}
	}
}

// Clones `.Short_Bytes` and `.Bytes` keys onto `arena_alloc` so stack scratch buffers never alias map keys.
read_arena_string :: proc(cur: xitdb.Read_Cursor, arena_alloc: mem.Allocator) -> (s: string, err: xitdb.Error) {
	slot_ptr := xitdb.cursor_resolved(cur) or_return
	if slot_ptr.slot.tag == .Short_Bytes && !slot_ptr.slot.full {
		sb_buf: [8]u8 = ---
		b_obj := xitdb.cursor_read_bytes_buf(cur, sb_buf[:]) or_return
		return strings.clone(string(b_obj.value), arena_alloc), nil
	}
	return xitdb.cursor_read_string(cur, 0, arena_alloc)
}

// Reads non-negative integers stored as either `.Uint` (Elixir `odin_nif_transact`) or `.Int` (raw Odin).
read_cursor_nonneg_int :: proc(cur: xitdb.Read_Cursor) -> (val: i64, ok: bool, err: xitdb.Error) {
	slot_ptr := xitdb.cursor_resolved(cur) or_return
	#partial switch slot_ptr.slot.tag {
	case .Uint:
		u := xitdb.cursor_read_uint(cur) or_return
		return i64(u), true, nil
	case .Int:
		i := xitdb.cursor_read_int(cur) or_return
		if i < 0 {
			return 0, true, nil
		}
		return i, true, nil
	}
	return 0, false, nil
}

read_hash_map_nonneg_int :: proc(hm: xitdb.Read_Hash_Map, key: string) -> (val: i64, err: xitdb.Error) {
	cur_maybe := xitdb.hash_map_get_cursor(hm, key) or_return
	cur, has_cur := cur_maybe.?
	if !has_cur {
		return 0, nil
	}
	v, ok := read_cursor_nonneg_int(cur) or_return
	if !ok {
		return 0, nil
	}
	return v, nil
}

// Resolves snapshot root cursor coordinates `(root_tag_id, root_val_int)` from `Xitdb.db/1` or `Xitdb.as_of/2`.
resolve_snapshot_root_cursor :: proc(
	db: ^xitdb.Database,
	root_tag_id: i64,
	root_val_int: i64,
) -> (root_cur: xitdb.Read_Cursor, has_data: bool, out_of_range: bool, err: xitdb.Error) {
	if root_tag_id == -1 {
		rc := xitdb.database_root_cursor(db).read_cursor
		hist := xitdb.read_array_list_init(rc) or_return
		cnt := xitdb.array_list_count(hist) or_return
		if cnt == 0 {
			return {}, false, false, nil
		}
		resolved := root_val_int if root_val_int >= 0 else cnt + root_val_int
		if resolved < 0 || resolved >= cnt {
			return {}, false, true, nil
		}
		slot_maybe := xitdb.array_list_get_slot(hist, resolved) or_return
		s, found := slot_maybe.?
		if !found || s.value == 0 || (s.tag == .None && !s.full) {
			return {}, false, false, nil
		}
		return xitdb.Read_Cursor{
			slot_ptr = xitdb.Slot_Pointer{position = nil, slot = s},
			db       = db,
		}, true, false, nil
	}

	if root_val_int == 0 {
		return {}, false, false, nil
	}
	if root_tag_id < 0 || root_tag_id >= 16 {
		return {}, false, true, nil
	}
	tag := xitdb.Tag(u8(root_tag_id))
	if tag == .None {
		return {}, false, false, nil
	}
	return xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = xitdb.Slot{tag = tag, value = root_val_int}},
		db       = db,
	}, true, false, nil
}

get_term_float :: proc(env: ErlNifEnv, term: ERL_NIF_TERM) -> (f64, bool) {
	f: f64 = 0
	if nif_get_double(env, term, &f) != 0 {
		return f, true
	}
	i: i64 = 0
	if nif_get_int64(env, term, &i) != 0 {
		return f64(i), true
	}
	return 0, false
}

parse_bm25_opts :: proc(env: ErlNifEnv, opts_term: ERL_NIF_TERM) -> (opts: BM25_Opts, ok: bool) {
	opts = BM25_Opts{
		match_mode            = .All,
		prefix_enabled        = true,
		min_prefix_length     = 3,
		max_prefix_expansions = 64,
		k1                    = 1.2,
		b                     = 0.75,
		exact_boost           = 1.25,
		prefix_weight         = 1.0,
	}

	if nif_is_map(env, opts_term) == 0 {
		return opts, false
	}

	v: ERL_NIF_TERM
	if nif_get_map_value(env, opts_term, ATOM_MATCH, &v) != 0 {
		if v == ATOM_ALL {
			opts.match_mode = .All
		} else if v == ATOM_ANY {
			opts.match_mode = .Any
		} else {
			return opts, false
		}
	}

	if nif_get_map_value(env, opts_term, ATOM_PREFIX, &v) != 0 {
		if v == ATOM_TRUE {
			opts.prefix_enabled = true
		} else if v == ATOM_FALSE {
			opts.prefix_enabled = false
		} else {
			return opts, false
		}
	}

	if nif_get_map_value(env, opts_term, ATOM_MIN_PREFIX_LENGTH, &v) != 0 {
		iv: i64 = 0
		if nif_get_int64(env, v, &iv) == 0 || iv < 1 {
			return opts, false
		}
		opts.min_prefix_length = int(iv)
	}

	if nif_get_map_value(env, opts_term, ATOM_MAX_PREFIX_EXPANSIONS, &v) != 0 {
		iv: i64 = 0
		if nif_get_int64(env, v, &iv) == 0 || iv < 1 {
			return opts, false
		}
		opts.max_prefix_expansions = int(iv)
	}

	if nif_get_map_value(env, opts_term, ATOM_K1, &v) != 0 {
		fv, fok := get_term_float(env, v)
		if !fok || fv < 0.0 {
			return opts, false
		}
		opts.k1 = fv
	}

	if nif_get_map_value(env, opts_term, ATOM_B, &v) != 0 {
		fv, fok := get_term_float(env, v)
		if !fok || fv < 0.0 || fv > 1.0 {
			return opts, false
		}
		opts.b = fv
	}

	if nif_get_map_value(env, opts_term, ATOM_EXACT_BOOST, &v) != 0 {
		fv, fok := get_term_float(env, v)
		if !fok || fv < 0.0 {
			return opts, false
		}
		opts.exact_boost = fv
	}

	if nif_get_map_value(env, opts_term, ATOM_PREFIX_WEIGHT, &v) != 0 {
		fv, fok := get_term_float(env, v)
		if !fok || fv < 0.0 {
			return opts, false
		}
		opts.prefix_weight = fv
	}

	return opts, true
}

collect_postings_into_map :: proc(
	postings_cur: xitdb.Read_Cursor,
	multiplier: f64,
	dest: ^map[string]f64,
	arena_alloc: mem.Allocator,
) -> xitdb.Error {
	it := xitdb.cursor_iterator(postings_cur) or_return
	for {
		next_maybe := xitdb.cursor_iterator_next(&it) or_return
		elem_cur, has_next := next_maybe.?
		if !has_next {
			break
		}
		kv := xitdb.cursor_read_kv_pair(elem_cur, arena_alloc) or_return
		doc_key := read_arena_string(kv.key_cursor, arena_alloc) or_return
		if doc_key == "__tx" {
			continue
		}
		scaled_tf, ok_tf := read_cursor_nonneg_int(kv.value_cursor) or_return
		if !ok_tf || scaled_tf <= 0 {
			continue
		}
		tf := (f64(scaled_tf) / BM25_WEIGHT_SCALE) * multiplier
		if existing, found := dest[doc_key]; found {
			dest[doc_key] = existing + tf
		} else {
			dest[doc_key] = tf
		}
	}
	return nil
}

// `nif_sorted_map_seek(db_ref, slot_tag_id, slot_val_int, prefix_bin, limit_int)` ->
// `{:ok, [{term_bin, slot_tuple}, ...], next_cursor_or_nil} | {:error, reason}`
@(export)
odin_nif_sorted_map_seek :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(
		&arena,
		block_allocator = runtime.default_allocator(),
		array_allocator = runtime.default_allocator(),
	)
	defer mem.dynamic_arena_destroy(&arena)

	arena_alloc := mem.dynamic_arena_allocator(&arena)
	context.allocator = arena_alloc
	context.temp_allocator = arena_alloc

	if argc != 5 {
		return make_err(env, "badarg")
	}

	handle, ok := get_handle(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}

	tag_int: i64 = 0
	val_int: i64 = 0
	limit_int: i64 = 0
	if nif_get_int64(env, argv[1], &tag_int) == 0 ||
	   nif_get_int64(env, argv[2], &val_int) == 0 ||
	   nif_get_int64(env, argv[4], &limit_int) == 0 {
		return make_err(env, "badarg")
	}

	prefix, ok_p := get_string_from_binary(env, argv[3])
	if !ok_p {
		return make_err(env, "badarg")
	}

	if tag_int < 0 || tag_int >= 16 {
		return make_err(env, "badarg")
	}
	tag := xitdb.Tag(u8(tag_int))
	if tag != .Sorted_Map && tag != .None {
		return make_err(env, "unsupported")
	}

	if val_int == 0 || tag == .None || limit_int <= 0 {
		empty_list := nif_make_list_from_array(env, nil, 0)
		return nif_make_tuple3(env, ATOM_OK, empty_list, ATOM_NIL)
	}

	nif_rwlock_rlock(handle.rwlock)
	defer nif_rwlock_runlock(handle.rwlock)

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = xitdb.Slot{tag = tag, value = val_int}},
		db       = &handle.db,
	}

	sm_col, sm_err := xitdb.read_sorted_map_init(cur)
	if sm_err != nil {
		return make_xitdb_err(env, sm_err)
	}

	it, it_err := xitdb.sorted_map_iterator_from_string(sm_col, prefix)
	if it_err != nil {
		return make_xitdb_err(env, it_err)
	}

	cap_hint := int(min(limit_int, 256))
	items := make([dynamic]ERL_NIF_TERM, 0, cap_hint, arena_alloc)
	next_cursor_term: ERL_NIF_TERM = ATOM_NIL
	emitted: i64 = 0
	sb_buf: [8]u8 = ---

	for {
		next_maybe, n_err := xitdb.cursor_iterator_next(&it)
		if n_err != nil {
			return make_xitdb_err(env, n_err)
		}
		elem_cur, has_next := next_maybe.?
		if !has_next {
			break
		}

		kv, kv_err := xitdb.cursor_read_kv_pair(elem_cur, arena_alloc)
		if kv_err != nil {
			return make_xitdb_err(env, kv_err)
		}
		k_str, k_err := read_key_cursor_string(kv.key_cursor, sb_buf[:])
		if k_err != nil {
			return make_xitdb_err(env, k_err)
		}
		if !strings.has_prefix(k_str, prefix) {
			break
		}

		if emitted == limit_int {
			next_cursor_term = make_binary(env, k_str)
			break
		}

		val_slot, vs_err := xitdb.cursor_slot(kv.value_cursor)
		if vs_err != nil {
			return make_xitdb_err(env, vs_err)
		}
		val_term, vt_err := slot_to_term(env, &handle.db, val_slot)
		if vt_err != nil {
			return make_xitdb_err(env, vt_err)
		}

		append(&items, nif_make_tuple2(env, make_binary(env, k_str), val_term))
		emitted += 1
	}

	list_term: ERL_NIF_TERM
	if len(items) == 0 {
		list_term = nif_make_list_from_array(env, nil, 0)
	} else {
		list_term = nif_make_list_from_array(env, raw_data(items[:]), c.uint(len(items)))
	}
	return nif_make_tuple3(env, ATOM_OK, list_term, next_cursor_term)
}

// `nif_bm25_search(db_ref, root_tag_id, root_val_int, collection_bin, query_terms, limit_int, opts_map)` ->
// `{:ok, [{doc_key_bin, score_float}, ...]} | {:error, reason}`
@(export)
odin_nif_bm25_search :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()

	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(
		&arena,
		block_allocator = runtime.default_allocator(),
		array_allocator = runtime.default_allocator(),
	)
	defer mem.dynamic_arena_destroy(&arena)

	arena_alloc := mem.dynamic_arena_allocator(&arena)
	context.allocator = arena_alloc
	context.temp_allocator = arena_alloc

	if argc != 7 {
		return make_err(env, "badarg")
	}

	handle, ok := get_handle(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}

	root_tag_id: i64 = 0
	root_val_int: i64 = 0
	limit_int: i64 = 0
	if nif_get_int64(env, argv[1], &root_tag_id) == 0 ||
	   nif_get_int64(env, argv[2], &root_val_int) == 0 ||
	   nif_get_int64(env, argv[5], &limit_int) == 0 {
		return make_err(env, "badarg")
	}

	collection, ok_col := get_string_from_binary(env, argv[3])
	if !ok_col {
		return make_err(env, "badarg")
	}

	if nif_is_list(env, argv[4]) == 0 {
		return make_err(env, "badarg")
	}

	opts, ok_opts := parse_bm25_opts(env, argv[6])
	if !ok_opts {
		return make_err(env, "badarg")
	}

	query_terms := make([dynamic]string, 0, 8, arena_alloc)
	seen_query_terms := make(map[string]bool, 8, arena_alloc)
	head: ERL_NIF_TERM
	tail := argv[4]
	for nif_is_empty_list(env, tail) == 0 {
		if nif_get_list_cell(env, tail, &head, &tail) == 0 {
			return make_err(env, "badarg")
		}
		tok, ok_tok := get_string_from_binary(env, head)
		if !ok_tok {
			return make_err(env, "badarg")
		}
		if len(tok) == 0 || seen_query_terms[tok] {
			continue
		}
		seen_query_terms[tok] = true
		append(&query_terms, tok)
	}

	empty_list := nif_make_list_from_array(env, nil, 0)
	if len(query_terms) == 0 || limit_int <= 0 || len(collection) == 0 {
		return make_ok(env, empty_list)
	}

	nif_rwlock_rlock(handle.rwlock)
	defer nif_rwlock_runlock(handle.rwlock)

	root_cur, has_root, out_of_range, root_err := resolve_snapshot_root_cursor(&handle.db, root_tag_id, root_val_int)
	if root_err != nil {
		return make_xitdb_err(env, root_err)
	}
	if out_of_range {
		return make_err(env, "moment_out_of_range")
	}
	if !has_root {
		return make_ok(env, empty_list)
	}

	// Traverse root["idx"]["search"][collection]
	root_hm, rhm_err := xitdb.read_hash_map_init(root_cur)
	if rhm_err != nil {
		return make_xitdb_err(env, rhm_err)
	}
	idx_maybe, idx_err := xitdb.hash_map_get_cursor(root_hm, "idx")
	if idx_err != nil {
		return make_xitdb_err(env, idx_err)
	}
	idx_cur, has_idx := idx_maybe.?
	if !has_idx {
		return make_ok(env, empty_list)
	}

	idx_hm, ihm_err := xitdb.read_hash_map_init(idx_cur)
	if ihm_err != nil {
		return make_xitdb_err(env, ihm_err)
	}
	search_maybe, s_err := xitdb.hash_map_get_cursor(idx_hm, "search")
	if s_err != nil {
		return make_xitdb_err(env, s_err)
	}
	search_cur, has_search := search_maybe.?
	if !has_search {
		return make_ok(env, empty_list)
	}

	search_hm, shm_err := xitdb.read_hash_map_init(search_cur)
	if shm_err != nil {
		return make_xitdb_err(env, shm_err)
	}
	col_maybe, c_err := xitdb.hash_map_get_cursor(search_hm, collection)
	if c_err != nil {
		return make_xitdb_err(env, c_err)
	}
	col_cur, has_col := col_maybe.?
	if !has_col {
		return make_ok(env, empty_list)
	}

	col_hm, chm_err := xitdb.read_hash_map_init(col_cur)
	if chm_err != nil {
		return make_xitdb_err(env, chm_err)
	}

	// 1. Read corpus stats from `meta` (`doc_count` & `total_len`)
	meta_maybe, m_err := xitdb.hash_map_get_cursor(col_hm, "meta")
	if m_err != nil {
		return make_xitdb_err(env, m_err)
	}
	meta_cur, has_meta := meta_maybe.?
	if !has_meta {
		return make_ok(env, empty_list)
	}
	meta_hm, mhm_err := xitdb.read_hash_map_init(meta_cur)
	if mhm_err != nil {
		return make_xitdb_err(env, mhm_err)
	}

	doc_count, dc_err := read_hash_map_nonneg_int(meta_hm, "doc_count")
	if dc_err != nil {
		return make_xitdb_err(env, dc_err)
	}
	total_len, tl_err := read_hash_map_nonneg_int(meta_hm, "total_len")
	if tl_err != nil {
		return make_xitdb_err(env, tl_err)
	}

	if doc_count <= 0 || total_len <= 0 {
		return make_ok(env, empty_list)
	}

	docs_maybe, d_err := xitdb.hash_map_get_cursor(col_hm, "docs")
	if d_err != nil {
		return make_xitdb_err(env, d_err)
	}
	docs_cur, has_docs := docs_maybe.?
	if !has_docs {
		return make_ok(env, empty_list)
	}
	docs_hm, dhm_err := xitdb.read_hash_map_init(docs_cur)
	if dhm_err != nil {
		return make_xitdb_err(env, dhm_err)
	}

	terms_maybe, t_err := xitdb.hash_map_get_cursor(col_hm, "terms")
	if t_err != nil {
		return make_xitdb_err(env, t_err)
	}
	terms_cur, has_terms := terms_maybe.?
	if !has_terms {
		return make_ok(env, empty_list)
	}
	terms_sm, tsm_err := xitdb.read_sorted_map_init(terms_cur)
	if tsm_err != nil {
		return make_xitdb_err(env, tsm_err)
	}

	// 2. Collect virtual-token posting maps (exact + bounded B+Tree prefix expansion)
	num_tokens := len(query_terms)
	token_postings := make([]map[string]f64, num_tokens, arena_alloc)
	idfs := make([]f64, num_tokens, arena_alloc)
	sb_buf: [8]u8 = ---

	for q_tok, tok_idx in query_terms {
		merged := make(map[string]f64, 32, arena_alloc)
		use_prefix := opts.prefix_enabled && utf8.rune_count_in_string(q_tok) >= opts.min_prefix_length

		if use_prefix {
			it, it_err := xitdb.sorted_map_iterator_from_string(terms_sm, q_tok)
			if it_err != nil {
				return make_xitdb_err(env, it_err)
			}
			scanned := 0
			for scanned < opts.max_prefix_expansions {
				next_maybe, n_err := xitdb.cursor_iterator_next(&it)
				if n_err != nil {
					return make_xitdb_err(env, n_err)
				}
				elem_cur, has_next := next_maybe.?
				if !has_next {
					break
				}
				kv, kv_err := xitdb.cursor_read_kv_pair(elem_cur, arena_alloc)
				if kv_err != nil {
					return make_xitdb_err(env, kv_err)
				}
				matched_term, kt_err := read_key_cursor_string(kv.key_cursor, sb_buf[:])
				if kt_err != nil {
					return make_xitdb_err(env, kt_err)
				}
				if !strings.has_prefix(matched_term, q_tok) {
					break
				}
				mult := opts.exact_boost if matched_term == q_tok else opts.prefix_weight
				if cp_err := collect_postings_into_map(kv.value_cursor, mult, &merged, arena_alloc); cp_err != nil {
					return make_xitdb_err(env, cp_err)
				}
				scanned += 1
			}
		} else {
			p_maybe, p_err := xitdb.sorted_map_get_cursor(terms_sm, q_tok)
			if p_err != nil {
				return make_xitdb_err(env, p_err)
			}
			if p_cur, has_p := p_maybe.?; has_p {
				if cp_err := collect_postings_into_map(p_cur, opts.exact_boost, &merged, arena_alloc); cp_err != nil {
					return make_xitdb_err(env, cp_err)
				}
			}
		}

		if opts.match_mode == .All && len(merged) == 0 {
			return make_ok(env, empty_list)
		}

		df := f64(len(merged))
		idfs[tok_idx] = math.ln(1.0 + (f64(doc_count) - df + 0.5) / (df + 0.5))
		token_postings[tok_idx] = merged
	}

	// 3. Resolve candidate document keys (`:all` smallest-posting intersection vs `:any` union)
	candidates := make([dynamic]string, 0, 64, arena_alloc)
	if opts.match_mode == .All {
		smallest_idx := 0
		for i in 1 ..< num_tokens {
			if len(token_postings[i]) < len(token_postings[smallest_idx]) {
				smallest_idx = i
			}
		}
		for doc_key in token_postings[smallest_idx] {
			in_all := true
			for i in 0 ..< num_tokens {
				if i == smallest_idx {
					continue
				}
				if doc_key not_in token_postings[i] {
					in_all = false
					break
				}
			}
			if in_all {
				append(&candidates, doc_key)
			}
		}
	} else {
		seen_docs := make(map[string]bool, 64, arena_alloc)
		for i in 0 ..< num_tokens {
			for doc_key in token_postings[i] {
				if !seen_docs[doc_key] {
					seen_docs[doc_key] = true
					append(&candidates, doc_key)
				}
			}
		}
	}

	if len(candidates) == 0 {
		return make_ok(env, empty_list)
	}

	// 4. Score candidates in IEEE-754 f64 & maintain bounded Top-K min-heap
	avg_dl := max((f64(total_len) / BM25_WEIGHT_SCALE) / f64(doc_count), 1.0e-6)
	k_limit := int(limit_int)
	top_heap := make([dynamic]BM25_Hit, 0, min(len(candidates), k_limit), arena_alloc)

	for doc_key in candidates {
		raw_doc_len: i64 = 0
		doc_maybe, dm_err := xitdb.hash_map_get_cursor(docs_hm, doc_key)
		if dm_err != nil {
			return make_xitdb_err(env, dm_err)
		}
		if doc_cur, has_doc := doc_maybe.?; has_doc {
			doc_entry_hm, de_err := xitdb.read_hash_map_init(doc_cur)
			if de_err != nil {
				return make_xitdb_err(env, de_err)
			}
			dl_val, dl_err := read_hash_map_nonneg_int(doc_entry_hm, "len")
			if dl_err != nil {
				return make_xitdb_err(env, dl_err)
			}
			raw_doc_len = dl_val
		}

		doc_len := f64(raw_doc_len) / BM25_WEIGHT_SCALE
		norm := opts.k1 * (1.0 - opts.b + opts.b * (doc_len / avg_dl))

		score: f64 = 0.0
		for i in 0 ..< num_tokens {
			if tf, ok_tf := token_postings[i][doc_key]; ok_tf && tf > 0.0 {
				score += idfs[i] * (tf * (opts.k1 + 1.0)) / (tf + norm)
			}
		}

		if score > 0.0 {
			bm25_heap_push(&top_heap, BM25_Hit{doc_key = doc_key, score = score}, k_limit)
		}
	}

	if len(top_heap) == 0 {
		return make_ok(env, empty_list)
	}

	slice.sort_by(top_heap[:], bm25_hit_better)

	hit_terms := make([]ERL_NIF_TERM, len(top_heap), arena_alloc)
	for hit, idx in top_heap {
		hit_terms[idx] = nif_make_tuple2(
			env,
			make_binary(env, hit.doc_key),
			nif_make_double(env, hit.score),
		)
	}
	return make_ok(env, nif_make_list_from_array(env, raw_data(hit_terms), c.uint(len(hit_terms))))
}
```

---

## 4. Elixir NIF and Search Integration (`lib/xitdb/nif.ex` & `lib/xitdb/ash/search.ex`)

### 4.1 `lib/xitdb/nif.ex` Declarations

```elixir
  def nif_sorted_map_seek(_db_ref, _slot_tag_id, _slot_val_int, _prefix_bin, _limit_int),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_bm25_search(
        _db_ref,
        _root_tag_id,
        _root_val_int,
        _collection_bin,
        _query_terms,
        _limit_int,
        _opts_map
      ),
      do: :erlang.nif_error(:nif_not_loaded)
```

### 4.2 `lib/xitdb/ash/search.ex` Backend Toggle, Tie-Break Alignment & Lazy Prefix Seek

1. **Extend `@query_schema` in `Xitdb.Ash.Search`:**
   ```elixir
   exact_boost: [
     type: :float,
     default: @exact_match_boost,
     doc: "Term-frequency multiplier when a matched index term equals the query token."
   ],
   prefix_weight: [
     type: :float,
     default: 1.0,
     doc: "Term-frequency multiplier for non-exact B+Tree prefix expansions."
   ],
   backend: [
     type: {:in, [:auto, :nif, :elixir]},
     default: :auto,
     doc:
       "Selects native Odin NIF pushdown (`:nif`), cursor-backed Elixir baseline (`:elixir`), " <>
         "or automatic NIF dispatch (`:auto`)."
   ]
   ```

2. **Dispatch `:auto | :nif | :elixir` & Pass Snapshot Root Coordinates:**
   ```elixir
   defp score_collection(db, collection, tokens, opts, pk_kind) do
     case resolve_backend(opts[:backend], db) do
       :nif -> score_collection_nif(db, collection, tokens, opts, pk_kind)
       :elixir -> score_collection_elixir(db, collection, tokens, opts, pk_kind)
     end
   end

   defp resolve_backend(:elixir, _db), do: :elixir
   defp resolve_backend(:nif, _db), do: :nif

   defp resolve_backend(:auto, db) do
     case Storage.root_cursor(db) do
       %Xitdb.Cursor{tx_mode: false} ->
         if function_exported?(Xitdb.NIF, :nif_bm25_search, 7), do: :nif, else: :elixir

       _ ->
         :elixir
     end
   end

   defp score_collection_nif(db, collection, tokens, opts, pk_kind) do
     case Storage.root_cursor(db) do
       %Xitdb.Cursor{tx_mode: false, db_ref: db_ref, tag_id: root_tag_id, value: root_val_int} ->
         nif_opts = %{
           match: opts[:match],
           prefix: opts[:prefix?],
           min_prefix_length: opts[:min_prefix_length],
           max_prefix_expansions: opts[:max_prefix_expansions],
           k1: opts[:k1] * 1.0,
           b: opts[:b] * 1.0,
           exact_boost: opts[:exact_boost] * 1.0,
           prefix_weight: opts[:prefix_weight] * 1.0
         }

         case Xitdb.NIF.nif_bm25_search(
                db_ref,
                root_tag_id,
                root_val_int,
                collection,
                tokens,
                opts[:limit],
                nif_opts
              ) do
           {:ok, raw_hits} ->
             Enum.map(raw_hits, fn {doc_key, score} ->
               {decode_doc_key(doc_key, pk_kind), score}
             end)

           {:error, reason} ->
             raise Xitdb.Error, reason: reason, details: %{collection: collection}
         end

       _ ->
         raise ArgumentError, "backend: :nif requires a committed Xitdb handle or snapshot cursor"
     end
   end
   ```

3. **Align `collect_token_postings/4` & Tie-Breaking in `score_collection_elixir/5`:**
   - Replace hardcoded `@exact_match_boost` / `1.0` in `collect_token_postings/4` with `opts[:exact_boost]` and `opts[:prefix_weight]`, and pass `opts[:backend]` to `Storage.scan_prefix/5`.
   - Sort `{doc_key, score}` **before** `decode_doc_key(doc_key, pk_kind)` so `:integer` PK ties break on raw UTF-8 `doc_key` byte order identically to `odin_nif_bm25_search`:
     ```elixir
     candidate_keys
     |> Enum.reduce([], fn doc_key, acc ->
       doc_len = Storage.read_doc_len(db, collection, doc_key) / @weight_scale
       norm = k1 * (1.0 - b + b * (doc_len / max(avg_dl, 1.0e-6)))

       score =
         Enum.reduce(weighted_tokens, 0.0, fn {postings, idf}, sum ->
           case Map.fetch(postings, doc_key) do
             {:ok, tf} when tf > 0.0 -> sum + idf * (tf * (k1 + 1.0)) / (tf + norm)
             _ -> sum
           end
         end)

       if score > 0.0, do: [{doc_key, score} | acc], else: acc
     end)
     |> Enum.sort_by(fn {doc_key, score} -> {-score, doc_key} end)
     |> Enum.take(opts[:limit])
     |> Enum.map(fn {doc_key, score} -> {decode_doc_key(doc_key, pk_kind), score} end)
     ```

4. **Lazy Cursor Prefix Seek in `Xitdb.Ash.Search.Storage`:**
   Expose `root_cursor/1` (`@doc false`) and `scan_prefix_cursors/4` returning `{[{term_bin, %Xitdb.Cursor{}}], next_cursor_or_nil}`:
   ```elixir
   @spec scan_prefix_cursors(term(), String.t(), String.t(), pos_integer()) ::
           {[{String.t(), Xitdb.Cursor.t()}], String.t() | nil}
   def scan_prefix_cursors(db, collection, prefix, limit) do
     case get_in_search(db, collection, "terms") do
       %Xitdb.Cursor{db_ref: db_ref, tag_id: tag_id, value: val, moment: moment} ->
         case Xitdb.NIF.nif_sorted_map_seek(db_ref, tag_id, val, prefix, limit) do
           {:ok, entries, next_cursor} ->
             cursors =
               Enum.map(entries, fn {term, slot_tuple} ->
                 {term, Xitdb.Cursor.from_nif_tuple(db_ref, slot_tuple, moment)}
               end)

             {cursors, next_cursor}

           _ ->
             {[], nil}
         end

       _ ->
         {[], nil}
     end
   end

   @spec scan_prefix(term(), String.t(), String.t(), pos_integer(), :auto | :nif | :elixir) :: [
           {String.t(), [{String.t(), pos_integer()}]}
         ]
   def scan_prefix(db, collection, prefix, limit, backend \\ :auto)

   def scan_prefix(db, collection, prefix, limit, :elixir) do
     scan_prefix_via_slot_entries(db, collection, prefix, limit)
   end

   def scan_prefix(db, collection, prefix, limit, _backend) do
     if function_exported?(Xitdb.NIF, :nif_sorted_map_seek, 5) do
       {cursor_entries, _next} = scan_prefix_cursors(db, collection, prefix, limit)
       Enum.map(cursor_entries, fn {term, cur} -> {term, Enum.to_list(cur)} end)
     else
       scan_prefix_via_slot_entries(db, collection, prefix, limit)
     end
   end
   ```

---

## 5. Differential Property & Snapshot Isolation Test Suite (`test/xitdb/ash/search_nif_test.exs`)

Save as `test/xitdb/ash/search_nif_test.exs` during Wave 3 execution:

```elixir
defmodule Xitdb.Ash.SearchNifTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Xitdb.Ash.Search
  alias Xitdb.Ash.Search.Storage

  defmodule IntDoc do
    use Ash.Resource, domain: Xitdb.Ash.SearchNifTest.Domain, data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store Xitdb.Ash.SearchNifTest.DummyStore
      collection :int_docs
      search_field :title, boost: 2.0
      search_field :body, boost: 0.75
    end

    attributes do
      attribute :id, :integer, primary_key?: true, allow_nil?: false, public?: true
      attribute :title, :string, public?: true
      attribute :body, :string, public?: true
    end
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource IntDoc
    end
  end

  test "nif_sorted_map_seek/5 returns lazy cursor tuples and lookahead continuation key" do
    {:ok, db} = Xitdb.open(backend: :memory)

    db =
      Enum.reduce(
        [
          %IntDoc{id: 1, title: "capital alpha", body: "cap"},
          %IntDoc{id: 2, title: "captain beta", body: "capstone"},
          %IntDoc{id: 10, title: "capture gamma", body: "delta"}
        ],
        db,
        &Search.index_record(&2, IntDoc, &1)
      )

    {entries, next_key} = Storage.scan_prefix_cursors(db, "int_docs", "cap", 2)
    assert Enum.map(entries, &elem(&1, 0)) == ["cap", "capital"]
    assert Enum.all?(entries, fn {_term, cur} -> match?(%Xitdb.Cursor{}, cur) end)
    assert next_key == "capstone"

    {rest, exhausted} = Storage.scan_prefix_cursors(db, "int_docs", next_key, 10)
    assert Enum.map(rest, &elem(&1, 0)) == ["capstone"]
    assert exhausted == nil
  end

  test "honors Xitdb.as_of/2 historical moments and UTF-8 doc_key tie-breaking on integer PKs" do
    {:ok, db} = Xitdb.open(backend: :memory)

    # Identical content on IDs 2 and 10 -> identical BM25 scores; "10" < "2" in UTF-8 bytes
    db = Search.index_record(db, IntDoc, %IntDoc{id: 2, title: "nordic Zürich", body: "fond"})
    db = Search.index_record(db, IntDoc, %IntDoc{id: 10, title: "nordic Zürich", body: "fond"})
    snap_before_delete = Xitdb.as_of(db, -1)

    db = Search.remove_record(db, IntDoc, 10)

    assert Search.ids(IntDoc, "zür", db: snap_before_delete, backend: :nif) == [10, 2]
    assert Search.ids(IntDoc, "zür", db: snap_before_delete, backend: :elixir) == [10, 2]
    assert Search.ids(IntDoc, "zür", db: db, backend: :nif) == [2]
  end

  property "backend: :nif matches backend: :elixir within 1.0e-5 across randomized corpora & params" do
    vocab = ["cap", "capital", "captain", "zürich", "über", "东京", "market", "fund", "equity"]

    doc_gen =
      tuple({
        integer(1..40),
        list_of(member_of(vocab), min_length: 0, max_length: 6),
        list_of(member_of(vocab), min_length: 0, max_length: 8)
      })

    check all(
            docs <- list_of(doc_gen, min_length: 0, max_length: 25),
            q_words <- list_of(member_of(vocab), min_length: 1, max_length: 3),
            match_mode <- member_of([:all, :any]),
            prefix? <- boolean(),
            max_exp <- integer(1..8),
            limit <- integer(1..15),
            k1 <- float(min: 0.5, max: 2.0),
            b <- float(min: 0.0, max: 1.0),
            max_runs: 60
          ) do
      {:ok, db} = Xitdb.open(backend: :memory)

      db =
        Enum.reduce(docs, db, fn {id, t_words, b_words}, acc ->
          rec = %IntDoc{id: id, title: Enum.join(t_words, " "), body: Enum.join(b_words, " ")}
          Search.index_record(acc, IntDoc, rec)
        end)

      q = Enum.join(q_words, " ")

      common_opts = [
        db: db,
        match: match_mode,
        prefix?: prefix?,
        max_prefix_expansions: max_exp,
        limit: limit,
        k1: k1,
        b: b
      ]

      nif_hits = Search.query(IntDoc, q, Keyword.put(common_opts, :backend, :nif))
      ex_hits = Search.query(IntDoc, q, Keyword.put(common_opts, :backend, :elixir))

      assert Enum.map(nif_hits, &elem(&1, 0)) == Enum.map(ex_hits, &elem(&1, 0))

      Enum.zip(nif_hits, ex_hits)
      |> Enum.each(fn {{id_a, score_a}, {id_b, score_b}} ->
        assert id_a == id_b
        assert_in_delta score_a, score_b, 1.0e-5
      end)
    end
  end
end
```

---

## 6. Wave 3 Track 11B Execution Guide: Physical `nested_in` Subtree Storage, Reparenting & Recursive Child Index Purging

> **Wave 2 vs. Wave 3 Cutover Seam:** Wave 2 (Track 11A) ships `Indexer`, `Query`, and `Mutator` with flat collections only: Wave 2 fixtures (`AgendaSession`, `Conference`) declare no `nested_in`, and `nested_in` branches in `Query`/`Mutator` must be guarded on `Info.nested_in(resource) == nil` (equivalently, `Store.reverse_fks/2` rules never carry `nested?: true`). Wave 3 (Track 11B) enables `nested_in :events` on `AgendaSession` (`cardinality: :many`) and `Conference` (`cardinality: :one`) and un-guards the paths below.

To complete **100% of Wave 3** (`wave3_deferred_native_search_and_nesting`), execute the deferred physical document-subtree nesting slice (**Track 11B**) across the following four modules and two test suites. Complete reference implementations already live in the shared Wave 2 reference files linked below:

### 6.1 `lib/xitdb/ash/indexer.ex` — Physical Subtree Location, Reparenting & Recursive Child Cleanup
- **Reference Source:** [`../ash_codec_and_indexer_20261111/reference.md`](../ash_codec_and_indexer_20261111/reference.md) (and [`../ash_codec_and_indexer_20261111/plan.md`](../ash_codec_and_indexer_20261111/plan.md) Phases 5–7)
- **Deliverables to Activate:**
  1. **`plan_entity_location/5` & `_parent` Locator:**
     When `Info.nested_in(resource)` returns `%NestedIn{parent_collection: p_col, path: path, foreign_key: fk, cardinality: card}`, verify `root[p_col][parent_doc_id]` exists, write entity attributes under `root[p_col][parent_doc_id][path]` (`:one`) or `root[p_col][parent_doc_id][path][doc_id]` (`:many`), and maintain `idx.<col>._parent[pk_key] => parent_doc_id` for `O(log N)` primary-key fetches (`Indexer.fetch_cursor/4` -> `Storage.fetch_nested_cursor/6`).
  2. **Parent-Jump Enumeration (`nested_cursors_for_parent/4` & `all_cursors/3`):**
     Implement `Storage.list_nested_cursors_for_parent/6` and `Indexer.nested_cursors_for_parent/4` for `O(1)` subtree reads when filtering by `nested.foreign_key`, and iterate `idx.<col>._parent` in `Indexer.all_cursors/3` when full-scanning a `nested_in` resource.
  3. **Foreign-Key Reparenting Cleanup:**
     When an update mutates `nested.foreign_key` (`old_parent_id != new_parent_id`), remove the stale child slot from `root[p_col][old_parent_id][path]` and overwrite `idx.<col>._parent[pk_key]` with `new_parent_id` in the same atomic transaction.
  4. **Recursive Child Index Purging (`plan_purge_nested_children_ops/5` + Native BM25 Search Cleanup):**
     Before deleting a parent entity cursor, traverse incoming `Store.reverse_fk_rules(store, parent_resource)` entries marked `nested?: true`, hydrate each nested child cursor, and recursively invoke `delete_record/4` so child `_parent`, unique identity, secondary B+Tree, **and** `Xitdb.Ash.Search.remove_record/4` (`.idx.search.<child_col>`) postings are atomically purged before the parent subtree is removed.

### 6.2 `lib/xitdb/ash/store.ex` — Boot-Time Implicit `nested_in` Reverse-FK Rule Synthesis
- **Reference Source:** [`../ash_store_and_test_sandbox_20261111/reference.md`](../ash_store_and_test_sandbox_20261111/reference.md) (`build_nested_fk_rules/4`)
- **Deliverable to Activate:**
  During `Store` boot-time reverse-FK graph compilation over Xitdb resources owned by the current store, synthesize an implicit `%{source_resource: child, foreign_key: nested.foreign_key, on_delete: :delete, nested?: true}` rule on the parent resource unless an explicit `references` block already overrides that foreign key (e.g. `on_delete: :restrict`).

### 6.3 `lib/xitdb/ash/query.ex` & `lib/xitdb/ash/mutator.ex` — Parent-Jump Narrowing & Nested Cascade Checks
- **Reference Sources:**
  - [`../ash_query_engine_20261111/reference.md`](../ash_query_engine_20261111/reference.md) (`plan_narrowing/4`, `fetch_nested_parent_cursors/3`, and relationship aggregate `nested_in` branch)
  - [`../ash_mutator_and_cascades_20261111/reference.md`](../ash_mutator_and_cascades_20261111/reference.md) (`nested?: true` branch in reverse-FK `:restrict` / `:delete` cascade evaluation)
- **Deliverables to Activate:**
  1. In `Xitdb.Ash.Query` Stage 1 (`plan_narrowing/4`) and same-store relationship aggregates, detect `nested != nil and Map.has_key?(eq_map, nested.foreign_key)` and jump directly via `Indexer.nested_cursors_for_parent/4`, optionally intersecting with secondary B+Tree indexes on the child resource.
  2. In `Xitdb.Ash.Mutator`, evaluate `:restrict` counts and `:delete` cascade targets via `Indexer.nested_cursors_for_parent/4` whenever `rule.nested?` is `true`.

### 6.4 `test/xitdb/ash/indexer_test.exs` & `test/xitdb/ash/data_layer_test.exs` — Nested Subtree Verification
- **Reference Source:** [`../ash_datalayer_and_verification_suite_20261111/references/ash3_contract_fixes_and_verification_suite.md`](../ash_datalayer_and_verification_suite_20261111/references/ash3_contract_fixes_and_verification_suite.md) (`AgendaSession` `:many` and `EventConfig` `:one` nested resources)
- **Verification Gate:**
  Un-skip / enable all `nested_in` `:many` and `:one` scenarios (`_parent` direct PK lookup, parent-FK `O(1)` subtree reads, foreign-key reparenting, `:restrict` vs `:delete` parent destruction, and nested child BM25 search index cleanup), then verify:
  ```bash
  odin check native -no-entry-point -collection:xitdb=native/xitdb-odin/xitdb
  mix precommit
  ```
