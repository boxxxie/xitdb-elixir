package xitdb_nif

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

ErlNifEnv :: distinct rawptr
ERL_NIF_TERM :: distinct c.ulong

@(default_calling_convention = "c")
foreign _ {
	nif_alloc_db_resource :: proc(size: c.size_t) -> rawptr ---
	nif_make_db_resource :: proc(env: ErlNifEnv, obj: rawptr) -> ERL_NIF_TERM ---
	nif_get_db_resource :: proc(env: ErlNifEnv, term: ERL_NIF_TERM, obj_out: ^rawptr) -> c.int ---
	nif_rwlock_create :: proc(name: cstring) -> rawptr ---
	nif_rwlock_destroy :: proc(lock: rawptr) ---
	nif_rwlock_rlock :: proc(lock: rawptr) ---
	nif_rwlock_runlock :: proc(lock: rawptr) ---
	nif_rwlock_rwlock :: proc(lock: rawptr) ---
	nif_rwlock_rwunlock :: proc(lock: rawptr) ---

	nif_inspect_binary :: proc(env: ErlNifEnv, term: ERL_NIF_TERM, data_out: ^[^]u8, size_out: ^c.size_t) -> c.int ---
	nif_get_atom_bytes :: proc(env: ErlNifEnv, term: ERL_NIF_TERM, buf: [^]u8, buf_size: c.uint, len_out: ^c.int) -> c.int ---
	nif_get_int64 :: proc(env: ErlNifEnv, term: ERL_NIF_TERM, val_out: ^i64) -> c.int ---
	nif_get_uint64 :: proc(env: ErlNifEnv, term: ERL_NIF_TERM, val_out: ^u64) -> c.int ---
	nif_get_double :: proc(env: ErlNifEnv, term: ERL_NIF_TERM, val_out: ^f64) -> c.int ---
	nif_get_tuple :: proc(env: ErlNifEnv, term: ERL_NIF_TERM, arity_out: ^c.int, array_out: ^[^]ERL_NIF_TERM) -> c.int ---
	nif_get_list_cell :: proc(env: ErlNifEnv, term: ERL_NIF_TERM, head_out: ^ERL_NIF_TERM, tail_out: ^ERL_NIF_TERM) -> c.int ---
	nif_get_list_length :: proc(env: ErlNifEnv, term: ERL_NIF_TERM, len_out: ^c.uint) -> c.int ---
	nif_is_empty_list :: proc(env: ErlNifEnv, term: ERL_NIF_TERM) -> c.int ---
	nif_is_binary :: proc(env: ErlNifEnv, term: ERL_NIF_TERM) -> c.int ---
	nif_is_atom :: proc(env: ErlNifEnv, term: ERL_NIF_TERM) -> c.int ---
	nif_is_tuple :: proc(env: ErlNifEnv, term: ERL_NIF_TERM) -> c.int ---
	nif_is_list :: proc(env: ErlNifEnv, term: ERL_NIF_TERM) -> c.int ---
	nif_is_map :: proc(env: ErlNifEnv, term: ERL_NIF_TERM) -> c.int ---
	nif_get_map_value :: proc(env: ErlNifEnv, map_term: ERL_NIF_TERM, key: ERL_NIF_TERM, val_out: ^ERL_NIF_TERM) -> c.int ---

	nif_make_atom_len :: proc(env: ErlNifEnv, name: [^]u8, length: c.size_t) -> ERL_NIF_TERM ---
	nif_make_int64 :: proc(env: ErlNifEnv, val: i64) -> ERL_NIF_TERM ---
	nif_make_uint64 :: proc(env: ErlNifEnv, val: u64) -> ERL_NIF_TERM ---
	nif_make_double :: proc(env: ErlNifEnv, val: f64) -> ERL_NIF_TERM ---
	nif_make_binary_slice :: proc(env: ErlNifEnv, src: [^]u8, length: c.size_t) -> ERL_NIF_TERM ---
	nif_make_tuple2 :: proc(env: ErlNifEnv, e1, e2: ERL_NIF_TERM) -> ERL_NIF_TERM ---
	nif_make_tuple3 :: proc(env: ErlNifEnv, e1, e2, e3: ERL_NIF_TERM) -> ERL_NIF_TERM ---
	nif_make_tuple4 :: proc(env: ErlNifEnv, e1, e2, e3, e4: ERL_NIF_TERM) -> ERL_NIF_TERM ---
	nif_make_tuple5 :: proc(env: ErlNifEnv, e1, e2, e3, e4, e5: ERL_NIF_TERM) -> ERL_NIF_TERM ---
	nif_make_list_from_array :: proc(env: ErlNifEnv, arr: [^]ERL_NIF_TERM, cnt: c.uint) -> ERL_NIF_TERM ---
	nif_make_map_from_arrays :: proc(env: ErlNifEnv, keys: [^]ERL_NIF_TERM, vals: [^]ERL_NIF_TERM, cnt: c.size_t, map_out: ^ERL_NIF_TERM) -> c.int ---
}

Db_Handle :: struct {
	core:      xitdb.Core,
	db:        xitdb.Database,
	rwlock:    rawptr,
	is_closed: bool,
	backend:   u8, // 0 = memory, 1 = file, 2 = buffered_file
}

// ============================================================================
// Pre-Interned Global Atoms & Term Helpers
// ============================================================================

ATOM_OK:               ERL_NIF_TERM
ATOM_ERROR:            ERL_NIF_TERM
ATOM_NIL:              ERL_NIF_TERM
ATOM_TRUE:             ERL_NIF_TERM
ATOM_FALSE:            ERL_NIF_TERM
ATOM_CURSOR:           ERL_NIF_TERM
ATOM_TAGGED:           ERL_NIF_TERM
ATOM_XITDB_SET:        ERL_NIF_TERM
ATOM_PUT:              ERL_NIF_TERM
ATOM_APPEND:           ERL_NIF_TERM
ATOM_INSERT:           ERL_NIF_TERM
ATOM_RM:               ERL_NIF_TERM
ATOM_REMOVE:           ERL_NIF_TERM
ATOM_SLICE:            ERL_NIF_TERM
ATOM_FORK:             ERL_NIF_TERM
ATOM_INDEX_ON:         ERL_NIF_TERM
ATOM_INIT_COL:         ERL_NIF_TERM
ATOM_RESET_COL:        ERL_NIF_TERM
ATOM_META:             ERL_NIF_TERM
ATOM_SAVEPOINT:        ERL_NIF_TERM
ATOM_MOMENT_COUNT:     ERL_NIF_TERM
ATOM_FILE_SIZE:        ERL_NIF_TERM
ATOM_MOMENT_INDEX:     ERL_NIF_TERM
ATOM_COMMIT_SIZE:      ERL_NIF_TERM
ATOM_ROOT_SLOT:        ERL_NIF_TERM
ATOM_OP:               ERL_NIF_TERM
ATOM_PATH:             ERL_NIF_TERM
ATOM_OLD_VALUE:        ERL_NIF_TERM
ATOM_NEW_VALUE:        ERL_NIF_TERM
ATOM_VALUE:            ERL_NIF_TERM
ATOM_DOC:              ERL_NIF_TERM
ATOM_INSTANT:          ERL_NIF_TERM
ATOM_VARS:                  ERL_NIF_TERM
ATOM_ROWS:                  ERL_NIF_TERM
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
TAG_ATOMS:                  [16]ERL_NIF_TERM

make_atom :: proc(env: ErlNifEnv, s: string) -> ERL_NIF_TERM {
	return nif_make_atom_len(env, raw_data(s), c.size_t(len(s)))
}

