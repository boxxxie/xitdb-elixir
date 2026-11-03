package xitdb_client_benchmarks

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import xitdb "xitdb:."

MAX_RUNS :: 64

Bench_Record :: struct {
	rank:       int,
	name:       string,
	ops:        int,
	bytes_used: i64,
	samples_ns: [MAX_RUNS]f64,
	runs:       int,
}

g_runs: int = 5
g_warmup: int = 1
g_commit_sha: string = "unknown"
g_run_id: string = "run-0"
g_jsonl_path: string = "benchmarks/odin.jsonl"
g_history_path: string = "benchmarks/history.jsonl"
g_records: [dynamic]Bench_Record

resolve_git_commit :: proc(allocator := context.allocator) -> string {
	head_bytes, err := os.read_entire_file(".git/HEAD", allocator)
	if err != nil {
		return "unknown"
	}
	head_str := strings.trim_space(string(head_bytes))
	if strings.has_prefix(head_str, "ref: ") {
		ref_rel := strings.trim_space(head_str[5:])
		ref_path := fmt.aprintf(".git/%s", ref_rel, allocator = allocator)
		if ref_bytes, r_err := os.read_entire_file(ref_path, allocator); r_err == nil {
			sha := strings.trim_space(string(ref_bytes))
			if len(sha) > 12 {
				return sha[:12]
			}
			return sha
		}
		return "unknown"
	}
	if len(head_str) > 12 {
		return head_str[:12]
	}
	return head_str
}

calc_percentile :: proc(sorted: []f64, p: f64) -> f64 {
	n := len(sorted)
	if n == 0 {
		return 0
	}
	if n == 1 {
		return sorted[0]
	}
	pos := p * f64(n - 1)
	lo := int(math.floor(pos))
	hi := min(lo + 1, n - 1)
	frac := pos - f64(lo)
	return sorted[lo] + frac * (sorted[hi] - sorted[lo])
}

emit_jsonl :: proc() {
	sb := strings.builder_make(context.temp_allocator)
	for rec in g_records {
		samples := make([]f64, rec.runs, context.temp_allocator)
		for i in 0 ..< rec.runs {
			samples[i] = rec.samples_ns[i]
		}
		slice.sort(samples)
		min_ns := samples[0]
		max_ns := samples[len(samples) - 1]
		med_ns := calc_percentile(samples, 0.50)
		q1_ns := calc_percentile(samples, 0.25)
		q3_ns := calc_percentile(samples, 0.75)
		iqr_ns := q3_ns - q1_ns
		p95_ns := calc_percentile(samples, 0.95)
		p99_ns := calc_percentile(samples, 0.99)

		sum_ns: f64 = 0
		for s in samples {
			sum_ns += s
		}
		mean_ns := sum_ns / f64(rec.runs)
		var_ns2: f64 = 0
		if rec.runs > 1 {
			for s in samples {
				d := s - mean_ns
				var_ns2 += d * d
			}
			var_ns2 /= f64(rec.runs - 1)
		}
		stddev_ns := math.sqrt(var_ns2)
		cv_pct := (stddev_ns / max(mean_ns, 1e-9)) * 100.0
		total_ms := (med_ns * f64(max(rec.ops, 1))) / 1e6
		ops_per_sec := i64(math.round(1e9 / max(med_ns, 1.0)))

		fmt.sbprintf(
			&sb,
			"{{\"rank\":%d,\"lang\":\"odin\",\"commit\":\"%s\",\"run_id\":\"%s\",\"name\":\"%s\",\"ops\":%d,\"runs\":%d,\"warmup\":%d,\"total_ms\":%.3f,\"ns_per_op\":%d,\"mean_ns\":%.2f,\"median_ns\":%.2f,\"stddev_ns\":%.2f,\"variance_ns2\":%.2f,\"cv_pct\":%.2f,\"min_ns\":%d,\"max_ns\":%d,\"iqr_ns\":%.2f,\"p95_ns\":%d,\"p99_ns\":%d,\"ops_per_sec\":%d,\"bytes_used\":%d,\"samples_ns\":[",
			rec.rank,
			g_commit_sha,
			g_run_id,
			rec.name,
			rec.ops,
			rec.runs,
			g_warmup,
			total_ms,
			i64(math.round(med_ns)),
			mean_ns,
			med_ns,
			stddev_ns,
			var_ns2,
			cv_pct,
			i64(math.round(min_ns)),
			i64(math.round(max_ns)),
			iqr_ns,
			i64(math.round(p95_ns)),
			i64(math.round(p99_ns)),
			ops_per_sec,
			rec.bytes_used,
		)
		for i in 0 ..< rec.runs {
			if i > 0 {
				strings.write_byte(&sb, ',')
			}
			fmt.sbprintf(&sb, "%d", i64(math.round(rec.samples_ns[i])))
		}
		strings.write_string(&sb, "]}\n")
	}

	payload := strings.to_string(sb)
	_ = os.write_entire_file(g_jsonl_path, transmute([]u8)payload)

	if hist_f, err := os.open(g_history_path, {.Write, .Create, .Append}, os.Permissions_Default_File); err == nil {
		_, _ = os.write_string(hist_f, payload)
		_ = os.close(hist_f)
	}
}

