package xitdb_client_benchmarks

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import xitdb "xitdb:."

MAX_RUNS        :: 64
MAX_TOTAL_RANKS :: 32

Bench_Record :: struct {
	rank:       int,
	name:       string,
	ops:        int,
	bytes_used: i64,
	samples_ns: [MAX_RUNS]f64,
	runs:       int,
}

g_runs:           int = 5
g_warmup:         int = 1
g_commit_sha:     string = "unknown"
g_run_id:         string = "run-0"
g_append_primary: bool = false
g_save_history:   bool = true
g_jsonl_path:     string = "benchmarks/odin.jsonl"
g_history_path:   string = "benchmarks/history.jsonl"
g_groups_filter:  string = ""
g_name_filter:    string = ""
g_records:        [dynamic]Bench_Record

g_selective_run:  bool = false
g_existing_lines: [MAX_TOTAL_RANKS]string
g_updated_lines:  [MAX_TOTAL_RANKS]string

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
		if packed_bytes, p_err := os.read_entire_file(".git/packed-refs", allocator); p_err == nil {
			lines := strings.split_lines(string(packed_bytes), allocator)
			suffix := fmt.aprintf(" %s", ref_rel, allocator = allocator)
			for line in lines {
				trimmed := strings.trim_space(line)
				if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") || strings.has_prefix(trimmed, "^") {
					continue
				}
				if strings.has_suffix(trimmed, suffix) && len(trimmed) >= 12 {
					return trimmed[:12]
				}
			}
		}
		return "unknown"
	}
	if len(head_str) > 12 {
		return head_str[:12]
	}
	return head_str
}

parse_cli_args :: proc() {
	g_commit_sha = resolve_git_commit()
	unix_sec := i64(time.to_unix_nanoseconds(time.now())) / 1_000_000_000
	g_run_id = fmt.aprintf("run-%d", unix_sec)

	args := os.args[1:]
	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--append" || arg == "-append" {
			g_append_primary = true
		} else if arg == "--no-history" || arg == "-no-history" {
			g_save_history = false
		} else if (arg == "--runs" || arg == "-runs") && i + 1 < len(args) {
			if v, ok := strconv.parse_int(args[i + 1]); ok && v > 0 {
				g_runs = clamp(v, 1, MAX_RUNS)
			}
			i += 1
		} else if strings.has_prefix(arg, "--runs=") || strings.has_prefix(arg, "-runs:") {
			eq := strings.index_any(arg, "=:")
			if v, ok := strconv.parse_int(arg[eq + 1:]); ok && v > 0 {
				g_runs = clamp(v, 1, MAX_RUNS)
			}
		} else if (arg == "--warmup" || arg == "-warmup") && i + 1 < len(args) {
			if v, ok := strconv.parse_int(args[i + 1]); ok && v >= 0 {
				g_warmup = v
			}
			i += 1
		} else if strings.has_prefix(arg, "--warmup=") || strings.has_prefix(arg, "-warmup:") {
			eq := strings.index_any(arg, "=:")
			if v, ok := strconv.parse_int(arg[eq + 1:]); ok && v >= 0 {
				g_warmup = v
			}
		} else if (arg == "--commit" || arg == "-commit") && i + 1 < len(args) {
			g_commit_sha = args[i + 1]
			i += 1
		} else if strings.has_prefix(arg, "--commit=") || strings.has_prefix(arg, "-commit:") {
			eq := strings.index_any(arg, "=:")
			g_commit_sha = arg[eq + 1:]
		} else if (arg == "--run-id" || arg == "-run-id") && i + 1 < len(args) {
			g_run_id = args[i + 1]
			i += 1
		} else if strings.has_prefix(arg, "--run-id=") || strings.has_prefix(arg, "-run-id:") {
			eq := strings.index_any(arg, "=:")
			g_run_id = arg[eq + 1:]
		} else if (arg == "--output" || arg == "-output") && i + 1 < len(args) {
			g_jsonl_path = args[i + 1]
			i += 1
		} else if strings.has_prefix(arg, "--output=") || strings.has_prefix(arg, "-output:") {
			eq := strings.index_any(arg, "=:")
			g_jsonl_path = arg[eq + 1:]
		} else if (arg == "--history" || arg == "-history") && i + 1 < len(args) {
			g_history_path = args[i + 1]
			i += 1
		} else if strings.has_prefix(arg, "--history=") || strings.has_prefix(arg, "-history:") {
			eq := strings.index_any(arg, "=:")
			g_history_path = arg[eq + 1:]
		} else if (arg == "--groups" || arg == "-groups" || arg == "--group" || arg == "-group") && i + 1 < len(args) {
			g_groups_filter = args[i + 1]
			i += 1
		} else if strings.has_prefix(arg, "--groups=") || strings.has_prefix(arg, "-groups:") || strings.has_prefix(arg, "--group=") || strings.has_prefix(arg, "-group:") {
			eq := strings.index_any(arg, "=:")
			g_groups_filter = arg[eq + 1:]
		} else if (arg == "--filter" || arg == "-filter") && i + 1 < len(args) {
			g_name_filter = args[i + 1]
			i += 1
		} else if strings.has_prefix(arg, "--filter=") || strings.has_prefix(arg, "-filter:") {
			eq := strings.index_any(arg, "=:")
			g_name_filter = arg[eq + 1:]
		}
		i += 1
	}
	g_selective_run = (len(g_groups_filter) > 0 && g_groups_filter != "all") || len(g_name_filter) > 0
}