@(export)
odin_nif_init_atoms :: proc "c" (env: ErlNifEnv) {
	context = runtime.default_context()
	ATOM_OK           = make_atom(env, "ok")
	ATOM_ERROR        = make_atom(env, "error")
	ATOM_NIL          = make_atom(env, "nil")
	ATOM_TRUE         = make_atom(env, "true")
	ATOM_FALSE        = make_atom(env, "false")
	ATOM_CURSOR       = make_atom(env, "cursor")
	ATOM_TAGGED       = make_atom(env, "tagged")
	ATOM_XITDB_SET    = make_atom(env, "__xitdb_set__")
	ATOM_PUT          = make_atom(env, "put")
	ATOM_APPEND       = make_atom(env, "append")
	ATOM_INSERT       = make_atom(env, "insert")
	ATOM_RM           = make_atom(env, "rm")
	ATOM_REMOVE       = make_atom(env, "remove")
	ATOM_SLICE        = make_atom(env, "slice")
	ATOM_FORK         = make_atom(env, "fork")
	ATOM_INDEX_ON     = make_atom(env, "index_on")
	ATOM_INIT_COL     = make_atom(env, "init_col")
	ATOM_RESET_COL    = make_atom(env, "reset_col")
	ATOM_META         = make_atom(env, "meta")
	ATOM_SAVEPOINT    = make_atom(env, "savepoint")
	ATOM_MOMENT_COUNT = make_atom(env, "moment_count")
	ATOM_FILE_SIZE    = make_atom(env, "file_size")
	ATOM_MOMENT_INDEX = make_atom(env, "moment_index")
	ATOM_COMMIT_SIZE  = make_atom(env, "commit_size")
	ATOM_ROOT_SLOT    = make_atom(env, "root_slot")
	ATOM_OP           = make_atom(env, "op")
	ATOM_PATH         = make_atom(env, "path")
	ATOM_OLD_VALUE    = make_atom(env, "old_value")
	ATOM_NEW_VALUE    = make_atom(env, "new_value")
	ATOM_VALUE        = make_atom(env, "value")
	ATOM_DOC          = make_atom(env, "doc")
	ATOM_INSTANT      = make_atom(env, "instant")
	ATOM_VARS                  = make_atom(env, "vars")
	ATOM_ROWS                  = make_atom(env, "rows")
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

	for i in 0 ..< 16 {
		TAG_ATOMS[i] = make_atom(env, tag_to_atom_name(xitdb.Tag(u8(i))))
	}
}

make_binary :: proc(env: ErlNifEnv, s: string) -> ERL_NIF_TERM {
	if len(s) == 0 {
		return nif_make_binary_slice(env, nil, 0)
	}
	return nif_make_binary_slice(env, raw_data(s), c.size_t(len(s)))
}

make_bytes_binary :: proc(env: ErlNifEnv, b: []u8) -> ERL_NIF_TERM {
	if len(b) == 0 {
		return nif_make_binary_slice(env, nil, 0)
	}
	return nif_make_binary_slice(env, raw_data(b), c.size_t(len(b)))
}

make_ok :: proc(env: ErlNifEnv, term: ERL_NIF_TERM) -> ERL_NIF_TERM {
	return nif_make_tuple2(env, ATOM_OK, term)
}

make_err :: proc(env: ErlNifEnv, reason: string) -> ERL_NIF_TERM {
	return nif_make_tuple2(env, ATOM_ERROR, make_atom(env, reason))
}

make_xitdb_err :: proc(env: ErlNifEnv, err: xitdb.Error) -> ERL_NIF_TERM {
	msg := fmt.tprintf("%v", err)
	return nif_make_tuple2(env, ATOM_ERROR, make_binary(env, msg))
}

get_string_from_binary :: proc(env: ErlNifEnv, term: ERL_NIF_TERM) -> (string, bool) {
	data: [^]u8 = nil
	size: c.size_t = 0
	if nif_inspect_binary(env, term, &data, &size) == 0 {
		return "", false
	}
	if size == 0 {
		return "", true
	}
	return string(data[:size]), true
}

get_atom_string :: proc(env: ErlNifEnv, term: ERL_NIF_TERM, buf: []u8) -> (string, bool) {
	out_len: c.int = 0
	if nif_get_atom_bytes(env, term, raw_data(buf), c.uint(len(buf)), &out_len) == 0 {
		return "", false
	}
	return string(buf[:out_len]), true
}

tag_to_atom_name :: proc(tag: xitdb.Tag) -> string {
	switch tag {
	case .None:
		return "none"
	case .Index:
		return "index"
	case .Array_List:
		return "array_list"
	case .Linked_Array_List:
		return "linked_array_list"
	case .Hash_Map:
		return "hash_map"
	case .KV_Pair:
		return "kv_pair"
	case .Bytes:
		return "bytes"
	case .Short_Bytes:
		return "short_bytes"
	case .Uint:
		return "uint"
	case .Int:
		return "int"
	case .Float:
		return "float"
	case .Hash_Set:
		return "hash_set"
	case .Counted_Hash_Map:
		return "counted_hash_map"
	case .Counted_Hash_Set:
		return "counted_hash_set"
	case .Sorted_Map:
		return "sorted_map"
	case .Sorted_Set:
		return "sorted_set"
	case .Sorted_KV_Pair:
		return "sorted_kv_pair"
	}
	return "none"
}

is_container_tag :: proc(tag: xitdb.Tag) -> bool {
	#partial switch tag {
	case .Array_List, .Linked_Array_List, .Hash_Map, .Counted_Hash_Map,
	     .Sorted_Map, .Hash_Set, .Counted_Hash_Set, .Sorted_Set:
		return true
	}
	return false
}

slot_to_term :: proc(env: ErlNifEnv, db: ^xitdb.Database, slot: xitdb.Slot) -> (res: ERL_NIF_TERM, err: xitdb.Error) {
	if slot.tag == .None && !slot.full {
		return ATOM_NIL, nil
	}
	if is_container_tag(slot.tag) {
		tag_u8 := u8(slot.tag)
		// Return {:cursor, tag_atom, tag_int, slot_value, full_int}
		return nif_make_tuple5(
			env,
			ATOM_CURSOR,
			TAG_ATOMS[tag_u8],
			nif_make_int64(env, i64(tag_u8)),
			nif_make_int64(env, slot.value),
			nif_make_int64(env, 1 if slot.full else 0),
		), nil
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = db,
	}

	#partial switch slot.tag {
	case .Uint:
		u := xitdb.cursor_read_uint(cur) or_return
		return nif_make_uint64(env, u), nil
	case .Int:
		i := xitdb.cursor_read_int(cur) or_return
		return nif_make_int64(env, i), nil
	case .Float:
		f := xitdb.cursor_read_float(cur) or_return
		return nif_make_double(env, f), nil
	case .Short_Bytes, .Bytes:
		if slot.full {
			obj := xitdb.cursor_read_bytes_object(cur, 0, context.temp_allocator) or_return
			if len(obj.format_tag) == 2 && obj.format_tag[0] == 'b' && obj.format_tag[1] == 'l' {
				if len(obj.value) == 1 && obj.value[0] == '1' {
					return ATOM_TRUE, nil
				}
				return ATOM_FALSE, nil
			}
			return nif_make_tuple3(
				env,
				ATOM_TAGGED,
				make_bytes_binary(env, obj.format_tag),
				make_bytes_binary(env, obj.value),
			), nil
		}
		if slot.tag == .Short_Bytes {
			sb_buf: [8]u8 = ---
			b_obj := xitdb.cursor_read_bytes_buf(cur, sb_buf[:]) or_return
			return make_bytes_binary(env, b_obj.value), nil
		}
		b := xitdb.cursor_read_bytes(cur, 0, context.temp_allocator) or_return
		return make_bytes_binary(env, b), nil
	}

	return ATOM_NIL, nil
}

read_key_cursor_string :: proc(cur: xitdb.Read_Cursor, sb_buf: []u8) -> (s: string, err: xitdb.Error) {
	if cur.slot_ptr.slot.tag == .Short_Bytes && !cur.slot_ptr.slot.full {
		b_obj := xitdb.cursor_read_bytes_buf(cur, sb_buf) or_return
		return string(b_obj.value), nil
	}
	return xitdb.cursor_read_string(cur, 0, context.temp_allocator)
}

