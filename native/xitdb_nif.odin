package xitdb_nif

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
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
	nif_get_map_size :: proc(env: ErlNifEnv, map_term: ERL_NIF_TERM, size_out: ^c.size_t) -> c.int ---
	nif_map_to_kv_arrays :: proc(env: ErlNifEnv, map_term: ERL_NIF_TERM, keys_out: [^]ERL_NIF_TERM, vals_out: [^]ERL_NIF_TERM, max_cnt: c.size_t, count_out: ^c.size_t) -> c.int ---

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
	nif_make_new_map :: proc(env: ErlNifEnv) -> ERL_NIF_TERM ---
	nif_make_map_put :: proc(env: ErlNifEnv, map_in: ERL_NIF_TERM, key: ERL_NIF_TERM, value: ERL_NIF_TERM, map_out: ^ERL_NIF_TERM) -> c.int ---
	nif_map_to_kv_list :: proc(env: ErlNifEnv, map_term: ERL_NIF_TERM, list_out: ^ERL_NIF_TERM) -> c.int ---
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
ATOM_RM_IF_EXISTS:     ERL_NIF_TERM
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
ATOM_STRUCT:                ERL_NIF_TERM
ATOM_KIND:                  ERL_NIF_TERM
ATOM_DATA:                  ERL_NIF_TERM
ATOM_MAP:                   ERL_NIF_TERM
ATOM_XITDB_COLLECTION_MOD:  ERL_NIF_TERM
ATOM_MAPSET_MOD:            ERL_NIF_TERM
ATOM_XITDB_COL:             ERL_NIF_TERM
ATOM_MERGE_MAP:             ERL_NIF_TERM
TAG_ATOMS:                  [17]ERL_NIF_TERM

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
	ATOM_RM_IF_EXISTS = make_atom(env, "rm_if_exists")
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
	ATOM_STRUCT                = make_atom(env, "__struct__")
	ATOM_KIND                  = make_atom(env, "kind")
	ATOM_DATA                  = make_atom(env, "data")
	ATOM_MAP                   = make_atom(env, "map")
	ATOM_XITDB_COLLECTION_MOD  = make_atom(env, "Elixir.Xitdb.Collection")
	ATOM_MAPSET_MOD            = make_atom(env, "Elixir.MapSet")
	ATOM_XITDB_COL             = make_atom(env, "__xitdb_col__")
	ATOM_MERGE_MAP             = make_atom(env, "merge_map")

	for i in 0 ..< 17 {
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

make_map_safe :: proc(env: ErlNifEnv, keys: []ERL_NIF_TERM, vals: []ERL_NIF_TERM) -> ERL_NIF_TERM {
	if len(keys) == 0 {
		return nif_make_new_map(env)
	}
	map_term: ERL_NIF_TERM
	if nif_make_map_from_arrays(env, raw_data(keys), raw_data(vals), c.size_t(len(keys)), &map_term) != 0 {
		return map_term
	}
	map_term = nif_make_new_map(env)
	for i in 0 ..< len(keys) {
		next_map: ERL_NIF_TERM
		if nif_make_map_put(env, map_term, keys[i], vals[i], &next_map) != 0 {
			map_term = next_map
		}
	}
	return map_term
}

materialize_slot :: proc(env: ErlNifEnv, db: ^xitdb.Database, slot: xitdb.Slot, is_root: bool = false) -> (res: ERL_NIF_TERM, err: xitdb.Error) {
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
			term := materialize_slot(env, db, elem_slot, false) or_return
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
			if is_root && key_str == "__tx" {
				continue
			}
			val_slot := xitdb.cursor_slot(kv.value_cursor) or_return
			k_term := make_binary(env, key_str)
			v_term := materialize_slot(env, db, val_slot, false) or_return
			append(&keys, k_term)
			append(&vals, v_term)
		}
		return make_map_safe(env, keys[:], vals[:]), nil
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
			return nif_make_new_map(env)
		}
		keys := make([]ERL_NIF_TERM, len(v), context.temp_allocator)
		vals := make([]ERL_NIF_TERM, len(v), context.temp_allocator)
		for entry, idx in v {
			keys[idx] = make_binary(env, entry.key)
			vals[idx] = pull_value_to_term(env, entry.val)
		}
		return make_map_safe(env, keys, vals)
	}
	return ATOM_NIL
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
	if h.rwlock == nil {
		return nil, false
	}
	return h, true
}

acquire_rlock :: proc(env: ErlNifEnv, term: ERL_NIF_TERM) -> (^Db_Handle, bool) {
	h, ok := get_handle(env, term)
	if !ok {
		return nil, false
	}
	nif_rwlock_rlock(h.rwlock)
	if h.is_closed {
		nif_rwlock_runlock(h.rwlock)
		return nil, false
	}
	return h, true
}

acquire_wlock :: proc(env: ErlNifEnv, term: ERL_NIF_TERM) -> (^Db_Handle, bool) {
	h, ok := get_handle(env, term)
	if !ok {
		return nil, false
	}
	nif_rwlock_rwlock(h.rwlock)
	if h.is_closed {
		nif_rwlock_rwunlock(h.rwlock)
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
	if handle.rwlock == nil {
		_ = xitdb.core_destroy(&handle.core, close_file = true)
		handle.is_closed = true
		_ = nif_make_db_resource(env, raw_res)
		return make_err(env, "alloc_failed")
	}
	res_term := nif_make_db_resource(env, raw_res)
	return make_ok(env, res_term)
}

@(export)
odin_nif_close :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	ptr: rawptr = nil
	if argc != 1 || nif_get_db_resource(env, argv[0], &ptr) == 0 || ptr == nil {
		return ATOM_OK
	}
	handle := (^Db_Handle)(ptr)
	if handle.rwlock == nil {
		return ATOM_OK
	}
	nif_rwlock_rwlock(handle.rwlock)
	defer nif_rwlock_rwunlock(handle.rwlock)

	if !handle.is_closed {
		_ = xitdb.core_destroy(&handle.core, close_file = true)
		handle.is_closed = true
	}
	return ATOM_OK
}

@(export)
odin_nif_sync :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 1 {
		return make_err(env, "badarg")
	}
	handle, ok := acquire_wlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_rwunlock(handle.rwlock)

	if err := xitdb.core_sync(&handle.core); err != nil {
		return make_xitdb_err(env, err)
	}
	return ATOM_OK
}

@(export)
odin_nif_info :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 1 {
		return make_err(env, "badarg")
	}
	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	rc := xitdb.database_root_cursor(&handle.db).read_cursor
	moment_count: i64 = 0
	if hist, err := xitdb.read_array_list_init(rc); err == nil {
		if cnt, c_err := xitdb.array_list_count(hist); c_err == nil {
			moment_count = cnt
		}
	}
	file_size, fs_err := xitdb.core_length(&handle.core)
	if fs_err != nil {
		return make_xitdb_err(env, fs_err)
	}

	keys := [2]ERL_NIF_TERM{
		ATOM_MOMENT_COUNT,
		ATOM_FILE_SIZE,
	}
	vals := [2]ERL_NIF_TERM{
		nif_make_int64(env, moment_count),
		nif_make_int64(env, file_size),
	}
	m := make_map_safe(env, keys[:], vals[:])
	return make_ok(env, m)
}

is_pointer_tag :: proc(tag: xitdb.Tag) -> bool {
	#partial switch tag {
	case .Index,
	     .Array_List,
	     .Linked_Array_List,
	     .Hash_Map,
	     .KV_Pair,
	     .Bytes,
	     .Hash_Set,
	     .Counted_Hash_Map,
	     .Counted_Hash_Set,
	     .Sorted_Map,
	     .Sorted_Set,
	     .Sorted_KV_Pair:
		return true
	}
	return false
}

resolve_slot_arg :: proc(
	handle: ^Db_Handle,
	tag_int: i64,
	val_int: i64,
) -> (
	slot: xitdb.Slot,
	is_root: bool,
	is_empty: bool,
	err: xitdb.Error,
	err_reason: string,
) {
	if tag_int == -1 {
		rc := xitdb.database_root_cursor(&handle.db).read_cursor
		hist, h_err := xitdb.read_array_list_init(rc)
		if h_err != nil {
			return {}, true, false, h_err, ""
		}
		cnt, c_err := xitdb.array_list_count(hist)
		if c_err != nil {
			return {}, true, false, c_err, ""
		}
		if cnt == 0 {
			if val_int == -1 || val_int == 0 {
				return xitdb.Slot{tag = .Hash_Map, value = 0, full = false}, true, true, nil, ""
			}
			return {}, true, false, nil, "moment_out_of_range"
		}
		resolved := val_int if val_int >= 0 else cnt + val_int
		if resolved < 0 || resolved >= cnt {
			return {}, true, false, nil, "moment_out_of_range"
		}
		slot_maybe, s_err := xitdb.array_list_get_slot(hist, resolved)
		if s_err != nil {
			return {}, true, false, s_err, ""
		}
		m_slot, has_slot := slot_maybe.?
		if !has_slot {
			return {}, true, false, nil, "moment_not_found"
		}
		return m_slot, true, false, nil, ""
	}

	if tag_int < 0 || tag_int > i64(xitdb.MAX_TAG_VALUE) {
		return {}, false, false, nil, "invalid_slot"
	}

	tag := xitdb.Tag(u8(tag_int))
	if is_pointer_tag(tag) {
		if val_int < 0 {
			return {}, false, false, nil, "invalid_slot"
		}
		if val_int == 0 {
			if is_container_tag(tag) {
				return xitdb.Slot{tag = tag, value = 0, full = false}, false, true, nil, ""
			}
			return {}, false, false, nil, "invalid_slot"
		}
		core_len, cl_err := xitdb.core_length(&handle.core)
		if cl_err != nil {
			return {}, false, false, cl_err, ""
		}
		if val_int < xitdb.HEADER_LENGTH || val_int >= core_len {
			return {}, false, false, nil, "invalid_slot"
		}
	} else if tag == .None {
		return xitdb.Slot{tag = .None, value = 0, full = false}, false, true, nil, ""
	}

	return xitdb.Slot{tag = tag, value = val_int}, false, false, nil, ""
}

@(export)
odin_nif_moment_slot :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 2 {
		return make_err(env, "badarg")
	}
	moment_idx: i64 = -1
	if nif_get_int64(env, argv[1], &moment_idx) == 0 {
		return make_err(env, "badarg")
	}

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	slot, _, is_empty, r_err, err_reason := resolve_slot_arg(handle, -1, moment_idx)
	if r_err != nil {
		return make_xitdb_err(env, r_err)
	}
	if err_reason != "" {
		return make_err(env, err_reason)
	}
	if is_empty {
		return make_ok(env, nif_make_tuple5(
			env,
			ATOM_CURSOR,
			TAG_ATOMS[u8(xitdb.Tag.Hash_Map)],
			nif_make_int64(env, i64(u8(xitdb.Tag.Hash_Map))),
			nif_make_int64(env, 0),
			nif_make_int64(env, 0),
		))
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
	defer free_all(context.temp_allocator)

	if argc != 4 {
		return make_err(env, "badarg")
	}
	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	tag_int: i64 = 0
	val_int: i64 = 0
	if nif_get_int64(env, argv[1], &tag_int) == 0 || nif_get_int64(env, argv[2], &val_int) == 0 {
		return make_err(env, "badarg")
	}
	key_str, ok_k := get_string_from_binary(env, argv[3])
	if !ok_k {
		return make_err(env, "badarg")
	}

	slot, _, is_empty, r_err, err_reason := resolve_slot_arg(handle, tag_int, val_int)
	if r_err != nil {
		return make_xitdb_err(env, r_err)
	}
	if err_reason != "" {
		return make_err(env, err_reason)
	}
	if is_empty {
		return ATOM_ERROR
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = &handle.db,
	}

	child_slot_maybe: Maybe(xitdb.Slot) = nil
	err: xitdb.Error = nil

	#partial switch slot.tag {
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
		return make_xitdb_err(env, err)
	}
	child_slot, has_child := child_slot_maybe.?
	if !has_child || (child_slot.tag == .None && !child_slot.full) {
		return ATOM_ERROR
	}

	term, t_err := slot_to_term(env, &handle.db, child_slot)
	if t_err != nil {
		return make_xitdb_err(env, t_err)
	}
	return make_ok(env, term)
}

@(export)
odin_nif_slot_get_index :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 4 {
		return make_err(env, "badarg")
	}
	tag_int: i64 = 0
	val_int: i64 = 0
	idx_int: i64 = 0
	if nif_get_int64(env, argv[1], &tag_int) == 0 ||
	   nif_get_int64(env, argv[2], &val_int) == 0 ||
	   nif_get_int64(env, argv[3], &idx_int) == 0 {
		return make_err(env, "badarg")
	}

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	slot, _, is_empty, r_err, err_reason := resolve_slot_arg(handle, tag_int, val_int)
	if r_err != nil {
		return make_xitdb_err(env, r_err)
	}
	if err_reason != "" {
		return make_err(env, err_reason)
	}
	if is_empty {
		return ATOM_ERROR
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = &handle.db,
	}

	child_slot_maybe: Maybe(xitdb.Slot) = nil
	err: xitdb.Error = nil

	#partial switch slot.tag {
	case .Array_List:
		al_col: xitdb.Read_Array_List
		al_col, err = xitdb.read_array_list_init(cur)
		if err == nil {
			cnt: i64
			cnt, err = xitdb.array_list_count(al_col)
			if err == nil {
				resolved := idx_int if idx_int >= 0 else cnt + idx_int
				if resolved < 0 || resolved >= cnt {
					return ATOM_ERROR
				}
				child_slot_maybe, err = xitdb.array_list_get_slot(al_col, resolved)
			}
		}
	case .Linked_Array_List:
		ll_col: xitdb.Read_Linked_Array_List
		ll_col, err = xitdb.read_linked_array_list_init(cur)
		if err == nil {
			cnt: i64
			cnt, err = xitdb.linked_array_list_count(ll_col)
			if err == nil {
				resolved := idx_int if idx_int >= 0 else cnt + idx_int
				if resolved < 0 || resolved >= cnt {
					return ATOM_ERROR
				}
				child_slot_maybe, err = xitdb.linked_array_list_get_slot(ll_col, resolved)
			}
		}
	case:
		return ATOM_ERROR
	}

	if err != nil {
		return make_xitdb_err(env, err)
	}
	child_slot, has_child := child_slot_maybe.?
	if !has_child {
		return ATOM_ERROR
	}

	term, t_err := slot_to_term(env, &handle.db, child_slot)
	if t_err != nil {
		return make_xitdb_err(env, t_err)
	}
	return make_ok(env, term)
}

@(export)
odin_nif_slot_count :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 3 {
		return make_err(env, "badarg")
	}
	tag_int: i64 = 0
	val_int: i64 = 0
	if nif_get_int64(env, argv[1], &tag_int) == 0 || nif_get_int64(env, argv[2], &val_int) == 0 {
		return make_err(env, "badarg")
	}

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	slot, _, is_empty, r_err, err_reason := resolve_slot_arg(handle, tag_int, val_int)
	if r_err != nil {
		return make_xitdb_err(env, r_err)
	}
	if err_reason != "" {
		return make_err(env, err_reason)
	}

	#partial switch slot.tag {
	case .Array_List, .Linked_Array_List, .Counted_Hash_Map, .Counted_Hash_Set, .Sorted_Map, .Sorted_Set:
		if is_empty {
			return make_ok(env, nif_make_int64(env, 0))
		}
		cur := xitdb.Read_Cursor{
			slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
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
	defer free_all(context.temp_allocator)

	if argc != 4 {
		return make_err(env, "badarg")
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

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	slot, is_root, is_empty, r_err, err_reason := resolve_slot_arg(handle, tag_int, val_int)
	if r_err != nil {
		return make_xitdb_err(env, r_err)
	}
	if err_reason != "" {
		return make_err(env, err_reason)
	}
	if is_empty {
		return make_ok(env, ATOM_FALSE)
	}
	if is_root && key_str == "__tx" {
		return make_ok(env, ATOM_FALSE)
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = &handle.db,
	}

	#partial switch slot.tag {
	case .Hash_Set, .Counted_Hash_Set:
		hs := xitdb.Read_Hash_Set{cursor = cur}
		slot_maybe, err := xitdb.hash_set_get_slot(hs, key_str)
		if err == .Key_Not_Found {
			return make_ok(env, ATOM_FALSE)
		}
		if err != nil {
			return make_xitdb_err(env, err)
		}
		_, found := slot_maybe.?
		return make_ok(env, ATOM_TRUE if found else ATOM_FALSE)

	case .Sorted_Set:
		ss := xitdb.Read_Sorted_Set{cursor = cur}
		found, err := xitdb.sorted_set_contains(ss, key_str)
		if err == .Key_Not_Found {
			return make_ok(env, ATOM_FALSE)
		}
		if err != nil {
			return make_xitdb_err(env, err)
		}
		return make_ok(env, ATOM_TRUE if found else ATOM_FALSE)

	case .Hash_Map, .Counted_Hash_Map:
		hm := xitdb.Read_Hash_Map{cursor = cur}
		slot_maybe, err := xitdb.hash_map_get_slot(hm, key_str)
		if err == .Key_Not_Found {
			return make_ok(env, ATOM_FALSE)
		}
		if err != nil {
			return make_xitdb_err(env, err)
		}
		s, found := slot_maybe.?
		return make_ok(env, ATOM_TRUE if (found && (s.tag != .None || s.full)) else ATOM_FALSE)

	case .Sorted_Map:
		sm := xitdb.Read_Sorted_Map{cursor = cur}
		slot_maybe, err := xitdb.sorted_map_get_slot(sm, key_str)
		if err == .Key_Not_Found {
			return make_ok(env, ATOM_FALSE)
		}
		if err != nil {
			return make_xitdb_err(env, err)
		}
		s, found := slot_maybe.?
		return make_ok(env, ATOM_TRUE if (found && (s.tag != .None || s.full)) else ATOM_FALSE)
	}

	return make_err(env, "unsupported")
}

@(export)
odin_nif_slot_slice :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 5 {
		return make_err(env, "badarg")
	}
	tag_int, val_int, start_idx, length: i64
	if nif_get_int64(env, argv[1], &tag_int) == 0 ||
	   nif_get_int64(env, argv[2], &val_int) == 0 ||
	   nif_get_int64(env, argv[3], &start_idx) == 0 ||
	   nif_get_int64(env, argv[4], &length) == 0 {
		return make_err(env, "badarg")
	}
	if start_idx < 0 {
		return make_xitdb_err(env, .Invalid_Range)
	}
	if length <= 0 {
		return make_ok(env, nif_make_list_from_array(env, nil, 0))
	}

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	slot, _, is_empty, r_err, err_reason := resolve_slot_arg(handle, tag_int, val_int)
	if r_err != nil {
		return make_xitdb_err(env, r_err)
	}
	if err_reason != "" {
		return make_err(env, err_reason)
	}
	if is_empty {
		#partial switch slot.tag {
		case .Array_List, .Linked_Array_List, .Sorted_Map, .Sorted_Set:
			return make_ok(env, nif_make_list_from_array(env, nil, 0))
		case:
			return make_err(env, "unsupported")
		}
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = &handle.db,
	}

	it: xitdb.Cursor_Iterator
	err: xitdb.Error = nil

	#partial switch slot.tag {
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

	cap_hint := min(int(length), 256)
	items := make([dynamic]ERL_NIF_TERM, 0, cap_hint, context.temp_allocator)
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
		#partial switch slot.tag {
		case .Array_List, .Linked_Array_List:
			s, s_err := xitdb.cursor_slot(elem_cur)
			if s_err != nil {
				return make_xitdb_err(env, s_err)
			}
			t, t_err := slot_to_term(env, &handle.db, s)
			if t_err != nil {
				return make_xitdb_err(env, t_err)
			}
			append(&items, t)
		case .Sorted_Set:
			kv, kv_err := xitdb.cursor_read_kv_pair(elem_cur, context.temp_allocator)
			if kv_err != nil {
				return make_xitdb_err(env, kv_err)
			}
			ks, ks_err := xitdb.cursor_slot(kv.key_cursor)
			if ks_err != nil {
				return make_xitdb_err(env, ks_err)
			}
			t, t_err := slot_to_term(env, &handle.db, ks)
			if t_err != nil {
				return make_xitdb_err(env, t_err)
			}
			append(&items, t)
		case .Sorted_Map:
			kv, kv_err := xitdb.cursor_read_kv_pair(elem_cur, context.temp_allocator)
			if kv_err != nil {
				return make_xitdb_err(env, kv_err)
			}
			k_str, k_err := read_key_cursor_string(kv.key_cursor, sb_buf[:])
			if k_err != nil {
				return make_xitdb_err(env, k_err)
			}
			vs, vs_err := xitdb.cursor_slot(kv.value_cursor)
			if vs_err != nil {
				return make_xitdb_err(env, vs_err)
			}
			vt, vt_err := slot_to_term(env, &handle.db, vs)
			if vt_err != nil {
				return make_xitdb_err(env, vt_err)
			}
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

	if argc != 5 {
		return make_err(env, "badarg")
	}
	tag_int, val_int, offset, limit: i64
	if nif_get_int64(env, argv[1], &tag_int) == 0 ||
	   nif_get_int64(env, argv[2], &val_int) == 0 ||
	   nif_get_int64(env, argv[3], &offset) == 0 ||
	   nif_get_int64(env, argv[4], &limit) == 0 {
		return make_err(env, "badarg")
	}
	if offset < 0 {
		return make_xitdb_err(env, .Invalid_Range)
	}
	if limit == 0 {
		return make_ok(env, nif_make_list_from_array(env, nil, 0))
	}

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	slot, is_root, is_empty, r_err, err_reason := resolve_slot_arg(handle, tag_int, val_int)
	if r_err != nil {
		return make_xitdb_err(env, r_err)
	}
	if err_reason != "" {
		return make_err(env, err_reason)
	}
	if is_empty {
		return make_ok(env, nif_make_list_from_array(env, nil, 0))
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = &handle.db,
	}

	it: xitdb.Cursor_Iterator
	err: xitdb.Error = nil
	direct_seek := false

	#partial switch slot.tag {
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

	cap_hint := min(int(limit), 256) if limit > 0 else 64
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

		#partial switch slot.tag {
		case .Array_List, .Linked_Array_List:
			if seen >= offset {
				s, s_err := xitdb.cursor_slot(elem_cur)
				if s_err != nil {
					return make_xitdb_err(env, s_err)
				}
				t, t_err := slot_to_term(env, &handle.db, s)
				if t_err != nil {
					return make_xitdb_err(env, t_err)
				}
				append(&items, t)
				emitted += 1
			}
			seen += 1

		case .Hash_Set, .Counted_Hash_Set, .Sorted_Set:
			if seen >= offset {
				kv, kv_err := xitdb.cursor_read_kv_pair(elem_cur, context.temp_allocator)
				if kv_err != nil {
					return make_xitdb_err(env, kv_err)
				}
				ks, ks_err := xitdb.cursor_slot(kv.key_cursor)
				if ks_err != nil {
					return make_xitdb_err(env, ks_err)
				}
				t, t_err := slot_to_term(env, &handle.db, ks)
				if t_err != nil {
					return make_xitdb_err(env, t_err)
				}
				append(&items, t)
				emitted += 1
			}
			seen += 1

		case .Hash_Map, .Counted_Hash_Map, .Sorted_Map:
			kv, kv_err := xitdb.cursor_read_kv_pair(elem_cur, context.temp_allocator)
			if kv_err != nil {
				return make_xitdb_err(env, kv_err)
			}
			k_str, k_err := read_key_cursor_string(kv.key_cursor, sb_buf[:])
			if k_err != nil {
				return make_xitdb_err(env, k_err)
			}
			if is_root && k_str == "__tx" {
				continue
			}
			if seen >= offset {
				vs, vs_err := xitdb.cursor_slot(kv.value_cursor)
				if vs_err != nil {
					return make_xitdb_err(env, vs_err)
				}
				vt, vt_err := slot_to_term(env, &handle.db, vs)
				if vt_err != nil {
					return make_xitdb_err(env, vt_err)
				}
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

	if argc != 4 {
		return make_err(env, "badarg")
	}
	tag_int, val_int, full_int: i64
	if nif_get_int64(env, argv[1], &tag_int) == 0 ||
	   nif_get_int64(env, argv[2], &val_int) == 0 ||
	   nif_get_int64(env, argv[3], &full_int) == 0 {
		return make_err(env, "badarg")
	}

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	slot, is_root, is_empty, r_err, err_reason := resolve_slot_arg(handle, tag_int, val_int)
	if r_err != nil {
		return make_xitdb_err(env, r_err)
	}
	if err_reason != "" {
		return make_err(env, err_reason)
	}
	if is_empty {
		#partial switch slot.tag {
		case .Array_List, .Linked_Array_List:
			return make_ok(env, nif_make_list_from_array(env, nil, 0))
		case .Hash_Set, .Counted_Hash_Set, .Sorted_Set:
			return make_ok(env, nif_make_tuple2(env, ATOM_XITDB_SET, nif_make_list_from_array(env, nil, 0)))
		case .Hash_Map, .Counted_Hash_Map, .Sorted_Map:
			return make_ok(env, nif_make_new_map(env))
		case:
			return make_ok(env, ATOM_NIL)
		}
	}

	if !is_root {
		slot.full = (full_int != 0)
	}
	term, err := materialize_slot(env, &handle.db, slot, is_root)
	if err != nil {
		return make_xitdb_err(env, err)
	}
	return make_ok(env, term)
}