record_samples :: proc(rank: int, name: string, ops: int, samples: [MAX_RUNS]f64, bytes_used: i64 = 0) {
	rec := Bench_Record{
		rank       = rank,
		name       = name,
		ops        = ops,
		bytes_used = bytes_used,
		samples_ns = samples,
		runs       = g_runs,
	}
	append(&g_records, rec)
	fmt.printf("  [Odin #%02d] %-56s %8.0f ns/op\n", rank, name, samples[0])
}

run_bench :: proc(rank: int, name: string, ops: int, fn: proc() -> (time.Duration, i64)) {
	for _ in 0 ..< g_warmup {
		_, _ = fn()
		free_all(context.temp_allocator)
	}
	samples: [MAX_RUNS]f64
	max_bytes: i64 = 0
	for r in 0 ..< g_runs {
		dur, bytes := fn()
		samples[r] = f64(time.duration_nanoseconds(dur)) / f64(max(ops, 1))
		if bytes > max_bytes {
			max_bytes = bytes
		}
		free_all(context.temp_allocator)
	}
	record_samples(rank, name, ops, samples, max_bytes)
}

seed_fixture_db :: proc(core: ^xitdb.Core, db: ^xitdb.Database, n: int) {
	tx := xitdb.tx_init(db, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
	defer xitdb.tx_destroy(&tx)
	xitdb.tx_index_on(&tx, "users", "username", "username->id")

	for i in 0 ..< n {
		uid := fmt.tprintf("u%d", i)
		uname := fmt.tprintf("user_%04d", i)
		dept := "eng" if i % 2 == 0 else "design"
		_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.name", uid), uname)
		_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.username", uid), uname)
		_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.dept", uid), dept)
		_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.age", uid), u64(20 + (i % 40)))
		_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.roles[0]", uid), "member")
		_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.roles[1]", uid), "builder")
		_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.profile.city", uid), "Montreal")
		_ = xitdb.tx_put(&tx, fmt.tprintf(".counted_users#%s", uid), uname)
		_ = xitdb.tx_put(&tx, fmt.tprintf(".sorted_users$%s", uid), uname)
		_ = xitdb.tx_put(&tx, fmt.tprintf(".counted_set#%s%s", "%", uid), uid)
		_ = xitdb.tx_put(&tx, fmt.tprintf(".items[%d]", i), uname)
		_ = xitdb.tx_put(&tx, fmt.tprintf(".linked[[%d]]", i), uname)
	}
	rep, _ := xitdb.tx_commit(&tx)
	xitdb.tx_report_destroy(&rep, context.temp_allocator)
}

main :: proc() {
	g_commit_sha = resolve_git_commit()
	unix_sec := i64(time.to_unix_nanoseconds(time.now())) / 1_000_000_000
	g_run_id = fmt.aprintf("run-%d", unix_sec)

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		if (args[i] == "--runs" || args[i] == "-runs") && i + 1 < len(args) {
			if v, ok := strconv.parse_int(args[i + 1]); ok && v > 0 {
				g_runs = clamp(v, 1, MAX_RUNS)
			}
			i += 1
		}
	}

	g_records = make([dynamic]Bench_Record, 0, 24)

	// Shared fixture DB for read/query benchmarks (N=500)
	core := xitdb.core_memory_init()
	defer xitdb.core_destroy(&core)
	db, _ := xitdb.database_init(&core, xitdb.sha1_hasher())
	seed_fixture_db(&core, &db, 500)

	rc := xitdb.database_root_cursor(&db).read_cursor
	hist, _ := xitdb.read_array_list_init(rc)
	m0_cur_maybe, _ := xitdb.array_list_get_cursor(hist, 0)
	m0_cur := m0_cur_maybe.?
	m0_map, _ := xitdb.read_hash_map_init(m0_cur)

	users_cur_maybe, _ := xitdb.hash_map_get_cursor(m0_map, "users")
	users_map, _ := xitdb.read_hash_map_init(users_cur_maybe.?)
	sorted_cur_maybe, _ := xitdb.hash_map_get_cursor(m0_map, "sorted_users")
	sorted_map, _ := xitdb.read_sorted_map_init(sorted_cur_maybe.?)
	items_cur_maybe, _ := xitdb.hash_map_get_cursor(m0_map, "items")
	items_al, _ := xitdb.read_array_list_init(items_cur_maybe.?)
	linked_cur_maybe, _ := xitdb.hash_map_get_cursor(m0_map, "linked")
	linked_ll, _ := xitdb.read_linked_array_list_init(linked_cur_maybe.?)
	cusers_cur_maybe, _ := xitdb.hash_map_get_cursor(m0_map, "counted_users")
	cusers_chm, _ := xitdb.read_counted_hash_map_init(cusers_cur_maybe.?)
	cset_cur_maybe, _ := xitdb.hash_map_get_cursor(m0_map, "counted_set")
	cset_chs, _ := xitdb.read_counted_hash_set_init(cset_cur_maybe.?)

	samples: [MAX_RUNS]f64

	// #1: 3-hop lazy HAMT lookup
	for r in 0 ..< (g_warmup + g_runs) {
		t0 := time.now()
		for i in 0 ..< 500 {
			uid := fmt.tprintf("u%d", i)
			u_cur, _ := xitdb.hash_map_get_cursor(m0_map, "users")
			um, _ := xitdb.read_hash_map_init(u_cur.?)
			id_cur, _ := xitdb.hash_map_get_cursor(um, uid)
			idm, _ := xitdb.read_hash_map_init(id_cur.?)
			n_cur, _ := xitdb.hash_map_get_cursor(idm, "name")
			_, _ = xitdb.cursor_read_string(n_cur.?, 0, context.temp_allocator)
		}
		if r >= g_warmup {
			samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 500.0
		}
		free_all(context.temp_allocator)
	}
	record_samples(1, "Access: 3-hop lazy HAMT lookup (root[users][id][name])", 500, samples)

	// #2: Single-call selector
	for r in 0 ..< (g_warmup + g_runs) {
		t0 := time.now()
		for i in 0 ..< 500 {
			sel := fmt.tprintf("@-1.users.u%d.name", i)
			_, _ = xitdb.get_string(&db, sel, context.temp_allocator)
		}
		if r >= g_warmup {
			samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 500.0
		}
		free_all(context.temp_allocator)
	}
	record_samples(2, "Access: Single-call selector select(.users.<id>.name)", 500, samples)

	// #3: Sorted_Map B+Tree key lookup
	for r in 0 ..< (g_warmup + g_runs) {
		t0 := time.now()
		for i in 0 ..< 500 {
			uid := fmt.tprintf("u%d", i)
			vc, _ := xitdb.sorted_map_get_cursor(sorted_map, uid)
			_, _ = xitdb.cursor_read_string(vc.?, 0, context.temp_allocator)
		}
		if r >= g_warmup {
			samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 500.0
		}
		free_all(context.temp_allocator)
	}
	record_samples(3, "Access: Sorted_Map B+Tree key lookup (sorted[key])", 500, samples)

	// #4: Array_List random index lookup
	for r in 0 ..< (g_warmup + g_runs) {
		t0 := time.now()
		for i in 0 ..< 500 {
			ec, _ := xitdb.array_list_get_cursor(items_al, i64((i * 37) % 500))
			_, _ = xitdb.cursor_read_string(ec.?, 0, context.temp_allocator)
		}
		if r >= g_warmup {
			samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 500.0
		}
		free_all(context.temp_allocator)
	}
	record_samples(4, "Access: Array_List random index lookup (items[idx])", 500, samples)

	// #5: Linked_Array_List random index lookup
	for r in 0 ..< (g_warmup + g_runs) {
		t0 := time.now()
		for i in 0 ..< 500 {
			ec, _ := xitdb.linked_array_list_get_cursor(linked_ll, i64((i * 37) % 500))
			_, _ = xitdb.cursor_read_string(ec.?, 0, context.temp_allocator)
		}
		if r >= g_warmup {
			samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 500.0
		}
		free_all(context.temp_allocator)
	}
	record_samples(5, "Access: Linked_Array_List random index lookup (linked[idx])", 500, samples)

	// #6: O(1) Counted_Hash_Map count
	for r in 0 ..< (g_warmup + g_runs) {
		t0 := time.now()
		for _ in 0 ..< 1000 {
			_, _ = xitdb.counted_hash_map_count(cusers_chm)
		}
		if r >= g_warmup {
			samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 1000.0
		}
	}
	record_samples(6, "Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)", 1000, samples)

	// #7: O(1) Counted_Hash_Set membership check
	for r in 0 ..< (g_warmup + g_runs) {
		t0 := time.now()
		for i in 0 ..< 1000 {
			uid := fmt.tprintf("u%d", i % 500)
			_, _ = xitdb.hash_set_get_slot(cset_chs.read_hash_set, uid)
		}
		if r >= g_warmup {
			samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 1000.0
		}
		free_all(context.temp_allocator)
	}
	record_samples(7, "Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)", 1000, samples)

	// #8: O(log N) Enum.slice window
	for r in 0 ..< (g_warmup + g_runs) {
		t0 := time.now()
		for _ in 0 ..< 200 {
			it, _ := xitdb.cursor_iterator_array_list_from_index(items_al.cursor, 200)
			for _ in 0 ..< 20 {
				nm, _ := xitdb.cursor_iterator_next(&it)
				if ec, ok := nm.?; ok {
					_, _ = xitdb.cursor_read_string(ec, 0, context.temp_allocator)
				}
			}
		}
		if r >= g_warmup {
			samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 200.0
		}
		free_all(context.temp_allocator)
	}
	record_samples(8, "Enum: O(log N) Enum.slice/2 window (offset 200, len 20)", 200, samples)

	// #9: Lazy Stream.take(10) early-halt on Sorted_Map (N=500)
	for r in 0 ..< (g_warmup + g_runs) {
		t0 := time.now()
		for _ in 0 ..< 200 {
			it, _ := xitdb.sorted_map_iterator(sorted_map)
			for _ in 0 ..< 10 {
				nm, _ := xitdb.cursor_iterator_next(&it)
				kv_cur, ok := nm.?
				if !ok {
					break
				}
				kv, _ := xitdb.cursor_read_kv_pair(kv_cur, context.temp_allocator)
				_, _ = xitdb.cursor_read_string(kv.key_cursor, 0, context.temp_allocator)
				_, _ = xitdb.cursor_read_string(kv.value_cursor, 0, context.temp_allocator)
			}
		}
		if r >= g_warmup {
			samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 200.0
		}
		free_all(context.temp_allocator)
	}
	record_samples(9, "Stream: Lazy Stream.take(10) early-halt on Sorted_Map", 200, samples)

	// #10: Full Enum.to_list stream over Array_List (N=500)
	for r in 0 ..< (g_warmup + g_runs) {
		t0 := time.now()
		it, _ := xitdb.array_list_iterator(items_al)
		for {
			nm, _ := xitdb.cursor_iterator_next(&it)
			ec, ok := nm.?
			if !ok {
				break
			}
			_, _ = xitdb.cursor_read_string(ec, 0, context.temp_allocator)
		}
		if r >= g_warmup {
			samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 500.0
		}
		free_all(context.temp_allocator)
	}
	record_samples(10, "Enum: Full Enum.to_list/1 stream over Array_List (N=500)", 500, samples)

	// #11: Subtree materialize (nested user profile)
	u0_cur_maybe, _ := xitdb.hash_map_get_cursor(users_map, "u0")
	u0_cur := u0_cur_maybe.?
	for r in 0 ..< (g_warmup + g_runs) {
		t0 := time.now()
		for _ in 0 ..< 200 {
			_, _ = xitdb.pull(u0_cur, "*", context.temp_allocator)
		}
		if r >= g_warmup {
			samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 200.0
		}
		free_all(context.temp_allocator)
	}
	record_samples(11, "Materialize: Eager subtree materialize/1 (user profile)", 200, samples)

	// #12: Single nested entity transact commit
	run_bench(12, "Tx: Single nested entity transact commit (6 attributes)", 100, proc() -> (time.Duration, i64) {
		c := xitdb.core_memory_init()
		defer xitdb.core_destroy(&c)
		d, _ := xitdb.database_init(&c, xitdb.sha1_hasher())
		t0 := time.now()
		for i in 0 ..< 100 {
			tx := xitdb.tx_init(&d, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
			uid := fmt.tprintf("u%d", i)
			_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.name", uid), "Alice")
			_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.age", uid), u64(30))
			_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.dept", uid), "eng")
			_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.city", uid), "Montreal")
			_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.roles[0]", uid), "admin")
			_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.roles[1]", uid), "staff")
			rep, _ := xitdb.tx_commit(&tx)
			xitdb.tx_report_destroy(&rep, context.temp_allocator)
			xitdb.tx_destroy(&tx)
		}
		dur := time.since(t0)
		sz, _ := xitdb.core_length(&c)
		return dur, sz
	})

	// #13: Bulk batch transact (100 entities in 1 commit)
	run_bench(13, "Tx: Bulk batch transact (100 entities in 1 commit)", 100, proc() -> (time.Duration, i64) {
		c := xitdb.core_memory_init()
		defer xitdb.core_destroy(&c)
		d, _ := xitdb.database_init(&c, xitdb.sha1_hasher())
		t0 := time.now()
		tx := xitdb.tx_init(&d, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
		for i in 0 ..< 100 {
			uid := fmt.tprintf("u%d", i)
			_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.name", uid), "Alice")
			_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.age", uid), u64(30))
			_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.dept", uid), "eng")
		}
		rep, _ := xitdb.tx_commit(&tx)
		xitdb.tx_report_destroy(&rep, context.temp_allocator)
		xitdb.tx_destroy(&tx)
		dur := time.since(t0)
		sz, _ := xitdb.core_length(&c)
		return dur, sz
	})

	// #14: Incremental put_in nested attribute commit
	run_bench(14, "Tx: Incremental put_in nested attribute commit", 100, proc() -> (time.Duration, i64) {
		c := xitdb.core_memory_init()
		defer xitdb.core_destroy(&c)
		d, _ := xitdb.database_init(&c, xitdb.sha1_hasher())
		tx0 := xitdb.tx_init(&d, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
		_ = xitdb.tx_put(&tx0, ".users.alice.score", u64(0))
		r0, _ := xitdb.tx_commit(&tx0)
		xitdb.tx_report_destroy(&r0, context.temp_allocator)
		xitdb.tx_destroy(&tx0)

		t0 := time.now()
		for i in 1 ..= 100 {
			tx := xitdb.tx_init(&d, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
			_ = xitdb.tx_put(&tx, ".users.alice.score", u64(i))
			rep, _ := xitdb.tx_commit(&tx)
			xitdb.tx_report_destroy(&rep, context.temp_allocator)
			xitdb.tx_destroy(&tx)
		}
		dur := time.since(t0)
		sz, _ := xitdb.core_length(&c)
		return dur, sz
	})

	// #15: Linked_Array_List O(log N) mid-list insert_at + delete_at
	run_bench(15, "Tx: Linked_Array_List O(log N) mid-list insert + delete", 50, proc() -> (time.Duration, i64) {
		c := xitdb.core_memory_init()
		defer xitdb.core_destroy(&c)
		d, _ := xitdb.database_init(&c, xitdb.sha1_hasher())
		tx0 := xitdb.tx_init(&d, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
		for i in 0 ..< 500 {
			_ = xitdb.tx_put(&tx0, fmt.tprintf(".linked[[%d]]", i), fmt.tprintf("item_%d", i))
		}
		r0, _ := xitdb.tx_commit(&tx0)
		xitdb.tx_report_destroy(&r0, context.temp_allocator)
		xitdb.tx_destroy(&tx0)

		t0 := time.now()
		for i in 0 ..< 50 {
			tx := xitdb.tx_init(&d, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
			_ = xitdb.tx_insert(&tx, ".linked", 250, fmt.tprintf("mid_%d", i))
			_ = xitdb.tx_rm(&tx, ".linked[[250]]")
			rep, _ := xitdb.tx_commit(&tx)
			xitdb.tx_report_destroy(&rep, context.temp_allocator)
			xitdb.tx_destroy(&tx)
		}
		dur := time.since(t0)
		sz, _ := xitdb.core_length(&c)
		return dur, sz
	})

	// #16: O(1) zero-copy subtree fork (500 entities)
	max_fork_bytes: i64 = 0
	for r in 0 ..< (g_warmup + g_runs) {
		c := xitdb.core_memory_init()
		d, _ := xitdb.database_init(&c, xitdb.sha1_hasher())
		seed_fixture_db(&c, &d, 500)
		t0 := time.now()
		for i in 0 ..< 100 {
			tx := xitdb.tx_init(&d, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
			_ = xitdb.tx_fork(&tx, ".users", fmt.tprintf(".users_clone_%d", i))
			rep, _ := xitdb.tx_commit(&tx)
			xitdb.tx_report_destroy(&rep, context.temp_allocator)
			xitdb.tx_destroy(&tx)
		}
		dur := time.since(t0)
		sz, _ := xitdb.core_length(&c)
		if r >= g_warmup {
			samples[r - g_warmup] = f64(time.duration_nanoseconds(dur)) / 100.0
			if sz > max_fork_bytes {
				max_fork_bytes = sz
			}
		}
		xitdb.core_destroy(&c)
		free_all(context.temp_allocator)
	}
	record_samples(16, "Tx: O(1) zero-copy subtree fork (500 entities)", 100, samples, max_fork_bytes)

	// Shared 100-moment history DB for #17 (as_of across 100 moments), #18 (history_of), and #20 (compact)
	hist_core := xitdb.core_memory_init()
	defer xitdb.core_destroy(&hist_core)
	hist_db, _ := xitdb.database_init(&hist_core, xitdb.sha1_hasher())
	for i in 0 ..< 100 {
		tx := xitdb.tx_init(&hist_db, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
		_ = xitdb.tx_put(&tx, ".users.alice.score", u64(i))
		_ = xitdb.tx_put(&tx, ".users.bob.score", u64(1000))
		rep, _ := xitdb.tx_commit(&tx)
		xitdb.tx_report_destroy(&rep, context.temp_allocator)
		xitdb.tx_destroy(&tx)
	}
	hist_rc := xitdb.database_root_cursor(&hist_db).read_cursor
	hist_al, _ := xitdb.read_array_list_init(hist_rc)

	// #17: Time-Travel as_of(db, moment) across 100 distinct historical moments
	for r in 0 ..< (g_warmup + g_runs) {
		t0 := time.now()
		for m in 0 ..< 100 {
			mc, _ := xitdb.array_list_get_cursor(hist_al, i64(m))
			mm, _ := xitdb.read_hash_map_init(mc.?)
			uc, _ := xitdb.hash_map_get_cursor(mm, "users")
			um, _ := xitdb.read_hash_map_init(uc.?)
			ac, _ := xitdb.hash_map_get_cursor(um, "alice")
			am, _ := xitdb.read_hash_map_init(ac.?)
			sc, _ := xitdb.hash_map_get_cursor(am, "score")
			_, _ = xitdb.cursor_read_uint(sc.?)
		}
		if r >= g_warmup {
			samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 100.0
		}
		free_all(context.temp_allocator)
	}
	record_samples(17, "Time-Travel: Historical as_of(db, m) across 100 moments", 100, samples)

	// #18: Time-Travel history_of(db, selector) lineage across 100 moments
	for r in 0 ..< (g_warmup + g_runs) {
		t0 := time.now()
		for _ in 0 ..< 50 {
			_, _ = xitdb.history_of(&hist_db, ".users.alice.score", context.temp_allocator)
		}
		if r >= g_warmup {
			samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 50.0
		}
		free_all(context.temp_allocator)
	}
	record_samples(18, "Time-Travel: history_of(db, selector) (100 moments)", 50, samples)

	// #19: diff_moments (1 of 200 entities mutated)
	diff_core := xitdb.core_memory_init()
	defer xitdb.core_destroy(&diff_core)
	diff_db, _ := xitdb.database_init(&diff_core, xitdb.sha1_hasher())
	seed_fixture_db(&diff_core, &diff_db, 200)
	tx_mut := xitdb.tx_init(&diff_db, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
	_ = xitdb.tx_put(&tx_mut, ".users.u42.age", u64(99))
	rep_mut, _ := xitdb.tx_commit(&tx_mut)
	xitdb.tx_report_destroy(&rep_mut, context.temp_allocator)
	xitdb.tx_destroy(&tx_mut)

	for r in 0 ..< (g_warmup + g_runs) {
		t0 := time.now()
		for _ in 0 ..< 50 {
			_, _ = xitdb.diff_moments(&diff_db, 0, 1, false, context.temp_allocator)
		}
		if r >= g_warmup {
			samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 50.0
		}
		free_all(context.temp_allocator)
	}
	record_samples(19, "Time-Travel: diff_moments (1 of 200 entities mutated)", 50, samples)

	// #20: compact/1 100-moment database deduplication
	compact_bytes: i64 = 0
	for r in 0 ..< (g_warmup + g_runs) {
		t0 := time.now()
		for _ in 0 ..< 20 {
			target_core := xitdb.core_memory_init()
			_, _ = xitdb.database_compact(&hist_db, &target_core)
			sz, _ := xitdb.core_length(&target_core)
			if sz > compact_bytes {
				compact_bytes = sz
			}
			xitdb.core_destroy(&target_core)
		}
		if r >= g_warmup {
			samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 20.0
		}
		free_all(context.temp_allocator)
	}
	record_samples(20, "Lifecycle: compact/1 100-moment database deduplication", 20, samples, compact_bytes)

	// #21: Datomic pull projection
	for r in 0 ..< (g_warmup + g_runs) {
		t0 := time.now()
		for i in 0 ..< 200 {
			uid := fmt.tprintf("u%d", i)
			uc, _ := xitdb.hash_map_get_cursor(users_map, uid)
			_, _ = xitdb.pull(uc.?, "{name, age, roles[0..2], profile{city}}", context.temp_allocator)
		}
		if r >= g_warmup {
			samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 200.0
		}
		free_all(context.temp_allocator)
	}
	record_samples(21, "Query: Datomic pull projection (4 attrs + nested slice)", 200, samples)

	// #22: Datalog B+Tree index prefix + join
	q_prefix := `
		find ?name, ?age
		where
			$username->id[?name] = ?id
			starts_with(?name, "user_001")
			.users[?id].age = ?age
			.users[?id].dept = "eng"
	`
	for r in 0 ..< (g_warmup + g_runs) {
		t0 := time.now()
		for _ in 0 ..< 50 {
			_, _ = xitdb.query_datalog(&diff_db, q_prefix, -1, context.temp_allocator)
		}
		if r >= g_warmup {
			samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 50.0
		}
		free_all(context.temp_allocator)
	}
	record_samples(22, "Query: Datalog B+Tree index prefix + join (N=200)", 50, samples)

	// #23: Datalog grouped aggregation (count + sum, N=200)
	q_agg := `
		find ?dept, count(?id), sum(?age)
		where
			.users[?id].dept = ?dept
			.users[?id].age = ?age
	`
	for r in 0 ..< (g_warmup + g_runs) {
		t0 := time.now()
		for _ in 0 ..< 50 {
			_, _ = xitdb.query_datalog(&diff_db, q_agg, -1, context.temp_allocator)
		}
		if r >= g_warmup {
			samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 50.0
		}
		free_all(context.temp_allocator)
	}
	record_samples(23, "Query: Datalog grouped aggregation (count + sum, N=200)", 50, samples)

	// #24: Storage: Buffered_File transact + sync (50 commits)
	run_bench(24, "Storage: Buffered_File transact + sync (50 commits)", 50, proc() -> (time.Duration, i64) {
		tmp_path := fmt.tprintf("/tmp/xitdb_bench_odin_%d.xit", time.to_unix_nanoseconds(time.now()))
		defer os.remove(tmp_path)
		c, _ := xitdb.core_buffered_file_open(tmp_path)
		defer xitdb.core_destroy(&c)
		d, _ := xitdb.database_init(&c, xitdb.sha1_hasher())
		t0 := time.now()
		for i in 0 ..< 50 {
			tx := xitdb.tx_init(&d, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
			_ = xitdb.tx_put(&tx, fmt.tprintf(".events.e%d", i), u64(i))
			rep, _ := xitdb.tx_commit(&tx)
			xitdb.tx_report_destroy(&rep, context.temp_allocator)
			xitdb.tx_destroy(&tx)
		}
		_ = xitdb.core_sync(&c)
		dur := time.since(t0)
		sz, _ := xitdb.core_length(&c)
		return dur, sz
	})

	emit_jsonl()
}