materialize_slot :: proc(env: ErlNifEnv, db: ^xitdb.Database, slot: xitdb.Slot) -> (res: ERL_NIF_TERM, err: xitdb.Error) {
	if !is_container_tag(slot.tag) {
		return slot_to_term(env, db, slot)
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = db,
	}

	#partial switch slot.tag {
	case .Array_List, .Linked_Array_List:
		it := xitdb.cursor_iterator(cur) or_return
		items := make([dynamic]ERL_NIF_TERM, 0, 16, context.temp_allocator)
		for {
			next_maybe := xitdb.cursor_iterator_next(&it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			elem_slot := xitdb.cursor_slot(elem_cur) or_return
			term := materialize_slot(env, db, elem_slot) or_return
			append(&items, term)
		}
		if len(items) == 0 {
			return nif_make_list_from_array(env, nil, 0), nil
		}
		return nif_make_list_from_array(env, raw_data(items[:]), c.uint(len(items))), nil

	case .Hash_Set, .Counted_Hash_Set, .Sorted_Set:
		it := xitdb.cursor_iterator(cur) or_return
		items := make([dynamic]ERL_NIF_TERM, 0, 16, context.temp_allocator)
		for {
			next_maybe := xitdb.cursor_iterator_next(&it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			kv := xitdb.cursor_read_kv_pair(elem_cur, context.temp_allocator) or_return
			key_slot := xitdb.cursor_slot(kv.key_cursor) or_return
			term := slot_to_term(env, db, key_slot) or_return
			append(&items, term)
		}
		list_term: ERL_NIF_TERM
		if len(items) == 0 {
			list_term = nif_make_list_from_array(env, nil, 0)
		} else {
			list_term = nif_make_list_from_array(env, raw_data(items[:]), c.uint(len(items)))
		}
		return nif_make_tuple2(env, ATOM_XITDB_SET, list_term), nil

	case .Hash_Map, .Counted_Hash_Map, .Sorted_Map:
		it := xitdb.cursor_iterator(cur) or_return
		keys := make([dynamic]ERL_NIF_TERM, 0, 16, context.temp_allocator)
		vals := make([dynamic]ERL_NIF_TERM, 0, 16, context.temp_allocator)
		sb_buf: [8]u8 = ---
		for {
			next_maybe := xitdb.cursor_iterator_next(&it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			kv := xitdb.cursor_read_kv_pair(elem_cur, context.temp_allocator) or_return
			key_str := read_key_cursor_string(kv.key_cursor, sb_buf[:]) or_return
			if key_str == "__tx" {
				continue
			}
			val_slot := xitdb.cursor_slot(kv.value_cursor) or_return
			k_term := make_binary(env, key_str)
			v_term := materialize_slot(env, db, val_slot) or_return
			append(&keys, k_term)
			append(&vals, v_term)
		}
		map_term: ERL_NIF_TERM
		if len(keys) == 0 {
			_ = nif_make_map_from_arrays(env, nil, nil, 0, &map_term)
		} else {
			_ = nif_make_map_from_arrays(env, raw_data(keys[:]), raw_data(vals[:]), c.size_t(len(keys)), &map_term)
		}
		return map_term, nil
	}

	return ATOM_NIL, nil
}

pull_value_to_term :: proc(env: ErlNifEnv, pv: xitdb.Pull_Value) -> ERL_NIF_TERM {
	switch v in pv {
	case u64:
		return nif_make_uint64(env, v)
	case i64:
		return nif_make_int64(env, v)
	case f64:
		return nif_make_double(env, v)
	case string:
		return make_binary(env, v)
	case xitdb.Bytes:
		if len(v.format_tag) == 2 && v.format_tag[0] == 'b' && v.format_tag[1] == 'l' {
			if len(v.value) == 1 && v.value[0] == '1' {
				return ATOM_TRUE
			}
			return ATOM_FALSE
		}
		if len(v.format_tag) > 0 {
			return nif_make_tuple3(
				env,
				ATOM_TAGGED,
				make_bytes_binary(env, v.format_tag),
				make_bytes_binary(env, v.value),
			)
		}
		return make_bytes_binary(env, v.value)
	case xitdb.Pull_List:
		if len(v) == 0 {
			return nif_make_list_from_array(env, nil, 0)
		}
		items := make([]ERL_NIF_TERM, len(v), context.temp_allocator)
		for elem, idx in v {
			items[idx] = pull_value_to_term(env, elem)
		}
		return nif_make_list_from_array(env, raw_data(items), c.uint(len(items)))
	case xitdb.Pull_Map:
		if len(v) == 0 {
			m: ERL_NIF_TERM
			_ = nif_make_map_from_arrays(env, nil, nil, 0, &m)
			return m
		}
		keys := make([]ERL_NIF_TERM, len(v), context.temp_allocator)
		vals := make([]ERL_NIF_TERM, len(v), context.temp_allocator)
		for entry, idx in v {
			keys[idx] = make_binary(env, entry.key)
			vals[idx] = pull_value_to_term(env, entry.val)
		}
		m: ERL_NIF_TERM
		_ = nif_make_map_from_arrays(env, raw_data(keys), raw_data(vals), c.size_t(len(v)), &m)
		return m
	}
	return make_atom(env, "nil")
}

// ============================================================================
// Resource Destructor & Lifecycle NIFs
// ============================================================================

@(export)
odin_nif_dtor :: proc "c" (env: ErlNifEnv, obj: rawptr) {
	context = runtime.default_context()
	handle := (^Db_Handle)(obj)
	if handle == nil {
		return
	}
	if !handle.is_closed {
		_ = xitdb.core_destroy(&handle.core, close_file = true)
		handle.is_closed = true
	}
	if handle.rwlock != nil {
		nif_rwlock_destroy(handle.rwlock)
		handle.rwlock = nil
	}
}

get_handle :: proc(env: ErlNifEnv, term: ERL_NIF_TERM) -> (^Db_Handle, bool) {
	ptr: rawptr = nil
	if nif_get_db_resource(env, term, &ptr) == 0 || ptr == nil {
		return nil, false
	}
	h := (^Db_Handle)(ptr)
	if h.is_closed {
		return nil, false
	}
	return h, true
}

@(export)
odin_nif_open :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 3 {
		return make_err(env, "badarg")
	}

	atom_buf: [64]u8 = ---
	backend_str, ok_b := get_atom_string(env, argv[0], atom_buf[:])
	if !ok_b {
		return make_err(env, "invalid_backend")
	}

	path_str, ok_p := get_string_from_binary(env, argv[1])
	if !ok_p {
		return make_err(env, "invalid_path")
	}

	hash_buf: [64]u8 = ---
	hash_str, ok_h := get_atom_string(env, argv[2], hash_buf[:])
	if !ok_h {
		return make_err(env, "invalid_hash")
	}

	hasher := xitdb.sha256_hasher() if hash_str == "sha256" else xitdb.sha1_hasher()

	raw_res := nif_alloc_db_resource(c.size_t(size_of(Db_Handle)))
	if raw_res == nil {
		return make_err(env, "alloc_failed")
	}
	handle := (^Db_Handle)(raw_res)
	handle^ = {}

	open_err: xitdb.Error = nil
	switch backend_str {
	case "memory":
		handle.core = xitdb.core_memory_init(context.allocator)
		handle.backend = 0
	case "file":
		handle.core, open_err = xitdb.core_file_open(path_str, os.File_Flags{.Read, .Write, .Create}, true)
		handle.backend = 1
	case "buffered_file":
		handle.core, open_err = xitdb.core_buffered_file_open(path_str, xitdb.DEFAULT_BUFFER_SIZE, os.File_Flags{.Read, .Write, .Create}, true, context.allocator)
		handle.backend = 2
	case:
		handle.is_closed = true
		_ = nif_make_db_resource(env, raw_res)
		return make_err(env, "unknown_backend")
	}

	if open_err != nil {
		handle.is_closed = true
		_ = nif_make_db_resource(env, raw_res)
		return make_xitdb_err(env, open_err)
	}

	init_err: xitdb.Error = nil
	handle.db, init_err = xitdb.database_init(&handle.core, hasher)
	if init_err != nil {
		_ = xitdb.core_destroy(&handle.core, close_file = true)
		handle.is_closed = true
		_ = nif_make_db_resource(env, raw_res)
		return make_xitdb_err(env, init_err)
	}

	handle.rwlock = nif_rwlock_create("xitdb_rwlock")
	res_term := nif_make_db_resource(env, raw_res)
	return make_ok(env, res_term)
}

@(export)
odin_nif_close :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	ptr: rawptr = nil
	if argc != 1 || nif_get_db_resource(env, argv[0], &ptr) == 0 || ptr == nil {
		return make_atom(env, "ok")
	}
	handle := (^Db_Handle)(ptr)
	nif_rwlock_rwlock(handle.rwlock)
	defer nif_rwlock_rwunlock(handle.rwlock)

	if !handle.is_closed {
		_ = xitdb.core_destroy(&handle.core, close_file = true)
		handle.is_closed = true
	}
	return make_atom(env, "ok")
}