// ============================================================================
// Escaped Path & Selector Parser (Quotes, Backslashes, Root Inheritance)
// ============================================================================

parse_escaped_quoted :: proc(s: string, quote_i: int, allocator: runtime.Allocator) -> (key: string, next_i: int, err_reason: string) {
	if quote_i >= len(s) {
		return "", 0, "invalid_selector"
	}
	quote := s[quote_i]
	if quote != '"' && quote != '\'' {
		return "", 0, "invalid_selector"
	}
	i := quote_i + 1
	start := i
	has_escape := false
	b: strings.Builder

	for i < len(s) {
		ch := s[i]
		if ch == quote {
			if has_escape {
				return strings.to_string(b), i + 1, ""
			}
			return s[start:i], i + 1, ""
		}
		if ch == '\\' {
			if i + 1 >= len(s) {
				return "", 0, "invalid_selector"
			}
			if !has_escape {
				has_escape = true
				b = strings.builder_make(0, len(s) - start, allocator)
				strings.write_string(&b, s[start:i])
			}
			esc := s[i + 1]
			switch esc {
			case '\\':
				strings.write_byte(&b, '\\')
			case '"':
				strings.write_byte(&b, '"')
			case '\'':
				strings.write_byte(&b, '\'')
			case 'n':
				strings.write_byte(&b, '\n')
			case 'r':
				strings.write_byte(&b, '\r')
			case 't':
				strings.write_byte(&b, '\t')
			case:
				strings.write_byte(&b, esc)
			}
			i += 2
			continue
		}
		if has_escape {
			strings.write_byte(&b, ch)
		}
		i += 1
	}

	return "", 0, "invalid_selector"
}

parse_escaped_bracketed_string :: proc(s: string, start_i: int, allocator: runtime.Allocator) -> (key: string, next_i: int, err_reason: string) {
	if start_i + 2 >= len(s) || s[start_i] != '[' {
		return "", 0, "invalid_selector"
	}
	quote := s[start_i + 1]
	if quote != '"' && quote != '\'' {
		return "", 0, "invalid_selector"
	}
	parsed_key, after_quote, err := parse_escaped_quoted(s, start_i + 1, allocator)
	if err != "" {
		return "", 0, err
	}
	if after_quote >= len(s) || s[after_quote] != ']' {
		return "", 0, "invalid_selector"
	}
	return parsed_key, after_quote + 1, ""
}

parse_escaped_ident_or_bracket :: proc(s: string, start_i: int, allocator: runtime.Allocator) -> (key: string, next_i: int, err_reason: string) {
	if start_i >= len(s) {
		return "", start_i, "invalid_selector"
	}
	if s[start_i] == '[' {
		return parse_escaped_bracketed_string(s, start_i, allocator)
	}
	if s[start_i] == '"' || s[start_i] == '\'' {
		return parse_escaped_quoted(s, start_i, allocator)
	}
	i := start_i
	for i < len(s) {
		ch := s[i]
		if ch == '.' || ch == '[' || ch == ']' || ch == '#' || ch == '$' || ch == '%' || ch == '^' || ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' {
			break
		}
		i += 1
	}
	if i == start_i {
		return "", start_i, "invalid_selector"
	}
	return s[start_i:i], i, ""
}

parse_escaped_steps :: proc(path_str: string, allocator := context.temp_allocator) -> (res: []xitdb.Path_Step, err_reason: string) {
	s := strings.trim_space(path_str)
	if len(s) == 0 {
		return nil, ""
	}
	steps := make([dynamic]xitdb.Path_Step, 0, 8, allocator)
	i := 0

	for i < len(s) {
		ch := s[i]
		switch ch {
		case '.':
			i += 1
			key, next_i, er := parse_escaped_ident_or_bracket(s, i, allocator)
			if er != "" {
				return nil, er
			}
			append(&steps, xitdb.Path_Step{kind = .Hash_Map_Key, key = key})
			i = next_i

		case '#':
			i += 1
			kind := xitdb.Step_Kind.Counted_Hash_Map_Key
			if i < len(s) && s[i] == '%' {
				kind = .Counted_Set_Member
				i += 1
			}
			key, next_i, er := parse_escaped_ident_or_bracket(s, i, allocator)
			if er != "" {
				return nil, er
			}
			append(&steps, xitdb.Path_Step{kind = kind, key = key})
			i = next_i

		case '$':
			i += 1
			key, next_i, er := parse_escaped_ident_or_bracket(s, i, allocator)
			if er != "" {
				return nil, er
			}
			append(&steps, xitdb.Path_Step{kind = .Sorted_Map_Key, key = key})
			i = next_i

		case '%':
			i += 1
			key, next_i, er := parse_escaped_ident_or_bracket(s, i, allocator)
			if er != "" {
				return nil, er
			}
			append(&steps, xitdb.Path_Step{kind = .Hash_Set_Member, key = key})
			i = next_i

		case '^':
			i += 1
			key, next_i, er := parse_escaped_ident_or_bracket(s, i, allocator)
			if er != "" {
				return nil, er
			}
			append(&steps, xitdb.Path_Step{kind = .Sorted_Set_Member, key = key})
			i = next_i

		case '[':
			if i + 1 < len(s) && s[i + 1] == '[' {
				i += 2
				start := i
				for i < len(s) && s[i] != ']' {
					i += 1
				}
				if i + 1 >= len(s) || s[i] != ']' || s[i + 1] != ']' {
					return nil, "invalid_selector"
				}
				idx_str := strings.trim_space(s[start:i])
				idx, ok := strconv.parse_i64(idx_str)
				if !ok {
					return nil, "invalid_selector"
				}
				append(&steps, xitdb.Path_Step{kind = .Linked_List_Idx, index = idx})
				i += 2
			} else if i + 1 < len(s) && (s[i + 1] == '"' || s[i + 1] == '\'') {
				key, next_i, er := parse_escaped_bracketed_string(s, i, allocator)
				if er != "" {
					return nil, er
				}
				step_kind := xitdb.Step_Kind.Hash_Map_Key
				if len(steps) == 1 {
					if steps[0].kind == .Counted_Hash_Map_Key {
						steps[0].kind = .Hash_Map_Key
						step_kind = .Counted_Hash_Map_Key
					} else if steps[0].kind == .Sorted_Map_Key {
						steps[0].kind = .Hash_Map_Key
						step_kind = .Sorted_Map_Key
					}
				}
				append(&steps, xitdb.Path_Step{kind = step_kind, key = key})
				i = next_i
			} else {
				i += 1
				start := i
				for i < len(s) && s[i] != ']' {
					i += 1
				}
				if i >= len(s) || s[i] != ']' {
					return nil, "invalid_selector"
				}
				idx_str := strings.trim_space(s[start:i])
				idx, ok := strconv.parse_i64(idx_str)
				if !ok {
					return nil, "invalid_selector"
				}
				append(&steps, xitdb.Path_Step{kind = .Array_List_Idx, index = idx})
				i += 1
			}

		case:
			key, next_i, er := parse_escaped_ident_or_bracket(s, i, allocator)
			if er != "" {
				return nil, er
			}
			append(&steps, xitdb.Path_Step{kind = .Hash_Map_Key, key = key})
			i = next_i
		}
	}

	return steps[:], ""
}

parse_escaped_selector :: proc(sel_str: string, allocator := context.temp_allocator) -> (res: xitdb.Parsed_Selector, err_reason: string) {
	s := strings.trim_space(sel_str)
	if len(s) == 0 {
		return {}, ""
	}
	i := 0
	if s[i] == '@' {
		i += 1
		start := i
		if i < len(s) && s[i] == '-' {
			i += 1
		}
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i += 1
		}
		if i == start || (i == start + 1 && s[start] == '-') {
			return {}, "invalid_selector"
		}
		m_idx, ok := strconv.parse_i64(s[start:i])
		if !ok {
			return {}, "invalid_selector"
		}
		res.has_moment = true
		res.moment_index = m_idx
	}
	steps, er := parse_escaped_steps(s[i:], allocator)
	if er != "" {
		return {}, er
	}
	res.steps = steps
	return res, ""
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
	case:
		return .Unexpected_Tag
	}
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
		buf := make([]u8, 1024, context.temp_allocator)
		a_str, ok := get_atom_string(env, term, buf)
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

term_to_key_string :: proc(env: ErlNifEnv, term: ERL_NIF_TERM) -> (string, bool) {
	if nif_is_binary(env, term) != 0 {
		return get_string_from_binary(env, term)
	}
	if nif_is_atom(env, term) != 0 {
		if term == ATOM_NIL || term == ATOM_TRUE || term == ATOM_FALSE {
			return "", false
		}
		buf: [128]u8 = ---
		if s, ok := get_atom_string(env, term, buf[:]); ok {
			out := make([]u8, len(s), context.temp_allocator)
			copy(out, s)
			return string(out), true
		}
		big := make([]u8, 1024, context.temp_allocator)
		return get_atom_string(env, term, big)
	}
	i_val: i64 = 0
	if nif_get_int64(env, term, &i_val) != 0 {
		return fmt.tprintf("%d", i_val), true
	}
	return "", false
}

term_to_kind_string :: proc(env: ErlNifEnv, term: ERL_NIF_TERM) -> (string, bool) {
	if nif_is_atom(env, term) != 0 {
		buf := make([]u8, 128, context.temp_allocator)
		return get_atom_string(env, term, buf)
	}
	if nif_is_binary(env, term) != 0 {
		return get_string_from_binary(env, term)
	}
	return "", false
}

is_supported_col_kind :: proc(kind: string) -> bool {
	switch kind {
	case "hash_map", "counted_hash_map", "sorted_map",
	     "array_list", "linked_array_list",
	     "hash_set", "counted_hash_set", "sorted_set":
		return true
	}
	return false
}

validate_write_term :: proc(env: ErlNifEnv, term: ERL_NIF_TERM) -> bool {
	if _, ok := decode_writeable_value(env, term); ok {
		return true
	}
	if nif_is_tuple(env, term) != 0 {
		arity: c.int = 0
		elems: [^]ERL_NIF_TERM = nil
		if nif_get_tuple(env, term, &arity, &elems) == 0 {
			return false
		}
		if arity == 2 && elems[0] == ATOM_XITDB_SET {
			return validate_set_elements_term(env, elems[1])
		}
		if arity == 3 && elems[0] == ATOM_XITDB_COL {
			kind_str, ok_k := term_to_kind_string(env, elems[1])
			if !ok_k || !is_supported_col_kind(kind_str) {
				return false
			}
			return validate_collection_data_term(env, kind_str, elems[2])
		}
		return false
	}
	if nif_is_list(env, term) != 0 {
		head: ERL_NIF_TERM
		tail := term
		for nif_is_empty_list(env, tail) == 0 {
			if nif_get_list_cell(env, tail, &head, &tail) == 0 {
				return false
			}
			if !validate_write_term(env, head) {
				return false
			}
		}
		return true
	}
	if nif_is_map(env, term) != 0 {
		struct_term: ERL_NIF_TERM
		if nif_get_map_value(env, term, ATOM_STRUCT, &struct_term) != 0 {
			if struct_term == ATOM_XITDB_COLLECTION_MOD {
				kind_term, data_term: ERL_NIF_TERM
				if nif_get_map_value(env, term, ATOM_KIND, &kind_term) == 0 ||
				   nif_get_map_value(env, term, ATOM_DATA, &data_term) == 0 {
					return false
				}
				kind_str, ok_k := term_to_kind_string(env, kind_term)
				if !ok_k || !is_supported_col_kind(kind_str) {
					return false
				}
				return validate_collection_data_term(env, kind_str, data_term)
			}
			if struct_term == ATOM_MAPSET_MOD {
				ms_map: ERL_NIF_TERM
				if nif_get_map_value(env, term, ATOM_MAP, &ms_map) == 0 || nif_is_map(env, ms_map) == 0 {
					return false
				}
				kv_list: ERL_NIF_TERM
				if nif_map_to_kv_list(env, ms_map, &kv_list) == 0 {
					return false
				}
				head: ERL_NIF_TERM
				tail := kv_list
				for nif_is_empty_list(env, tail) == 0 {
					if nif_get_list_cell(env, tail, &head, &tail) == 0 {
						return false
					}
					arity: c.int = 0
					elems: [^]ERL_NIF_TERM = nil
					if nif_get_tuple(env, head, &arity, &elems) == 0 || arity != 2 {
						return false
					}
					if _, ok_s := term_to_key_string(env, elems[0]); !ok_s {
						return false
					}
				}
				return true
			}
			return false
		}
		return validate_kv_term(env, term)
	}
	return false
}

validate_set_elements_term :: proc(env: ErlNifEnv, data_term: ERL_NIF_TERM) -> bool {
	if nif_is_map(env, data_term) != 0 {
		struct_term: ERL_NIF_TERM
		if nif_get_map_value(env, data_term, ATOM_STRUCT, &struct_term) != 0 && struct_term == ATOM_MAPSET_MOD {
			return validate_write_term(env, data_term)
		}
		return false
	}
	if nif_is_list(env, data_term) == 0 {
		return false
	}
	head: ERL_NIF_TERM
	tail := data_term
	for nif_is_empty_list(env, tail) == 0 {
		if nif_get_list_cell(env, tail, &head, &tail) == 0 {
			return false
		}
		if _, ok_s := term_to_key_string(env, head); !ok_s {
			return false
		}
	}
	return true
}

validate_kv_term :: proc(env: ErlNifEnv, data_term: ERL_NIF_TERM) -> bool {
	kv_list: ERL_NIF_TERM
	if nif_is_map(env, data_term) != 0 {
		if nif_map_to_kv_list(env, data_term, &kv_list) == 0 {
			return false
		}
	} else if nif_is_list(env, data_term) != 0 {
		kv_list = data_term
	} else {
		return false
	}
	head: ERL_NIF_TERM
	tail := kv_list
	for nif_is_empty_list(env, tail) == 0 {
		if nif_get_list_cell(env, tail, &head, &tail) == 0 {
			return false
		}
		arity: c.int = 0
		elems: [^]ERL_NIF_TERM = nil
		if nif_get_tuple(env, head, &arity, &elems) == 0 || arity != 2 {
			return false
		}
		if _, ok_k := term_to_key_string(env, elems[0]); !ok_k {
			return false
		}
		if !validate_write_term(env, elems[1]) {
			return false
		}
	}
	return true
}

validate_collection_data_term :: proc(env: ErlNifEnv, kind_str: string, data_term: ERL_NIF_TERM) -> bool {
	switch kind_str {
	case "hash_map", "counted_hash_map", "sorted_map":
		return validate_kv_term(env, data_term)
	case "array_list", "linked_array_list":
		return validate_write_term(env, data_term) && nif_is_list(env, data_term) != 0
	case "hash_set", "counted_hash_set", "sorted_set":
		return validate_set_elements_term(env, data_term)
	}
	return false
}

write_hash_map_entries :: proc(env: ErlNifEnv, hm: ^xitdb.Write_Hash_Map, kv_list: ERL_NIF_TERM) -> (ok: bool, err: xitdb.Error) {
	head: ERL_NIF_TERM
	tail := kv_list
	for nif_is_empty_list(env, tail) == 0 {
		if nif_get_list_cell(env, tail, &head, &tail) == 0 {
			return false, nil
		}
		arity: c.int = 0
		elems: [^]ERL_NIF_TERM = nil
		if nif_get_tuple(env, head, &arity, &elems) == 0 || arity != 2 {
			return false, nil
		}
		k_str, ok_k := term_to_key_string(env, elems[0])
		if !ok_k {
			return false, nil
		}
		if wdata, ok_s := decode_writeable_value(env, elems[1]); ok_s {
			xitdb.hash_map_put(hm, k_str, wdata) or_return
		} else {
			v_cur := xitdb.hash_map_put_cursor(hm, k_str) or_return
			w_ok, w_err := write_term_to_cursor(env, &v_cur, elems[1])
			if w_err != nil {
				return true, w_err
			}
			if !w_ok {
				return false, nil
			}
		}
	}
	return true, nil
}

write_sorted_map_entries :: proc(env: ErlNifEnv, sm: ^xitdb.Write_Sorted_Map, kv_list: ERL_NIF_TERM) -> (ok: bool, err: xitdb.Error) {
	head: ERL_NIF_TERM
	tail := kv_list
	for nif_is_empty_list(env, tail) == 0 {
		if nif_get_list_cell(env, tail, &head, &tail) == 0 {
			return false, nil
		}
		arity: c.int = 0
		elems: [^]ERL_NIF_TERM = nil
		if nif_get_tuple(env, head, &arity, &elems) == 0 || arity != 2 {
			return false, nil
		}
		k_str, ok_k := term_to_key_string(env, elems[0])
		if !ok_k {
			return false, nil
		}
		if wdata, ok_s := decode_writeable_value(env, elems[1]); ok_s {
			xitdb.sorted_map_put(sm, k_str, wdata) or_return
		} else {
			v_cur := xitdb.sorted_map_put_cursor(sm, k_str) or_return
			w_ok, w_err := write_term_to_cursor(env, &v_cur, elems[1])
			if w_err != nil {
				return true, w_err
			}
			if !w_ok {
				return false, nil
			}
		}
	}
	return true, nil
}

write_hash_set_entries :: proc(env: ErlNifEnv, hs: ^xitdb.Write_Hash_Set, data_term: ERL_NIF_TERM) -> (ok: bool, err: xitdb.Error) {
	if nif_is_map(env, data_term) != 0 {
		ms_map: ERL_NIF_TERM
		if nif_get_map_value(env, data_term, ATOM_MAP, &ms_map) == 0 {
			return false, nil
		}
		kv_list: ERL_NIF_TERM
		if nif_map_to_kv_list(env, ms_map, &kv_list) == 0 {
			return false, nil
		}
		head: ERL_NIF_TERM
		tail := kv_list
		for nif_is_empty_list(env, tail) == 0 {
			if nif_get_list_cell(env, tail, &head, &tail) == 0 {
				return false, nil
			}
			arity: c.int = 0
			elems: [^]ERL_NIF_TERM = nil
			if nif_get_tuple(env, head, &arity, &elems) == 0 || arity != 2 {
				return false, nil
			}
			k_str, ok_k := term_to_key_string(env, elems[0])
			if !ok_k {
				return false, nil
			}
			xitdb.hash_set_put(hs, k_str) or_return
		}
		return true, nil
	}
	head: ERL_NIF_TERM
	tail := data_term
	for nif_is_empty_list(env, tail) == 0 {
		if nif_get_list_cell(env, tail, &head, &tail) == 0 {
			return false, nil
		}
		k_str, ok_k := term_to_key_string(env, head)
		if !ok_k {
			return false, nil
		}
		xitdb.hash_set_put(hs, k_str) or_return
	}
	return true, nil
}

write_sorted_set_entries :: proc(env: ErlNifEnv, ss: ^xitdb.Write_Sorted_Set, data_term: ERL_NIF_TERM) -> (ok: bool, err: xitdb.Error) {
	if nif_is_map(env, data_term) != 0 {
		ms_map: ERL_NIF_TERM
		if nif_get_map_value(env, data_term, ATOM_MAP, &ms_map) == 0 {
			return false, nil
		}
		kv_list: ERL_NIF_TERM
		if nif_map_to_kv_list(env, ms_map, &kv_list) == 0 {
			return false, nil
		}
		head: ERL_NIF_TERM
		tail := kv_list
		for nif_is_empty_list(env, tail) == 0 {
			if nif_get_list_cell(env, tail, &head, &tail) == 0 {
				return false, nil
			}
			arity: c.int = 0
			elems: [^]ERL_NIF_TERM = nil
			if nif_get_tuple(env, head, &arity, &elems) == 0 || arity != 2 {
				return false, nil
			}
			k_str, ok_k := term_to_key_string(env, elems[0])
			if !ok_k {
				return false, nil
			}
			xitdb.sorted_set_put(ss, k_str) or_return
		}
		return true, nil
	}
	head: ERL_NIF_TERM
	tail := data_term
	for nif_is_empty_list(env, tail) == 0 {
		if nif_get_list_cell(env, tail, &head, &tail) == 0 {
			return false, nil
		}
		k_str, ok_k := term_to_key_string(env, head)
		if !ok_k {
			return false, nil
		}
		xitdb.sorted_set_put(ss, k_str) or_return
	}
	return true, nil
}