rank_group :: proc(rank: int) -> string {
	switch {
	case rank >= 1 && rank <= 5:
		return "access"
	case rank >= 6 && rank <= 11:
		return "enumerable"
	case rank >= 12 && rank <= 16:
		return "transactions"
	case rank >= 17 && rank <= 20:
		return "time_travel"
	case rank >= 21 && rank <= 26:
		return "queries"
	case:
		return "unknown"
	}
}

should_run_group :: proc(group_name: string) -> bool {
	if len(g_groups_filter) == 0 || g_groups_filter == "all" {
		return true
	}
	parts := strings.split_multi(g_groups_filter, {",", "|"}, context.temp_allocator)
	for raw_p in parts {
		p := strings.to_lower(strings.trim_space(raw_p), context.temp_allocator)
		if len(p) == 0 do continue
		if p == "all" || p == group_name {
			return true
		}
		if (p == "enum" || p == "stream" || p == "materialize") && group_name == "enumerable" {
			return true
		}
		if (p == "tx" || p == "transaction") && group_name == "transactions" {
			return true
		}
		if (p == "time-travel" || p == "timetravel" || p == "history" || p == "lifecycle" || p == "compact" || p == "compaction") && group_name == "time_travel" {
			return true
		}
		if (p == "query" || p == "search" || p == "storage" || p == "datalog" || p == "pull" || p == "bm25") && group_name == "queries" {
			return true
		}
	}
	return false
}

matches_name_filter :: proc(bench_name: string) -> bool {
	if len(g_name_filter) == 0 {
		return true
	}
	lower_name := strings.to_lower(bench_name, context.temp_allocator)
	parts := strings.split_multi(g_name_filter, {"|", ","}, context.temp_allocator)
	for raw_p in parts {
		p := strings.to_lower(strings.trim_space(raw_p), context.temp_allocator)
		if len(p) > 0 && strings.contains(lower_name, p) {
			return true
		}
	}
	return false
}

should_run_bench :: proc(rank: int, bench_name: string) -> bool {
	return should_run_group(rank_group(rank)) && matches_name_filter(bench_name)
}