@(export)
odin_nif_sync :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	handle, ok := get_handle(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	nif_rwlock_rwlock(handle.rwlock)
	defer nif_rwlock_rwunlock(handle.rwlock)

	if err := xitdb.core_sync(&handle.core); err != nil {
		return make_xitdb_err(env, err)
	}
	return make_atom(env, "ok")
}

@(export)
odin_nif_info :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	handle, ok := get_handle(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	nif_rwlock_rlock(handle.rwlock)
	defer nif_rwlock_runlock(handle.rwlock)

	rc := xitdb.database_root_cursor(&handle.db).read_cursor
	moment_count: i64 = 0
	if hist, err := xitdb.read_array_list_init(rc); err == nil {
		moment_count, _ = xitdb.array_list_count(hist)
	}
	file_size, _ := xitdb.core_length(&handle.core)

	keys := [2]ERL_NIF_TERM{
		make_atom(env, "moment_count"),
		make_atom(env, "file_size"),
	}
	vals := [2]ERL_NIF_TERM{
		nif_make_int64(env, moment_count),
		nif_make_int64(env, file_size),
	}
	m: ERL_NIF_TERM
	_ = nif_make_map_from_arrays(env, raw_data(keys[:]), raw_data(vals[:]), 2, &m)
	return make_ok(env, m)
}

@(export)
odin_nif_moment_slot :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()

	handle, ok := get_handle(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	moment_idx: i64 = -1
	if nif_get_int64(env, argv[1], &moment_idx) == 0 {
		return make_err(env, "badarg")
	}

	nif_rwlock_rlock(handle.rwlock)
	defer nif_rwlock_runlock(handle.rwlock)

	rc := xitdb.database_root_cursor(&handle.db).read_cursor
	hist, h_err := xitdb.read_array_list_init(rc)
	if h_err != nil {
		return make_xitdb_err(env, h_err)
	}
	cnt, c_err := xitdb.array_list_count(hist)
	if c_err != nil {
		return make_xitdb_err(env, c_err)
	}
	if cnt == 0 {
		return make_ok(env, nif_make_tuple5(
			env,
			ATOM_CURSOR,
			TAG_ATOMS[u8(xitdb.Tag.Hash_Map)],
			nif_make_int64(env, i64(u8(xitdb.Tag.Hash_Map))),
			nif_make_int64(env, 0),
			nif_make_int64(env, 0),
		))
	}

	resolved := moment_idx if moment_idx >= 0 else cnt + moment_idx
	if resolved < 0 || resolved >= cnt {
		return make_err(env, "moment_out_of_range")
	}

	slot_maybe, s_err := xitdb.array_list_get_slot(hist, resolved)
	if s_err != nil {
		return make_xitdb_err(env, s_err)
	}
	slot, has_slot := slot_maybe.?
	if !has_slot {
		return make_err(env, "moment_not_found")
	}

	term, t_err := slot_to_term(env, &handle.db, slot)
	if t_err != nil {
		return make_xitdb_err(env, t_err)
	}
	return make_ok(env, term)
}

// ============================================================================
// Fast-Path Slot Navigation & Enumerable NIFs
// ============================================================================

@(export)
odin_nif_slot_get_key :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()

	handle, ok := get_handle(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	tag_int: i64 = 0
	val_int: i64 = 0
	if nif_get_int64(env, argv[1], &tag_int) == 0 || nif_get_int64(env, argv[2], &val_int) == 0 {
		return make_err(env, "badarg")
	}
	key_str, ok_k := get_string_from_binary(env, argv[3])
	if !ok_k {
		return make_err(env, "badarg")
	}
	if tag_int != -1 && val_int == 0 {
		return ATOM_ERROR
	}

	nif_rwlock_rlock(handle.rwlock)
	defer nif_rwlock_runlock(handle.rwlock)

	if tag_int == -1 {
		rc := xitdb.database_root_cursor(&handle.db)
		hist, h_err := xitdb.read_array_list_init(rc.read_cursor)
		if h_err != nil {
			return ATOM_ERROR
		}
		cnt, c_err := xitdb.array_list_count(hist)
		if c_err != nil || cnt == 0 {
			return ATOM_ERROR
		}
		resolved := val_int if val_int >= 0 else cnt + val_int
		if resolved < 0 || resolved >= cnt {
			return ATOM_ERROR
		}
		slot_maybe, s_err := xitdb.array_list_get_slot(hist, resolved)
		if s_err != nil {
			return ATOM_ERROR
		}
		s, found := slot_maybe.?
		if !found || s.value == 0 {
			return ATOM_ERROR
		}
		tag_int = i64(u8(s.tag))
		val_int = s.value
	}

	tag := xitdb.Tag(u8(tag_int))
	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = xitdb.Slot{tag = tag, value = val_int}},
		db       = &handle.db,
	}

	child_slot_maybe: Maybe(xitdb.Slot) = nil
	err: xitdb.Error = nil

	#partial switch tag {
	case .Hash_Map:
		m: xitdb.Read_Hash_Map
		m, err = xitdb.read_hash_map_init(cur)
		if err == nil {
			child_slot_maybe, err = xitdb.hash_map_get_slot(m, key_str)
		}
	case .Counted_Hash_Map:
		cm: xitdb.Read_Counted_Hash_Map
		cm, err = xitdb.read_counted_hash_map_init(cur)
		if err == nil {
			child_slot_maybe, err = xitdb.hash_map_get_slot(cm.read_hash_map, key_str)
		}
	case .Sorted_Map:
		sm_col: xitdb.Read_Sorted_Map
		sm_col, err = xitdb.read_sorted_map_init(cur)
		if err == nil {
			child_slot_maybe, err = xitdb.sorted_map_get_slot(sm_col, key_str)
		}
	case:
		return ATOM_ERROR
	}

	if err != nil {
		return ATOM_ERROR
	}
	child_slot, has_child := child_slot_maybe.?
	if !has_child || (child_slot.tag == .None && !child_slot.full) {
		return ATOM_ERROR
	}

	if child_slot.tag == .Bytes || child_slot.full {
		defer free_all(context.temp_allocator)
	}
	term, t_err := slot_to_term(env, &handle.db, child_slot)
	if t_err != nil {
		return ATOM_ERROR
	}
	return make_ok(env, term)
}