write_collection_term_to_cursor :: proc(env: ErlNifEnv, cur: ^xitdb.Write_Cursor, kind_str: string, data_term: ERL_NIF_TERM) -> (ok: bool, err: xitdb.Error) {
	kv_list := data_term
	if nif_is_map(env, data_term) != 0 && (kind_str == "hash_map" || kind_str == "counted_hash_map" || kind_str == "sorted_map") {
		if nif_map_to_kv_list(env, data_term, &kv_list) == 0 {
			return false, nil
		}
	}

	switch kind_str {
	case "hash_map":
		hm, init_err := xitdb.write_hash_map_init(cur^)
		if init_err != nil {
			return true, init_err
		}
		return write_hash_map_entries(env, &hm, kv_list)
	case "counted_hash_map":
		chm, init_err := xitdb.write_counted_hash_map_init(cur^)
		if init_err != nil {
			return true, init_err
		}
		return write_hash_map_entries(env, &chm.write_hash_map, kv_list)
	case "sorted_map":
		sm, init_err := xitdb.write_sorted_map_init(cur^)
		if init_err != nil {
			return true, init_err
		}
		return write_sorted_map_entries(env, &sm, kv_list)
	case "array_list":
		al, init_err := xitdb.write_array_list_init(cur^)
		if init_err != nil {
			return true, init_err
		}
		head: ERL_NIF_TERM
		tail := data_term
		for nif_is_empty_list(env, tail) == 0 {
			if nif_get_list_cell(env, tail, &head, &tail) == 0 {
				return false, nil
			}
			if wdata, ok_s := decode_writeable_value(env, head); ok_s {
				xitdb.array_list_append(&al, wdata) or_return
			} else {
				elem_cur := xitdb.array_list_append_cursor(&al) or_return
				w_ok, w_err := write_term_to_cursor(env, &elem_cur, head)
				if w_err != nil {
					return true, w_err
				}
				if !w_ok {
					return false, nil
				}
			}
		}
		return true, nil
	case "linked_array_list":
		ll, init_err := xitdb.write_linked_array_list_init(cur^)
		if init_err != nil {
			return true, init_err
		}
		head: ERL_NIF_TERM
		tail := data_term
		for nif_is_empty_list(env, tail) == 0 {
			if nif_get_list_cell(env, tail, &head, &tail) == 0 {
				return false, nil
			}
			if wdata, ok_s := decode_writeable_value(env, head); ok_s {
				xitdb.linked_array_list_append(&ll, wdata) or_return
			} else {
				elem_cur := xitdb.linked_array_list_append_cursor(&ll) or_return
				w_ok, w_err := write_term_to_cursor(env, &elem_cur, head)
				if w_err != nil {
					return true, w_err
				}
				if !w_ok {
					return false, nil
				}
			}
		}
		return true, nil
	case "hash_set":
		hs, init_err := xitdb.write_hash_set_init(cur^)
		if init_err != nil {
			return true, init_err
		}
		return write_hash_set_entries(env, &hs, data_term)
	case "counted_hash_set":
		cs, init_err := xitdb.write_counted_hash_set_init(cur^)
		if init_err != nil {
			return true, init_err
		}
		return write_hash_set_entries(env, &cs.write_hash_set, data_term)
	case "sorted_set":
		ss, init_err := xitdb.write_sorted_set_init(cur^)
		if init_err != nil {
			return true, init_err
		}
		return write_sorted_set_entries(env, &ss, data_term)
	}
	return false, nil
}

write_term_to_cursor :: proc(env: ErlNifEnv, cur: ^xitdb.Write_Cursor, term: ERL_NIF_TERM) -> (ok: bool, err: xitdb.Error) {
	if wdata, ok_s := decode_writeable_value(env, term); ok_s {
		return true, xitdb.cursor_write(cur, wdata)
	}
	if nif_is_tuple(env, term) != 0 {
		arity: c.int = 0
		elems: [^]ERL_NIF_TERM = nil
		if nif_get_tuple(env, term, &arity, &elems) == 0 {
			return false, nil
		}
		if arity == 2 && elems[0] == ATOM_XITDB_SET {
			return write_collection_term_to_cursor(env, cur, "hash_set", elems[1])
		}
		if arity == 3 && elems[0] == ATOM_XITDB_COL {
			kind_str, ok_k := term_to_kind_string(env, elems[1])
			if !ok_k {
				return false, nil
			}
			return write_collection_term_to_cursor(env, cur, kind_str, elems[2])
		}
		return false, nil
	}
	if nif_is_list(env, term) != 0 {
		return write_collection_term_to_cursor(env, cur, "array_list", term)
	}
	if nif_is_map(env, term) != 0 {
		struct_term: ERL_NIF_TERM
		if nif_get_map_value(env, term, ATOM_STRUCT, &struct_term) != 0 {
			if struct_term == ATOM_XITDB_COLLECTION_MOD {
				kind_term, data_term: ERL_NIF_TERM
				if nif_get_map_value(env, term, ATOM_KIND, &kind_term) == 0 ||
				   nif_get_map_value(env, term, ATOM_DATA, &data_term) == 0 {
					return false, nil
				}
				kind_str, ok_k := term_to_kind_string(env, kind_term)
				if !ok_k {
					return false, nil
				}
				return write_collection_term_to_cursor(env, cur, kind_str, data_term)
			}
			if struct_term == ATOM_MAPSET_MOD {
				return write_collection_term_to_cursor(env, cur, "counted_hash_set", term)
			}
			return false, nil
		}
		return write_collection_term_to_cursor(env, cur, "hash_map", term)
	}
	return false, nil
}

Structured_Op_Kind :: enum u8 {
	Put,
	Append,
	Insert,
}

Structured_Op_Ctx :: struct {
	kind:  Structured_Op_Kind,
	steps: []xitdb.Path_Step,
	index: i64,
	env:   ErlNifEnv,
	term:  ERL_NIF_TERM,
}

structured_op_callback :: proc(moment_cur: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	sc := (^Structured_Op_Ctx)(user_data)
	target_cur := xitdb.write_steps_cursor(moment_cur^, sc.steps) or_return

	switch sc.kind {
	case .Put:
		// Reset prior slot before writing nested collection cleanly
		xitdb.put_at_steps(moment_cur^, sc.steps, xitdb.Slot{}) or_return
		target_cur = xitdb.write_steps_cursor(moment_cur^, sc.steps) or_return
		ok, err := write_term_to_cursor(sc.env, &target_cur, sc.term)
		if err != nil {
			return err
		}
		if !ok {
			return .Unexpected_Tag
		}
		return nil

	case .Append:
		slot_ptr := xitdb.cursor_resolved(target_cur.read_cursor) or_return
		#partial switch slot_ptr.slot.tag {
		case .None, .Array_List:
			al := xitdb.write_array_list_init(target_cur) or_return
			elem_cur := xitdb.array_list_append_cursor(&al) or_return
			ok, err := write_term_to_cursor(sc.env, &elem_cur, sc.term)
			if err != nil {
				return err
			}
			if !ok {
				return .Unexpected_Tag
			}
			return nil
		case .Linked_Array_List:
			ll := xitdb.write_linked_array_list_init(target_cur) or_return
			elem_cur := xitdb.linked_array_list_append_cursor(&ll) or_return
			ok, err := write_term_to_cursor(sc.env, &elem_cur, sc.term)
			if err != nil {
				return err
			}
			if !ok {
				return .Unexpected_Tag
			}
			return nil
		case:
			return .Unexpected_Tag
		}

	case .Insert:
		ll := xitdb.write_linked_array_list_init(target_cur) or_return
		elem_cur := xitdb.linked_array_list_insert_cursor(&ll, sc.index) or_return
		ok, err := write_term_to_cursor(sc.env, &elem_cur, sc.term)
		if err != nil {
			return err
		}
		if !ok {
			return .Unexpected_Tag
		}
		return nil
	}
	return nil
}

Slice_Op_Ctx :: struct {
	steps:  []xitdb.Path_Step,
	offset: i64,
	size:   i64,
}

slice_op_callback :: proc(moment_cur: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	sc := (^Slice_Op_Ctx)(user_data)
	target_cur := xitdb.write_steps_cursor(moment_cur^, sc.steps) or_return
	slot_ptr := xitdb.cursor_resolved(target_cur.read_cursor) or_return

	#partial switch slot_ptr.slot.tag {
	case .Array_List:
		al_col := xitdb.write_array_list_init(target_cur) or_return
		if sc.offset > 0 {
			cnt := xitdb.array_list_count(al_col.read_array_list) or_return
			keep: i64 = 0
			if sc.offset < cnt && sc.size > 0 {
				keep = min(sc.size, cnt - sc.offset)
				for i: i64 = 0; i < keep; i += 1 {
					s_maybe := xitdb.array_list_get_slot(al_col.read_array_list, sc.offset + i) or_return
					s, has_s := s_maybe.?
					xitdb.array_list_put(&al_col, i, s if has_s else xitdb.Slot{}) or_return
				}
			}
			return xitdb.array_list_slice(&al_col, keep)
		}
		return xitdb.array_list_slice(&al_col, sc.size)

	case .Linked_Array_List:
		ll_col := xitdb.write_linked_array_list_init(target_cur) or_return
		return xitdb.linked_array_list_slice(&ll_col, sc.offset, sc.size)

	case:
		return .Unexpected_Tag
	}
}

Rm_If_Exists_Ctx :: struct {
	steps: []xitdb.Path_Step,
	tx:    ^xitdb.Tx,
}

rm_if_exists_callback :: proc(moment_cur: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	rc := (^Rm_If_Exists_Ctx)(user_data)
	if len(rc.steps) == 0 {
		return .Invalid_Range
	}
	existing, r_err := xitdb.read_steps_cursor(moment_cur.read_cursor, rc.steps)
	if r_err != nil {
		if r_err == .Key_Not_Found {
			return nil
		}
		return r_err
	}
	if _, found := existing.?; !found {
		return nil
	}

	// Evict secondary index entries if matching any rule in rc.tx.index_rules
	if rc.tx != nil && len(rc.tx.index_rules) > 0 && len(rc.steps) >= 2 {
		moment_hm := xitdb.write_hash_map_init(moment_cur^) or_return
		for rule in rc.tx.index_rules {
			if rc.steps[0].key != rule.source_map_key {
				continue
			}
			is_field_op := len(rc.steps) == 3 && rc.steps[2].key == rule.field_key
			is_record_rm := len(rc.steps) == 2
			if !is_field_op && !is_record_rm {
				continue
			}
			lookup := [3]xitdb.Path_Step{
				xitdb.hm(rule.source_map_key),
				xitdb.hm(rc.steps[1].key),
				xitdb.hm(rule.field_key),
			}
			old_maybe := xitdb.read_steps_cursor(moment_hm.read_hash_map.cursor, lookup[:]) or_return
			if old_cur, has_old := old_maybe.?; has_old {
				old_slot := xitdb.cursor_slot(old_cur) or_return
				if old_slot.tag == .Short_Bytes || old_slot.tag == .Bytes {
					old_key := xitdb.cursor_read_string(old_cur, 0, context.temp_allocator) or_return
					idx_cur := xitdb.hash_map_put_cursor(&moment_hm, rule.index_map_key) or_return
					idx_sm := xitdb.write_sorted_map_init(idx_cur) or_return
					_, _ = xitdb.sorted_map_remove(&idx_sm, old_key)
				}
			}
		}
	}

	parent_cur := moment_cur^
	if len(rc.steps) > 1 {
		parent_cur = xitdb.write_steps_cursor(moment_cur^, rc.steps[:len(rc.steps) - 1]) or_return
	}
	last := rc.steps[len(rc.steps) - 1]
	switch last.kind {
	case .Hash_Map_Key:
		m := xitdb.write_hash_map_init(parent_cur) or_return
		_, err := xitdb.hash_map_remove(&m, last.key)
		return err
	case .Counted_Hash_Map_Key:
		cm := xitdb.write_counted_hash_map_init(parent_cur) or_return
		_, err := xitdb.hash_map_remove(&cm.write_hash_map, last.key)
		return err
	case .Sorted_Map_Key:
		sm := xitdb.write_sorted_map_init(parent_cur) or_return
		_, err := xitdb.sorted_map_remove(&sm, last.key)
		return err
	case .Linked_List_Idx:
		ll := xitdb.write_linked_array_list_init(parent_cur) or_return
		return xitdb.linked_array_list_remove(&ll, last.index)
	case .Hash_Set_Member:
		hs := xitdb.write_hash_set_init(parent_cur) or_return
		_, err := xitdb.hash_set_remove(&hs, last.key)
		return err
	case .Counted_Set_Member:
		cs := xitdb.write_counted_hash_set_init(parent_cur) or_return
		_, err := xitdb.hash_set_remove(&cs.write_hash_set, last.key)
		return err
	case .Sorted_Set_Member:
		ss := xitdb.write_sorted_set_init(parent_cur) or_return
		_, err := xitdb.sorted_set_remove(&ss, last.key)
		return err
	case .Array_List_Idx:
		return .Write_Not_Allowed
	}
	return nil
}

KV_Stack_Buf :: struct {
	keys_buf: [16]ERL_NIF_TERM,
	vals_buf: [16]ERL_NIF_TERM,
}

extract_map_kvs :: proc(env: ErlNifEnv, map_term: ERL_NIF_TERM, sb: ^KV_Stack_Buf) -> (keys: []ERL_NIF_TERM, vals: []ERL_NIF_TERM, ok: bool) {
	sz: c.size_t = 0
	if nif_get_map_size(env, map_term, &sz) == 0 {
		return nil, nil, false
	}
	if sz == 0 {
		return nil, nil, true
	}
	n := int(sz)
	if n <= len(sb.keys_buf) {
		keys = sb.keys_buf[:n]
		vals = sb.vals_buf[:n]
	} else {
		keys = make([]ERL_NIF_TERM, n, context.temp_allocator)
		vals = make([]ERL_NIF_TERM, n, context.temp_allocator)
	}
	cnt: c.size_t = 0
	if nif_map_to_kv_arrays(env, map_term, raw_data(keys), raw_data(vals), sz, &cnt) == 0 {
		return nil, nil, false
	}
	return keys[:int(cnt)], vals[:int(cnt)], true
}

validate_merge_collection_data :: proc(env: ErlNifEnv, kind_str: string, data_term: ERL_NIF_TERM) -> bool {
	switch kind_str {
	case "hash_map", "counted_hash_map", "sorted_map":
		st: ERL_NIF_TERM
		if nif_is_map(env, data_term) != 0 && nif_get_map_value(env, data_term, ATOM_STRUCT, &st) == 0 {
			sb: KV_Stack_Buf = ---
			keys, vals, ok := extract_map_kvs(env, data_term, &sb)
			if !ok {
				return false
			}
			for i in 0 ..< len(keys) {
				if _, ok_k := term_to_key_string(env, keys[i]); !ok_k {
					return false
				}
				if !validate_merge_map_term(env, vals[i], false) {
					return false
				}
			}
			return true
		}
		if nif_is_list(env, data_term) != 0 {
			head: ERL_NIF_TERM
			tail := data_term
			for nif_is_empty_list(env, tail) == 0 {
				if nif_get_list_cell(env, tail, &head, &tail) == 0 {
					return false
				}
				arity: c.int = 0
				elems: [^]ERL_NIF_TERM = nil
				if nif_get_tuple(env, head, &arity, &elems) == 0 || arity != 2 {
					return false
				}
				if _, ok_k := term_to_key_string(env, elems[0]); !ok_k {
					return false
				}
				if !validate_merge_map_term(env, elems[1], false) {
					return false
				}
			}
			return true
		}
		return false
	case "array_list", "linked_array_list":
		return nif_is_list(env, data_term) != 0 && validate_merge_map_term(env, data_term, false)
	case "hash_set", "counted_hash_set", "sorted_set":
		return validate_set_elements_term(env, data_term)
	}
	return false
}

validate_merge_map_term :: proc(env: ErlNifEnv, term: ERL_NIF_TERM, is_root: bool = true) -> bool {
	if !is_root {
		if _, ok := decode_writeable_value(env, term); ok {
			return true
		}
		if nif_is_tuple(env, term) != 0 {
			arity: c.int = 0
			elems: [^]ERL_NIF_TERM = nil
			if nif_get_tuple(env, term, &arity, &elems) == 0 {
				return false
			}
			if arity == 2 && elems[0] == ATOM_XITDB_SET {
				return validate_set_elements_term(env, elems[1])
			}
			if arity == 3 && elems[0] == ATOM_XITDB_COL {
				kind_str, ok_k := term_to_kind_string(env, elems[1])
				if !ok_k || !is_supported_col_kind(kind_str) {
					return false
				}
				return validate_collection_data_term(env, kind_str, elems[2])
			}
			return false
		}
		if nif_is_list(env, term) != 0 {
			head: ERL_NIF_TERM
			tail := term
			for nif_is_empty_list(env, tail) == 0 {
				if nif_get_list_cell(env, tail, &head, &tail) == 0 {
					return false
				}
				if !validate_merge_map_term(env, head, false) {
					return false
				}
			}
			return true
		}
	}

	if nif_is_map(env, term) == 0 {
		return false
	}
	struct_term: ERL_NIF_TERM
	if nif_get_map_value(env, term, ATOM_STRUCT, &struct_term) != 0 {
		if is_root {
			return false
		}
		if struct_term == ATOM_XITDB_COLLECTION_MOD {
			kind_term, data_term: ERL_NIF_TERM
			if nif_get_map_value(env, term, ATOM_KIND, &kind_term) == 0 ||
			   nif_get_map_value(env, term, ATOM_DATA, &data_term) == 0 {
				return false
			}
			kind_str, ok_k := term_to_kind_string(env, kind_term)
			if !ok_k || !is_supported_col_kind(kind_str) {
				return false
			}
			return validate_merge_collection_data(env, kind_str, data_term)
		}
		if struct_term == ATOM_MAPSET_MOD {
			ms_map: ERL_NIF_TERM
			if nif_get_map_value(env, term, ATOM_MAP, &ms_map) == 0 || nif_is_map(env, ms_map) == 0 {
				return false
			}
			sb: KV_Stack_Buf = ---
			keys, _, ok := extract_map_kvs(env, ms_map, &sb)
			if !ok {
				return false
			}
			for k in keys {
				if _, ok_s := term_to_key_string(env, k); !ok_s {
					return false
				}
			}
			return true
		}
		return false
	}

	sb: KV_Stack_Buf = ---
	keys, vals, ok := extract_map_kvs(env, term, &sb)
	if !ok {
		return false
	}
	for i in 0 ..< len(keys) {
		if _, ok_k := term_to_key_string(env, keys[i]); !ok_k {
			return false
		}
		if !validate_merge_map_term(env, vals[i], false) {
			return false
		}
	}
	return true
}

is_pure_removal_term :: proc(env: ErlNifEnv, term: ERL_NIF_TERM) -> bool {
	if term == ATOM_NIL {
		return true
	}
	if nif_is_map(env, term) == 0 {
		return false
	}
	struct_term: ERL_NIF_TERM
	if nif_get_map_value(env, term, ATOM_STRUCT, &struct_term) != 0 {
		if struct_term == ATOM_XITDB_COLLECTION_MOD {
			kind_term, data_term: ERL_NIF_TERM
			if nif_get_map_value(env, term, ATOM_KIND, &kind_term) == 0 ||
			   nif_get_map_value(env, term, ATOM_DATA, &data_term) == 0 {
				return false
			}
			kind_str, ok_k := term_to_kind_string(env, kind_term)
			if !ok_k || (kind_str != "hash_map" && kind_str != "counted_hash_map" && kind_str != "sorted_map") {
				return false
			}
			st2: ERL_NIF_TERM
			if nif_is_map(env, data_term) != 0 && nif_get_map_value(env, data_term, ATOM_STRUCT, &st2) == 0 {
				sb: KV_Stack_Buf = ---
				_, vals, ok := extract_map_kvs(env, data_term, &sb)
				if !ok || len(vals) == 0 {
					return false
				}
				for v in vals {
					if !is_pure_removal_term(env, v) {
						return false
					}
				}
				return true
			}
			if nif_is_list(env, data_term) != 0 {
				if nif_is_empty_list(env, data_term) != 0 {
					return false
				}
				head: ERL_NIF_TERM
				tail := data_term
				for nif_is_empty_list(env, tail) == 0 {
					if nif_get_list_cell(env, tail, &head, &tail) == 0 {
						return false
					}
					arity: c.int = 0
					elems: [^]ERL_NIF_TERM = nil
					if nif_get_tuple(env, head, &arity, &elems) == 0 || arity != 2 {
						return false
					}
					if !is_pure_removal_term(env, elems[1]) {
						return false
					}
				}
				return true
			}
		}
		return false
	}
	sb: KV_Stack_Buf = ---
	_, vals, ok := extract_map_kvs(env, term, &sb)
	if !ok || len(vals) == 0 {
		return false
	}
	for v in vals {
		if !is_pure_removal_term(env, v) {
			return false
		}
	}
	return true
}

Pending_Index_Op :: struct {
	index_map_key: string,
	old_key:       string,
	has_old:       bool,
	new_key:       string,
	has_new:       bool,
	record_id:     string,
}

Merge_State :: struct {
	env:         ErlNifEnv,
	tx:          ^xitdb.Tx,
	has_indexes: bool,
	pending_idx: [dynamic]Pending_Index_Op,
}

Merge_Map_Ctx :: struct {
	env:      ErlNifEnv,
	map_term: ERL_NIF_TERM,
	tx:       ^xitdb.Tx,
}

read_cur_string_if_bytes :: proc(cur: xitdb.Read_Cursor) -> (s: string, ok: bool, err: xitdb.Error) {
	slot := xitdb.cursor_slot(cur) or_return
	if slot.tag == .Short_Bytes || slot.tag == .Bytes {
		str := xitdb.cursor_read_string(cur, 0, context.temp_allocator) or_return
		return str, true, nil
	}
	return "", false, nil
}

queue_record_removal_indexes :: proc(ms: ^Merge_State, src_key: string, rec_cur: xitdb.Read_Cursor) -> xitdb.Error {
	for rule in ms.tx.index_rules {
		if rule.source_map_key != src_key {
			continue
		}
		f_steps := [1]xitdb.Path_Step{xitdb.hm(rule.field_key)}
		old_maybe, f_err := xitdb.read_steps_cursor(rec_cur, f_steps[:])
		if f_err != nil {
			if f_err == .Key_Not_Found || f_err == .Unexpected_Tag {
				continue
			}
			return f_err
		}
		if old_cur, has_old := old_maybe.?; has_old {
			if old_key, is_str, r_err := read_cur_string_if_bytes(old_cur); r_err != nil {
				return r_err
			} else if is_str {
				append(&ms.pending_idx, Pending_Index_Op{
					index_map_key = rule.index_map_key,
					old_key       = old_key,
					has_old       = true,
				})
			}
		}
	}
	return nil
}

queue_field_index_change :: proc(
	ms: ^Merge_State,
	src_key: string,
	rec_key: string,
	field_key: string,
	old_cur_maybe: Maybe(xitdb.Read_Cursor),
	new_val_str: string,
	has_new_str: bool,
) -> xitdb.Error {
	old_str := ""
	has_old_str := false
	checked_old := false
	for rule in ms.tx.index_rules {
		if rule.source_map_key != src_key || rule.field_key != field_key {
			continue
		}
		if !checked_old {
			checked_old = true
			if old_cur, has_old := old_cur_maybe.?; has_old {
				s, is_str := read_cur_string_if_bytes(old_cur) or_return
				old_str = s
				has_old_str = is_str
			}
		}
		if has_old_str && has_new_str && old_str == new_val_str {
			continue
		}
		if has_old_str || has_new_str {
			append(&ms.pending_idx, Pending_Index_Op{
				index_map_key = rule.index_map_key,
				old_key       = old_str,
				has_old       = has_old_str,
				new_key       = new_val_str,
				has_new       = has_new_str,
				record_id     = rec_key,
			})
		}
	}
	return nil
}