load_existing_jsonl_ranks :: proc(path: string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return
	lines := strings.split_lines(string(data), context.allocator)
	prefix :: "{\"rank\":"
	for raw_line in lines {
		line := strings.trim_space(raw_line)
		if !strings.has_prefix(line, prefix) do continue
		rest := line[len(prefix):]
		comma := strings.index_byte(rest, ',')
		if comma <= 0 do continue
		if r, ok := strconv.parse_int(rest[:comma]); ok && r >= 1 && r < MAX_TOTAL_RANKS {
			g_existing_lines[r] = fmt.aprintf("%s\n", line)
		}
	}
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
	if len(g_records) == 0 {
		return
	}

	new_sb := strings.builder_make(context.temp_allocator)
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

		line_sb := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(
			&line_sb,
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
				strings.write_byte(&line_sb, ',')
			}
			fmt.sbprintf(&line_sb, "%d", i64(math.round(rec.samples_ns[i])))
		}
		strings.write_string(&line_sb, "]}\n")

		line_str := strings.to_string(line_sb)
		strings.write_string(&new_sb, line_str)
		if rec.rank >= 1 && rec.rank < MAX_TOTAL_RANKS {
			g_updated_lines[rec.rank] = strings.clone(line_str, context.allocator)
		}
	}

	new_payload := strings.to_string(new_sb)

	if g_append_primary {
		if f, err := os.open(g_jsonl_path, {.Write, .Create, .Append}, os.Permissions_Default_File); err == nil {
			_, _ = os.write_string(f, new_payload)
			_ = os.close(f)
		}
	} else if g_selective_run {
		load_existing_jsonl_ranks(g_jsonl_path)
		merged_sb := strings.builder_make(context.temp_allocator)
		for r in 1 ..< MAX_TOTAL_RANKS {
			if len(g_updated_lines[r]) > 0 {
				strings.write_string(&merged_sb, g_updated_lines[r])
			} else if len(g_existing_lines[r]) > 0 {
				strings.write_string(&merged_sb, g_existing_lines[r])
			}
		}
		merged_payload := strings.to_string(merged_sb)
		_ = os.write_entire_file(g_jsonl_path, transmute([]u8)merged_payload)
	} else {
		_ = os.write_entire_file(g_jsonl_path, transmute([]u8)new_payload)
	}

	if g_save_history {
		if hist_f, err := os.open(g_history_path, {.Write, .Create, .Append}, os.Permissions_Default_File); err == nil {
			_, _ = os.write_string(hist_f, new_payload)
			_ = os.close(hist_f)
		}
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
	sorted := make([]f64, g_runs, context.temp_allocator)
	for i in 0 ..< g_runs {
		sorted[i] = samples[i]
	}
	slice.sort(sorted)
	med := calc_percentile(sorted, 0.50)
	fmt.printf("  [Odin #%02d] %-56s %8.0f ns/op\n", rank, name, med)
}

run_bench :: proc(rank: int, name: string, ops: int, fn: proc() -> (time.Duration, i64)) {
	if !should_run_bench(rank, name) {
		return
	}
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

BENCH_BM25_WEIGHT_SCALE :: 100.0

Bench_BM25_Hit :: struct {
	doc_key: string,
	score:   f64,
}

bench_bm25_hit_better :: #force_inline proc(a, b: Bench_BM25_Hit) -> bool {
	if a.score != b.score {
		return a.score > b.score
	}
	return a.doc_key < b.doc_key
}

bench_bm25_hit_worse :: #force_inline proc(a, b: Bench_BM25_Hit) -> bool {
	return bench_bm25_hit_better(b, a)
}