@(export)
odin_nif_slot_get_index :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()

	handle, ok := get_handle(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	tag_int: i64 = 0
	val_int: i64 = 0
	idx_int: i64 = 0
	if nif_get_int64(env, argv[1], &tag_int) == 0 ||
	   nif_get_int64(env, argv[2], &val_int) == 0 ||
	   nif_get_int64(env, argv[3], &idx_int) == 0 {
		return make_err(env, "badarg")
	}
	if val_int == 0 {
		return ATOM_ERROR
	}

	nif_rwlock_rlock(handle.rwlock)
	defer nif_rwlock_runlock(handle.rwlock)

	tag := xitdb.Tag(u8(tag_int))
	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = xitdb.Slot{tag = tag, value = val_int}},
		db       = &handle.db,
	}

	child_slot_maybe: Maybe(xitdb.Slot) = nil
	err: xitdb.Error = nil

	#partial switch tag {
	case .Array_List:
		al_col: xitdb.Read_Array_List
		al_col, err = xitdb.read_array_list_init(cur)
		if err == nil {
			cnt, _ := xitdb.array_list_count(al_col)
			resolved := idx_int if idx_int >= 0 else cnt + idx_int
			if resolved < 0 || resolved >= cnt {
				return ATOM_ERROR
			}
			child_slot_maybe, err = xitdb.array_list_get_slot(al_col, resolved)
		}
	case .Linked_Array_List:
		ll_col: xitdb.Read_Linked_Array_List
		ll_col, err = xitdb.read_linked_array_list_init(cur)
		if err == nil {
			cnt, _ := xitdb.linked_array_list_count(ll_col)
			resolved := idx_int if idx_int >= 0 else cnt + idx_int
			if resolved < 0 || resolved >= cnt {
				return ATOM_ERROR
			}
			child_slot_maybe, err = xitdb.linked_array_list_get_slot(ll_col, resolved)
		}
	case:
		return ATOM_ERROR
	}

	if err != nil {
		return ATOM_ERROR
	}
	child_slot, has_child := child_slot_maybe.?
	if !has_child {
		return ATOM_ERROR
	}

	if child_slot.tag == .Bytes || child_slot.full {
		defer free_all(context.temp_allocator)
	}
	term, t_err := slot_to_term(env, &handle.db, child_slot)
	if t_err != nil {
		return ATOM_ERROR
	}
	return make_ok(env, term)
}

@(export)
odin_nif_slot_count :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()

	handle, ok := get_handle(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	tag_int: i64 = 0
	val_int: i64 = 0
	if nif_get_int64(env, argv[1], &tag_int) == 0 || nif_get_int64(env, argv[2], &val_int) == 0 {
		return make_err(env, "badarg")
	}
	if val_int == 0 {
		return make_ok(env, nif_make_int64(env, 0))
	}

	tag := xitdb.Tag(u8(tag_int))
	#partial switch tag {
	case .Array_List, .Linked_Array_List, .Counted_Hash_Map, .Counted_Hash_Set, .Sorted_Map, .Sorted_Set:
		nif_rwlock_rlock(handle.rwlock)
		defer nif_rwlock_runlock(handle.rwlock)

		cur := xitdb.Read_Cursor{
			slot_ptr = xitdb.Slot_Pointer{position = nil, slot = xitdb.Slot{tag = tag, value = val_int}},
			db       = &handle.db,
		}
		cnt, err := xitdb.cursor_count(cur)
		if err != nil {
			return make_xitdb_err(env, err)
		}
		return make_ok(env, nif_make_int64(env, cnt))
	}

	return make_err(env, "uncounted")
}

@(export)
odin_nif_slot_contains :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()

	handle, ok := get_handle(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	tag_int: i64 = 0
	val_int: i64 = 0
	if nif_get_int64(env, argv[1], &tag_int) == 0 || nif_get_int64(env, argv[2], &val_int) == 0 {
		return make_err(env, "badarg")
	}
	key_str, ok_k := get_string_from_binary(env, argv[3])
	if !ok_k {
		return make_err(env, "badarg")
	}
	if val_int == 0 {
		return make_ok(env, ATOM_FALSE)
	}

	nif_rwlock_rlock(handle.rwlock)
	defer nif_rwlock_runlock(handle.rwlock)

	tag := xitdb.Tag(u8(tag_int))
	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = xitdb.Slot{tag = tag, value = val_int}},
		db       = &handle.db,
	}

	#partial switch tag {
	case .Hash_Set, .Counted_Hash_Set:
		hs := xitdb.Read_Hash_Set{cursor = cur}
		slot_maybe, err := xitdb.hash_set_get_slot(hs, key_str)
		if err != nil {
			return make_ok(env, ATOM_FALSE)
		}
		_, found := slot_maybe.?
		return make_ok(env, ATOM_TRUE if found else ATOM_FALSE)

	case .Sorted_Set:
		ss := xitdb.Read_Sorted_Set{cursor = cur}
		found, err := xitdb.sorted_set_contains(ss, key_str)
		if err != nil {
			return make_ok(env, ATOM_FALSE)
		}
		return make_ok(env, ATOM_TRUE if found else ATOM_FALSE)

	case .Hash_Map, .Counted_Hash_Map:
		hm := xitdb.Read_Hash_Map{cursor = cur}
		slot_maybe, err := xitdb.hash_map_get_slot(hm, key_str)
		if err != nil {
			return make_ok(env, ATOM_FALSE)
		}
		_, found := slot_maybe.?
		return make_ok(env, ATOM_TRUE if found else ATOM_FALSE)

	case .Sorted_Map:
		sm := xitdb.Read_Sorted_Map{cursor = cur}
		slot_maybe, err := xitdb.sorted_map_get_slot(sm, key_str)
		if err != nil {
			return make_ok(env, ATOM_FALSE)
		}
		_, found := slot_maybe.?
		return make_ok(env, ATOM_TRUE if found else ATOM_FALSE)
	}

	return make_err(env, "unsupported")
}

@(export)
odin_nif_slot_slice :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	handle, ok := get_handle(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	tag_int, val_int, start_idx, length: i64
	if nif_get_int64(env, argv[1], &tag_int) == 0 ||
	   nif_get_int64(env, argv[2], &val_int) == 0 ||
	   nif_get_int64(env, argv[3], &start_idx) == 0 ||
	   nif_get_int64(env, argv[4], &length) == 0 {
		return make_err(env, "badarg")
	}
	if val_int == 0 || length <= 0 {
		return make_ok(env, nif_make_list_from_array(env, nil, 0))
	}

	nif_rwlock_rlock(handle.rwlock)
	defer nif_rwlock_runlock(handle.rwlock)

	tag := xitdb.Tag(u8(tag_int))
	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = xitdb.Slot{tag = tag, value = val_int}},
		db       = &handle.db,
	}

	it: xitdb.Cursor_Iterator
	err: xitdb.Error = nil

	#partial switch tag {
	case .Array_List:
		it, err = xitdb.cursor_iterator_array_list_from_index(cur, start_idx)
	case .Linked_Array_List:
		it, err = xitdb.cursor_iterator_linked_array_list_from_index(cur, start_idx)
	case .Sorted_Map, .Sorted_Set:
		it, err = xitdb.cursor_iterator_sorted_from_index(cur, start_idx)
	case:
		return make_err(env, "unsupported")
	}

	if err != nil {
		return make_xitdb_err(env, err)
	}

	items := make([dynamic]ERL_NIF_TERM, 0, int(length), context.temp_allocator)
	sb_buf: [8]u8 = ---
	for i: i64 = 0; i < length; i += 1 {
		next_maybe, n_err := xitdb.cursor_iterator_next(&it)
		if n_err != nil {
			return make_xitdb_err(env, n_err)
		}
		elem_cur, has_next := next_maybe.?
		if !has_next {
			break
		}
		#partial switch tag {
		case .Array_List, .Linked_Array_List:
			s, _ := xitdb.cursor_slot(elem_cur)
			t, _ := slot_to_term(env, &handle.db, s)
			append(&items, t)
		case .Sorted_Set:
			kv, _ := xitdb.cursor_read_kv_pair(elem_cur, context.temp_allocator)
			ks, _ := xitdb.cursor_slot(kv.key_cursor)
			t, _ := slot_to_term(env, &handle.db, ks)
			append(&items, t)
		case .Sorted_Map:
			kv, _ := xitdb.cursor_read_kv_pair(elem_cur, context.temp_allocator)
			k_str, _ := read_key_cursor_string(kv.key_cursor, sb_buf[:])
			vs, _ := xitdb.cursor_slot(kv.value_cursor)
			vt, _ := slot_to_term(env, &handle.db, vs)
			append(&items, nif_make_tuple2(env, make_binary(env, k_str), vt))
		}
	}

	if len(items) == 0 {
		return make_ok(env, nif_make_list_from_array(env, nil, 0))
	}
	return make_ok(env, nif_make_list_from_array(env, raw_data(items[:]), c.uint(len(items))))
}