flush_pending_indexes :: proc(ms: ^Merge_State, moment_hm: ^xitdb.Write_Hash_Map) -> xitdb.Error {
	if len(ms.pending_idx) == 0 {
		return nil
	}
	xitdb.cursor_reload_slot(&moment_hm.write_cursor) or_return
	for pop in ms.pending_idx {
		idx_cur := xitdb.hash_map_put_cursor(moment_hm, pop.index_map_key) or_return
		idx_sm := xitdb.write_sorted_map_init(idx_cur) or_return
		if pop.has_old {
			_, _ = xitdb.sorted_map_remove(&idx_sm, pop.old_key)
		}
		if pop.has_new {
			xitdb.sorted_map_put(&idx_sm, pop.new_key, pop.record_id) or_return
		}
	}
	clear(&ms.pending_idx)
	return nil
}

hm_has_key :: proc(hm: ^xitdb.Write_Hash_Map, key: string) -> (res: bool, err: xitdb.Error) {
	xitdb.cursor_reload_slot(&hm.write_cursor) or_return
	rhm := xitdb.Read_Hash_Map{cursor = hm.write_cursor.read_cursor}
	c_maybe, r_err := xitdb.hash_map_get_slot(rhm, key)
	if r_err != nil {
		if r_err == .Key_Not_Found {
			return false, nil
		}
		return false, r_err
	}
	if slot, found := c_maybe.?; found && slot.tag != .None {
		return true, nil
	}
	return false, nil
}

sm_has_key :: proc(sm: ^xitdb.Write_Sorted_Map, key: string) -> (res: bool, err: xitdb.Error) {
	xitdb.cursor_reload_slot(&sm.write_cursor) or_return
	rsm := xitdb.Read_Sorted_Map{cursor = sm.write_cursor.read_cursor}
	c_maybe, r_err := xitdb.sorted_map_get_slot(rsm, key)
	if r_err != nil {
		if r_err == .Key_Not_Found {
			return false, nil
		}
		return false, r_err
	}
	if slot, found := c_maybe.?; found && slot.tag != .None {
		return true, nil
	}
	return false, nil
}

merge_kv_entry_hm :: proc(
	ms: ^Merge_State,
	hm: ^xitdb.Write_Hash_Map,
	key_term: ERL_NIF_TERM,
	val_term: ERL_NIF_TERM,
	reset: bool,
	depth: int,
	src_key: string,
	rec_key: string,
) -> xitdb.Error {
	k_str, ok_k := term_to_key_string(ms.env, key_term)
	if !ok_k {
		return .Unexpected_Tag
	}

	if val_term == ATOM_NIL {
		if reset {
			return nil
		}
		if ms.has_indexes && (depth == 1 || depth == 2) {
			xitdb.cursor_reload_slot(&hm.write_cursor) or_return
			rhm := xitdb.Read_Hash_Map{cursor = hm.write_cursor.read_cursor}
			c_maybe, r_err := xitdb.hash_map_get_cursor(rhm, k_str)
			if r_err != nil && r_err != .Key_Not_Found {
				return r_err
			}
			if found_cur, found := c_maybe.?; found {
				if depth == 1 {
					queue_record_removal_indexes(ms, src_key, found_cur) or_return
				} else {
					queue_field_index_change(ms, src_key, rec_key, k_str, found_cur, "", false) or_return
				}
			}
		}
		_, rm_err := xitdb.hash_map_remove(hm, k_str)
		return rm_err
	}

	if wdata, is_scalar := decode_writeable_value(ms.env, val_term); is_scalar {
		if ms.has_indexes && depth == 2 {
			has_matching_rule := false
			for rule in ms.tx.index_rules {
				if rule.source_map_key == src_key && rule.field_key == k_str {
					has_matching_rule = true
					break
				}
			}
			if has_matching_rule {
				old_maybe: Maybe(xitdb.Read_Cursor) = nil
				if !reset {
					xitdb.cursor_reload_slot(&hm.write_cursor) or_return
					rhm := xitdb.Read_Hash_Map{cursor = hm.write_cursor.read_cursor}
					cm, r_err := xitdb.hash_map_get_cursor(rhm, k_str)
					if r_err != nil && r_err != .Key_Not_Found {
						return r_err
					}
					old_maybe = cm
				}
				new_str, is_new_str := wdata.(string)
				queue_field_index_change(ms, src_key, rec_key, k_str, old_maybe, new_str, is_new_str) or_return
			}
		}
		return xitdb.hash_map_put(hm, k_str, wdata)
	}

	if !reset && is_pure_removal_term(ms.env, val_term) {
		exists := hm_has_key(hm, k_str) or_return
		if !exists {
			return nil
		}
	}

	if ms.has_indexes && depth == 2 && !reset {
		has_matching_rule := false
		for rule in ms.tx.index_rules {
			if rule.source_map_key == src_key && rule.field_key == k_str {
				has_matching_rule = true
				break
			}
		}
		if has_matching_rule {
			xitdb.cursor_reload_slot(&hm.write_cursor) or_return
			rhm := xitdb.Read_Hash_Map{cursor = hm.write_cursor.read_cursor}
			cm, r_err := xitdb.hash_map_get_cursor(rhm, k_str)
			if r_err == nil {
				queue_field_index_change(ms, src_key, rec_key, k_str, cm, "", false) or_return
			}
		}
	}

	child_cur := xitdb.hash_map_put_cursor(hm, k_str) or_return
	next_src := k_str if depth == 0 else src_key
	next_rec := k_str if depth == 1 else rec_key
	return merge_node_into_cursor(ms, &child_cur, val_term, reset, depth + 1, next_src, next_rec)
}

merge_kv_entry_sm :: proc(
	ms: ^Merge_State,
	sm: ^xitdb.Write_Sorted_Map,
	key_term: ERL_NIF_TERM,
	val_term: ERL_NIF_TERM,
	reset: bool,
	depth: int,
	src_key: string,
	rec_key: string,
) -> xitdb.Error {
	k_str, ok_k := term_to_key_string(ms.env, key_term)
	if !ok_k {
		return .Unexpected_Tag
	}

	if val_term == ATOM_NIL {
		if reset {
			return nil
		}
		if ms.has_indexes && (depth == 1 || depth == 2) {
			xitdb.cursor_reload_slot(&sm.write_cursor) or_return
			rsm := xitdb.Read_Sorted_Map{cursor = sm.write_cursor.read_cursor}
			c_maybe, r_err := xitdb.sorted_map_get_cursor(rsm, k_str)
			if r_err != nil && r_err != .Key_Not_Found {
				return r_err
			}
			if found_cur, found := c_maybe.?; found {
				if depth == 1 {
					queue_record_removal_indexes(ms, src_key, found_cur) or_return
				} else {
					queue_field_index_change(ms, src_key, rec_key, k_str, found_cur, "", false) or_return
				}
			}
		}
		_, rm_err := xitdb.sorted_map_remove(sm, k_str)
		return rm_err
	}

	if wdata, is_scalar := decode_writeable_value(ms.env, val_term); is_scalar {
		if ms.has_indexes && depth == 2 {
			has_matching_rule := false
			for rule in ms.tx.index_rules {
				if rule.source_map_key == src_key && rule.field_key == k_str {
					has_matching_rule = true
					break
				}
			}
			if has_matching_rule {
				old_maybe: Maybe(xitdb.Read_Cursor) = nil
				if !reset {
					xitdb.cursor_reload_slot(&sm.write_cursor) or_return
					rsm := xitdb.Read_Sorted_Map{cursor = sm.write_cursor.read_cursor}
					cm, r_err := xitdb.sorted_map_get_cursor(rsm, k_str)
					if r_err != nil && r_err != .Key_Not_Found {
						return r_err
					}
					old_maybe = cm
				}
				new_str, is_new_str := wdata.(string)
				queue_field_index_change(ms, src_key, rec_key, k_str, old_maybe, new_str, is_new_str) or_return
			}
		}
		return xitdb.sorted_map_put(sm, k_str, wdata)
	}

	if !reset && is_pure_removal_term(ms.env, val_term) {
		exists := sm_has_key(sm, k_str) or_return
		if !exists {
			return nil
		}
	}

	child_cur := xitdb.sorted_map_put_cursor(sm, k_str) or_return
	next_src := k_str if depth == 0 else src_key
	next_rec := k_str if depth == 1 else rec_key
	return merge_node_into_cursor(ms, &child_cur, val_term, reset, depth + 1, next_src, next_rec)
}

merge_map_entries_hm :: proc(
	ms: ^Merge_State,
	hm: ^xitdb.Write_Hash_Map,
	map_term: ERL_NIF_TERM,
	reset: bool,
	depth: int,
	src_key: string,
	rec_key: string,
) -> xitdb.Error {
	sb: KV_Stack_Buf = ---
	keys, vals, ok := extract_map_kvs(ms.env, map_term, &sb)
	if !ok {
		return .Unexpected_Tag
	}
	for i in 0 ..< len(keys) {
		merge_kv_entry_hm(ms, hm, keys[i], vals[i], reset, depth, src_key, rec_key) or_return
	}
	return nil
}

merge_kv_collection_into_cursor :: proc(
	ms: ^Merge_State,
	cur: ^xitdb.Write_Cursor,
	kind_str: string,
	data_term: ERL_NIF_TERM,
	reset: bool,
	depth: int,
	src_key: string,
	rec_key: string,
) -> xitdb.Error {
	st: ERL_NIF_TERM
	is_map_data := nif_is_map(ms.env, data_term) != 0 && nif_get_map_value(ms.env, data_term, ATOM_STRUCT, &st) == 0

	if reset {
		xitdb.cursor_write(cur, xitdb.Slot{}) or_return
	}

	switch kind_str {
	case "hash_map", "counted_hash_map":
		hm: xitdb.Write_Hash_Map
		if kind_str == "counted_hash_map" {
			chm := xitdb.write_counted_hash_map_init(cur^) or_return
			hm = chm.write_hash_map
		} else {
			hm = xitdb.write_hash_map_init(cur^) or_return
		}
		if is_map_data {
			return merge_map_entries_hm(ms, &hm, data_term, reset, depth, src_key, rec_key)
		}
		head: ERL_NIF_TERM
		tail := data_term
		for nif_is_empty_list(ms.env, tail) == 0 {
			if nif_get_list_cell(ms.env, tail, &head, &tail) == 0 {
				return .Unexpected_Tag
			}
			arity: c.int = 0
			elems: [^]ERL_NIF_TERM = nil
			if nif_get_tuple(ms.env, head, &arity, &elems) == 0 || arity != 2 {
				return .Unexpected_Tag
			}
			merge_kv_entry_hm(ms, &hm, elems[0], elems[1], false, depth, src_key, rec_key) or_return
		}
		return nil

	case "sorted_map":
		sm := xitdb.write_sorted_map_init(cur^) or_return
		if is_map_data {
			sb: KV_Stack_Buf = ---
			keys, vals, ok := extract_map_kvs(ms.env, data_term, &sb)
			if !ok {
				return .Unexpected_Tag
			}
			for i in 0 ..< len(keys) {
				merge_kv_entry_sm(ms, &sm, keys[i], vals[i], reset, depth, src_key, rec_key) or_return
			}
			return nil
		}
		head: ERL_NIF_TERM
		tail := data_term
		for nif_is_empty_list(ms.env, tail) == 0 {
			if nif_get_list_cell(ms.env, tail, &head, &tail) == 0 {
				return .Unexpected_Tag
			}
			arity: c.int = 0
			elems: [^]ERL_NIF_TERM = nil
			if nif_get_tuple(ms.env, head, &arity, &elems) == 0 || arity != 2 {
				return .Unexpected_Tag
			}
			merge_kv_entry_sm(ms, &sm, elems[0], elems[1], false, depth, src_key, rec_key) or_return
		}
		return nil
	}
	return .Unexpected_Tag
}

merge_list_into_cursor :: proc(
	ms: ^Merge_State,
	cur: ^xitdb.Write_Cursor,
	kind_str: string,
	list_term: ERL_NIF_TERM,
	depth: int,
	src_key: string,
	rec_key: string,
) -> xitdb.Error {
	xitdb.cursor_write(cur, xitdb.Slot{}) or_return
	if kind_str == "linked_array_list" {
		ll := xitdb.write_linked_array_list_init(cur^) or_return
		head: ERL_NIF_TERM
		tail := list_term
		for nif_is_empty_list(ms.env, tail) == 0 {
			if nif_get_list_cell(ms.env, tail, &head, &tail) == 0 {
				return .Unexpected_Tag
			}
			if wdata, ok_s := decode_writeable_value(ms.env, head); ok_s {
				xitdb.linked_array_list_append(&ll, wdata) or_return
			} else {
				elem_cur := xitdb.linked_array_list_append_cursor(&ll) or_return
				merge_node_into_cursor(ms, &elem_cur, head, true, depth + 1, src_key, rec_key) or_return
			}
		}
		return nil
	}

	al := xitdb.write_array_list_init(cur^) or_return
	head: ERL_NIF_TERM
	tail := list_term
	for nif_is_empty_list(ms.env, tail) == 0 {
		if nif_get_list_cell(ms.env, tail, &head, &tail) == 0 {
			return .Unexpected_Tag
		}
		if wdata, ok_s := decode_writeable_value(ms.env, head); ok_s {
			xitdb.array_list_append(&al, wdata) or_return
		} else {
			elem_cur := xitdb.array_list_append_cursor(&al) or_return
			merge_node_into_cursor(ms, &elem_cur, head, true, depth + 1, src_key, rec_key) or_return
		}
	}
	return nil
}

merge_node_into_cursor :: proc(
	ms: ^Merge_State,
	cur: ^xitdb.Write_Cursor,
	term: ERL_NIF_TERM,
	reset: bool,
	depth: int,
	src_key: string,
	rec_key: string,
) -> xitdb.Error {
	if wdata, ok_s := decode_writeable_value(ms.env, term); ok_s {
		return xitdb.cursor_write(cur, wdata)
	}
	if nif_is_tuple(ms.env, term) != 0 {
		xitdb.cursor_write(cur, xitdb.Slot{}) or_return
		w_ok, w_err := write_term_to_cursor(ms.env, cur, term)
		if w_err != nil {
			return w_err
		}
		return nil if w_ok else .Unexpected_Tag
	}
	if nif_is_list(ms.env, term) != 0 {
		return merge_list_into_cursor(ms, cur, "array_list", term, depth, src_key, rec_key)
	}
	if nif_is_map(ms.env, term) != 0 {
		struct_term: ERL_NIF_TERM
		if nif_get_map_value(ms.env, term, ATOM_STRUCT, &struct_term) != 0 {
			if struct_term == ATOM_XITDB_COLLECTION_MOD {
				kind_term, data_term: ERL_NIF_TERM
				if nif_get_map_value(ms.env, term, ATOM_KIND, &kind_term) == 0 ||
				   nif_get_map_value(ms.env, term, ATOM_DATA, &data_term) == 0 {
					return .Unexpected_Tag
				}
				kind_str, ok_k := term_to_kind_string(ms.env, kind_term)
				if !ok_k {
					return .Unexpected_Tag
				}
				switch kind_str {
				case "hash_map", "counted_hash_map", "sorted_map":
					return merge_kv_collection_into_cursor(ms, cur, kind_str, data_term, reset, depth, src_key, rec_key)
				case "array_list", "linked_array_list":
					return merge_list_into_cursor(ms, cur, kind_str, data_term, depth, src_key, rec_key)
				case "hash_set", "counted_hash_set", "sorted_set":
					xitdb.cursor_write(cur, xitdb.Slot{}) or_return
					w_ok, w_err := write_collection_term_to_cursor(ms.env, cur, kind_str, data_term)
					if w_err != nil {
						return w_err
					}
					return nil if w_ok else .Unexpected_Tag
				}
				return .Unexpected_Tag
			}
			if struct_term == ATOM_MAPSET_MOD {
				xitdb.cursor_write(cur, xitdb.Slot{}) or_return
				w_ok, w_err := write_collection_term_to_cursor(ms.env, cur, "counted_hash_set", term)
				if w_err != nil {
					return w_err
				}
				return nil if w_ok else .Unexpected_Tag
			}
			return .Unexpected_Tag
		}

		sz: c.size_t = 0
		if nif_get_map_size(ms.env, term, &sz) == 0 {
			return .Unexpected_Tag
		}
		eff_reset := reset || sz == 0
		if eff_reset {
			xitdb.cursor_write(cur, xitdb.Slot{}) or_return
		}
		hm := xitdb.write_hash_map_init(cur^) or_return
		if sz == 0 {
			return nil
		}
		return merge_map_entries_hm(ms, &hm, term, eff_reset, depth, src_key, rec_key)
	}
	return .Unexpected_Tag
}

merge_map_callback :: proc(moment_cur: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	mc := (^Merge_Map_Ctx)(user_data)
	sb: KV_Stack_Buf = ---
	keys, vals, ok := extract_map_kvs(mc.env, mc.map_term, &sb)
	if !ok {
		return .Unexpected_Tag
	}
	if len(keys) == 0 {
		return nil
	}
	ms := Merge_State{
		env         = mc.env,
		tx          = mc.tx,
		has_indexes = mc.tx != nil && len(mc.tx.index_rules) > 0,
	}
	if ms.has_indexes {
		ms.pending_idx = make([dynamic]Pending_Index_Op, 0, 8, context.temp_allocator)
	}
	moment_hm := xitdb.write_hash_map_init(moment_cur^) or_return
	for i in 0 ..< len(keys) {
		merge_kv_entry_hm(&ms, &moment_hm, keys[i], vals[i], false, 0, "", "") or_return
		if ms.has_indexes && len(ms.pending_idx) > 0 {
			flush_pending_indexes(&ms, &moment_hm) or_return
		}
	}
	return nil
}

@(export)
odin_nif_transact :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 4 {
		return make_err(env, "badarg")
	}

	base_moment: i64 = -1
	if nif_get_int64(env, argv[1], &base_moment) == 0 {
		return make_err(env, "badarg")
	}
	doc_str := ""
	if argv[3] != ATOM_NIL {
		var_doc, ok_doc := get_string_from_binary(env, argv[3])
		if !ok_doc {
			return make_err(env, "badarg")
		}
		doc_str = var_doc
	}
	if nif_is_list(env, argv[2]) == 0 {
		return make_err(env, "invalid_ops_list")
	}

	handle, ok := acquire_wlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
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
		if nif_get_tuple(env, head, &arity, &elems) == 0 || arity < 1 {
			return make_err(env, "invalid_op_tuple")
		}

		op_atom := elems[0]

		switch op_atom {
		case ATOM_PUT:
			if arity != 3 {
				return make_err(env, "invalid_put_op")
			}
			path_str, ok_p := get_string_from_binary(env, elems[1])
			if !ok_p {
				return make_err(env, "invalid_put_op")
			}
			steps, s_err := parse_escaped_steps(path_str, tx.allocator)
			if s_err != "" {
				return make_err(env, s_err)
			}
			if val, ok_v := decode_writeable_value(env, elems[2]); ok_v {
				if len(steps) == 0 {
					return make_xitdb_err(env, .Invalid_Range)
				}
				append(&tx.ops, xitdb.Tx_Op{kind = .Put, steps = steps, val = val})
			} else if validate_write_term(env, elems[2]) {
				if len(steps) == 0 {
					return make_xitdb_err(env, .Invalid_Range)
				}
				sc := new(Structured_Op_Ctx, tx.allocator)
				sc^ = Structured_Op_Ctx{kind = .Put, steps = steps, env = env, term = elems[2]}
				xitdb.tx_with_cursor(&tx, structured_op_callback, sc)
			} else {
				return make_err(env, "invalid_put_op")
			}

		case ATOM_APPEND:
			if arity != 3 {
				return make_err(env, "invalid_append_op")
			}
			path_str, ok_p := get_string_from_binary(env, elems[1])
			if !ok_p {
				return make_err(env, "invalid_append_op")
			}
			steps, s_err := parse_escaped_steps(path_str, tx.allocator)
			if s_err != "" {
				return make_err(env, s_err)
			}
			if len(steps) == 0 {
				return make_err(env, "invalid_append_op")
			}
			if val, ok_v := decode_writeable_value(env, elems[2]); ok_v {
				append(&tx.ops, xitdb.Tx_Op{kind = .Append, steps = steps, val = val})
			} else if validate_write_term(env, elems[2]) {
				sc := new(Structured_Op_Ctx, tx.allocator)
				sc^ = Structured_Op_Ctx{kind = .Append, steps = steps, env = env, term = elems[2]}
				xitdb.tx_with_cursor(&tx, structured_op_callback, sc)
			} else {
				return make_err(env, "invalid_append_op")
			}

		case ATOM_INSERT:
			if arity != 4 {
				return make_err(env, "invalid_insert_op")
			}
			path_str, ok_p := get_string_from_binary(env, elems[1])
			idx_val: i64 = 0
			ok_i := nif_get_int64(env, elems[2], &idx_val) != 0
			if !ok_p || !ok_i {
				return make_err(env, "invalid_insert_op")
			}
			steps, s_err := parse_escaped_steps(path_str, tx.allocator)
			if s_err != "" {
				return make_err(env, s_err)
			}
			if len(steps) == 0 {
				return make_err(env, "invalid_insert_op")
			}
			if val, ok_v := decode_writeable_value(env, elems[3]); ok_v {
				append(&tx.ops, xitdb.Tx_Op{kind = .Insert, steps = steps, offset = idx_val, val = val})
			} else if validate_write_term(env, elems[3]) {
				sc := new(Structured_Op_Ctx, tx.allocator)
				sc^ = Structured_Op_Ctx{kind = .Insert, steps = steps, index = idx_val, env = env, term = elems[3]}
				xitdb.tx_with_cursor(&tx, structured_op_callback, sc)
			} else {
				return make_err(env, "invalid_insert_op")
			}

		case ATOM_RM:
			if arity != 2 {
				return make_err(env, "invalid_rm_op")
			}
			path_str, ok_p := get_string_from_binary(env, elems[1])
			if !ok_p {
				return make_err(env, "invalid_rm_op")
			}
			steps, s_err := parse_escaped_steps(path_str, tx.allocator)
			if s_err != "" {
				return make_err(env, s_err)
			}
			append(&tx.ops, xitdb.Tx_Op{kind = .Remove, steps = steps})

		case ATOM_RM_IF_EXISTS:
			if arity != 2 {
				return make_err(env, "invalid_rm_op")
			}
			path_str, ok_p := get_string_from_binary(env, elems[1])
			if !ok_p {
				return make_err(env, "invalid_rm_op")
			}
			steps, s_err := parse_escaped_steps(path_str, tx.allocator)
			if s_err != "" {
				return make_err(env, s_err)
			}
			rc := new(Rm_If_Exists_Ctx, tx.allocator)
			rc^ = Rm_If_Exists_Ctx{steps = steps, tx = &tx}
			xitdb.tx_with_cursor(&tx, rm_if_exists_callback, rc)

		case ATOM_SLICE:
			if arity != 4 {
				return make_err(env, "invalid_slice_op")
			}
			path_str, ok_p := get_string_from_binary(env, elems[1])
			offset_val: i64 = 0
			size_val: i64 = 0
			ok_o := nif_get_int64(env, elems[2], &offset_val) != 0
			ok_s := nif_get_int64(env, elems[3], &size_val) != 0
			if !ok_p || !ok_o || !ok_s {
				return make_err(env, "invalid_slice_op")
			}
			if offset_val < 0 || size_val < 0 {
				return make_xitdb_err(env, .Invalid_Range)
			}
			steps, s_err := parse_escaped_steps(path_str, tx.allocator)
			if s_err != "" {
				return make_err(env, s_err)
			}
			if len(steps) == 0 {
				return make_xitdb_err(env, .Invalid_Range)
			}
			sc := new(Slice_Op_Ctx, tx.allocator)
			sc^ = Slice_Op_Ctx{steps = steps, offset = offset_val, size = size_val}
			xitdb.tx_with_cursor(&tx, slice_op_callback, sc)

		case ATOM_FORK:
			if arity != 3 {
				return make_err(env, "invalid_fork_op")
			}
			from_str, ok_f := get_string_from_binary(env, elems[1])
			to_str, ok_t := get_string_from_binary(env, elems[2])
			if !ok_f || !ok_t {
				return make_err(env, "invalid_fork_op")
			}
			from_steps, f_err := parse_escaped_steps(from_str, tx.allocator)
			if f_err != "" {
				return make_err(env, f_err)
			}
			to_steps, t_err := parse_escaped_steps(to_str, tx.allocator)
			if t_err != "" {
				return make_err(env, t_err)
			}
			if len(from_steps) == 0 || len(to_steps) == 0 {
				return make_xitdb_err(env, .Invalid_Range)
			}
			append(&tx.ops, xitdb.Tx_Op{kind = .Fork, from_steps = from_steps, steps = to_steps})
			xitdb.tx_savepoint(&tx)

		case ATOM_INDEX_ON:
			if arity != 4 {
				return make_err(env, "invalid_index_on_op")
			}
			src_map, ok_1 := get_string_from_binary(env, elems[1])
			field_key, ok_2 := get_string_from_binary(env, elems[2])
			idx_map, ok_3 := get_string_from_binary(env, elems[3])
			if !ok_1 || !ok_2 || !ok_3 {
				return make_err(env, "invalid_index_on_op")
			}
			xitdb.tx_index_on(&tx, src_map, field_key, idx_map)

		case ATOM_INSTANT:
			if arity != 2 {
				return make_err(env, "invalid_instant_op")
			}
			inst_val: i64 = 0
			if nif_get_int64(env, elems[1], &inst_val) == 0 {
				return make_err(env, "invalid_instant_op")
			}
			xitdb.tx_instant(&tx, inst_val)

		case ATOM_META:
			if arity != 3 {
				return make_err(env, "invalid_meta_op")
			}
			key_str, ok_k := get_string_from_binary(env, elems[1])
			if !ok_k {
				return make_err(env, "invalid_meta_op")
			}
			if key_str == "tx_instant" {
				inst_val: i64 = 0
				if nif_get_int64(env, elems[2], &inst_val) == 0 {
					return make_err(env, "invalid_meta_op")
				}
				xitdb.tx_instant(&tx, inst_val)
			} else {
				val, ok_v := decode_writeable_value(env, elems[2])
				if !ok_v {
					return make_err(env, "invalid_meta_op")
				}
				xitdb.tx_meta(&tx, key_str, val)
			}

		case ATOM_SAVEPOINT:
			if arity != 1 {
				return make_err(env, "invalid_savepoint_op")
			}
			xitdb.tx_savepoint(&tx)

		case ATOM_INIT_COL, ATOM_RESET_COL:
			if arity != 3 {
				return make_err(env, "invalid_init_col_op")
			}
			path_str, ok_p := get_string_from_binary(env, elems[1])
			kind_str, ok_k := get_string_from_binary(env, elems[2])
			if !ok_p || !ok_k || !is_supported_col_kind(kind_str) {
				return make_err(env, "invalid_init_col_op")
			}
			steps, s_err := parse_escaped_steps(path_str, tx.allocator)
			if s_err != "" {
				return make_err(env, s_err)
			}
			ic := new(Init_Col_Ctx, tx.allocator)
			ic.steps = steps
			ic.kind = kind_str
			ic.reset = (op_atom == ATOM_RESET_COL)
			xitdb.tx_with_cursor(&tx, init_col_callback, ic)

		case ATOM_MERGE_MAP:
			if arity != 2 {
				return make_err(env, "invalid_merge_map_op")
			}
			if !validate_merge_map_term(env, elems[1], true) {
				return make_err(env, "invalid_put_op")
			}
			mc := new(Merge_Map_Ctx, tx.allocator)
			mc.env = env
			mc.map_term = elems[1]
			mc.tx = &tx
			xitdb.tx_with_cursor(&tx, merge_map_callback, mc)

		case:
			return make_err(env, "unknown_tx_op")
		}
	}

	rep, c_err := xitdb.tx_commit(&tx)
	if c_err != nil {
		return make_xitdb_err(env, c_err)
	}
	moment_idx := rep.moment_index
	xitdb.tx_report_destroy(&rep, context.temp_allocator)
	return make_ok(env, nif_make_int64(env, moment_idx))
}

