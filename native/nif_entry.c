#include <erl_nif.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static ErlNifResourceType* XITDB_RES_TYPE = NULL;

extern void odin_nif_init_atoms(ErlNifEnv* env);
extern void odin_nif_dtor(ErlNifEnv* env, void* obj);
extern ERL_NIF_TERM odin_nif_open(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM odin_nif_close(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM odin_nif_sync(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM odin_nif_info(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM odin_nif_moment_slot(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM odin_nif_slot_get_key(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM odin_nif_slot_get_index(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM odin_nif_slot_count(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM odin_nif_slot_contains(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM odin_nif_slot_slice(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM odin_nif_slot_entries(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM odin_nif_slot_materialize(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM odin_nif_transact(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM odin_nif_select(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM odin_nif_pull(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM odin_nif_diff_moments(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM odin_nif_history_of(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM odin_nif_query_datalog(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM odin_nif_compact(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM odin_nif_sorted_map_seek(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);
extern ERL_NIF_TERM odin_nif_bm25_search(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);

static void xitdb_resource_dtor(ErlNifEnv* env, void* obj) {
    odin_nif_dtor(env, obj);
}

static int nif_load(ErlNifEnv* env, void** priv_data, ERL_NIF_TERM load_info) {
    (void)priv_data;
    (void)load_info;
    XITDB_RES_TYPE = enif_open_resource_type(
        env,
        NULL,
        "xitdb_db_resource",
        xitdb_resource_dtor,
        ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER,
        NULL
    );
    if (XITDB_RES_TYPE == NULL) return -1;
    odin_nif_init_atoms(env);
    return 0;
}

static int nif_upgrade(ErlNifEnv* env, void** priv_data, void** old_priv_data, ERL_NIF_TERM load_info) {
    (void)old_priv_data;
    return nif_load(env, priv_data, load_info);
}

// Resource & RWLock helpers called from Odin
void* nif_alloc_db_resource(size_t size) {
    if (XITDB_RES_TYPE == NULL) return NULL;
    return enif_alloc_resource(XITDB_RES_TYPE, size);
}

ERL_NIF_TERM nif_make_db_resource(ErlNifEnv* env, void* obj) {
    ERL_NIF_TERM term = enif_make_resource(env, obj);
    enif_release_resource(obj);
    return term;
}

int nif_get_db_resource(ErlNifEnv* env, ERL_NIF_TERM term, void** obj_out) {
    if (XITDB_RES_TYPE == NULL) return 0;
    return enif_get_resource(env, term, XITDB_RES_TYPE, obj_out);
}

void* nif_rwlock_create(const char* name) {
    return (void*)enif_rwlock_create((char*)name);
}

void nif_rwlock_destroy(void* lock) {
    if (lock != NULL) {
        enif_rwlock_destroy((ErlNifRWLock*)lock);
    }
}

void nif_rwlock_rlock(void* lock) {
    if (lock != NULL) enif_rwlock_rlock((ErlNifRWLock*)lock);
}

void nif_rwlock_runlock(void* lock) {
    if (lock != NULL) enif_rwlock_runlock((ErlNifRWLock*)lock);
}

void nif_rwlock_rwlock(void* lock) {
    if (lock != NULL) enif_rwlock_rwlock((ErlNifRWLock*)lock);
}

void nif_rwlock_rwunlock(void* lock) {
    if (lock != NULL) enif_rwlock_rwunlock((ErlNifRWLock*)lock);
}

// Term inspection helpers
int nif_inspect_binary(ErlNifEnv* env, ERL_NIF_TERM term, const unsigned char** data_out, size_t* size_out) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, term, &bin)) return 0;
    *data_out = bin.data;
    *size_out = bin.size;
    return 1;
}

int nif_get_atom_bytes(ErlNifEnv* env, ERL_NIF_TERM term, char* buf, unsigned int buf_size, int* len_out) {
    int written = enif_get_atom(env, term, buf, buf_size, ERL_NIF_UTF8);
    if (written <= 0) return 0;
    *len_out = written - 1;
    return 1;
}

int nif_get_int64(ErlNifEnv* env, ERL_NIF_TERM term, int64_t* val_out) {
    ErlNifSInt64 v = 0;
    if (!enif_get_int64(env, term, &v)) return 0;
    *val_out = (int64_t)v;
    return 1;
}

int nif_get_uint64(ErlNifEnv* env, ERL_NIF_TERM term, uint64_t* val_out) {
    ErlNifUInt64 v = 0;
    if (!enif_get_uint64(env, term, &v)) return 0;
    *val_out = (uint64_t)v;
    return 1;
}

int nif_get_double(ErlNifEnv* env, ERL_NIF_TERM term, double* val_out) {
    return enif_get_double(env, term, val_out);
}

int nif_get_tuple(ErlNifEnv* env, ERL_NIF_TERM term, int* arity_out, const ERL_NIF_TERM** array_out) {
    return enif_get_tuple(env, term, arity_out, array_out);
}

int nif_get_list_cell(ErlNifEnv* env, ERL_NIF_TERM term, ERL_NIF_TERM* head_out, ERL_NIF_TERM* tail_out) {
    return enif_get_list_cell(env, term, head_out, tail_out);
}

int nif_get_list_length(ErlNifEnv* env, ERL_NIF_TERM term, unsigned int* len_out) {
    return enif_get_list_length(env, term, len_out);
}

int nif_is_empty_list(ErlNifEnv* env, ERL_NIF_TERM term) {
    return enif_is_empty_list(env, term);
}

int nif_is_binary(ErlNifEnv* env, ERL_NIF_TERM term) {
    return enif_is_binary(env, term);
}

int nif_is_atom(ErlNifEnv* env, ERL_NIF_TERM term) {
    return enif_is_atom(env, term);
}

int nif_is_tuple(ErlNifEnv* env, ERL_NIF_TERM term) {
    return enif_is_tuple(env, term);
}

int nif_is_list(ErlNifEnv* env, ERL_NIF_TERM term) {
    return enif_is_list(env, term);
}

int nif_is_map(ErlNifEnv* env, ERL_NIF_TERM term) {
    return enif_is_map(env, term);
}

int nif_get_map_value(ErlNifEnv* env, ERL_NIF_TERM map, ERL_NIF_TERM key, ERL_NIF_TERM* val_out) {
    return enif_get_map_value(env, map, key, val_out);
}

// Term creation helpers
ERL_NIF_TERM nif_make_atom_len(ErlNifEnv* env, const char* name, size_t len) {
    return enif_make_atom_len(env, name, len);
}

ERL_NIF_TERM nif_make_int64(ErlNifEnv* env, int64_t val) {
    return enif_make_int64(env, (ErlNifSInt64)val);
}

ERL_NIF_TERM nif_make_uint64(ErlNifEnv* env, uint64_t val) {
    return enif_make_uint64(env, (ErlNifUInt64)val);
}

ERL_NIF_TERM nif_make_double(ErlNifEnv* env, double val) {
    return enif_make_double(env, val);
}

ERL_NIF_TERM nif_make_binary_slice(ErlNifEnv* env, const unsigned char* src, size_t len) {
    ERL_NIF_TERM term;
    unsigned char* dst = enif_make_new_binary(env, len, &term);
    if (len > 0 && src != NULL && dst != NULL) {
        memcpy(dst, src, len);
    }
    return term;
}

ERL_NIF_TERM nif_make_tuple2(ErlNifEnv* env, ERL_NIF_TERM e1, ERL_NIF_TERM e2) {
    return enif_make_tuple2(env, e1, e2);
}

ERL_NIF_TERM nif_make_tuple3(ErlNifEnv* env, ERL_NIF_TERM e1, ERL_NIF_TERM e2, ERL_NIF_TERM e3) {
    return enif_make_tuple3(env, e1, e2, e3);
}

ERL_NIF_TERM nif_make_tuple4(ErlNifEnv* env, ERL_NIF_TERM e1, ERL_NIF_TERM e2, ERL_NIF_TERM e3, ERL_NIF_TERM e4) {
    return enif_make_tuple4(env, e1, e2, e3, e4);
}

ERL_NIF_TERM nif_make_tuple5(ErlNifEnv* env, ERL_NIF_TERM e1, ERL_NIF_TERM e2, ERL_NIF_TERM e3, ERL_NIF_TERM e4, ERL_NIF_TERM e5) {
    return enif_make_tuple5(env, e1, e2, e3, e4, e5);
}

ERL_NIF_TERM nif_make_list_from_array(ErlNifEnv* env, const ERL_NIF_TERM* arr, unsigned int cnt) {
    return enif_make_list_from_array(env, arr, cnt);
}

int nif_make_map_from_arrays(ErlNifEnv* env, ERL_NIF_TERM* keys, ERL_NIF_TERM* vals, size_t cnt, ERL_NIF_TERM* map_out) {
    return enif_make_map_from_arrays(env, keys, vals, cnt, map_out);
}

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
    {"nif_sorted_map_seek",  6, odin_nif_sorted_map_seek,  ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_bm25_search",      7, odin_nif_bm25_search,      ERL_NIF_DIRTY_JOB_CPU_BOUND}
};

ERL_NIF_INIT(Elixir.Xitdb.NIF, nif_funcs, nif_load, NULL, nif_upgrade, NULL)