@(export)
odin_nif_slot_entries :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	handle, ok := get_handle(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	tag_int, val_int, offset, limit: i64
	if nif_get_int64(env, argv[1], &tag_int) == 0 ||
	   nif_get_int64(env, argv[2], &val_int) == 0 ||
	   nif_get_int64(env, argv[3], &offset) == 0 ||
	   nif_get_int64(env, argv[4], &limit) == 0 {
		return make_err(env, "badarg")
	}
	if val_int == 0 {
		return make_ok(env, nif_make_list_from_array(env, nil, 0))
	}

	nif_rwlock_rlock(handle.rwlock)
	defer nif_rwlock_runlock(handle.rwlock)

	tag := xitdb.Tag(u8(tag_int))
	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = xitdb.Slot{tag = tag, value = val_int}},
		db       = &handle.db,
	}

	it: xitdb.Cursor_Iterator
	err: xitdb.Error = nil
	direct_seek := false

	#partial switch tag {
	case .Array_List:
		it, err = xitdb.cursor_iterator_array_list_from_index(cur, offset)
		direct_seek = true
	case .Linked_Array_List:
		it, err = xitdb.cursor_iterator_linked_array_list_from_index(cur, offset)
		direct_seek = true
	case .Sorted_Map, .Sorted_Set:
		it, err = xitdb.cursor_iterator_sorted_from_index(cur, offset)
		direct_seek = true
	case:
		it, err = xitdb.cursor_iterator(cur)
	}
	if err != nil {
		return make_xitdb_err(env, err)
	}

	cap_hint := int(limit) if limit > 0 else 64
	items := make([dynamic]ERL_NIF_TERM, 0, cap_hint, context.temp_allocator)
	seen: i64 = offset if direct_seek else 0
	emitted: i64 = 0
	sb_buf: [8]u8 = ---

	for {
		if limit > 0 && emitted >= limit {
			break
		}
		next_maybe, n_err := xitdb.cursor_iterator_next(&it)
		if n_err != nil {
			return make_xitdb_err(env, n_err)
		}
		elem_cur, has_next := next_maybe.?
		if !has_next {
			break
		}

		#partial switch tag {
		case .Array_List, .Linked_Array_List:
			if seen >= offset {
				s, _ := xitdb.cursor_slot(elem_cur)
				t, _ := slot_to_term(env, &handle.db, s)
				append(&items, t)
				emitted += 1
			}
			seen += 1

		case .Hash_Set, .Counted_Hash_Set, .Sorted_Set:
			if seen >= offset {
				kv, _ := xitdb.cursor_read_kv_pair(elem_cur, context.temp_allocator)
				ks, _ := xitdb.cursor_slot(kv.key_cursor)
				t, _ := slot_to_term(env, &handle.db, ks)
				append(&items, t)
				emitted += 1
			}
			seen += 1

		case .Hash_Map, .Counted_Hash_Map, .Sorted_Map:
			kv, _ := xitdb.cursor_read_kv_pair(elem_cur, context.temp_allocator)
			k_str, _ := read_key_cursor_string(kv.key_cursor, sb_buf[:])
			if k_str == "__tx" {
				continue
			}
			if seen >= offset {
				vs, _ := xitdb.cursor_slot(kv.value_cursor)
				vt, _ := slot_to_term(env, &handle.db, vs)
				append(&items, nif_make_tuple2(env, make_binary(env, k_str), vt))
				emitted += 1
			}
			seen += 1
		}
	}

	if len(items) == 0 {
		return make_ok(env, nif_make_list_from_array(env, nil, 0))
	}
	return make_ok(env, nif_make_list_from_array(env, raw_data(items[:]), c.uint(len(items))))
}

@(export)
odin_nif_slot_materialize :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	handle, ok := get_handle(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	tag_int, val_int, full_int: i64
	if nif_get_int64(env, argv[1], &tag_int) == 0 ||
	   nif_get_int64(env, argv[2], &val_int) == 0 ||
	   nif_get_int64(env, argv[3], &full_int) == 0 {
		return make_err(env, "badarg")
	}

	nif_rwlock_rlock(handle.rwlock)
	defer nif_rwlock_runlock(handle.rwlock)

	tag := xitdb.Tag(u8(tag_int))
	if val_int == 0 && is_container_tag(tag) {
		m: ERL_NIF_TERM
		_ = nif_make_map_from_arrays(env, nil, nil, 0, &m)
		return make_ok(env, m)
	}

	slot := xitdb.Slot{tag = tag, value = val_int, full = (full_int != 0)}
	term, err := materialize_slot(env, &handle.db, slot)
	if err != nil {
		return make_xitdb_err(env, err)
	}
	return make_ok(env, term)
}

// ============================================================================
// Coarse-Grained Transactions (`odin_nif_transact`)
// ============================================================================

Init_Col_Ctx :: struct {
	steps: []xitdb.Path_Step,
	kind:  string,
	reset: bool,
}

init_col_callback :: proc(moment_cur: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	ic := (^Init_Col_Ctx)(user_data)
	if ic.reset && len(ic.steps) > 0 {
		xitdb.put_at_steps(moment_cur^, ic.steps, xitdb.Slot{}) or_return
	}
	target := moment_cur^
	if len(ic.steps) > 0 {
		target = xitdb.write_steps_cursor(moment_cur^, ic.steps) or_return
	}
	switch ic.kind {
	case "hash_map":
		_, err := xitdb.write_hash_map_init(target)
		return err
	case "counted_hash_map":
		_, err := xitdb.write_counted_hash_map_init(target)
		return err
	case "sorted_map":
		_, err := xitdb.write_sorted_map_init(target)
		return err
	case "array_list":
		_, err := xitdb.write_array_list_init(target)
		return err
	case "linked_array_list":
		_, err := xitdb.write_linked_array_list_init(target)
		return err
	case "hash_set":
		_, err := xitdb.write_hash_set_init(target)
		return err
	case "counted_hash_set":
		_, err := xitdb.write_counted_hash_set_init(target)
		return err
	case "sorted_set":
		_, err := xitdb.write_sorted_set_init(target)
		return err
	}
	return nil
}

decode_writeable_value :: proc(env: ErlNifEnv, term: ERL_NIF_TERM) -> (xitdb.Writeable_Data, bool) {
	if nif_is_binary(env, term) != 0 {
		s, ok := get_string_from_binary(env, term)
		return s, ok
	}
	if nif_is_atom(env, term) != 0 {
		if term == ATOM_TRUE {
			return xitdb.Bytes{value = transmute([]u8)string("1"), format_tag = transmute([]u8)string("bl")}, true
		}
		if term == ATOM_FALSE {
			return xitdb.Bytes{value = transmute([]u8)string("0"), format_tag = transmute([]u8)string("bl")}, true
		}
		if term == ATOM_NIL {
			return xitdb.Slot{}, true
		}
		buf: [64]u8 = ---
		a_str, ok := get_atom_string(env, term, buf[:])
		if !ok {
			return nil, false
		}
		return a_str, true
	}
	if nif_is_tuple(env, term) != 0 {
		arity: c.int = 0
		elems: [^]ERL_NIF_TERM = nil
		if nif_get_tuple(env, term, &arity, &elems) != 0 && arity == 3 && elems[0] == ATOM_TAGGED {
			fmt_tag, ok_t := get_string_from_binary(env, elems[1])
			payload, ok_p := get_string_from_binary(env, elems[2])
			if ok_t && ok_p {
				return xitdb.Bytes{
					value      = transmute([]u8)payload,
					format_tag = transmute([]u8)fmt_tag,
				}, true
			}
		}
		return nil, false
	}

	u_val: u64 = 0
	if nif_get_uint64(env, term, &u_val) != 0 {
		return u_val, true
	}
	i_val: i64 = 0
	if nif_get_int64(env, term, &i_val) != 0 {
		if i_val >= 0 {
			return u64(i_val), true
		}
		return i_val, true
	}
	f_val: f64 = 0
	if nif_get_double(env, term, &f_val) != 0 {
		return f_val, true
	}
	return nil, false
}