// ============================================================================
// High-Level Query, Pull, Diff, History, Datalog & Compaction NIFs
// ============================================================================

@(export)
odin_nif_select :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 3 {
		return make_err(env, "badarg")
	}
	moment_idx: i64 = -1
	if nif_get_int64(env, argv[1], &moment_idx) == 0 {
		return make_err(env, "badarg")
	}
	sel_str, ok_s := get_string_from_binary(env, argv[2])
	if !ok_s {
		return make_err(env, "badarg")
	}

	parsed, p_err := parse_escaped_selector(sel_str, context.temp_allocator)
	if p_err != "" {
		return make_err(env, p_err)
	}
	effective_moment := parsed.moment_index if parsed.has_moment else moment_idx

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	m_slot, _, is_empty, r_err, err_reason := resolve_slot_arg(handle, -1, effective_moment)
	if r_err != nil {
		return make_xitdb_err(env, r_err)
	}
	if err_reason != "" {
		return make_err(env, err_reason)
	}
	if is_empty {
		if len(parsed.steps) > 0 {
			return make_ok(env, ATOM_NIL)
		}
		return make_ok(env, nif_make_tuple5(
			env,
			ATOM_CURSOR,
			TAG_ATOMS[u8(xitdb.Tag.Hash_Map)],
			nif_make_int64(env, i64(u8(xitdb.Tag.Hash_Map))),
			nif_make_int64(env, 0),
			nif_make_int64(env, 0),
		))
	}

	m_cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = m_slot},
		db       = &handle.db,
	}
	cur := m_cur
	if len(parsed.steps) > 0 {
		cur_maybe, err := xitdb.read_steps_cursor(m_cur, parsed.steps)
		if err != nil {
			if err == .Unexpected_Tag {
				return make_ok(env, ATOM_NIL)
			}
			return make_xitdb_err(env, err)
		}
		found_cur, found := cur_maybe.?
		if !found {
			return make_ok(env, ATOM_NIL)
		}
		cur = found_cur
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

// --- Quote/Escape-Aware Pull Engine ---

split_top_level_pull_specs :: proc(inner: string, allocator: runtime.Allocator) -> []string {
	specs := make([dynamic]string, 0, 8, allocator)
	brace_depth := 0
	bracket_depth := 0
	in_quote: u8 = 0
	start := 0
	i := 0
	for i < len(inner) {
		ch := inner[i]
		if in_quote != 0 {
			if ch == '\\' && i + 1 < len(inner) {
				i += 2
				continue
			}
			if ch == in_quote {
				in_quote = 0
			}
			i += 1
			continue
		}
		if ch == '"' || ch == '\'' {
			in_quote = ch
		} else if ch == '{' {
			brace_depth += 1
		} else if ch == '}' {
			if brace_depth > 0 {
				brace_depth -= 1
			}
		} else if ch == '[' {
			bracket_depth += 1
		} else if ch == ']' {
			if bracket_depth > 0 {
				bracket_depth -= 1
			}
		} else if (ch == ',' || ch == '\n') && brace_depth == 0 && bracket_depth == 0 {
			part := strings.trim_space(inner[start:i])
			if len(part) > 0 {
				append(&specs, part)
			}
			start = i + 1
		}
		i += 1
	}
	if start < len(inner) {
		part := strings.trim_space(inner[start:])
		if len(part) > 0 {
			append(&specs, part)
		}
	}
	return specs[:]
}

find_top_level_pull_brace :: proc(s: string) -> int {
	in_quote: u8 = 0
	bracket_depth := 0
	i := 0
	for i < len(s) {
		ch := s[i]
		if in_quote != 0 {
			if ch == '\\' && i + 1 < len(s) {
				i += 2
				continue
			}
			if ch == in_quote {
				in_quote = 0
			}
			i += 1
			continue
		}
		if ch == '"' || ch == '\'' {
			in_quote = ch
		} else if ch == '[' {
			bracket_depth += 1
		} else if ch == ']' {
			if bracket_depth > 0 {
				bracket_depth -= 1
			}
		} else if ch == '{' && bracket_depth == 0 {
			return i
		}
		i += 1
	}
	return -1
}

find_last_unquoted_lbracket :: proc(s: string) -> int {
	in_quote: u8 = 0
	last_idx := -1
	i := 0
	for i < len(s) {
		ch := s[i]
		if in_quote != 0 {
			if ch == '\\' && i + 1 < len(s) {
				i += 2
				continue
			}
			if ch == in_quote {
				in_quote = 0
			}
			i += 1
			continue
		}
		if ch == '"' || ch == '\'' {
			in_quote = ch
		} else if ch == '[' {
			last_idx = i
		}
		i += 1
	}
	return last_idx
}

nif_pull_wildcard :: proc(
	env: ErlNifEnv,
	db: ^xitdb.Database,
	cur: xitdb.Read_Cursor,
	is_root: bool,
	visited: ^map[i64]bool,
) -> (res: ERL_NIF_TERM, err_reason: string, err: xitdb.Error) {
	slot := xitdb.cursor_slot(cur) or_return
	if !is_container_tag(slot.tag) {
		term := slot_to_term(env, db, slot) or_return
		return term, "", nil
	}
	if slot.value > 0 {
		if visited[slot.value] {
			return ATOM_NIL, "", nil
		}
		visited[slot.value] = true
	}
	defer if slot.value > 0 {
		delete_key(visited, slot.value)
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
			v, v_reason, v_err := nif_pull_wildcard(env, db, elem_cur, false, visited)
			if v_err != nil {
				return 0, "", v_err
			}
			if v_reason != "" {
				return 0, v_reason, nil
			}
			append(&items, v)
		}
		if len(items) == 0 {
			return nif_make_list_from_array(env, nil, 0), "", nil
		}
		return nif_make_list_from_array(env, raw_data(items[:]), c.uint(len(items))), "", nil

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
			v := slot_to_term(env, db, key_slot) or_return
			append(&items, v)
		}
		if len(items) == 0 {
			return nif_make_list_from_array(env, nil, 0), "", nil
		}
		return nif_make_list_from_array(env, raw_data(items[:]), c.uint(len(items))), "", nil

	case .Hash_Map, .Counted_Hash_Map, .Sorted_Map:
		it := xitdb.cursor_iterator(cur) or_return
		keys := make([dynamic]ERL_NIF_TERM, 0, 16, context.temp_allocator)
		vals := make([dynamic]ERL_NIF_TERM, 0, 16, context.temp_allocator)
		for {
			next_maybe := xitdb.cursor_iterator_next(&it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			kv := xitdb.cursor_read_kv_pair(elem_cur, context.temp_allocator) or_return
			k_str := xitdb.cursor_read_string(kv.key_cursor, 0, context.temp_allocator) or_return
			if is_root && k_str == "__tx" {
				continue
			}
			v, v_reason, v_err := nif_pull_wildcard(env, db, kv.value_cursor, false, visited)
			if v_err != nil {
				return 0, "", v_err
			}
			if v_reason != "" {
				return 0, v_reason, nil
			}
			append(&keys, make_binary(env, k_str))
			append(&vals, v)
		}
		return make_map_safe(env, keys[:], vals[:]), "", nil
	}
	return ATOM_NIL, "", nil
}

is_simple_hash_map_ident :: proc(s: string) -> (string, bool) {
	p := s
	if len(p) > 0 && p[0] == '.' {
		p = p[1:]
	}
	if len(p) == 0 {
		return "", false
	}
	for i := 0; i < len(p); i += 1 {
		ch := p[i]
		if ch == '.' || ch == '[' || ch == ']' || ch == '#' || ch == '$' || ch == '%' || ch == '^' ||
		   ch == '"' || ch == '\'' || ch == '\\' || ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' {
			return "", false
		}
	}
	return p, true
}

nif_pull_range :: proc(
	env: ErlNifEnv,
	db: ^xitdb.Database,
	cur: xitdb.Read_Cursor,
	start_idx: i64,
	end_idx: i64,
	sub_pattern: string,
	visited: ^map[i64]bool,
) -> (res: ERL_NIF_TERM, err_reason: string, err: xitdb.Error) {
	if start_idx < 0 || end_idx < start_idx {
		return 0, "", .Invalid_Range
	}
	slot := xitdb.cursor_slot(cur) or_return
	it: xitdb.Cursor_Iterator
	#partial switch slot.tag {
	case .Array_List:
		al_col := xitdb.read_array_list_init(cur) or_return
		it = xitdb.array_list_iterator_from(al_col, start_idx) or_return
	case .Linked_Array_List:
		ll_col := xitdb.read_linked_array_list_init(cur) or_return
		it = xitdb.linked_array_list_iterator_from(ll_col, start_idx) or_return
	case:
		return 0, "", .Unexpected_Tag
	}

	limit := end_idx - start_idx
	items := make([dynamic]ERL_NIF_TERM, 0, min(max(0, int(limit)), 256), context.temp_allocator)
	trimmed_sub := strings.trim_space(sub_pattern)
	wildcard_sub := len(trimmed_sub) == 0 || trimmed_sub == "*"
	for i: i64 = 0; i < limit; i += 1 {
		c_maybe := xitdb.cursor_iterator_next(&it) or_return
		elem_cur, ok := c_maybe.?
		if !ok {
			break
		}
		if wildcard_sub {
			elem_slot := xitdb.cursor_slot(elem_cur) or_return
			if !is_container_tag(elem_slot.tag) {
				term := slot_to_term(env, db, elem_slot) or_return
				append(&items, term)
				continue
			}
		}
		v, v_reason, v_err := nif_pull_cursor(env, db, elem_cur, trimmed_sub, false, visited)
		if v_err != nil {
			return 0, "", v_err
		}
		if v_reason != "" {
			return 0, v_reason, nil
		}
		append(&items, v)
	}
	if len(items) == 0 {
		return nif_make_list_from_array(env, nil, 0), "", nil
	}
	return nif_make_list_from_array(env, raw_data(items[:]), c.uint(len(items))), "", nil
}

nif_pull_cursor :: proc(
	env: ErlNifEnv,
	db: ^xitdb.Database,
	cur: xitdb.Read_Cursor,
	pattern: string,
	is_root: bool,
	visited: ^map[i64]bool,
) -> (res: ERL_NIF_TERM, err_reason: string, err: xitdb.Error) {
	p := strings.trim_space(pattern)
	if len(p) == 0 || p == "*" {
		return nif_pull_wildcard(env, db, cur, is_root, visited)
	}

	if len(p) >= 2 && p[0] == '{' && p[len(p) - 1] == '}' {
		inner := strings.trim_space(p[1 : len(p) - 1])
		specs := split_top_level_pull_specs(inner, context.temp_allocator)
		keys := make([dynamic]ERL_NIF_TERM, 0, len(specs), context.temp_allocator)
		vals := make([dynamic]ERL_NIF_TERM, 0, len(specs), context.temp_allocator)

		cur_slot := xitdb.cursor_slot(cur) or_return

		// Pass 1: if wildcard `*` appears anywhere at top level, expand base entries first so explicit specs override
		has_star := false
		if strings.contains_rune(inner, '*') {
			for spec in specs {
				if strings.trim_space(spec) == "*" {
					has_star = true
					break
				}
			}
		}
		if has_star {
			#partial switch cur_slot.tag {
			case .Hash_Map, .Counted_Hash_Map, .Sorted_Map:
				it := xitdb.cursor_iterator(cur) or_return
				for {
					next_maybe := xitdb.cursor_iterator_next(&it) or_return
					elem_cur, ok := next_maybe.?
					if !ok {
						break
					}
					kv := xitdb.cursor_read_kv_pair(elem_cur, context.temp_allocator) or_return
					k_str := xitdb.cursor_read_string(kv.key_cursor, 0, context.temp_allocator) or_return
					if is_root && k_str == "__tx" {
						continue
					}
					v, v_reason, v_err := nif_pull_wildcard(env, db, kv.value_cursor, false, visited)
					if v_err != nil {
						return 0, "", v_err
					}
					if v_reason != "" {
						return 0, v_reason, nil
					}
					append(&keys, make_binary(env, k_str))
					append(&vals, v)
				}
			}
		}

		cur_hm: xitdb.Read_Hash_Map
		has_cur_hm := false
		if cur_slot.tag == .Hash_Map {
			hm_init, hm_err := xitdb.read_hash_map_init(cur)
			if hm_err == nil {
				cur_hm = hm_init
				has_cur_hm = true
			}
		} else if cur_slot.tag == .Counted_Hash_Map {
			chm_init, chm_err := xitdb.read_counted_hash_map_init(cur)
			if chm_err == nil {
				cur_hm = chm_init.read_hash_map
				has_cur_hm = true
			}
		}

		// Pass 2: explicit field specs
		for raw_spec in specs {
			s := strings.trim_space(raw_spec)
			if len(s) == 0 || s == "*" {
				continue
			}

			brace_idx := find_top_level_pull_brace(s)
			sub_pattern := "*"
			path_part := s
			if brace_idx == 0 {
				return 0, "invalid_pull_pattern", nil
			}
			if brace_idx > 0 {
				path_part = strings.trim_space(s[:brace_idx])
				sub_pattern = strings.trim_space(s[brace_idx:])
			}

			range_start: i64 = 0
			range_end: i64 = -1
			has_range := false
			if bracket_idx := find_last_unquoted_lbracket(path_part); bracket_idx > 0 && strings.has_suffix(path_part, "]") {
				inside := path_part[bracket_idx + 1 : len(path_part) - 1]
				if len(inside) > 0 && inside[0] != '"' && inside[0] != '\'' {
					if dots_idx := strings.index(inside, ".."); dots_idx >= 0 {
						r_start, ok1 := strconv.parse_i64(strings.trim_space(inside[:dots_idx]))
						r_end, ok2 := strconv.parse_i64(strings.trim_space(inside[dots_idx + 2:]))
						if !ok1 || !ok2 {
							return 0, "", .Invalid_Range
						}
						range_start = r_start
						range_end = r_end
						has_range = true
						path_part = strings.trim_space(path_part[:bracket_idx])
					}
				}
			}

			target_cur: xitdb.Read_Cursor
			found_target := false
			label: string

			if single_key, is_simple := is_simple_hash_map_ident(path_part); is_simple && has_cur_hm {
				target_maybe, r_err := xitdb.hash_map_get_cursor(cur_hm, single_key)
				if r_err != nil {
					if r_err == .Unexpected_Tag {
						continue
					}
					return 0, "", r_err
				}
				if tc, ok := target_maybe.?; ok {
					target_cur = tc
					found_target = true
					label = single_key
				}
			} else {
				steps, p_err := parse_escaped_steps(path_part, context.temp_allocator)
				if p_err != "" {
					return 0, p_err, nil
				}
				if len(steps) == 0 {
					continue
				}
				target_maybe, r_err := xitdb.read_steps_cursor(cur, steps)
				if r_err != nil {
					if r_err == .Unexpected_Tag {
						continue
					}
					return 0, "", r_err
				}
				if tc, ok := target_maybe.?; ok {
					target_cur = tc
					found_target = true
					label = steps[len(steps) - 1].key if len(steps[len(steps) - 1].key) > 0 else path_part
				}
			}

			if !found_target {
				continue
			}

			pulled: ERL_NIF_TERM
			if has_range {
				pr, pr_reason, pr_err := nif_pull_range(env, db, target_cur, range_start, range_end, sub_pattern, visited)
				if pr_err != nil {
					return 0, "", pr_err
				}
				if pr_reason != "" {
					return 0, pr_reason, nil
				}
				pulled = pr
			} else if len(sub_pattern) == 0 || sub_pattern == "*" {
				t_slot := xitdb.cursor_slot(target_cur) or_return
				if !is_container_tag(t_slot.tag) {
					pulled = slot_to_term(env, db, t_slot) or_return
				} else {
					pc, pc_reason, pc_err := nif_pull_cursor(env, db, target_cur, sub_pattern, false, visited)
					if pc_err != nil {
						return 0, "", pc_err
					}
					if pc_reason != "" {
						return 0, pc_reason, nil
					}
					pulled = pc
				}
			} else {
				pc, pc_reason, pc_err := nif_pull_cursor(env, db, target_cur, sub_pattern, false, visited)
				if pc_err != nil {
					return 0, "", pc_err
				}
				if pc_reason != "" {
					return 0, pc_reason, nil
				}
				pulled = pc
			}
			append(&keys, make_binary(env, label))
			append(&vals, pulled)
		}

		return make_map_safe(env, keys[:], vals[:]), "", nil
	}

	return 0, "invalid_pull_pattern", nil
}

@(export)
odin_nif_pull :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 4 {
		return make_err(env, "badarg")
	}
	tag_int, val_int: i64
	if nif_get_int64(env, argv[1], &tag_int) == 0 || nif_get_int64(env, argv[2], &val_int) == 0 {
		return make_err(env, "badarg")
	}
	pattern_str, ok_p := get_string_from_binary(env, argv[3])
	if !ok_p {
		return make_err(env, "badarg")
	}

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	slot, is_root, is_empty, r_err, err_reason := resolve_slot_arg(handle, tag_int, val_int)
	if r_err != nil {
		return make_xitdb_err(env, r_err)
	}
	if err_reason != "" {
		return make_err(env, err_reason)
	}
	if is_empty {
		#partial switch slot.tag {
		case .Array_List, .Linked_Array_List, .Hash_Set, .Counted_Hash_Set, .Sorted_Set:
			return make_ok(env, nif_make_list_from_array(env, nil, 0))
		case .Hash_Map, .Counted_Hash_Map, .Sorted_Map:
			return make_ok(env, nif_make_new_map(env))
		case:
			return make_ok(env, ATOM_NIL)
		}
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = &handle.db,
	}
	visited: map[i64]bool
	visited.allocator = context.temp_allocator
	res_term, p_reason, p_err := nif_pull_cursor(env, &handle.db, cur, pattern_str, is_root, &visited)
	if p_err != nil {
		return make_xitdb_err(env, p_err)
	}
	if p_reason != "" {
		return make_err(env, p_reason)
	}
	return make_ok(env, res_term)
}