bench_bm25_heap_push :: proc(heap: ^[dynamic]Bench_BM25_Hit, item: Bench_BM25_Hit, k: int) {
	if len(heap^) < k {
		append(heap, item)
		idx := len(heap^) - 1
		for idx > 0 {
			parent := (idx - 1) / 2
			if bench_bm25_hit_worse(heap[idx], heap[parent]) {
				heap[idx], heap[parent] = heap[parent], heap[idx]
				idx = parent
			} else {
				break
			}
		}
		return
	}
	if k > 0 && bench_bm25_hit_better(item, heap[0]) {
		heap[0] = item
		n := len(heap^)
		idx := 0
		for {
			left := 2*idx + 1
			right := 2*idx + 2
			worst := idx
			if left < n && bench_bm25_hit_worse(heap[left], heap[worst]) {
				worst = left
			}
			if right < n && bench_bm25_hit_worse(heap[right], heap[worst]) {
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

bench_read_arena_string :: proc(cur: xitdb.Read_Cursor, alloc: mem.Allocator) -> string {
	slot_ptr, _ := xitdb.cursor_resolved(cur)
	if slot_ptr.slot.tag == .Short_Bytes && !slot_ptr.slot.full {
		sb_buf: [8]u8 = ---
		b_obj, _ := xitdb.cursor_read_bytes_buf(cur, sb_buf[:])
		return strings.clone(string(b_obj.value), alloc)
	}
	s, _ := xitdb.cursor_read_string(cur, 0, alloc)
	return s
}

bench_read_nonneg_int :: proc(hm: xitdb.Read_Hash_Map, key: string) -> i64 {
	cm, _ := xitdb.hash_map_get_cursor(hm, key)
	cur, ok := cm.?
	if !ok {
		return 0
	}
	sp, _ := xitdb.cursor_resolved(cur)
	if sp.slot.tag == .Uint {
		u, _ := xitdb.cursor_read_uint(cur)
		return i64(u)
	}
	if sp.slot.tag == .Int {
		v, _ := xitdb.cursor_read_int(cur)
		return max(v, 0)
	}
	return 0
}

seed_bm25_fixture_db :: proc(db: ^xitdb.Database, n: int) {
	nord_variants := [?]string{"nordic", "north", "nordstrom"}
	cap_variants := [?]string{"capital", "captain", "cap", "capsule"}
	extra_terms := [?]string{"equity", "growth", "market", "credit", "buyout", "zurich", "london", "tokyo"}

	tx := xitdb.tx_init(db, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
	defer xitdb.tx_destroy(&tx)

	total_len: u64 = 0
	for i in 0 ..< n {
		doc_key := fmt.tprintf("%d", i + 1)
		t1 := nord_variants[i % len(nord_variants)]
		t2 := cap_variants[i % len(cap_variants)]
		t3 := extra_terms[i % len(extra_terms)]

		_ = xitdb.tx_put(&tx, fmt.tprintf(".idx.search.articles.docs.%s.len", doc_key), u64(600))
		_ = xitdb.tx_put(&tx, fmt.tprintf(".idx.search.articles.terms$%s.%s", t1, doc_key), u64(300))
		_ = xitdb.tx_put(&tx, fmt.tprintf(".idx.search.articles.terms$%s.%s", t2, doc_key), u64(200))
		_ = xitdb.tx_put(&tx, fmt.tprintf(".idx.search.articles.terms$%s.%s", t3, doc_key), u64(100))
		total_len += 600
	}
	_ = xitdb.tx_put(&tx, ".idx.search.articles.meta.doc_count", u64(n))
	_ = xitdb.tx_put(&tx, ".idx.search.articles.meta.total_len", total_len)

	rep, _ := xitdb.tx_commit(&tx)
	xitdb.tx_report_destroy(&rep, context.temp_allocator)
}

bench_raw_bm25_search :: proc(root_map: xitdb.Read_Hash_Map, collection: string, query_terms: []string, k_limit: int, allocator := context.temp_allocator) -> []Bench_BM25_Hit {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(
		&arena,
		block_allocator = runtime.default_allocator(),
		array_allocator = runtime.default_allocator(),
	)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	idx_c, _ := xitdb.hash_map_get_cursor(root_map, "idx")
	idx_m, _ := xitdb.read_hash_map_init(idx_c.?)
	search_c, _ := xitdb.hash_map_get_cursor(idx_m, "search")
	search_m, _ := xitdb.read_hash_map_init(search_c.?)
	col_c, _ := xitdb.hash_map_get_cursor(search_m, collection)
	col_m, _ := xitdb.read_hash_map_init(col_c.?)

	meta_c, _ := xitdb.hash_map_get_cursor(col_m, "meta")
	meta_m, _ := xitdb.read_hash_map_init(meta_c.?)
	doc_count := bench_read_nonneg_int(meta_m, "doc_count")
	total_len := bench_read_nonneg_int(meta_m, "total_len")

	docs_c, _ := xitdb.hash_map_get_cursor(col_m, "docs")
	docs_m, _ := xitdb.read_hash_map_init(docs_c.?)
	terms_c, _ := xitdb.hash_map_get_cursor(col_m, "terms")
	terms_sm, _ := xitdb.read_sorted_map_init(terms_c.?)

	num_tokens := len(query_terms)
	token_postings := make([]map[string]f64, num_tokens, alloc)
	idfs := make([]f64, num_tokens, alloc)
	sb_buf: [8]u8 = ---

	for q_tok, tok_idx in query_terms {
		merged := make(map[string]f64, 32, alloc)
		if utf8.rune_count_in_string(q_tok) >= 3 {
			it, _ := xitdb.sorted_map_iterator_from_string(terms_sm, q_tok)
			scanned := 0
			for scanned < 64 {
				nm, _ := xitdb.cursor_iterator_next(&it)
				elem_c, has_next := nm.?
				if !has_next {
					break
				}
				kv, _ := xitdb.cursor_read_kv_pair(elem_c, alloc)
				matched := bench_read_arena_string(kv.key_cursor, alloc)
				if !strings.has_prefix(matched, q_tok) {
					break
				}
				mult := 1.25 if matched == q_tok else 1.0
				pit, _ := xitdb.cursor_iterator(kv.value_cursor)
				for {
					pnm, _ := xitdb.cursor_iterator_next(&pit)
					pelem, ph := pnm.?
					if !ph {
						break
					}
					pkv, _ := xitdb.cursor_read_kv_pair(pelem, alloc)
					dk := bench_read_arena_string(pkv.key_cursor, alloc)
					if dk == "__tx" {
						continue
					}
					vsp, _ := xitdb.cursor_resolved(pkv.value_cursor)
					raw_tf: i64 = 0
					if vsp.slot.tag == .Uint {
						u, _ := xitdb.cursor_read_uint(pkv.value_cursor)
						raw_tf = i64(u)
					} else if vsp.slot.tag == .Int {
						iv, _ := xitdb.cursor_read_int(pkv.value_cursor)
						raw_tf = iv
					}
					if raw_tf > 0 {
						tf := (f64(raw_tf) / BENCH_BM25_WEIGHT_SCALE) * mult
						merged[dk] = merged[dk] + tf
					}
				}
				scanned += 1
			}
		} else {
			_ = sb_buf
		}
		df := f64(len(merged))
		idfs[tok_idx] = math.ln(1.0 + (f64(doc_count) - df + 0.5) / (df + 0.5))
		token_postings[tok_idx] = merged
	}

	candidates := make([dynamic]string, 0, 64, alloc)
	smallest_idx := 0
	for i in 1 ..< num_tokens {
		if len(token_postings[i]) < len(token_postings[smallest_idx]) {
			smallest_idx = i
		}
	}
	for dk in token_postings[smallest_idx] {
		in_all := true
		for i in 0 ..< num_tokens {
			if i != smallest_idx && dk not_in token_postings[i] {
				in_all = false
				break
			}
		}
		if in_all {
			append(&candidates, dk)
		}
	}

	avg_dl := max((f64(total_len) / BENCH_BM25_WEIGHT_SCALE) / f64(doc_count), 1.0e-6)
	top_heap := make([dynamic]Bench_BM25_Hit, 0, min(len(candidates), k_limit), alloc)
	for dk in candidates {
		dm, _ := xitdb.hash_map_get_cursor(docs_m, dk)
		raw_len: i64 = 0
		if dc, hd := dm.?; hd {
			dem, _ := xitdb.read_hash_map_init(dc)
			raw_len = bench_read_nonneg_int(dem, "len")
		}
		dl := f64(raw_len) / BENCH_BM25_WEIGHT_SCALE
		norm := 1.2 * (1.0 - 0.75 + 0.75 * (dl / avg_dl))
		score: f64 = 0.0
		for i in 0 ..< num_tokens {
			if tf, ok_tf := token_postings[i][dk]; ok_tf && tf > 0.0 {
				score += idfs[i] * (tf * 2.2) / (tf + norm)
			}
		}
		if score > 0.0 {
			bench_bm25_heap_push(&top_heap, Bench_BM25_Hit{doc_key = dk, score = score}, k_limit)
		}
	}
	slice.sort_by(top_heap[:], bench_bm25_hit_better)
	out := make([]Bench_BM25_Hit, len(top_heap), allocator)
	for hit, idx in top_heap {
		out[idx] = Bench_BM25_Hit{
			doc_key = strings.clone(hit.doc_key, allocator),
			score   = hit.score,
		}
	}
	return out
}

Bench_Single_Entity_Ctx :: struct {
	uid: string,
}

bench_single_entity_cb :: proc(moment_cur: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	ctx := (^Bench_Single_Entity_Ctx)(user_data)
	moment_hm := xitdb.write_hash_map_init(moment_cur^) or_return
	users_cur := xitdb.hash_map_put_cursor(&moment_hm, "users") or_return
	users_hm := xitdb.write_hash_map_init(users_cur) or_return
	u_cur := xitdb.hash_map_put_cursor(&users_hm, ctx.uid) or_return
	u_hm := xitdb.write_hash_map_init(u_cur) or_return
	xitdb.hash_map_put(&u_hm, "name", "Alice") or_return
	xitdb.hash_map_put(&u_hm, "age", u64(30)) or_return
	xitdb.hash_map_put(&u_hm, "dept", "eng") or_return
	xitdb.hash_map_put(&u_hm, "city", "Montreal") or_return
	roles_cur := xitdb.hash_map_put_cursor(&u_hm, "roles") or_return
	xitdb.cursor_write(&roles_cur, xitdb.Slot{}) or_return
	roles_al := xitdb.write_array_list_init(roles_cur) or_return
	xitdb.array_list_append(&roles_al, "admin") or_return
	xitdb.array_list_append(&roles_al, "staff") or_return
	return nil
}

bench_bulk_entities_cb :: proc(moment_cur: ^xitdb.Write_Cursor, _user_data: rawptr) -> xitdb.Error {
	moment_hm := xitdb.write_hash_map_init(moment_cur^) or_return
	users_cur := xitdb.hash_map_put_cursor(&moment_hm, "users") or_return
	users_hm := xitdb.write_hash_map_init(users_cur) or_return
	for i in 0 ..< 100 {
		uid := fmt.tprintf("u%d", i)
		u_cur := xitdb.hash_map_put_cursor(&users_hm, uid) or_return
		u_hm := xitdb.write_hash_map_init(u_cur) or_return
		xitdb.hash_map_put(&u_hm, "name", "Alice") or_return
		xitdb.hash_map_put(&u_hm, "age", u64(30)) or_return
		xitdb.hash_map_put(&u_hm, "dept", "eng") or_return
	}
	return nil
}

main :: proc() {
	parse_cli_args()
	g_records = make([dynamic]Bench_Record, 0, 26)

	r1 := should_run_bench(1, "Access: 3-hop lazy HAMT lookup (root[users][id][name])")
	r2 := should_run_bench(2, "Access: Single-call selector select(.users.<id>.name)")
	r3 := should_run_bench(3, "Access: Sorted_Map B+Tree key lookup (sorted[key])")
	r4 := should_run_bench(4, "Access: Array_List random index lookup (items[idx])")
	r5 := should_run_bench(5, "Access: Linked_Array_List random index lookup (linked[idx])")
	r6 := should_run_bench(6, "Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)")
	r7 := should_run_bench(7, "Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)")
	r8 := should_run_bench(8, "Enum: O(log N) Enum.slice/2 window (offset 200, len 20)")
	r9 := should_run_bench(9, "Stream: Lazy Stream.take(10) early-halt on Sorted_Map")
	r10 := should_run_bench(10, "Enum: Full Enum.to_list/1 stream over Array_List (N=500)")
	r11 := should_run_bench(11, "Materialize: Eager subtree materialize/1 (user profile)")
	r16 := should_run_bench(16, "Tx: O(1) zero-copy subtree fork (500 entities)")
	r17 := should_run_bench(17, "Time-Travel: Historical as_of(db, m) across 100 moments")
	r18 := should_run_bench(18, "Time-Travel: history_of(db, selector) (100 moments)")
	r19 := should_run_bench(19, "Time-Travel: diff_moments (1 of 200 entities mutated)")
	r20 := should_run_bench(20, "Lifecycle: compact/1 100-moment database deduplication")
	r21 := should_run_bench(21, "Query: Datomic pull projection (4 attrs + nested slice)")
	r22 := should_run_bench(22, "Query: Datalog B+Tree index prefix + join (N=200)")
	r23 := should_run_bench(23, "Query: Datalog grouped aggregation (count + sum, N=200)")
	r25 := should_run_bench(25, "Search: Sorted_Map B+Tree prefix seek (limit=16)")
	r26 := should_run_bench(26, "Search: BM25 corpus search (N=200, 2-term prefix, limit=10)")

	need_main_db := r1 || r2 || r3 || r4 || r5 || r6 || r7 || r8 || r9 || r10 || r11 || r21 || r25
	need_hist_db := r17 || r18 || r20
	need_diff_db := r19 || r22 || r23
	need_search_db := r26

	// Shared fixture DB for read/query benchmarks (N=500)
	core: xitdb.Core
	db: xitdb.Database
	m0_map: xitdb.Read_Hash_Map
	users_map: xitdb.Read_Hash_Map
	sorted_map: xitdb.Read_Sorted_Map
	items_al: xitdb.Read_Array_List
	linked_ll: xitdb.Read_Linked_Array_List
	cusers_chm: xitdb.Read_Counted_Hash_Map
	cset_chs: xitdb.Read_Counted_Hash_Set
	defer if need_main_db {
		xitdb.core_destroy(&core)
	}
	if need_main_db {
		core = xitdb.core_memory_init()
		db, _ = xitdb.database_init(&core, xitdb.sha1_hasher())
		seed_fixture_db(&core, &db, 500)

		rc := xitdb.database_root_cursor(&db).read_cursor
		hist, _ := xitdb.read_array_list_init(rc)
		m0_cur_maybe, _ := xitdb.array_list_get_cursor(hist, 0)
		m0_cur := m0_cur_maybe.?
		m0_map, _ = xitdb.read_hash_map_init(m0_cur)

		users_cur_maybe, _ := xitdb.hash_map_get_cursor(m0_map, "users")
		users_map, _ = xitdb.read_hash_map_init(users_cur_maybe.?)
		sorted_cur_maybe, _ := xitdb.hash_map_get_cursor(m0_map, "sorted_users")
		sorted_map, _ = xitdb.read_sorted_map_init(sorted_cur_maybe.?)
		items_cur_maybe, _ := xitdb.hash_map_get_cursor(m0_map, "items")
		items_al, _ = xitdb.read_array_list_init(items_cur_maybe.?)
		linked_cur_maybe, _ := xitdb.hash_map_get_cursor(m0_map, "linked")
		linked_ll, _ = xitdb.read_linked_array_list_init(linked_cur_maybe.?)
		cusers_cur_maybe, _ := xitdb.hash_map_get_cursor(m0_map, "counted_users")
		cusers_chm, _ = xitdb.read_counted_hash_map_init(cusers_cur_maybe.?)
		cset_cur_maybe, _ := xitdb.hash_map_get_cursor(m0_map, "counted_set")
		cset_chs, _ = xitdb.read_counted_hash_set_init(cset_cur_maybe.?)
	}

	samples: [MAX_RUNS]f64

	// #1: 3-hop lazy HAMT lookup
	if r1 {
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
	}

	// #2: Single-call selector
	if r2 {
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
	}

	// #3: Sorted_Map B+Tree key lookup
	if r3 {
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
	}

	// #4: Array_List random index lookup
	if r4 {
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
	}

	// #5: Linked_Array_List random index lookup
	if r5 {
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
	}

	// #6: O(1) Counted_Hash_Map count
	if r6 {
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
	}

	// #7: O(1) Counted_Hash_Set membership check
	if r7 {
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
	}

	// #8: O(log N) Enum.slice window
	if r8 {
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
	}

	// #9: Lazy Stream.take(10) early-halt on Sorted_Map (N=500)
	if r9 {
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
	}

	// #10: Full Enum.to_list stream over Array_List (N=500)
	if r10 {
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for _ in 0 ..< 50 {
				it, _ := xitdb.array_list_iterator(items_al)
				for {
					nm, _ := xitdb.cursor_iterator_next(&it)
					ec, ok := nm.?
					if !ok {
						break
					}
					_, _ = xitdb.cursor_read_string(ec, 0, context.temp_allocator)
				}
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 50.0
			}
			free_all(context.temp_allocator)
		}
		record_samples(10, "Enum: Full Enum.to_list/1 stream over Array_List (N=500)", 50, samples)
	}

	// #11: Subtree materialize (nested user profile)
	if r11 {
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
	}

	// #12: Single nested entity transact commit
	run_bench(12, "Tx: Single nested entity transact commit (6 attributes)", 100, proc() -> (time.Duration, i64) {
		c := xitdb.core_memory_init()
		defer xitdb.core_destroy(&c)
		d, _ := xitdb.database_init(&c, xitdb.sha1_hasher())
		t0 := time.now()
		for i in 0 ..< 100 {
			tx := xitdb.tx_init(&d, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
			ctx := Bench_Single_Entity_Ctx{uid = fmt.tprintf("u%d", i)}
			xitdb.tx_with_cursor(&tx, bench_single_entity_cb, &ctx)
			rep, _ := xitdb.tx_commit(&tx)
			xitdb.tx_report_destroy(&rep, context.temp_allocator)
			xitdb.tx_destroy(&tx)
		}
		dur := time.since(t0)
		sz, _ := xitdb.core_length(&c)
		return dur, sz
	})

	// #13: Bulk batch transact (100 entities in 1 commit)
	run_bench(13, "Tx: Bulk batch transact (100 entities in 1 commit)", 1, proc() -> (time.Duration, i64) {
		c := xitdb.core_memory_init()
		defer xitdb.core_destroy(&c)
		d, _ := xitdb.database_init(&c, xitdb.sha1_hasher())
		t0 := time.now()
		tx := xitdb.tx_init(&d, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
		xitdb.tx_with_cursor(&tx, bench_bulk_entities_cb)
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
	if r16 {
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
	}

	// Shared 100-moment history DB for #17 (as_of across 100 moments), #18 (history_of), and #20 (compact)
	hist_core: xitdb.Core
	hist_db: xitdb.Database
	hist_al: xitdb.Read_Array_List
	defer if need_hist_db {
		xitdb.core_destroy(&hist_core)
	}
	if need_hist_db {
		hist_core = xitdb.core_memory_init()
		hist_db, _ = xitdb.database_init(&hist_core, xitdb.sha1_hasher())
		for i in 0 ..< 100 {
			tx := xitdb.tx_init(&hist_db, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
			_ = xitdb.tx_put(&tx, ".users.alice.score", u64(i))
			_ = xitdb.tx_put(&tx, ".users.bob.score", u64(1000))
			rep, _ := xitdb.tx_commit(&tx)
			xitdb.tx_report_destroy(&rep, context.temp_allocator)
			xitdb.tx_destroy(&tx)
		}
		hist_rc := xitdb.database_root_cursor(&hist_db).read_cursor
		hist_al, _ = xitdb.read_array_list_init(hist_rc)
	}

	// #17: Time-Travel as_of(db, moment) across 100 distinct historical moments
	if r17 {
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
	}

	// #18: Time-Travel history_of(db, selector) lineage across 100 moments
	if r18 {
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
	}

	// Shared 200-entity diff DB for #19 (diff_moments), #22 (Datalog prefix), #23 (Datalog agg)
	diff_core: xitdb.Core
	diff_db: xitdb.Database
	defer if need_diff_db {
		xitdb.core_destroy(&diff_core)
	}
	if need_diff_db {
		diff_core = xitdb.core_memory_init()
		diff_db, _ = xitdb.database_init(&diff_core, xitdb.sha1_hasher())
		seed_fixture_db(&diff_core, &diff_db, 200)
		tx_mut := xitdb.tx_init(&diff_db, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
		_ = xitdb.tx_put(&tx_mut, ".users.u42.age", u64(99))
		rep_mut, _ := xitdb.tx_commit(&tx_mut)
		xitdb.tx_report_destroy(&rep_mut, context.temp_allocator)
		xitdb.tx_destroy(&tx_mut)
	}

	// #19: diff_moments (1 of 200 entities mutated)
	if r19 {
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
	}

	// #20: compact/1 100-moment database deduplication
	if r20 {
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
	}

	// #21: Datomic pull projection
	if r21 {
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
	}

	// #22: Datalog B+Tree index prefix + join
	if r22 {
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
	}

	// #23: Datalog grouped aggregation (count + sum, N=200)
	if r23 {
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
	}

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

	// #25: Search: Sorted_Map B+Tree prefix seek (limit=16)
	if r25 {
		sb_seek: [8]u8 = ---
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for _ in 0 ..< 100 {
				it, _ := xitdb.sorted_map_iterator_from_string(sorted_map, "u4")
				cnt := 0
				for cnt < 16 {
					nm, _ := xitdb.cursor_iterator_next(&it)
					ec, hn := nm.?
					if !hn {
						break
					}
					kv, _ := xitdb.cursor_read_kv_pair(ec, context.temp_allocator)
					sp, _ := xitdb.cursor_resolved(kv.key_cursor)
					ks: string
					if sp.slot.tag == .Short_Bytes && !sp.slot.full {
						bo, _ := xitdb.cursor_read_bytes_buf(kv.key_cursor, sb_seek[:])
						ks = string(bo.value)
					} else {
						ks, _ = xitdb.cursor_read_string(kv.key_cursor, 0, context.temp_allocator)
					}
					if !strings.has_prefix(ks, "u4") {
						break
					}
					_, _ = xitdb.cursor_slot(kv.value_cursor)
					cnt += 1
				}
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 100.0
			}
			free_all(context.temp_allocator)
		}
		record_samples(25, "Search: Sorted_Map B+Tree prefix seek (limit=16)", 100, samples)
	}

	// #26: Search: BM25 corpus search (N=200, 2-term prefix, limit=10)
	search_core: xitdb.Core
	search_db: xitdb.Database
	defer if need_search_db {
		xitdb.core_destroy(&search_core)
	}
	if need_search_db {
		search_core = xitdb.core_memory_init()
		search_db, _ = xitdb.database_init(&search_core, xitdb.sha1_hasher())
		seed_bm25_fixture_db(&search_db, 200)
	}
	if r26 {
		s_rc := xitdb.database_root_cursor(&search_db).read_cursor
		s_hist, _ := xitdb.read_array_list_init(s_rc)
		s_m0_cur, _ := xitdb.array_list_get_cursor(s_hist, 0)
		s_m0_map, _ := xitdb.read_hash_map_init(s_m0_cur.?)
		bm25_q := [2]string{"nord", "cap"}
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for _ in 0 ..< 50 {
				_ = bench_raw_bm25_search(s_m0_map, "articles", bm25_q[:], 10)
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 50.0
			}
			free_all(context.temp_allocator)
		}
		record_samples(26, "Search: BM25 corpus search (N=200, 2-term prefix, limit=10)", 50, samples)
	}

	emit_jsonl()
}