@(export)
odin_nif_transact :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	handle, ok := get_handle(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	base_moment: i64 = -1
	if nif_get_int64(env, argv[1], &base_moment) == 0 {
		return make_err(env, "badarg")
	}
	doc_str, _ := get_string_from_binary(env, argv[3])

	nif_rwlock_rwlock(handle.rwlock)
	defer nif_rwlock_rwunlock(handle.rwlock)

	tx := xitdb.tx_init(&handle.db, base_moment = base_moment, track_changes = false, allocator = context.temp_allocator)
	defer xitdb.tx_destroy(&tx)

	if len(doc_str) > 0 {
		xitdb.tx_doc(&tx, doc_str)
	}

	head: ERL_NIF_TERM
	tail := argv[2]
	for nif_is_empty_list(env, tail) == 0 {
		if nif_get_list_cell(env, tail, &head, &tail) == 0 {
			return make_err(env, "invalid_ops_list")
		}
		arity: c.int = 0
		elems: [^]ERL_NIF_TERM = nil
		if nif_get_tuple(env, head, &arity, &elems) == 0 || arity < 2 {
			return make_err(env, "invalid_op_tuple")
		}

		op_atom := elems[0]

		switch op_atom {
		case ATOM_PUT:
			path_str, ok_p := get_string_from_binary(env, elems[1])
			val, ok_v := decode_writeable_value(env, elems[2])
			if !ok_p || !ok_v {
				return make_err(env, "invalid_put_op")
			}
			if err := xitdb.tx_put(&tx, path_str, val); err != nil {
				return make_xitdb_err(env, err)
			}

		case ATOM_APPEND:
			path_str, ok_p := get_string_from_binary(env, elems[1])
			val, ok_v := decode_writeable_value(env, elems[2])
			if !ok_p || !ok_v {
				return make_err(env, "invalid_append_op")
			}
			if err := xitdb.tx_append(&tx, path_str, val); err != nil {
				return make_xitdb_err(env, err)
			}

		case ATOM_INSERT:
			path_str, ok_p := get_string_from_binary(env, elems[1])
			idx_val: i64 = 0
			ok_i := nif_get_int64(env, elems[2], &idx_val) != 0
			val, ok_v := decode_writeable_value(env, elems[3])
			if !ok_p || !ok_i || !ok_v {
				return make_err(env, "invalid_insert_op")
			}
			if err := xitdb.tx_insert(&tx, path_str, idx_val, val); err != nil {
				return make_xitdb_err(env, err)
			}

		case ATOM_RM:
			path_str, ok_p := get_string_from_binary(env, elems[1])
			if !ok_p {
				return make_err(env, "invalid_rm_op")
			}
			if err := xitdb.tx_rm(&tx, path_str); err != nil {
				return make_xitdb_err(env, err)
			}

		case ATOM_SLICE:
			path_str, ok_p := get_string_from_binary(env, elems[1])
			offset_val: i64 = 0
			size_val: i64 = 0
			ok_o := nif_get_int64(env, elems[2], &offset_val) != 0
			ok_s := nif_get_int64(env, elems[3], &size_val) != 0
			if !ok_p || !ok_o || !ok_s {
				return make_err(env, "invalid_slice_op")
			}
			if err := xitdb.tx_slice(&tx, path_str, size_val, offset_val); err != nil {
				return make_xitdb_err(env, err)
			}

		case ATOM_FORK:
			from_str, ok_f := get_string_from_binary(env, elems[1])
			to_str, ok_t := get_string_from_binary(env, elems[2])
			if !ok_f || !ok_t {
				return make_err(env, "invalid_fork_op")
			}
			if err := xitdb.tx_fork(&tx, from_str, to_str); err != nil {
				return make_xitdb_err(env, err)
			}
			xitdb.tx_savepoint(&tx)

		case ATOM_INDEX_ON:
			src_map, ok_1 := get_string_from_binary(env, elems[1])
			field_key, ok_2 := get_string_from_binary(env, elems[2])
			idx_map, ok_3 := get_string_from_binary(env, elems[3])
			if !ok_1 || !ok_2 || !ok_3 {
				return make_err(env, "invalid_index_on_op")
			}
			xitdb.tx_index_on(&tx, src_map, field_key, idx_map)

		case ATOM_INSTANT:
			inst_val: i64 = 0
			if nif_get_int64(env, elems[1], &inst_val) == 0 {
				return make_err(env, "invalid_instant_op")
			}
			xitdb.tx_instant(&tx, inst_val)

		case ATOM_META:
			if arity < 3 {
				return make_err(env, "invalid_meta_op")
			}
			key_str, ok_k := get_string_from_binary(env, elems[1])
			val, ok_v := decode_writeable_value(env, elems[2])
			if !ok_k || !ok_v {
				return make_err(env, "invalid_meta_op")
			}
			xitdb.tx_meta(&tx, key_str, val)

		case ATOM_SAVEPOINT:
			xitdb.tx_savepoint(&tx)

		case ATOM_INIT_COL, ATOM_RESET_COL:
			path_str, ok_p := get_string_from_binary(env, elems[1])
			kind_str, ok_k := get_string_from_binary(env, elems[2])
			if !ok_p || !ok_k {
				return make_err(env, "invalid_init_col_op")
			}
			steps, s_err := xitdb.parse_steps(path_str, context.temp_allocator)
			if s_err != nil {
				return make_xitdb_err(env, s_err)
			}
			ic := new(Init_Col_Ctx, context.temp_allocator)
			ic.steps = steps
			ic.kind = kind_str
			ic.reset = (op_atom == ATOM_RESET_COL)
			xitdb.tx_with_cursor(&tx, init_col_callback, ic)
		}
	}

	rep, c_err := xitdb.tx_commit(&tx)
	if c_err != nil {
		return make_xitdb_err(env, c_err)
	}
	xitdb.tx_report_destroy(&rep, context.temp_allocator)
	return make_ok(env, ATOM_OK)
}

// ============================================================================
// High-Level Query, Pull, Diff, History, Datalog & Compaction NIFs
// ============================================================================

@(export)
odin_nif_select :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	handle, ok := get_handle(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	moment_idx: i64 = -1
	if nif_get_int64(env, argv[1], &moment_idx) == 0 {
		return make_err(env, "badarg")
	}
	sel_str, ok_s := get_string_from_binary(env, argv[2])
	if !ok_s {
		return make_err(env, "badarg")
	}

	nif_rwlock_rlock(handle.rwlock)
	defer nif_rwlock_runlock(handle.rwlock)

	full_sel := sel_str
	if !strings.has_prefix(sel_str, "@") {
		full_sel = fmt.tprintf("@%d%s", moment_idx, sel_str)
	}

	cur_maybe, err := xitdb.select_cursor(&handle.db, full_sel)
	if err != nil {
		return make_xitdb_err(env, err)
	}
	cur, found := cur_maybe.?
	if !found {
		return make_ok(env, ATOM_NIL)
	}
	slot, s_err := xitdb.cursor_slot(cur)
	if s_err != nil {
		return make_xitdb_err(env, s_err)
	}
	term, t_err := slot_to_term(env, &handle.db, slot)
	if t_err != nil {
		return make_xitdb_err(env, t_err)
	}
	return make_ok(env, term)
}

@(export)
odin_nif_pull :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	handle, ok := get_handle(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	tag_int, val_int: i64
	if nif_get_int64(env, argv[1], &tag_int) == 0 || nif_get_int64(env, argv[2], &val_int) == 0 {
		return make_err(env, "badarg")
	}
	pattern_str, ok_p := get_string_from_binary(env, argv[3])
	if !ok_p {
		return make_err(env, "badarg")
	}

	nif_rwlock_rlock(handle.rwlock)
	defer nif_rwlock_runlock(handle.rwlock)

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = xitdb.Slot{tag = xitdb.Tag(u8(tag_int)), value = val_int}},
		db       = &handle.db,
	}

	pv, err := xitdb.pull(cur, pattern_str, context.temp_allocator)
	if err != nil {
		return make_xitdb_err(env, err)
	}
	return make_ok(env, pull_value_to_term(env, pv))
}