@(export)
odin_nif_diff_moments :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 3 {
		return make_err(env, "badarg")
	}
	moment_a, moment_b: i64
	if nif_get_int64(env, argv[1], &moment_a) == 0 || nif_get_int64(env, argv[2], &moment_b) == 0 {
		return make_err(env, "badarg")
	}

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
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

		old_val, o_err := materialize_slot(env, &handle.db, chg.old_slot, false)
		if o_err != nil {
			return make_xitdb_err(env, o_err)
		}
		new_val, n_err := materialize_slot(env, &handle.db, chg.new_slot, false)
		if n_err != nil {
			return make_xitdb_err(env, n_err)
		}

		vals := [4]ERL_NIF_TERM{
			op_atom,
			make_binary(env, chg.path_str),
			old_val,
			new_val,
		}
		append(&items, make_map_safe(env, keys[:], vals[:]))
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

	if argc != 2 {
		return make_err(env, "badarg")
	}
	sel_str, ok_s := get_string_from_binary(env, argv[1])
	if !ok_s {
		return make_err(env, "badarg")
	}

	parsed, p_err := parse_escaped_selector(sel_str, context.temp_allocator)
	if p_err != "" || parsed.has_moment || len(parsed.steps) == 0 {
		return make_err(env, "invalid_selector")
	}

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	rc := xitdb.database_root_cursor(&handle.db).read_cursor
	root_slot, rs_err := xitdb.cursor_slot(rc)
	if rs_err != nil {
		return make_xitdb_err(env, rs_err)
	}
	if root_slot.tag == .None || root_slot.value == 0 {
		return make_ok(env, nif_make_list_from_array(env, nil, 0))
	}

	history, h_err := xitdb.read_array_list_init(rc)
	if h_err != nil {
		return make_xitdb_err(env, h_err)
	}
	moment_count, mc_err := xitdb.array_list_count(history)
	if mc_err != nil {
		return make_xitdb_err(env, mc_err)
	}

	keys := [4]ERL_NIF_TERM{
		ATOM_MOMENT_INDEX,
		ATOM_VALUE,
		ATOM_DOC,
		ATOM_INSTANT,
	}
	items := make([dynamic]ERL_NIF_TERM, 0, 8, context.temp_allocator)
	prev_slot := xitdb.Slot{}

	for m_idx: i64 = 0; m_idx < moment_count; m_idx += 1 {
		mc_maybe, g_err := xitdb.array_list_get_cursor(history, m_idx)
		if g_err != nil {
			return make_xitdb_err(env, g_err)
		}
		mc, has_mc := mc_maybe.?
		if !has_mc {
			continue
		}
		target_maybe, s_err := xitdb.read_steps_cursor(mc, parsed.steps)
		if s_err != nil {
			if s_err == .Unexpected_Tag {
				cur_slot := xitdb.Slot{}
				if cur_slot != prev_slot {
					doc_str := ""
					inst_val: i64 = 0
					val_term, m_err := materialize_slot(env, &handle.db, cur_slot, false)
					if m_err != nil {
						return make_xitdb_err(env, m_err)
					}
					vals := [4]ERL_NIF_TERM{
						nif_make_int64(env, m_idx),
						val_term,
						make_binary(env, doc_str),
						nif_make_int64(env, inst_val),
					}
					append(&items, make_map_safe(env, keys[:], vals[:]))
					prev_slot = cur_slot
				}
				continue
			}
			return make_xitdb_err(env, s_err)
		}

		cur_slot := xitdb.Slot{}
		if tc, has_tc := target_maybe.?; has_tc {
			slot_res, cs_err := xitdb.cursor_slot(tc)
			if cs_err != nil {
				return make_xitdb_err(env, cs_err)
			}
			cur_slot = slot_res
		}
		if cur_slot != prev_slot {
			doc_str := ""
			inst_val: i64 = 0
			m_map, mm_err := xitdb.read_hash_map_init(mc)
			if mm_err != nil {
				return make_xitdb_err(env, mm_err)
			}
			tx_maybe, tx_err := xitdb.hash_map_get_cursor(m_map, "__tx")
			if tx_err != nil {
				return make_xitdb_err(env, tx_err)
			}
			if tx_cur, has_tx := tx_maybe.?; has_tx {
				tx_map, tm_err := xitdb.read_hash_map_init(tx_cur)
				if tm_err != nil {
					return make_xitdb_err(env, tm_err)
				}
				d_maybe, d_err := xitdb.hash_map_get_cursor(tx_map, "doc")
				if d_err != nil {
					return make_xitdb_err(env, d_err)
				}
				if d_cur, has_d := d_maybe.?; has_d {
					ds, ds_err := xitdb.cursor_read_string(d_cur, 0, context.temp_allocator)
					if ds_err != nil {
						return make_xitdb_err(env, ds_err)
					}
					doc_str = ds
				}
				i_maybe, i_err := xitdb.hash_map_get_cursor(tx_map, "tx_instant")
				if i_err != nil {
					return make_xitdb_err(env, i_err)
				}
				if i_cur, has_i := i_maybe.?; has_i {
					islot, is_err := xitdb.cursor_slot(i_cur)
					if is_err != nil {
						return make_xitdb_err(env, is_err)
					}
					if islot.tag == .Int {
						iv, iv_err := xitdb.cursor_read_int(i_cur)
						if iv_err != nil {
							return make_xitdb_err(env, iv_err)
						}
						inst_val = iv
					} else if islot.tag == .Uint {
						uv, uv_err := xitdb.cursor_read_uint(i_cur)
						if uv_err != nil {
							return make_xitdb_err(env, uv_err)
						}
						inst_val = i64(uv)
					}
				}
			}

			val_term, m_err := materialize_slot(env, &handle.db, cur_slot, false)
			if m_err != nil {
				return make_xitdb_err(env, m_err)
			}
			vals := [4]ERL_NIF_TERM{
				nif_make_int64(env, m_idx),
				val_term,
				make_binary(env, doc_str),
				nif_make_int64(env, inst_val),
			}
			append(&items, make_map_safe(env, keys[:], vals[:]))
			prev_slot = cur_slot
		}
	}

	if len(items) == 0 {
		return make_ok(env, nif_make_list_from_array(env, nil, 0))
	}
	return make_ok(env, nif_make_list_from_array(env, raw_data(items[:]), c.uint(len(items))))
}

// --- Self-Contained NIF Datalog Parser & Evaluator ---

NIF_MAX_DATALOG_VARS :: 16

NIF_Datalog_Env :: struct {
	vals:  [NIF_MAX_DATALOG_VARS]xitdb.Pull_Value,
	bound: [NIF_MAX_DATALOG_VARS]bool,
}

NIF_Datalog_Step :: struct {
	kind:    xitdb.Step_Kind,
	is_var:  bool,
	var_idx: int,
	lit_key: string,
	lit_idx: i64,
}

NIF_Datalog_Clause :: struct {
	kind:            xitdb.Datalog_Clause_Kind,
	negated:         bool,
	moment_kind:     xitdb.Datalog_Moment_Kind,
	moment_lit:      i64,
	moment_var:      int,
	steps:           []NIF_Datalog_Step,
	rhs_kind:        xitdb.Datalog_RHS_Kind,
	rhs_var:         int,
	rhs_lit:         xitdb.Pull_Value,
	pred_op:         xitdb.Datalog_Pred_Op,
	pred_lhs_var:    int,
	pred_rhs_var:    int,
	pred_rhs_lit:    xitdb.Pull_Value,
	reach_from_var:  int,
	reach_to_var:    int,
	reach_depth_var: int,
	reach_edge:      ^NIF_Datalog_Clause,
}

NIF_Datalog_Query :: struct {
	var_names:      [NIF_MAX_DATALOG_VARS]string,
	var_count:      int,
	find_items:     [dynamic]xitdb.Datalog_Find_Item,
	clauses:        [dynamic]NIF_Datalog_Clause,
	has_aggregates: bool,
	allocator:      runtime.Allocator,
}

NIF_Datalog_Group_Bucket :: struct {
	key_env:    NIF_Datalog_Env,
	counts:     [NIF_MAX_DATALOG_VARS]u64,
	sum_i64:    [NIF_MAX_DATALOG_VARS]i64,
	sum_u64:    [NIF_MAX_DATALOG_VARS]u64,
	sum_f64:    [NIF_MAX_DATALOG_VARS]f64,
	sum_kind:   [NIF_MAX_DATALOG_VARS]u8,
	min_vals:   [NIF_MAX_DATALOG_VARS]xitdb.Pull_Value,
	max_vals:   [NIF_MAX_DATALOG_VARS]xitdb.Pull_Value,
	has_minmax: [NIF_MAX_DATALOG_VARS]bool,
}

nif_dl_intern_var :: proc(q: ^NIF_Datalog_Query, name: string) -> (idx: int, err_reason: string) {
	if !strings.has_prefix(name, "?") || len(name) < 2 {
		return -1, "invalid_datalog_query"
	}
	for ch in name[1:] {
		if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == ',' || ch == ')' || ch == ']' {
			return -1, "invalid_datalog_query"
		}
	}
	for i in 0 ..< q.var_count {
		if q.var_names[i] == name {
			return i, ""
		}
	}
	if q.var_count >= NIF_MAX_DATALOG_VARS {
		return -1, "too_many_datalog_vars"
	}
	idx = q.var_count
	q.var_names[idx] = name
	q.var_count += 1
	return idx, ""
}

nif_dl_is_ws :: proc(ch: u8) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'
}

nif_dl_find_where_keyword :: proc(s: string) -> int {
	in_quote: u8 = 0
	depth := 0
	i := 0
	for i + 5 <= len(s) {
		ch := s[i]
		if in_quote != 0 {
			if ch == '\\' && i + 1 < len(s) {
				i += 2
				continue
			}
			if ch == in_quote {
				in_quote = 0
			}
			i += 1
			continue
		}
		if ch == '"' || ch == '\'' {
			in_quote = ch
		} else if ch == '{' || ch == '[' || ch == '(' {
			depth += 1
		} else if ch == '}' || ch == ']' || ch == ')' {
			if depth > 0 {
				depth -= 1
			}
		} else if depth == 0 && s[i : i + 5] == "where" {
			left_ok := i == 0 || nif_dl_is_ws(s[i - 1])
			right_ok := i + 5 == len(s) || nif_dl_is_ws(s[i + 5])
			if left_ok && right_ok {
				return i
			}
		}
		i += 1
	}
	return -1
}

nif_dl_split_comma_args :: proc(s: string, allocator: runtime.Allocator) -> []string {
	args := make([dynamic]string, 0, 4, allocator)
	in_quote: u8 = 0
	depth := 0
	start := 0
	i := 0
	for i < len(s) {
		ch := s[i]
		if in_quote != 0 {
			if ch == '\\' && i + 1 < len(s) {
				i += 2
				continue
			}
			if ch == in_quote {
				in_quote = 0
			}
			i += 1
			continue
		}
		if ch == '"' || ch == '\'' {
			in_quote = ch
		} else if ch == '(' || ch == '[' || ch == '{' {
			depth += 1
		} else if ch == ')' || ch == ']' || ch == '}' {
			if depth > 0 {
				depth -= 1
			}
		} else if ch == ',' && depth == 0 {
			append(&args, strings.trim_space(s[start:i]))
			start = i + 1
		}
		i += 1
	}
	if start < len(s) {
		append(&args, strings.trim_space(s[start:]))
	}
	return args[:]
}

nif_dl_looks_like_complete_clause :: proc(s: string) -> bool {
	if len(s) == 0 || s == "not" {
		return false
	}
	if strings.has_suffix(s, "=") || strings.has_suffix(s, "<") || strings.has_suffix(s, ">") || strings.has_suffix(s, "!") {
		return false
	}
	return true
}

nif_dl_looks_like_clause_start :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	if s[0] == '=' || s[0] == '<' || s[0] == '>' || s[0] == '!' {
		return false
	}
	if s[0] == '.' || s[0] == '$' || s[0] == '#' || s[0] == '@' || s[0] == '[' || s[0] == '^' || s[0] == '%' {
		return true
	}
	if strings.has_prefix(s, "not ") || strings.has_prefix(s, "not\t") ||
	   strings.has_prefix(s, "starts_with(") || strings.has_prefix(s, "contains(") || strings.has_prefix(s, "reach(") {
		return true
	}
	if s[0] == '?' {
		end_v := 1
		for end_v < len(s) && s[end_v] != ' ' && s[end_v] != '=' && s[end_v] != '!' && s[end_v] != '<' && s[end_v] != '>' {
			end_v += 1
		}
		after_v := strings.trim_space(s[end_v:])
		if strings.has_prefix(after_v, "==") || strings.has_prefix(after_v, "!=") ||
		   strings.has_prefix(after_v, "<=") || strings.has_prefix(after_v, ">=") ||
		   strings.has_prefix(after_v, "<") || strings.has_prefix(after_v, ">") {
			return true
		}
	}
	return false
}

nif_dl_split_where_clauses :: proc(where_body: string, allocator: runtime.Allocator) -> []string {
	out := make([dynamic]string, 0, 8, allocator)
	lines := strings.split_lines(where_body, allocator)
	for raw_line in lines {
		line := strings.trim_space(raw_line)
		if len(line) == 0 || strings.has_prefix(line, "//") || strings.has_prefix(line, "--") {
			continue
		}
		start := 0
		in_quote: u8 = 0
		paren_depth := 0
		bracket_depth := 0
		i := 0
		for i < len(line) {
			ch := line[i]
			if in_quote != 0 {
				if ch == '\\' && i + 1 < len(line) {
					i += 2
					continue
				}
				if ch == in_quote {
					in_quote = 0
				}
				i += 1
				continue
			}
			if ch == '"' || ch == '\'' {
				in_quote = ch
			} else if ch == '(' {
				paren_depth += 1
			} else if ch == ')' {
				if paren_depth > 0 {
					paren_depth -= 1
				}
			} else if ch == '[' {
				bracket_depth += 1
			} else if ch == ']' {
				if bracket_depth > 0 {
					bracket_depth -= 1
				}
			} else if (ch == ';' || ch == ',') && paren_depth == 0 && bracket_depth == 0 {
				sub := strings.trim_space(line[start:i])
				if len(sub) > 0 {
					append(&out, sub)
				}
				start = i + 1
			} else if nif_dl_is_ws(ch) && paren_depth == 0 && bracket_depth == 0 {
				prev := strings.trim_space(line[start:i])
				rest := strings.trim_space(line[i + 1:])
				if nif_dl_looks_like_complete_clause(prev) && nif_dl_looks_like_clause_start(rest) {
					append(&out, prev)
					start = i + 1
				}
			}
			i += 1
		}
		tail := strings.trim_space(line[start:])
		if len(tail) > 0 {
			append(&out, tail)
		}
	}
	return out[:]
}

nif_dl_parse_value :: proc(raw: string, allocator: runtime.Allocator) -> (res: xitdb.Pull_Value, ok: bool) {
	s := strings.trim_space(raw)
	if len(s) == 0 {
		return nil, false
	}
	if s == "true" {
		return xitdb.Bytes{value = transmute([]u8)string("1"), format_tag = transmute([]u8)string("bl")}, true
	}
	if s == "false" {
		return xitdb.Bytes{value = transmute([]u8)string("0"), format_tag = transmute([]u8)string("bl")}, true
	}
	if s == "nil" {
		return nil, true
	}
	if (s[0] == '"' || s[0] == '\'') && len(s) >= 2 {
		unq, next_i, er := parse_escaped_quoted(s, 0, allocator)
		if er != "" || next_i != len(s) {
			return nil, false
		}
		return unq, true
	}
	if strings.contains_rune(s, '.') || strings.contains_rune(s, 'e') || strings.contains_rune(s, 'E') {
		if f, fok := strconv.parse_f64(s); fok {
			return f, true
		}
		return nil, false
	}
	if iv, iok := strconv.parse_i64(s); iok {
		if iv >= 0 {
			return u64(iv), true
		}
		return iv, true
	}
	return nil, false
}

nif_dl_find_top_level_equals :: proc(s: string) -> int {
	in_quote: u8 = 0
	bracket_depth := 0
	i := 0
	for i < len(s) {
		ch := s[i]
		if in_quote != 0 {
			if ch == '\\' && i + 1 < len(s) {
				i += 2
				continue
			}
			if ch == in_quote {
				in_quote = 0
			}
			i += 1
			continue
		}
		if ch == '"' || ch == '\'' {
			in_quote = ch
		} else if ch == '[' {
			bracket_depth += 1
		} else if ch == ']' {
			if bracket_depth > 0 {
				bracket_depth -= 1
			}
		} else if ch == '=' && bracket_depth == 0 {
			return i
		}
		i += 1
	}
	return -1
}

nif_dl_find_op_outside_quotes :: proc(s: string, op: string) -> int {
	in_quote: u8 = 0
	i := 0
	for i + len(op) <= len(s) {
		ch := s[i]
		if in_quote != 0 {
			if ch == '\\' && i + 1 < len(s) {
				i += 2
				continue
			}
			if ch == in_quote {
				in_quote = 0
			}
			i += 1
			continue
		}
		if ch == '"' || ch == '\'' {
			in_quote = ch
			i += 1
			continue
		}
		if s[i : i + len(op)] == op {
			return i
		}
		i += 1
	}
	return -1
}

nif_dl_strip_outer_parens :: proc(raw: string) -> string {
	s := strings.trim_space(raw)
	for len(s) >= 2 && s[0] == '(' && s[len(s) - 1] == ')' {
		depth := 0
		in_quote: u8 = 0
		wraps := true
		i := 0
		for i < len(s) {
			ch := s[i]
			if in_quote != 0 {
				if ch == '\\' && i + 1 < len(s) {
					i += 2
					continue
				}
				if ch == in_quote {
					in_quote = 0
				}
				i += 1
				continue
			}
			if ch == '"' || ch == '\'' {
				in_quote = ch
			} else if ch == '(' {
				depth += 1
			} else if ch == ')' {
				depth -= 1
				if depth == 0 && i < len(s) - 1 {
					wraps = false
					break
				}
			}
			i += 1
		}
		if !wraps {
			break
		}
		s = strings.trim_space(s[1 : len(s) - 1])
	}
	return s
}

nif_dl_parse_key_or_var :: proc(q: ^NIF_Datalog_Query, s: string, start_i: int, kind: xitdb.Step_Kind, allocator: runtime.Allocator) -> (step: NIF_Datalog_Step, next_i: int, err_reason: string) {
	if start_i >= len(s) {
		return {}, start_i, "invalid_datalog_query"
	}
	if s[start_i] == '[' {
		if start_i + 1 < len(s) && s[start_i + 1] == '?' {
			end_b := start_i + 1
			for end_b < len(s) && s[end_b] != ']' {
				end_b += 1
			}
			if end_b >= len(s) {
				return {}, start_i, "invalid_datalog_query"
			}
			vname := strings.trim_space(s[start_i + 1 : end_b])
			v_idx, verr := nif_dl_intern_var(q, vname)
			if verr != "" {
				return {}, start_i, verr
			}
			return NIF_Datalog_Step{kind = kind, is_var = true, var_idx = v_idx}, end_b + 1, ""
		}
		key, ni, perr := parse_escaped_bracketed_string(s, start_i, allocator)
		if perr != "" {
			return {}, start_i, perr
		}
		return NIF_Datalog_Step{kind = kind, is_var = false, lit_key = key}, ni, ""
	}
	if s[start_i] == '?' {
		i := start_i + 1
		for i < len(s) {
			ch := s[i]
			if ch == '.' || ch == '[' || ch == ']' || ch == '#' || ch == '$' || ch == '%' || ch == '^' || nif_dl_is_ws(ch) {
				break
			}
			i += 1
		}
		v_idx, verr := nif_dl_intern_var(q, s[start_i:i])
		if verr != "" {
			return {}, start_i, verr
		}
		return NIF_Datalog_Step{kind = kind, is_var = true, var_idx = v_idx}, i, ""
	}
	key, ni, kerr := parse_escaped_ident_or_bracket(s, start_i, allocator)
	if kerr != "" {
		return {}, start_i, kerr
	}
	return NIF_Datalog_Step{kind = kind, is_var = false, lit_key = key}, ni, ""
}

nif_dl_parse_steps :: proc(q: ^NIF_Datalog_Query, path_str: string, allocator: runtime.Allocator) -> (res: []NIF_Datalog_Step, err_reason: string) {
	s := strings.trim_space(path_str)
	if len(s) == 0 {
		return nil, "invalid_datalog_query"
	}
	steps := make([dynamic]NIF_Datalog_Step, 0, 8, allocator)
	i := 0

	for i < len(s) {
		ch := s[i]
		switch ch {
		case '.', '#', '$', '%', '^':
			kind := xitdb.Step_Kind.Hash_Map_Key
			if ch == '#' {
				if i + 1 < len(s) && s[i + 1] == '%' {
					kind = .Counted_Set_Member
					i += 1
				} else {
					kind = .Counted_Hash_Map_Key
				}
			} else if ch == '$' {
				kind = .Sorted_Map_Key
			} else if ch == '%' {
				kind = .Hash_Set_Member
			} else if ch == '^' {
				kind = .Sorted_Set_Member
			}
			i += 1
			step, next_i, serr := nif_dl_parse_key_or_var(q, s, i, kind, allocator)
			if serr != "" {
				return nil, serr
			}
			append(&steps, step)
			i = next_i

		case '[':
			if i + 1 < len(s) && s[i + 1] == '[' {
				i += 2
				start := i
				for i < len(s) && s[i] != ']' {
					i += 1
				}
				if i + 1 >= len(s) || s[i] != ']' || s[i + 1] != ']' {
					return nil, "invalid_datalog_query"
				}
				inner := strings.trim_space(s[start:i])
				if strings.has_prefix(inner, "?") {
					v_idx, verr := nif_dl_intern_var(q, inner)
					if verr != "" {
						return nil, verr
					}
					append(&steps, NIF_Datalog_Step{kind = .Linked_List_Idx, is_var = true, var_idx = v_idx})
				} else {
					idx, ok := strconv.parse_i64(inner)
					if !ok {
						return nil, "invalid_datalog_query"
					}
					append(&steps, NIF_Datalog_Step{kind = .Linked_List_Idx, is_var = false, lit_idx = idx})
				}
				i += 2
			} else if i + 1 < len(s) && (s[i + 1] == '"' || s[i + 1] == '\'') {
				key, next_i, perr := parse_escaped_bracketed_string(s, i, allocator)
				if perr != "" {
					return nil, perr
				}
				step_kind := xitdb.Step_Kind.Hash_Map_Key
				if len(steps) == 1 {
					if steps[0].kind == .Counted_Hash_Map_Key {
						steps[0].kind = .Hash_Map_Key
						step_kind = .Counted_Hash_Map_Key
					} else if steps[0].kind == .Sorted_Map_Key {
						steps[0].kind = .Hash_Map_Key
						step_kind = .Sorted_Map_Key
					}
				}
				append(&steps, NIF_Datalog_Step{kind = step_kind, is_var = false, lit_key = key})
				i = next_i
			} else {
				i += 1
				start := i
				for i < len(s) && s[i] != ']' {
					i += 1
				}
				if i >= len(s) || s[i] != ']' {
					return nil, "invalid_datalog_query"
				}
				inner := strings.trim_space(s[start:i])
				if strings.has_prefix(inner, "?") {
					v_idx, verr := nif_dl_intern_var(q, inner)
					if verr != "" {
						return nil, verr
					}
					step_kind := xitdb.Step_Kind.Hash_Map_Key
					if len(steps) == 1 {
						if steps[0].kind == .Counted_Hash_Map_Key {
							steps[0].kind = .Hash_Map_Key
							step_kind = .Counted_Hash_Map_Key
						} else if steps[0].kind == .Sorted_Map_Key {
							steps[0].kind = .Hash_Map_Key
							step_kind = .Sorted_Map_Key
						}
					}
					append(&steps, NIF_Datalog_Step{kind = step_kind, is_var = true, var_idx = v_idx})
				} else {
					idx, ok := strconv.parse_i64(inner)
					if !ok {
						return nil, "invalid_datalog_query"
					}
					append(&steps, NIF_Datalog_Step{kind = .Array_List_Idx, is_var = false, lit_idx = idx})
				}
				i += 1
			}

		case:
			step, next_i, serr := nif_dl_parse_key_or_var(q, s, i, .Hash_Map_Key, allocator)
			if serr != "" {
				return nil, serr
			}
			append(&steps, step)
			i = next_i
		}
	}

	if len(steps) == 0 {
		return nil, "invalid_datalog_query"
	}
	return steps[:], ""
}

nif_dl_clause_uses_var :: proc(c: NIF_Datalog_Clause, var_idx: int) -> bool {
	if c.moment_kind == .Var_Moment && c.moment_var == var_idx {
		return true
	}
	if c.rhs_kind == .Var && c.rhs_var == var_idx {
		return true
	}
	for s in c.steps {
		if s.is_var && s.var_idx == var_idx {
			return true
		}
	}
	if c.kind == .Predicate {
		if c.pred_lhs_var == var_idx || c.pred_rhs_var == var_idx {
			return true
		}
	}
	return false
}

nif_dl_parse_predicate :: proc(q: ^NIF_Datalog_Query, s: string, negated: bool, allocator: runtime.Allocator) -> (clause: NIF_Datalog_Clause, err_reason: string) {
	ops := [?]struct {
		token: string,
		op:    xitdb.Datalog_Pred_Op,
	}{
		{"==", .Eq},
		{"!=", .Neq},
		{"<=", .Lte},
		{">=", .Gte},
		{"<", .Lt},
		{">", .Gt},
	}

	for entry in ops {
		if idx := nif_dl_find_op_outside_quotes(s, entry.token); idx > 0 {
			lhs_str := strings.trim_space(s[:idx])
			rhs_str := strings.trim_space(s[idx + len(entry.token):])
			lhs_var, lerr := nif_dl_intern_var(q, lhs_str)
			if lerr != "" {
				return {}, lerr
			}
			rhs_var := -1
			var_lit: xitdb.Pull_Value
			if strings.has_prefix(rhs_str, "?") {
				rv, rerr := nif_dl_intern_var(q, rhs_str)
				if rerr != "" {
					return {}, rerr
				}
				rhs_var = rv
			} else {
				lit, ok := nif_dl_parse_value(rhs_str, allocator)
				if !ok {
					return {}, "invalid_datalog_query"
				}
				var_lit = lit
			}
			return NIF_Datalog_Clause{
				kind         = .Predicate,
				negated      = negated,
				pred_op      = entry.op,
				pred_lhs_var = lhs_var,
				pred_rhs_var = rhs_var,
				pred_rhs_lit = var_lit,
			}, ""
		}
	}
	return {}, "invalid_datalog_query"
}

nif_dl_parse_clause :: proc(q: ^NIF_Datalog_Query, line: string, allocator: runtime.Allocator) -> (clause: NIF_Datalog_Clause, err_reason: string) {
	s := strings.trim_space(line)
	is_negated := false
	if len(s) > 4 && s[:3] == "not" && nif_dl_is_ws(s[3]) {
		is_negated = true
		s = strings.trim_space(s[4:])
	}
	s = nif_dl_strip_outer_parens(s)

	if strings.has_prefix(s, "reach(") && strings.has_suffix(s, ")") {
		inner := strings.trim_space(s[len("reach(") : len(s) - 1])
		args := nif_dl_split_comma_args(inner, allocator)
		if len(args) != 3 && len(args) != 4 {
			return {}, "invalid_reach_clause"
		}
		from_var, ferr := nif_dl_intern_var(q, args[0])
		if ferr != "" {
			return {}, "invalid_reach_clause"
		}
		to_var, terr := nif_dl_intern_var(q, args[1])
		if terr != "" {
			return {}, "invalid_reach_clause"
		}
		if from_var == to_var {
			return {}, "invalid_reach_clause"
		}
		depth_var := -1
		edge_str := args[2]
		if len(args) == 4 {
			dv, derr := nif_dl_intern_var(q, args[2])
			if derr != "" {
				return {}, "invalid_reach_clause"
			}
			depth_var = dv
			edge_str = args[3]
		}
		edge_clause := new(NIF_Datalog_Clause, allocator)
		ec, eerr := nif_dl_parse_clause(q, edge_str, allocator)
		if eerr != "" {
			return {}, eerr
		}
		if ec.kind != .Pattern {
			return {}, "invalid_reach_clause"
		}
		if !nif_dl_clause_uses_var(ec, from_var) || !nif_dl_clause_uses_var(ec, to_var) {
			return {}, "invalid_reach_clause"
		}
		edge_clause^ = ec
		return NIF_Datalog_Clause{
			kind            = .Reach,
			negated         = is_negated,
			reach_from_var  = from_var,
			reach_to_var    = to_var,
			reach_depth_var = depth_var,
			reach_edge      = edge_clause,
		}, ""
	}

	if (strings.has_prefix(s, "starts_with(") || strings.has_prefix(s, "contains(")) && strings.has_suffix(s, ")") {
		is_sw := strings.has_prefix(s, "starts_with(")
		open_p := strings.index_byte(s, '(')
		inner := s[open_p + 1 : len(s) - 1]
		args := nif_dl_split_comma_args(inner, allocator)
		if len(args) != 2 {
			return {}, "invalid_datalog_query"
		}
		lhs_var, lerr := nif_dl_intern_var(q, args[0])
		if lerr != "" {
			return {}, lerr
		}
		rhs_var := -1
		var_lit: xitdb.Pull_Value
		if strings.has_prefix(args[1], "?") {
			rv, rerr := nif_dl_intern_var(q, args[1])
			if rerr != "" {
				return {}, rerr
			}
			rhs_var = rv
		} else {
			lit, ok := nif_dl_parse_value(args[1], allocator)
			if !ok {
				return {}, "invalid_datalog_query"
			}
			var_lit = lit
		}
		return NIF_Datalog_Clause{
			kind         = .Predicate,
			negated      = is_negated,
			pred_op      = .Starts_With if is_sw else .Contains,
			pred_lhs_var = lhs_var,
			pred_rhs_var = rhs_var,
			pred_rhs_lit = var_lit,
		}, ""
	}

	if strings.has_prefix(s, "?") {
		return nif_dl_parse_predicate(q, s, is_negated, allocator)
	}

	clause.kind = .Not_Pattern if is_negated else .Pattern
	clause.moment_kind = .Default_Moment
	clause.moment_var = -1
	clause.rhs_var = -1

	if strings.has_prefix(s, "@") {
		s = s[1:]
		if strings.has_prefix(s, "?") {
			end_v := 1
			for end_v < len(s) && s[end_v] != '.' && s[end_v] != '[' && s[end_v] != '$' && s[end_v] != '#' && s[end_v] != '%' && s[end_v] != '^' && !nif_dl_is_ws(s[end_v]) {
				end_v += 1
			}
			m_var, merr := nif_dl_intern_var(q, s[:end_v])
			if merr != "" {
				return {}, merr
			}
			clause.moment_kind = .Var_Moment
			clause.moment_var = m_var
			s = s[end_v:]
		} else {
			end_m := 0
			if end_m < len(s) && s[end_m] == '-' {
				end_m += 1
			}
			for end_m < len(s) && s[end_m] >= '0' && s[end_m] <= '9' {
				end_m += 1
			}
			m_idx, ok := strconv.parse_i64(s[:end_m])
			if !ok {
				return {}, "invalid_datalog_query"
			}
			clause.moment_kind = .Literal_Moment
			clause.moment_lit = m_idx
			s = s[end_m:]
		}
	}

	eq_idx := nif_dl_find_top_level_equals(s)
	path_part := s
	if eq_idx >= 0 {
		path_part = strings.trim_space(s[:eq_idx])
		rhs_str := strings.trim_space(s[eq_idx + 1:])
		if strings.has_prefix(rhs_str, "?") {
			v_idx, verr := nif_dl_intern_var(q, rhs_str)
			if verr != "" {
				return {}, verr
			}
			clause.rhs_kind = .Var
			clause.rhs_var = v_idx
		} else {
			val, vok := nif_dl_parse_value(rhs_str, allocator)
			if !vok {
				return {}, "invalid_datalog_query"
			}
			clause.rhs_kind = .Literal
			clause.rhs_lit = val
		}
	} else {
		clause.rhs_kind = .None
	}

	steps, serr := nif_dl_parse_steps(q, path_part, allocator)
	if serr != "" {
		return {}, serr
	}
	clause.steps = steps
	return clause, ""
}

nif_dl_parse_find_item :: proc(q: ^NIF_Datalog_Query, token: string) -> (item: xitdb.Datalog_Find_Item, err_reason: string) {
	aggs := [?]struct {
		prefix: string,
		kind:   xitdb.Datalog_Agg_Kind,
	}{
		{"count(", .Count},
		{"sum(",   .Sum},
		{"min(",   .Min},
		{"max(",   .Max},
	}

	for a in aggs {
		if strings.has_prefix(token, a.prefix) && strings.has_suffix(token, ")") {
			inner := strings.trim_space(token[len(a.prefix) : len(token) - 1])
			v_idx, verr := nif_dl_intern_var(q, inner)
			if verr != "" {
				return {}, verr
			}
			return xitdb.Datalog_Find_Item{
				agg     = a.kind,
				var_idx = v_idx,
				label   = token,
			}, ""
		}
	}

	v_idx, verr := nif_dl_intern_var(q, token)
	if verr != "" {
		return {}, verr
	}
	return xitdb.Datalog_Find_Item{
		agg     = .None,
		var_idx = v_idx,
		label   = token,
	}, ""
}

nif_dl_parse_query :: proc(query_str: string, allocator: runtime.Allocator) -> (q: NIF_Datalog_Query, err_reason: string) {
	q = NIF_Datalog_Query{
		find_items = make([dynamic]xitdb.Datalog_Find_Item, 0, 8, allocator),
		clauses    = make([dynamic]NIF_Datalog_Clause, 0, 8, allocator),
		allocator  = allocator,
	}
	s := strings.trim_space(query_str)
	if len(s) < 5 || s[:4] != "find" || !nif_dl_is_ws(s[4]) {
		return {}, "invalid_datalog_query"
	}
	where_idx := nif_dl_find_where_keyword(s)
	if where_idx < 0 {
		return {}, "invalid_datalog_query"
	}

	find_part := strings.trim_space(s[len("find") : where_idx])
	find_tokens := strings.split(find_part, ",", allocator)
	for tok in find_tokens {
		item_str := strings.trim_space(tok)
		if len(item_str) == 0 {
			continue
		}
		item, ierr := nif_dl_parse_find_item(&q, item_str)
		if ierr != "" {
			return {}, ierr
		}
		if item.agg != .None {
			q.has_aggregates = true
		}
		append(&q.find_items, item)
	}
	if len(q.find_items) == 0 {
		return {}, "invalid_datalog_query"
	}

	where_body := strings.trim_space(s[where_idx + len("where"):])
	clauses_raw := nif_dl_split_where_clauses(where_body, allocator)
	for raw_clause in clauses_raw {
		line := strings.trim_space(raw_clause)
		if len(line) == 0 || strings.has_prefix(line, "//") || strings.has_prefix(line, "--") {
			continue
		}
		clause, cerr := nif_dl_parse_clause(&q, line, allocator)
		if cerr != "" {
			return {}, cerr
		}
		append(&q.clauses, clause)
	}
	return q, ""
}

nif_dl_pull_val_as_i64 :: proc(v: xitdb.Pull_Value) -> (i64, bool) {
	#partial switch val in v {
	case i64:
		return val, true
	case u64:
		return i64(val), true
	}
	return 0, false
}

nif_dl_value_equals :: proc(a, b: xitdb.Pull_Value) -> bool {
	if a == nil && b == nil {
		return true
	}
	if a == nil || b == nil {
		return false
	}
	if ai, ok1 := nif_dl_pull_val_as_i64(a); ok1 {
		if bi, ok2 := nif_dl_pull_val_as_i64(b); ok2 {
			return ai == bi
		}
	}
	#partial switch va in a {
	case string:
		if vb, ok := b.(string); ok {
			return va == vb
		}
	case f64:
		if vb, ok := b.(f64); ok {
			return va == vb
		}
	case xitdb.Bytes:
		if vb, ok := b.(xitdb.Bytes); ok {
			return string(va.format_tag) == string(vb.format_tag) && string(va.value) == string(vb.value)
		}
	}
	return false
}

nif_dl_compare_values :: proc(a, b: xitdb.Pull_Value) -> (cmp: int, ok: bool) {
	if ai, ok1 := nif_dl_pull_val_as_i64(a); ok1 {
		if bi, ok2 := nif_dl_pull_val_as_i64(b); ok2 {
			if ai < bi {
				return -1, true
			}
			if ai > bi {
				return 1, true
			}
			return 0, true
		}
	}
	#partial switch va in a {
	case string:
		if vb, is_s := b.(string); is_s {
			return strings.compare(va, vb), true
		}
	case f64:
		if vb, is_f := b.(f64); is_f {
			if va < vb {
				return -1, true
			}
			if va > vb {
				return 1, true
			}
			return 0, true
		}
	}
	return 0, false
}

nif_dl_slice_contains :: proc(list: []xitdb.Pull_Value, target: xitdb.Pull_Value) -> bool {
	for item in list {
		if nif_dl_value_equals(item, target) {
			return true
		}
	}
	return false
}

nif_dl_read_cursor_value :: proc(cur: xitdb.Read_Cursor, allocator: runtime.Allocator) -> (res: xitdb.Pull_Value, err: xitdb.Error) {
	// `xitdb.pull` handles scalars AND nested containers cleanly
	return xitdb.pull(cur, "*", allocator)
}

nif_dl_find_prefix_hint :: proc(q: ^NIF_Datalog_Query, var_idx: int) -> (string, bool) {
	for c in q.clauses {
		if c.kind == .Predicate && !c.negated && c.pred_op == .Starts_With && c.pred_lhs_var == var_idx {
			if s, is_s := c.pred_rhs_lit.(string); is_s {
				return s, true
			}
		}
	}
	return "", false
}

nif_dl_find_lower_bound_hint :: proc(q: ^NIF_Datalog_Query, var_idx: int) -> (string, bool) {
	for c in q.clauses {
		if c.kind == .Predicate && !c.negated && (c.pred_op == .Gte || c.pred_op == .Gt) && c.pred_lhs_var == var_idx && c.pred_rhs_var == -1 {
			if s, is_s := c.pred_rhs_lit.(string); is_s {
				return s, true
			}
		}
	}
	return "", false
}

nif_dl_eval_predicate :: proc(clause: ^NIF_Datalog_Clause, env: ^NIF_Datalog_Env) -> (ok_res: bool, bound_var: int) {
	bound_var = -1
	if !env.bound[clause.pred_lhs_var] {
		if !clause.negated && clause.pred_op == .Eq {
			if clause.pred_rhs_var < 0 {
				env.bound[clause.pred_lhs_var] = true
				env.vals[clause.pred_lhs_var] = clause.pred_rhs_lit
				return true, clause.pred_lhs_var
			} else if env.bound[clause.pred_rhs_var] {
				env.bound[clause.pred_lhs_var] = true
				env.vals[clause.pred_lhs_var] = env.vals[clause.pred_rhs_var]
				return true, clause.pred_lhs_var
			}
		}
		return false, -1
	}

	lhs := env.vals[clause.pred_lhs_var]
	rhs := clause.pred_rhs_lit
	if clause.pred_rhs_var >= 0 {
		if !env.bound[clause.pred_rhs_var] {
			if !clause.negated && clause.pred_op == .Eq {
				env.bound[clause.pred_rhs_var] = true
				env.vals[clause.pred_rhs_var] = lhs
				return true, clause.pred_rhs_var
			}
			return false, -1
		}
		rhs = env.vals[clause.pred_rhs_var]
	}

	raw_ok := false
	switch clause.pred_op {
	case .Eq:
		raw_ok = nif_dl_value_equals(lhs, rhs)
	case .Neq:
		raw_ok = !nif_dl_value_equals(lhs, rhs)
	case .Starts_With:
		ls, ok1 := lhs.(string)
		rs, ok2 := rhs.(string)
		raw_ok = ok1 && ok2 && strings.has_prefix(ls, rs)
	case .Contains:
		ls, ok1 := lhs.(string)
		rs, ok2 := rhs.(string)
		raw_ok = ok1 && ok2 && strings.contains(ls, rs)
	case .Lt, .Lte, .Gt, .Gte:
		cmp, ok := nif_dl_compare_values(lhs, rhs)
		if !ok {
			raw_ok = false
		} else if clause.pred_op == .Lt {
			raw_ok = cmp < 0
		} else if clause.pred_op == .Lte {
			raw_ok = cmp <= 0
		} else if clause.pred_op == .Gt {
			raw_ok = cmp > 0
		} else {
			raw_ok = cmp >= 0
		}
	}

	return (!raw_ok if clause.negated else raw_ok), -1
}

NIF_Reach_Queue_Item :: struct {
	node:  xitdb.Pull_Value,
	depth: u64,
}

nif_dl_eval_reach :: proc(
	db: ^xitdb.Database,
	q: ^NIF_Datalog_Query,
	clause: ^NIF_Datalog_Clause,
	clause_idx: int,
	default_moment: i64,
	env: ^NIF_Datalog_Env,
	out_rows: ^[dynamic][]xitdb.Pull_Value,
	out_envs: ^[dynamic]NIF_Datalog_Env,
	stop_after_first: bool,
	allocator: runtime.Allocator,
) -> (matched_any: bool, err: xitdb.Error) {
	if clause.reach_edge == nil {
		return false, nil
	}

	step_q := new(NIF_Datalog_Query, allocator)
	step_q^ = NIF_Datalog_Query{
		var_names  = q.var_names,
		var_count  = q.var_count,
		find_items = make([dynamic]xitdb.Datalog_Find_Item, 1, 1, allocator),
		clauses    = make([dynamic]NIF_Datalog_Clause, 1, 1, allocator),
		allocator  = allocator,
	}
	step_q.clauses[0] = clause.reach_edge^

	seeds := make([dynamic]xitdb.Pull_Value, 0, 4, allocator)
	if env.bound[clause.reach_from_var] {
		append(&seeds, env.vals[clause.reach_from_var])
	} else {
		step_q.find_items[0] = xitdb.Datalog_Find_Item{agg = .None, var_idx = clause.reach_from_var}
		seed_rows := make([dynamic][]xitdb.Pull_Value, 0, 8, allocator)
		seed_env := new(NIF_Datalog_Env, allocator)
		seed_env^ = env^
		seed_env.bound[clause.reach_from_var] = false
		seed_env.bound[clause.reach_to_var] = false
		_ = nif_dl_eval_pattern_moment(db, step_q, clause.reach_edge, 0, default_moment, seed_env, &seed_rows, nil, false, allocator) or_return
		for sr in seed_rows {
			if !nif_dl_slice_contains(seeds[:], sr[0]) {
				append(&seeds, sr[0])
			}
		}
	}

	step_q.find_items[0] = xitdb.Datalog_Find_Item{agg = .None, var_idx = clause.reach_to_var}
	edge_env := new(NIF_Datalog_Env, allocator)

	if clause.negated {
		for seed in seeds {
			visited := make([dynamic]xitdb.Pull_Value, 0, 8, allocator)
			queue := make([dynamic]NIF_Reach_Queue_Item, 0, 8, allocator)
			append(&queue, NIF_Reach_Queue_Item{node = seed, depth = 0})
			q_head := 0
			reached := false
			for q_head < len(queue) && !reached {
				curr := queue[q_head]
				q_head += 1

				edge_env^ = env^
				edge_env.bound[clause.reach_from_var] = true
				edge_env.vals[clause.reach_from_var] = curr.node
				edge_env.bound[clause.reach_to_var] = false

				neighbor_rows := make([dynamic][]xitdb.Pull_Value, 0, 4, allocator)
				_ = nif_dl_eval_pattern_moment(db, step_q, clause.reach_edge, 0, default_moment, edge_env, &neighbor_rows, nil, false, allocator) or_return

				for nrow in neighbor_rows {
					next_node := nrow[0]
					if nif_dl_slice_contains(visited[:], next_node) {
						continue
					}
					next_depth := curr.depth + 1
					append(&visited, next_node)
					append(&queue, NIF_Reach_Queue_Item{node = next_node, depth = next_depth})

					if env.bound[clause.reach_to_var] && !nif_dl_value_equals(env.vals[clause.reach_to_var], next_node) {
						continue
					}
					if clause.reach_depth_var >= 0 && env.bound[clause.reach_depth_var] {
						if !nif_dl_value_equals(env.vals[clause.reach_depth_var], next_depth) {
							continue
						}
					}
					reached = true
					break
				}
			}
			if !reached {
				was_bound := env.bound[clause.reach_from_var]
				if !was_bound {
					env.bound[clause.reach_from_var] = true
					env.vals[clause.reach_from_var] = seed
				}
				m, merr := nif_dl_eval_clauses(db, q, clause_idx + 1, default_moment, env, out_rows, out_envs, stop_after_first, allocator)
				if !was_bound {
					env.bound[clause.reach_from_var] = false
					env.vals[clause.reach_from_var] = nil
				}
				if merr != nil {
					return false, merr
				}
				if m {
					matched_any = true
					if stop_after_first {
						return true, nil
					}
				}
			}
		}
		return matched_any, nil
	}

	next_env := new(NIF_Datalog_Env, allocator)
	for seed in seeds {
		visited := make([dynamic]xitdb.Pull_Value, 0, 8, allocator)
		queue := make([dynamic]NIF_Reach_Queue_Item, 0, 8, allocator)
		append(&queue, NIF_Reach_Queue_Item{node = seed, depth = 0})
		q_head := 0

		for q_head < len(queue) {
			curr := queue[q_head]
			q_head += 1

			edge_env^ = env^
			edge_env.bound[clause.reach_from_var] = true
			edge_env.vals[clause.reach_from_var] = curr.node
			edge_env.bound[clause.reach_to_var] = false

			neighbor_rows := make([dynamic][]xitdb.Pull_Value, 0, 4, allocator)
			_ = nif_dl_eval_pattern_moment(db, step_q, clause.reach_edge, 0, default_moment, edge_env, &neighbor_rows, nil, false, allocator) or_return

			for nrow in neighbor_rows {
				next_node := nrow[0]
				if nif_dl_slice_contains(visited[:], next_node) {
					continue
				}
				next_depth := curr.depth + 1
				append(&visited, next_node)
				append(&queue, NIF_Reach_Queue_Item{node = next_node, depth = next_depth})

				if env.bound[clause.reach_to_var] && !nif_dl_value_equals(env.vals[clause.reach_to_var], next_node) {
					continue
				}
				if clause.reach_depth_var >= 0 && env.bound[clause.reach_depth_var] {
					if !nif_dl_value_equals(env.vals[clause.reach_depth_var], next_depth) {
						continue
					}
				}

				next_env^ = env^
				next_env.bound[clause.reach_from_var] = true
				next_env.vals[clause.reach_from_var] = seed
				next_env.bound[clause.reach_to_var] = true
				next_env.vals[clause.reach_to_var] = next_node
				if clause.reach_depth_var >= 0 {
					next_env.bound[clause.reach_depth_var] = true
					next_env.vals[clause.reach_depth_var] = next_depth
				}

				m := nif_dl_eval_clauses(db, q, clause_idx + 1, default_moment, next_env, out_rows, out_envs, stop_after_first, allocator) or_return
				if m {
					matched_any = true
					if stop_after_first {
						return true, nil
					}
				}
			}
		}
	}

	return matched_any, nil
}