@(export)
odin_nif_diff_moments :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	handle, ok := get_handle(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	moment_a, moment_b: i64
	if nif_get_int64(env, argv[1], &moment_a) == 0 || nif_get_int64(env, argv[2], &moment_b) == 0 {
		return make_err(env, "badarg")
	}

	nif_rwlock_rlock(handle.rwlock)
	defer nif_rwlock_runlock(handle.rwlock)

	changes, err := xitdb.diff_moments(&handle.db, moment_a, moment_b, false, context.temp_allocator)
	if err != nil {
		return make_xitdb_err(env, err)
	}

	keys := [4]ERL_NIF_TERM{
		ATOM_OP,
		ATOM_PATH,
		ATOM_OLD_VALUE,
		ATOM_NEW_VALUE,
	}
	items := make([dynamic]ERL_NIF_TERM, 0, len(changes), context.temp_allocator)
	for chg in changes {
		op_atom: ERL_NIF_TERM
		switch chg.op {
		case .Put:
			op_atom = ATOM_PUT
		case .Append:
			op_atom = ATOM_APPEND
		case .Insert:
			op_atom = ATOM_INSERT
		case .Remove:
			op_atom = ATOM_REMOVE
		case .Slice:
			op_atom = ATOM_SLICE
		case .Fork:
			op_atom = ATOM_FORK
		case .Savepoint, .Callback:
			op_atom = ATOM_PUT
		}

		old_val, _ := materialize_slot(env, &handle.db, chg.old_slot)
		new_val, _ := materialize_slot(env, &handle.db, chg.new_slot)

		vals := [4]ERL_NIF_TERM{
			op_atom,
			make_binary(env, chg.path_str),
			old_val,
			new_val,
		}
		m: ERL_NIF_TERM
		_ = nif_make_map_from_arrays(env, raw_data(keys[:]), raw_data(vals[:]), 4, &m)
		append(&items, m)
	}

	if len(items) == 0 {
		return make_ok(env, nif_make_list_from_array(env, nil, 0))
	}
	return make_ok(env, nif_make_list_from_array(env, raw_data(items[:]), c.uint(len(items))))
}

@(export)
odin_nif_history_of :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	handle, ok := get_handle(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	sel_str, ok_s := get_string_from_binary(env, argv[1])
	if !ok_s {
		return make_err(env, "badarg")
	}

	nif_rwlock_rlock(handle.rwlock)
	defer nif_rwlock_runlock(handle.rwlock)

	entries, err := xitdb.history_of(&handle.db, sel_str, context.temp_allocator)
	if err != nil {
		return make_xitdb_err(env, err)
	}

	keys := [4]ERL_NIF_TERM{
		ATOM_MOMENT_INDEX,
		ATOM_VALUE,
		ATOM_DOC,
		ATOM_INSTANT,
	}
	items := make([dynamic]ERL_NIF_TERM, 0, len(entries), context.temp_allocator)
	for entry in entries {
		val_term, _ := materialize_slot(env, &handle.db, entry.new_slot)
		vals := [4]ERL_NIF_TERM{
			nif_make_int64(env, entry.moment_index),
			val_term,
			make_binary(env, entry.tx_doc),
			nif_make_int64(env, entry.tx_instant),
		}
		m: ERL_NIF_TERM
		_ = nif_make_map_from_arrays(env, raw_data(keys[:]), raw_data(vals[:]), 4, &m)
		append(&items, m)
	}

	if len(items) == 0 {
		return make_ok(env, nif_make_list_from_array(env, nil, 0))
	}
	return make_ok(env, nif_make_list_from_array(env, raw_data(items[:]), c.uint(len(items))))
}

@(export)
odin_nif_query_datalog :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	handle, ok := get_handle(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	moment_idx: i64 = -1
	if nif_get_int64(env, argv[1], &moment_idx) == 0 {
		return make_err(env, "badarg")
	}
	query_str, ok_q := get_string_from_binary(env, argv[2])
	if !ok_q {
		return make_err(env, "badarg")
	}

	nif_rwlock_rlock(handle.rwlock)
	defer nif_rwlock_runlock(handle.rwlock)

	res, err := xitdb.query_datalog(&handle.db, query_str, moment_idx, context.temp_allocator)
	if err != nil {
		return make_xitdb_err(env, err)
	}

	vars_terms := make([]ERL_NIF_TERM, len(res.vars), context.temp_allocator)
	for v, idx in res.vars {
		vars_terms[idx] = make_binary(env, v)
	}
	vars_list: ERL_NIF_TERM
	if len(vars_terms) == 0 {
		vars_list = nif_make_list_from_array(env, nil, 0)
	} else {
		vars_list = nif_make_list_from_array(env, raw_data(vars_terms), c.uint(len(vars_terms)))
	}

	rows_terms := make([]ERL_NIF_TERM, len(res.rows), context.temp_allocator)
	for row, r_idx in res.rows {
		cols := make([]ERL_NIF_TERM, len(row), context.temp_allocator)
		for cell, c_idx in row {
			cols[c_idx] = pull_value_to_term(env, cell)
		}
		if len(cols) == 0 {
			rows_terms[r_idx] = nif_make_list_from_array(env, nil, 0)
		} else {
			rows_terms[r_idx] = nif_make_list_from_array(env, raw_data(cols), c.uint(len(cols)))
		}
	}
	rows_list: ERL_NIF_TERM
	if len(rows_terms) == 0 {
		rows_list = nif_make_list_from_array(env, nil, 0)
	} else {
		rows_list = nif_make_list_from_array(env, raw_data(rows_terms), c.uint(len(rows_terms)))
	}

	keys := [2]ERL_NIF_TERM{
		ATOM_VARS,
		ATOM_ROWS,
	}
	vals := [2]ERL_NIF_TERM{
		vars_list,
		rows_list,
	}
	m: ERL_NIF_TERM
	_ = nif_make_map_from_arrays(env, raw_data(keys[:]), raw_data(vals[:]), 2, &m)
	return make_ok(env, m)
}

@(export)
odin_nif_compact :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	handle, ok := get_handle(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	target_path, ok_p := get_string_from_binary(env, argv[1])
	if !ok_p {
		return make_err(env, "badarg")
	}

	nif_rwlock_rwlock(handle.rwlock)
	defer nif_rwlock_rwunlock(handle.rwlock)

	raw_res := nif_alloc_db_resource(c.size_t(size_of(Db_Handle)))
	if raw_res == nil {
		return make_err(env, "alloc_failed")
	}
	comp_handle := (^Db_Handle)(raw_res)
	comp_handle^ = {}

	open_err: xitdb.Error = nil
	if len(target_path) == 0 {
		comp_handle.core = xitdb.core_memory_init(context.allocator)
		comp_handle.backend = 0
	} else {
		comp_handle.core, open_err = xitdb.core_buffered_file_open(
			target_path,
			xitdb.DEFAULT_BUFFER_SIZE,
			os.File_Flags{.Read, .Write, .Create, .Trunc},
			true,
			context.allocator,
		)
		comp_handle.backend = 2
	}

	if open_err != nil {
		comp_handle.is_closed = true
		_ = nif_make_db_resource(env, raw_res)
		return make_xitdb_err(env, open_err)
	}

	comp_err: xitdb.Error = nil
	comp_handle.db, comp_err = xitdb.database_compact(&handle.db, &comp_handle.core)
	if comp_err != nil {
		_ = xitdb.core_destroy(&comp_handle.core, close_file = true)
		comp_handle.is_closed = true
		_ = nif_make_db_resource(env, raw_res)
		return make_xitdb_err(env, comp_err)
	}

	_ = xitdb.core_sync(&comp_handle.core)
	comp_handle.rwlock = nif_rwlock_create("xitdb_rwlock")
	res_term := nif_make_db_resource(env, raw_res)
	return make_ok(env, res_term)
}

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
		slot_ptr := xitdb.cursor_resolved(rc) or_return
		if slot_ptr.slot.tag == .None || slot_ptr.slot.value == 0 {
			return {}, false, false, nil
		}
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