nif_dl_eval_pattern_steps :: proc(
	db: ^xitdb.Database,
	q: ^NIF_Datalog_Query,
	clause: ^NIF_Datalog_Clause,
	start_step_idx: int,
	start_cur: xitdb.Read_Cursor,
	clause_idx: int,
	default_moment: i64,
	env: ^NIF_Datalog_Env,
	out_rows: ^[dynamic][]xitdb.Pull_Value,
	out_envs: ^[dynamic]NIF_Datalog_Env,
	check_only: bool,
	allocator: runtime.Allocator,
) -> (matched_any: bool, err: xitdb.Error) {
	step_idx := start_step_idx
	cur := start_cur

	for step_idx < len(clause.steps) {
		step := clause.steps[step_idx]
		slot := xitdb.cursor_slot(cur) or_return
		if slot.tag == .None {
			return false, nil
		}

		if !step.is_var || env.bound[step.var_idx] {
			ps: xitdb.Path_Step
			ps.kind = step.kind
			if !step.is_var {
				ps.key = step.lit_key
				ps.index = step.lit_idx
			} else {
				bval := env.vals[step.var_idx]
				if slot.tag == .Array_List || slot.tag == .Linked_Array_List {
					idx_val, ok := nif_dl_pull_val_as_i64(bval)
					if !ok {
						return false, nil
					}
					ps.kind = .Linked_List_Idx if slot.tag == .Linked_Array_List else .Array_List_Idx
					ps.index = idx_val
				} else {
					k_str, ok := bval.(string)
					if !ok {
						return false, nil
					}
					ps.key = k_str
					if slot.tag == .Sorted_Map {
						ps.kind = .Sorted_Map_Key
					} else if slot.tag == .Counted_Hash_Map {
						ps.kind = .Counted_Hash_Map_Key
					} else if slot.tag == .Hash_Set {
						ps.kind = .Hash_Set_Member
					} else if slot.tag == .Counted_Hash_Set {
						ps.kind = .Counted_Set_Member
					} else if slot.tag == .Sorted_Set {
						ps.kind = .Sorted_Set_Member
					}
				}
			}
			next_cur_maybe, r_err := xitdb.read_steps_cursor(cur, []xitdb.Path_Step{ps})
			if r_err != nil {
				if r_err == .Unexpected_Tag {
					return false, nil
				}
				return false, r_err
			}
			next_cur, ok := next_cur_maybe.?
			if !ok {
				return false, nil
			}
			cur = next_cur
			step_idx += 1
			continue
		}

		// Unbound variable step: branch across collection entries
		var_idx := step.var_idx
		it := new(xitdb.Cursor_Iterator, allocator)

		#partial switch slot.tag {
		case .Sorted_Map, .Sorted_Set:
			prefix_hint, has_prefix := nif_dl_find_prefix_hint(q, var_idx)
			lower_hint, has_lower := nif_dl_find_lower_bound_hint(q, var_idx)
			if has_prefix {
				it^ = xitdb.cursor_iterator_sorted_from_key(cur, transmute([]u8)prefix_hint) or_return
			} else if has_lower {
				it^ = xitdb.cursor_iterator_sorted_from_key(cur, transmute([]u8)lower_hint) or_return
			} else {
				it^ = xitdb.cursor_iterator(cur) or_return
			}
			for {
				c_maybe := xitdb.cursor_iterator_next(it) or_return
				c, has_c := c_maybe.?
				if !has_c {
					break
				}
				kv := xitdb.cursor_read_kv_pair(c, allocator) or_return
				k_str := xitdb.cursor_read_string(kv.key_cursor, 0, allocator) or_return
				if has_prefix && !strings.has_prefix(k_str, prefix_hint) {
					break
				}
				env.bound[var_idx] = true
				env.vals[var_idx] = k_str
				child_cur := kv.key_cursor if slot.tag == .Sorted_Set else kv.value_cursor
				m, merr := nif_dl_eval_pattern_steps(db, q, clause, step_idx + 1, child_cur, clause_idx, default_moment, env, out_rows, out_envs, check_only, allocator)
				env.bound[var_idx] = false
				env.vals[var_idx] = nil
				if merr != nil {
					return false, merr
				}
				if m {
					matched_any = true
					if check_only {
						return true, nil
					}
				}
			}
			return matched_any, nil

		case .Hash_Map, .Counted_Hash_Map, .Hash_Set, .Counted_Hash_Set:
			is_set := slot.tag == .Hash_Set || slot.tag == .Counted_Hash_Set
			it^ = xitdb.cursor_iterator(cur) or_return
			for {
				c_maybe := xitdb.cursor_iterator_next(it) or_return
				c, has_c := c_maybe.?
				if !has_c {
					break
				}
				kv := xitdb.cursor_read_kv_pair(c, allocator) or_return
				k_str := xitdb.cursor_read_string(kv.key_cursor, 0, allocator) or_return
				if step_idx == 0 && k_str == "__tx" {
					continue
				}
				env.bound[var_idx] = true
				env.vals[var_idx] = k_str
				child_cur := kv.key_cursor if is_set else kv.value_cursor
				m, merr := nif_dl_eval_pattern_steps(db, q, clause, step_idx + 1, child_cur, clause_idx, default_moment, env, out_rows, out_envs, check_only, allocator)
				env.bound[var_idx] = false
				env.vals[var_idx] = nil
				if merr != nil {
					return false, merr
				}
				if m {
					matched_any = true
					if check_only {
						return true, nil
					}
				}
			}
			return matched_any, nil

		case .Array_List, .Linked_Array_List:
			it^ = xitdb.cursor_iterator(cur) or_return
			idx: i64 = 0
			for {
				c_maybe := xitdb.cursor_iterator_next(it) or_return
				c, has_c := c_maybe.?
				if !has_c {
					break
				}
				env.bound[var_idx] = true
				env.vals[var_idx] = idx
				idx += 1
				m, merr := nif_dl_eval_pattern_steps(db, q, clause, step_idx + 1, c, clause_idx, default_moment, env, out_rows, out_envs, check_only, allocator)
				env.bound[var_idx] = false
				env.vals[var_idx] = nil
				if merr != nil {
					return false, merr
				}
				if m {
					matched_any = true
					if check_only {
						return true, nil
					}
				}
			}
			return matched_any, nil
		}

		return false, nil
	}

	// All steps consumed: check or bind RHS
	bound_rhs := -1
	switch clause.rhs_kind {
	case .None:
	case .Literal:
		actual := nif_dl_read_cursor_value(cur, allocator) or_return
		if !nif_dl_value_equals(actual, clause.rhs_lit) {
			return false, nil
		}
	case .Var:
		actual := nif_dl_read_cursor_value(cur, allocator) or_return
		if env.bound[clause.rhs_var] {
			if !nif_dl_value_equals(env.vals[clause.rhs_var], actual) {
				return false, nil
			}
		} else {
			env.bound[clause.rhs_var] = true
			env.vals[clause.rhs_var] = actual
			bound_rhs = clause.rhs_var
		}
	}

	if check_only {
		if bound_rhs >= 0 {
			env.bound[bound_rhs] = false
			env.vals[bound_rhs] = nil
		}
		return true, nil
	}
	res, rerr := nif_dl_eval_clauses(db, q, clause_idx + 1, default_moment, env, out_rows, out_envs, false, allocator)
	if bound_rhs >= 0 {
		env.bound[bound_rhs] = false
		env.vals[bound_rhs] = nil
	}
	return res, rerr
}

nif_dl_eval_pattern_moment :: proc(
	db: ^xitdb.Database,
	q: ^NIF_Datalog_Query,
	clause: ^NIF_Datalog_Clause,
	clause_idx: int,
	default_moment: i64,
	env: ^NIF_Datalog_Env,
	out_rows: ^[dynamic][]xitdb.Pull_Value,
	out_envs: ^[dynamic]NIF_Datalog_Env,
	check_only: bool,
	allocator: runtime.Allocator,
) -> (matched_any: bool, err: xitdb.Error) {
	rc := xitdb.database_root_cursor(db).read_cursor
	root_slot := xitdb.cursor_slot(rc) or_return

	if root_slot.tag != .Array_List {
		if root_slot.tag == .None {
			return false, nil
		}
		return nif_dl_eval_pattern_steps(db, q, clause, 0, rc, clause_idx, default_moment, env, out_rows, out_envs, check_only, allocator)
	}

	history := xitdb.read_array_list_init(rc) or_return
	moment_count := xitdb.array_list_count(history) or_return
	if moment_count == 0 {
		return false, nil
	}

	switch clause.moment_kind {
	case .Default_Moment:
		resolved := default_moment if default_moment >= 0 else moment_count + default_moment
		if resolved < 0 || resolved >= moment_count {
			return false, nil
		}
		mc_maybe := xitdb.array_list_get_cursor(history, resolved) or_return
		mc, ok := mc_maybe.?
		if !ok {
			return false, nil
		}
		return nif_dl_eval_pattern_steps(db, q, clause, 0, mc, clause_idx, default_moment, env, out_rows, out_envs, check_only, allocator)

	case .Literal_Moment:
		resolved := clause.moment_lit if clause.moment_lit >= 0 else moment_count + clause.moment_lit
		if resolved < 0 || resolved >= moment_count {
			return false, nil
		}
		mc_maybe := xitdb.array_list_get_cursor(history, resolved) or_return
		mc, ok := mc_maybe.?
		if !ok {
			return false, nil
		}
		return nif_dl_eval_pattern_steps(db, q, clause, 0, mc, clause_idx, default_moment, env, out_rows, out_envs, check_only, allocator)

	case .Var_Moment:
		if env.bound[clause.moment_var] {
			m_idx, ok := nif_dl_pull_val_as_i64(env.vals[clause.moment_var])
			if !ok {
				return false, nil
			}
			resolved := m_idx if m_idx >= 0 else moment_count + m_idx
			if resolved < 0 || resolved >= moment_count {
				return false, nil
			}
			mc_maybe := xitdb.array_list_get_cursor(history, resolved) or_return
			mc, has_mc := mc_maybe.?
			if !has_mc {
				return false, nil
			}
			return nif_dl_eval_pattern_steps(db, q, clause, 0, mc, clause_idx, default_moment, env, out_rows, out_envs, check_only, allocator)
		}
		v := clause.moment_var
		for m_idx: i64 = 0; m_idx < moment_count; m_idx += 1 {
			mc_maybe := xitdb.array_list_get_cursor(history, m_idx) or_return
			mc, has_mc := mc_maybe.?
			if !has_mc {
				continue
			}
			env.bound[v] = true
			env.vals[v] = m_idx
			m_matched, merr := nif_dl_eval_pattern_steps(db, q, clause, 0, mc, clause_idx, default_moment, env, out_rows, out_envs, check_only, allocator)
			env.bound[v] = false
			env.vals[v] = nil
			if merr != nil {
				return false, merr
			}
			if m_matched {
				matched_any = true
				if check_only {
					return true, nil
				}
			}
		}
		return matched_any, nil
	}
	return false, nil
}

nif_dl_eval_clauses :: proc(
	db: ^xitdb.Database,
	q: ^NIF_Datalog_Query,
	clause_idx: int,
	default_moment: i64,
	env: ^NIF_Datalog_Env,
	out_rows: ^[dynamic][]xitdb.Pull_Value,
	out_envs: ^[dynamic]NIF_Datalog_Env,
	stop_after_first: bool,
	allocator: runtime.Allocator,
) -> (matched_any: bool, err: xitdb.Error) {
	if clause_idx >= len(q.clauses) {
		if !stop_after_first {
			if q.has_aggregates && out_envs != nil {
				append(out_envs, env^)
			} else {
				row := make([]xitdb.Pull_Value, len(q.find_items), allocator)
				for item, i in q.find_items {
					row[i] = env.vals[item.var_idx]
				}
				append(out_rows, row)
			}
		}
		return true, nil
	}

	clause := &q.clauses[clause_idx]
	switch clause.kind {
	case .Predicate:
		ok_pred, bound_var := nif_dl_eval_predicate(clause, env)
		if !ok_pred {
			return false, nil
		}
		res, rerr := nif_dl_eval_clauses(db, q, clause_idx + 1, default_moment, env, out_rows, out_envs, stop_after_first, allocator)
		if bound_var >= 0 {
			env.bound[bound_var] = false
			env.vals[bound_var] = nil
		}
		return res, rerr

	case .Not_Pattern:
		neg_clause := new(NIF_Datalog_Clause, allocator)
		neg_clause^ = clause^
		neg_clause.kind = .Pattern
		neg_env := new(NIF_Datalog_Env, allocator)
		neg_env^ = env^
		has_match := nif_dl_eval_pattern_moment(db, q, neg_clause, -1, default_moment, neg_env, out_rows, out_envs, true, allocator) or_return
		if has_match {
			return false, nil
		}
		return nif_dl_eval_clauses(db, q, clause_idx + 1, default_moment, env, out_rows, out_envs, stop_after_first, allocator)

	case .Reach:
		return nif_dl_eval_reach(db, q, clause, clause_idx, default_moment, env, out_rows, out_envs, stop_after_first, allocator)

	case .Pattern:
		return nif_dl_eval_pattern_moment(db, q, clause, clause_idx, default_moment, env, out_rows, out_envs, stop_after_first, allocator)
	}
	return false, nil
}

nif_dl_compute_aggregations :: proc(q: ^NIF_Datalog_Query, envs: []NIF_Datalog_Env, allocator: runtime.Allocator) -> [][]xitdb.Pull_Value {
	buckets := make([dynamic]NIF_Datalog_Group_Bucket, 0, 8, allocator)
	has_group_keys := false
	for item in q.find_items {
		if item.agg == .None {
			has_group_keys = true
			break
		}
	}

	for env in envs {
		b_idx := -1
		for &b, i in buckets {
			same_group := true
			for item in q.find_items {
				if item.agg == .None {
					if !nif_dl_value_equals(b.key_env.vals[item.var_idx], env.vals[item.var_idx]) {
						same_group = false
						break
					}
				}
			}
			if same_group {
				b_idx = i
				break
			}
		}
		if b_idx < 0 {
			b_idx = len(buckets)
			append(&buckets, NIF_Datalog_Group_Bucket{key_env = env})
		}

		b := &buckets[b_idx]
		for item, col_i in q.find_items {
			if !env.bound[item.var_idx] {
				continue
			}
			val := env.vals[item.var_idx]
			switch item.agg {
			case .None:
			case .Count:
				b.counts[col_i] += 1
			case .Sum:
				#partial switch v in val {
				case u64:
					b.sum_u64[col_i] += v
				case i64:
					b.sum_kind[col_i] = 1
					b.sum_i64[col_i] += v
				case f64:
					b.sum_kind[col_i] = 2
					b.sum_f64[col_i] += v
				}
			case .Min:
				if !b.has_minmax[col_i] {
					b.min_vals[col_i] = val
					b.max_vals[col_i] = val
					b.has_minmax[col_i] = true
				} else if cmp, ok := nif_dl_compare_values(val, b.min_vals[col_i]); ok && cmp < 0 {
					b.min_vals[col_i] = val
				}
			case .Max:
				if !b.has_minmax[col_i] {
					b.min_vals[col_i] = val
					b.max_vals[col_i] = val
					b.has_minmax[col_i] = true
				} else if cmp, ok := nif_dl_compare_values(val, b.max_vals[col_i]); ok && cmp > 0 {
					b.max_vals[col_i] = val
				}
			}
		}
	}

	if len(buckets) == 0 && !has_group_keys {
		only_count_or_sum := true
		for item in q.find_items {
			if item.agg != .Count && item.agg != .Sum {
				only_count_or_sum = false
				break
			}
		}
		if only_count_or_sum {
			append(&buckets, NIF_Datalog_Group_Bucket{})
		}
	}

	rows := make([][]xitdb.Pull_Value, len(buckets), allocator)
	for &b, r_idx in buckets {
		row := make([]xitdb.Pull_Value, len(q.find_items), allocator)
		for item, col_i in q.find_items {
			switch item.agg {
			case .None:
				row[col_i] = b.key_env.vals[item.var_idx]
			case .Count:
				row[col_i] = b.counts[col_i]
			case .Sum:
				if b.sum_kind[col_i] == 2 {
					row[col_i] = b.sum_f64[col_i] + f64(b.sum_i64[col_i]) + f64(b.sum_u64[col_i])
				} else if b.sum_kind[col_i] == 1 {
					row[col_i] = b.sum_i64[col_i] + i64(b.sum_u64[col_i])
				} else {
					row[col_i] = b.sum_u64[col_i]
				}
			case .Min:
				row[col_i] = b.min_vals[col_i]
			case .Max:
				row[col_i] = b.max_vals[col_i]
			}
		}
		rows[r_idx] = row
	}
	return rows
}

@(export)
odin_nif_query_datalog :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 3 {
		return make_err(env, "badarg")
	}
	moment_idx: i64 = -1
	if nif_get_int64(env, argv[1], &moment_idx) == 0 {
		return make_err(env, "badarg")
	}
	query_str, ok_q := get_string_from_binary(env, argv[2])
	if !ok_q {
		return make_err(env, "badarg")
	}

	q_val, q_err := nif_dl_parse_query(query_str, context.temp_allocator)
	if q_err != "" {
		return make_err(env, q_err)
	}
	q := new(NIF_Datalog_Query, context.temp_allocator)
	q^ = q_val

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	raw_rows := make([dynamic][]xitdb.Pull_Value, 0, 8, context.temp_allocator)
	matched_envs := make([dynamic]NIF_Datalog_Env, 0, 8, context.temp_allocator)
	dl_env := new(NIF_Datalog_Env, context.temp_allocator)

	_, exec_err := nif_dl_eval_clauses(&handle.db, q, 0, moment_idx, dl_env, &raw_rows, &matched_envs, false, context.temp_allocator)
	if exec_err != nil {
		return make_xitdb_err(env, exec_err)
	}

	final_rows := raw_rows[:]
	if q.has_aggregates {
		final_rows = nif_dl_compute_aggregations(q, matched_envs[:], context.temp_allocator)
	}

	vars_terms := make([]ERL_NIF_TERM, len(q.find_items), context.temp_allocator)
	for item, idx in q.find_items {
		vars_terms[idx] = make_binary(env, item.label)
	}
	vars_list: ERL_NIF_TERM
	if len(vars_terms) == 0 {
		vars_list = nif_make_list_from_array(env, nil, 0)
	} else {
		vars_list = nif_make_list_from_array(env, raw_data(vars_terms), c.uint(len(vars_terms)))
	}

	rows_terms := make([]ERL_NIF_TERM, len(final_rows), context.temp_allocator)
	for row, r_idx in final_rows {
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

	keys := [2]ERL_NIF_TERM{ATOM_VARS, ATOM_ROWS}
	vals := [2]ERL_NIF_TERM{vars_list, rows_list}
	return make_ok(env, make_map_safe(env, keys[:], vals[:]))
}

@(export)
odin_nif_compact :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 2 {
		return make_err(env, "badarg")
	}
	target_path, ok_p := get_string_from_binary(env, argv[1])
	if !ok_p {
		return make_err(env, "badarg")
	}

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

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
	if comp_handle.rwlock == nil {
		_ = xitdb.core_destroy(&comp_handle.core, close_file = true)
		comp_handle.is_closed = true
		_ = nif_make_db_resource(env, raw_res)
		return make_err(env, "alloc_failed")
	}
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
	handle: ^Db_Handle,
	root_tag_id: i64,
	root_val_int: i64,
) -> (root_cur: xitdb.Read_Cursor, has_data: bool, err_reason: string, err: xitdb.Error) {
	slot, _, is_empty, r_err, reason := resolve_slot_arg(handle, root_tag_id, root_val_int)
	if r_err != nil {
		return {}, false, "", r_err
	}
	if reason != "" {
		return {}, false, reason, nil
	}
	if is_empty || slot.tag == .None || slot.value == 0 {
		return {}, false, "", nil
	}
	return xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = &handle.db,
	}, true, "", nil
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

// `nif_sorted_map_seek(db_ref, slot_tag_id, slot_val_int, prefix_bin, limit_int)` or
// `nif_sorted_map_seek(db_ref, slot_tag_id, slot_val_int, start_key_bin, limit_int, prefix_only_bool)` ->
// `{:ok, [{term_bin, slot_tuple}, ...], next_cursor_or_nil} | {:error, reason}`
@(export)
odin_nif_sorted_map_seek :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	arena_alloc := context.temp_allocator
	context.allocator = arena_alloc

	if argc != 5 && argc != 6 {
		return make_err(env, "badarg")
	}

	prefix_only := true
	if argc == 6 {
		if argv[5] == ATOM_TRUE {
			prefix_only = true
		} else if argv[5] == ATOM_FALSE {
			prefix_only = false
		} else {
			return make_err(env, "badarg")
		}
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

	if tag_int < 0 || tag_int > i64(xitdb.MAX_TAG_VALUE) {
		return make_err(env, "invalid_slot")
	}
	tag := xitdb.Tag(u8(tag_int))
	if tag != .Sorted_Map && tag != .None {
		return make_err(env, "unsupported")
	}

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	if val_int == 0 || tag == .None || limit_int <= 0 {
		if val_int < 0 {
			return make_err(env, "invalid_slot")
		}
		empty_list := nif_make_list_from_array(env, nil, 0)
		return nif_make_tuple3(env, ATOM_OK, empty_list, ATOM_NIL)
	}

	slot, _, _, r_err, err_reason := resolve_slot_arg(handle, tag_int, val_int)
	if r_err != nil {
		return make_xitdb_err(env, r_err)
	}
	if err_reason != "" {
		return make_err(env, err_reason)
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
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
		if prefix_only && !strings.has_prefix(k_str, prefix) {
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
	defer free_all(context.temp_allocator)
	arena_alloc := context.temp_allocator
	context.allocator = arena_alloc

	if argc != 7 {
		return make_err(env, "badarg")
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

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	root_cur, has_root, err_reason, root_err := resolve_snapshot_root_cursor(handle, root_tag_id, root_val_int)
	if root_err != nil {
		return make_xitdb_err(env, root_err)
	}
	if err_reason != "" {
		return make_err(env, err_reason)
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
