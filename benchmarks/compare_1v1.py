#!/usr/bin/env python3
"""
Statistical Benchmark Runner, Multi-Run Aggregator & Commit Regression Analyzer
for Xitdb Elixir Client (Elixir Wrapper vs Raw Odin).

Features:
- Multi-sample variance tracking (Mean, Median/p50, StdDev, Variance, CV%, Min/Max, IQR, p95, p99)
- Pools multiple runs associated with the same (commit, lang, benchmark) from JSONL history
- 1v1 Comparison (Elixir Wrapper vs Raw Odin) with Welch's z-score significance
- Commit-vs-Commit regression comparison (--compare-commits <SHA_A> <SHA_B>)
- Commit & Run history inspection (--list-commits, --inspect <pattern>)
- Code-change-to-benchmark mapping (--plan, --affected)
"""

import argparse
import json
import math
import os
import re
import subprocess
import sys
import time
from collections import defaultdict
from typing import Any, Dict, List, Optional, Set, Tuple

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BENCH_DIR = os.path.join(ROOT_DIR, "benchmarks")
SLICES_DIR = os.path.join(BENCH_DIR, "slices")
LIB_DIR = os.path.join(ROOT_DIR, "lib")
NATIVE_DIR = os.path.join(ROOT_DIR, "native")
ODIN_LIB_DIR = os.path.join(NATIVE_DIR, "xitdb-odin", "xitdb")
NIF_ODIN_PATH = os.path.join(NATIVE_DIR, "xitdb_nif.odin")
BENCH_ELIXIR_PATH = os.path.join(BENCH_DIR, "bench_elixir.exs")
BENCH_ODIN_PATH = os.path.join(BENCH_DIR, "bench_client.odin")
ODIN_JSONL = os.path.join(BENCH_DIR, "odin.jsonl")
ELIXIR_JSONL = os.path.join(BENCH_DIR, "elixir.jsonl")
HISTORY_JSONL = os.path.join(BENCH_DIR, "history.jsonl")

ALL_GROUPS = ["access", "enumerable", "transactions", "time_travel", "queries"]

GROUP_RANGES = {
    "access": "#1–#5 (Lazy Access Navigation & Point Lookups)",
    "enumerable": "#6–#11 (Enumerable Protocol & Subtree Materialization)",
    "transactions": "#12–#16 (Transactions, Incremental Put, List Edit & Zero-Copy Fork)",
    "time_travel": "#17–#20 (Historical as_of, history_of, diff_moments & Compaction)",
    "queries": "#21–#26 (Pull Projections, Datalog Engine, Buffered Sync & Search)",
}

BENCHMARK_CATALOG: List[Dict[str, Any]] = [
    {
        "rank": 1,
        "group": "access",
        "name": "Access: 3-hop lazy HAMT lookup (root[users][id][name])",
        "elixir_entries": [("lib/xitdb/cursor.ex", "fetch"), ("lib/xitdb/cursor.ex", "nif_slot_get")],
        "nif_entries": ["odin_nif_slot_get_key"],
    },
    {
        "rank": 2,
        "group": "access",
        "name": "Access: Single-call selector select(.users.<id>.name)",
        "elixir_entries": [("lib/xitdb.ex", "select!"), ("lib/xitdb.ex", "select"), ("lib/xitdb.ex", "do_select")],
        "nif_entries": ["odin_nif_select"],
    },
    {
        "rank": 3,
        "group": "access",
        "name": "Access: Sorted_Map B+Tree key lookup (sorted[key])",
        "elixir_entries": [("lib/xitdb/cursor.ex", "fetch"), ("lib/xitdb/cursor.ex", "nif_slot_get")],
        "nif_entries": ["odin_nif_slot_get_key"],
    },
    {
        "rank": 4,
        "group": "access",
        "name": "Access: Array_List random index lookup (items[idx])",
        "elixir_entries": [("lib/xitdb/cursor.ex", "fetch"), ("lib/xitdb/cursor.ex", "nif_slot_get")],
        "nif_entries": ["odin_nif_slot_get_index"],
    },
    {
        "rank": 5,
        "group": "access",
        "name": "Access: Linked_Array_List random index lookup (linked[idx])",
        "elixir_entries": [("lib/xitdb/cursor.ex", "fetch"), ("lib/xitdb/cursor.ex", "nif_slot_get")],
        "nif_entries": ["odin_nif_slot_get_index"],
    },
    {
        "rank": 6,
        "group": "enumerable",
        "name": "Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)",
        "elixir_entries": [("lib/xitdb/cursor.ex", "count")],
        "nif_entries": ["odin_nif_slot_count"],
    },
    {
        "rank": 7,
        "group": "enumerable",
        "name": "Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)",
        "elixir_entries": [("lib/xitdb/cursor.ex", "member?")],
        "nif_entries": ["odin_nif_slot_contains"],
    },
    {
        "rank": 8,
        "group": "enumerable",
        "name": "Enum: O(log N) Enum.slice/2 window (offset 200, len 20)",
        "elixir_entries": [("lib/xitdb/cursor.ex", "slice")],
        "nif_entries": ["odin_nif_slot_slice"],
    },
    {
        "rank": 9,
        "group": "enumerable",
        "name": "Stream: Lazy Stream.take(10) early-halt on Sorted_Map",
        "elixir_entries": [("lib/xitdb/cursor.ex", "reduce"), ("lib/xitdb/cursor.ex", "do_reduce")],
        "nif_entries": ["odin_nif_slot_entries"],
    },
    {
        "rank": 10,
        "group": "enumerable",
        "name": "Enum: Full Enum.to_list/1 stream over Array_List (N=500)",
        "elixir_entries": [("lib/xitdb/cursor.ex", "reduce"), ("lib/xitdb/cursor.ex", "do_reduce")],
        "nif_entries": ["odin_nif_slot_entries"],
    },
    {
        "rank": 11,
        "group": "enumerable",
        "name": "Materialize: Eager subtree materialize/1 (user profile)",
        "elixir_entries": [("lib/xitdb.ex", "materialize")],
        "nif_entries": ["odin_nif_slot_materialize"],
    },
    {
        "rank": 12,
        "group": "transactions",
        "name": "Tx: Single nested entity transact commit (6 attributes)",
        "elixir_entries": [("lib/xitdb.ex", "transact"), ("lib/xitdb/tx_compiler.ex", "compile_moment_map")],
        "nif_entries": ["odin_nif_transact"],
    },
    {
        "rank": 13,
        "group": "transactions",
        "name": "Tx: Bulk batch transact (100 entities in 1 commit)",
        "elixir_entries": [("lib/xitdb.ex", "transact"), ("lib/xitdb/tx_compiler.ex", "compile_moment_map")],
        "nif_entries": ["odin_nif_transact"],
    },
    {
        "rank": 14,
        "group": "transactions",
        "name": "Tx: Incremental put_in nested attribute commit",
        "elixir_entries": [("lib/xitdb.ex", "transact"), ("lib/xitdb/cursor.ex", "get_and_update")],
        "nif_entries": ["odin_nif_transact"],
    },
    {
        "rank": 15,
        "group": "transactions",
        "name": "Tx: Linked_Array_List O(log N) mid-list insert + delete",
        "elixir_entries": [("lib/xitdb.ex", "transact"), ("lib/xitdb.ex", "insert_at"), ("lib/xitdb.ex", "delete_at")],
        "nif_entries": ["odin_nif_transact"],
    },
    {
        "rank": 16,
        "group": "transactions",
        "name": "Tx: O(1) zero-copy subtree fork (500 entities)",
        "elixir_entries": [("lib/xitdb.ex", "transact"), ("lib/xitdb.ex", "fork")],
        "nif_entries": ["odin_nif_transact"],
    },
    {
        "rank": 17,
        "group": "time_travel",
        "name": "Time-Travel: Historical as_of(db, m) across 100 moments",
        "elixir_entries": [("lib/xitdb.ex", "as_of")],
        "nif_entries": ["odin_nif_moment_slot"],
    },
    {
        "rank": 18,
        "group": "time_travel",
        "name": "Time-Travel: history_of(db, selector) (100 moments)",
        "elixir_entries": [("lib/xitdb.ex", "history_of")],
        "nif_entries": ["odin_nif_history_of"],
    },
    {
        "rank": 19,
        "group": "time_travel",
        "name": "Time-Travel: diff_moments (1 of 200 entities mutated)",
        "elixir_entries": [("lib/xitdb.ex", "diff_moments")],
        "nif_entries": ["odin_nif_diff_moments"],
    },
    {
        "rank": 20,
        "group": "time_travel",
        "name": "Lifecycle: compact/1 100-moment database deduplication",
        "elixir_entries": [("lib/xitdb.ex", "compact")],
        "nif_entries": ["odin_nif_compact"],
    },
    {
        "rank": 21,
        "group": "queries",
        "name": "Query: Datomic pull projection (4 attrs + nested slice)",
        "elixir_entries": [("lib/xitdb.ex", "pull!"), ("lib/xitdb.ex", "pull"), ("lib/xitdb.ex", "do_nif_pull")],
        "nif_entries": ["odin_nif_pull"],
    },
    {
        "rank": 22,
        "group": "queries",
        "name": "Query: Datalog B+Tree index prefix + join (N=200)",
        "elixir_entries": [("lib/xitdb.ex", "query"), ("lib/xitdb.ex", "do_query")],
        "nif_entries": ["odin_nif_query_datalog"],
    },
    {
        "rank": 23,
        "group": "queries",
        "name": "Query: Datalog grouped aggregation (count + sum, N=200)",
        "elixir_entries": [("lib/xitdb.ex", "query"), ("lib/xitdb.ex", "do_query")],
        "nif_entries": ["odin_nif_query_datalog"],
    },
    {
        "rank": 24,
        "group": "queries",
        "name": "Storage: Buffered_File transact + sync (50 commits)",
        "elixir_entries": [("lib/xitdb.ex", "open"), ("lib/xitdb.ex", "transact"), ("lib/xitdb.ex", "sync"), ("lib/xitdb.ex", "info!"), ("lib/xitdb.ex", "close")],
        "nif_entries": ["odin_nif_open", "odin_nif_transact", "odin_nif_sync", "odin_nif_info", "odin_nif_close"],
    },
    {
        "rank": 25,
        "group": "queries",
        "name": "Search: Sorted_Map B+Tree prefix seek (limit=16)",
        "elixir_entries": [("lib/xitdb/nif.ex", "nif_sorted_map_seek"), ("lib/xitdb/ash/search.ex", "scan_prefix_cursors")],
        "nif_entries": ["odin_nif_sorted_map_seek"],
    },
    {
        "rank": 26,
        "group": "queries",
        "name": "Search: BM25 corpus search (N=200, 2-term prefix, limit=10)",
        "elixir_entries": [("lib/xitdb/nif.ex", "nif_bm25_search"), ("lib/xitdb/ash/search.ex", "score_collection_nif")],
        "nif_entries": ["odin_nif_bm25_search"],
    },
]

CATALOG_BY_RANK: Dict[int, Dict[str, Any]] = {b["rank"]: b for b in BENCHMARK_CATALOG}
CATALOG_BY_NAME: Dict[str, Dict[str, Any]] = {b["name"]: b for b in BENCHMARK_CATALOG}


def current_git_commit() -> str:
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--short=12", "HEAD"],
            cwd=ROOT_DIR,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if not out:
            return "unknown"
        status_out = subprocess.check_output(
            [
                "git",
                "status",
                "--porcelain",
                "--untracked-files=no",
                "--",
                "lib",
                "native",
                "benchmarks/bench_elixir.exs",
                "benchmarks/bench_client.odin",
            ],
            cwd=ROOT_DIR,
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if status_out:
            return f"{out}-dirty"
        return out
    except Exception:
        return "unknown"


def calc_percentile(sorted_vals: List[float], p: float) -> float:
    n = len(sorted_vals)
    if n == 0:
        return 0.0
    if n == 1:
        return sorted_vals[0]
    pos = p * (n - 1)
    lo = int(math.floor(pos))
    hi = min(lo + 1, n - 1)
    frac = pos - lo
    return sorted_vals[lo] + frac * (sorted_vals[hi] - sorted_vals[lo])


def compute_pooled_stats(records: List[Dict[str, Any]]) -> Dict[str, Any]:
    first = records[0]
    samples: List[float] = []
    run_ids: List[str] = []

    for r in records:
        rid = str(r.get("run_id", "run-0"))
        if rid not in run_ids:
            run_ids.append(rid)
        if "samples_ns" in r and isinstance(r["samples_ns"], list) and len(r["samples_ns"]) > 0:
            samples.extend(float(x) for x in r["samples_ns"])
        elif "ns_per_op" in r:
            samples.append(float(r["ns_per_op"]))

    if not samples:
        samples = [0.0]

    sorted_s = sorted(samples)
    n = len(sorted_s)
    min_ns = sorted_s[0]
    max_ns = sorted_s[-1]
    median_ns = calc_percentile(sorted_s, 0.50)
    q1_ns = calc_percentile(sorted_s, 0.25)
    q3_ns = calc_percentile(sorted_s, 0.75)
    iqr_ns = q3_ns - q1_ns
    p95_ns = calc_percentile(sorted_s, 0.95)
    p99_ns = calc_percentile(sorted_s, 0.99)

    mean_ns = sum(sorted_s) / n
    if n > 1:
        variance_ns2 = sum((x - mean_ns) ** 2 for x in sorted_s) / (n - 1)
    else:
        variance_ns2 = 0.0
    stddev_ns = math.sqrt(variance_ns2)
    cv_pct = (stddev_ns / max(mean_ns, 1e-9)) * 100.0

    ops = int(first.get("ops", 1))
    bytes_used = max(int(r.get("bytes_used", 0)) for r in records)
    total_ms = (median_ns * max(ops, 1)) / 1e6
    ops_per_sec = (ops * 1e9) / max(median_ns * max(ops, 1), 1.0)

    return {
        "rank": int(first.get("rank", 0)),
        "lang": first.get("lang", "elixir"),
        "commit": first.get("commit", "unknown"),
        "run_ids": run_ids,
        "num_invocations": len(records),
        "name": first["name"],
        "ops": ops,
        "runs": n,
        "total_ms": total_ms,
        "ns_per_op": round(median_ns),
        "median_ns": median_ns,
        "mean_ns": mean_ns,
        "stddev_ns": stddev_ns,
        "variance_ns2": variance_ns2,
        "cv_pct": cv_pct,
        "min_ns": min_ns,
        "max_ns": max_ns,
        "iqr_ns": iqr_ns,
        "p95_ns": p95_ns,
        "p99_ns": p99_ns,
        "ops_per_sec": round(ops_per_sec),
        "bytes_used": bytes_used,
        "samples_ns": samples,
    }


def load_jsonl_file(path: str) -> List[Dict[str, Any]]:
    if not os.path.isfile(path):
        return []
    out = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return out


def match_commit(record_commit: str, target_commit: Optional[str]) -> bool:
    if not target_commit:
        return True
    rc = record_commit.strip()
    tc = target_commit.strip()
    if rc.endswith("-dirty") != tc.endswith("-dirty"):
        return False
    if rc.endswith("-dirty"):
        rc = rc[:-6]
        tc = tc[:-6]
    return rc.startswith(tc) or tc.startswith(rc)


def deduplicate_by_run_id(records: List[Dict[str, Any]], latest_run: bool = False) -> List[Dict[str, Any]]:
    dedup: Dict[str, Dict[str, Any]] = {}
    order: List[str] = []
    for r in records:
        rid = str(r.get("run_id", "run-0"))
        if rid not in dedup:
            order.append(rid)
        dedup[rid] = r
    unique_recs = [dedup[rid] for rid in order]
    if latest_run and unique_recs:
        return [unique_recs[-1]]
    return unique_recs


def pool_by_lang_and_test(
    records: List[Dict[str, Any]],
    lang: str,
    commit: Optional[str] = None,
    latest_run: bool = False,
    run_id: Optional[str] = None,
) -> List[Dict[str, Any]]:
    filtered = [
        r
        for r in records
        if r.get("lang") == lang
        and match_commit(str(r.get("commit", "unknown")), commit)
        and (run_id is None or str(r.get("run_id", "")) == run_id)
    ]
    if not filtered and (commit or run_id):
        return []

    overall_latest_commit = filtered[-1].get("commit", "unknown") if filtered else "unknown"

    grouped: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    order: List[str] = []
    for r in filtered:
        name = r["name"]
        if name not in grouped:
            order.append(name)
        grouped[name].append(r)

    pooled = []
    for name in order:
        recs = grouped[name]
        if not commit and recs:
            latest_for_name = recs[-1].get("commit", "unknown")
            recs = [r for r in recs if r.get("commit", "unknown") == latest_for_name]
        recs = deduplicate_by_run_id(recs, latest_run=latest_run)
        stat = compute_pooled_stats(recs)
        if not commit and overall_latest_commit != "unknown":
            stat["commit"] = overall_latest_commit
        pooled.append(stat)
    pooled.sort(key=lambda x: x["rank"])
    return pooled


def fmt_kb(bytes_used: int) -> str:
    if bytes_used > 0:
        return f"{bytes_used / 1024.0:.1f} KB"
    return "-"


def welch_se(a: Dict[str, Any], b: Dict[str, Any]) -> float:
    var_a = a["variance_ns2"]
    var_b = b["variance_ns2"]
    n_a = max(a["runs"], 1)
    n_b = max(b["runs"], 1)
    return math.sqrt((var_a / n_a) + (var_b / n_b))


def welch_z_score(a: Dict[str, Any], b: Dict[str, Any]) -> float:
    se = welch_se(a, b)
    if se < 1e-6:
        return 99.0 if abs(a["mean_ns"] - b["mean_ns"]) >= 1.0 else 0.0
    return abs(a["mean_ns"] - b["mean_ns"]) / se


def run_cmd(cmd: List[str], label: str) -> None:
    print(f"==> Running {label}: {' '.join(cmd)}", file=sys.stderr)
    proc = subprocess.run(cmd, cwd=ROOT_DIR)
    if proc.returncode != 0:
        sys.exit(proc.returncode)


def print_1v1_comparison(odin_rows: List[Dict[str, Any]], elixir_rows: List[Dict[str, Any]]) -> None:
    ex_map = {r["name"]: r for r in elixir_rows}
    shared = [(o, ex_map[o["name"]]) for o in odin_rows if o["name"] in ex_map]

    if not shared:
        print("ERROR: No matching benchmarks found between Odin and Elixir.", file=sys.stderr)
        sys.exit(1)

    o_commit = odin_rows[0]["commit"]
    e_commit = elixir_rows[0]["commit"]
    o_samples = odin_rows[0]["runs"]
    e_samples = elixir_rows[0]["runs"]

    print()
    print("=" * 176)
    print(
        f"  Xitdb Client 1v1 Statistical Benchmark Comparison: Elixir NIF Wrapper vs Raw Odin (-o:speed)\n"
        f"  Commit: Odin={o_commit} ({o_samples} samples/test across {odin_rows[0]['num_invocations']} run(s)) | "
        f"Elixir={e_commit} ({e_samples} samples/test across {elixir_rows[0]['num_invocations']} run(s))"
    )
    print("=" * 176)
    header = (
        f"  {'Benchmark':<46} | {'Ops':>7} | {'Raw Odin Med ± σ (CV% | p95)':>32} | "
        f"{'Elixir Med ± σ (CV% | p95)':>32} | {'NIF Ratio (Sig)':>19} | {'Welch z':>8} | {'Footprint':>10}"
    )
    print(header)
    print("  " + "-" * 172)

    sub_2x = 0
    sub_5x = 0

    for o, ex in shared:
        o_sz = fmt_kb(o["bytes_used"])
        e_sz = fmt_kb(ex["bytes_used"])
        size_col = o_sz if o_sz == e_sz else f"{o_sz}!={e_sz}"

        o_med = max(o["median_ns"], 1.0)
        e_med = max(ex["median_ns"], 1.0)
        z_stat = welch_z_score(o, ex)
        sig_flag = "*" if z_stat >= 1.96 else "~"

        o_cell = f"{o['ns_per_op']:>6} ± {o['stddev_ns']:>5.1f} ({o['cv_pct']:>4.1f}%|p95:{o['p95_ns']:>6.0f})"
        e_cell = f"{ex['ns_per_op']:>6} ± {ex['stddev_ns']:>5.1f} ({ex['cv_pct']:>4.1f}%|p95:{ex['p95_ns']:>6.0f})"

        ratio = e_med / o_med
        if ratio <= 2.0:
            sub_2x += 1
        if ratio <= 5.0:
            sub_5x += 1
        ratio_str = f"{ratio:5.2f}x NIF  ({sig_flag})"

        print(
            f"  {o['name']:<46} | {o['ops']:>7} | {o_cell:>32} | "
            f"{e_cell:>32} | {ratio_str:>19} | {z_stat:>8.1f} | {size_col:>10}"
        )

    print("=" * 176)
    print(
        f"  Summary ({len(shared)} client benchmarks): {sub_2x}/{len(shared)} within <=2.0x of Raw Odin, "
        f"{sub_5x}/{len(shared)} within <=5.0x of Raw Odin | (* = Welch z>=1.96, ~ = within variance)"
    )
    print("=" * 176)


def compare_commits(
    records: List[Dict[str, Any]],
    sha_a: str,
    sha_b: str,
    lang: str,
    latest_run: bool = False,
    run_id: Optional[str] = None,
) -> None:
    rows_a = pool_by_lang_and_test(records, lang, sha_a, latest_run=latest_run, run_id=run_id)
    rows_b = pool_by_lang_and_test(records, lang, sha_b, latest_run=latest_run, run_id=run_id)

    if not rows_a:
        print(f"ERROR: No benchmark records found for commit '{sha_a}' (lang={lang}).", file=sys.stderr)
        sys.exit(1)
    if not rows_b:
        print(f"ERROR: No benchmark records found for commit '{sha_b}' (lang={lang}).", file=sys.stderr)
        sys.exit(1)

    map_b = {r["name"]: r for r in rows_b}
    paired = [(a, map_b[a["name"]]) for a in rows_a if a["name"] in map_b]

    full_a = rows_a[0]["commit"]
    full_b = rows_b[0]["commit"]

    print()
    print("=" * 154)
    print(
        f"  Commit-vs-Commit Benchmark Regression Report [{lang.upper()}]\n"
        f"  Baseline (A): {full_a} ({rows_a[0]['runs']} samples across {rows_a[0]['num_invocations']} run(s))  vs  "
        f"Candidate (B): {full_b} ({rows_b[0]['runs']} samples across {rows_b[0]['num_invocations']} run(s))"
    )
    print("=" * 154)
    print(
        f"  {'Benchmark':<46} | {'Baseline A (Med ± σ)':>22} | {'Candidate B (Med ± σ)':>22} | "
        f"{'Delta %':>9} | {'Speedup':>9} | {'Welch z':>7} | {'Verdict':<14}"
    )
    print("  " + "-" * 150)

    faster = 0
    slower = 0
    unchanged = 0

    for a, b in paired:
        med_a = max(a["median_ns"], 1.0)
        med_b = max(b["median_ns"], 1.0)
        delta_pct = ((med_b - med_a) / med_a) * 100.0
        speedup = med_a / med_b
        se = welch_se(a, b)
        z = welch_z_score(a, b)
        med_z = (abs(med_b - med_a) / se) if se >= 1e-6 else (99.0 if abs(med_b - med_a) >= 1.0 else 0.0)

        is_sig = (z >= 2.58) and (med_z >= 2.58) and (abs(delta_pct) >= 10.0) and (abs(med_b - med_a) >= 5.0)
        if is_sig and med_b < med_a:
            verdict = "FASTER"
            faster += 1
        elif is_sig and med_b > med_a:
            verdict = "REGRESSION"
            slower += 1
        else:
            verdict = "~NOISE"
            unchanged += 1

        cell_a = f"{a['ns_per_op']:>7} ± {a['stddev_ns']:>5.1f} ns"
        cell_b = f"{b['ns_per_op']:>7} ± {b['stddev_ns']:>5.1f} ns"
        print(
            f"  {a['name']:<46} | {cell_a:>22} | {cell_b:>22} | "
            f"{delta_pct:>+8.1f}% | {speedup:>8.2f}x | {z:>7.2f} | {verdict:<14}"
        )

    print("=" * 154)
    print(
        f"  Summary ({len(paired)} benchmarks): {faster} FASTER, {slower} REGRESSION, {unchanged} ~NOISE (within variance)"
    )
    print("=" * 154)


def list_commits(records: List[Dict[str, Any]]) -> None:
    if not records:
        print("No benchmark history records found.")
        return

    summary: Dict[Tuple[str, str], Dict[str, Any]] = {}
    for r in records:
        key = (str(r.get("commit", "unknown")), str(r.get("lang", "elixir")))
        if key not in summary:
            summary[key] = {"run_ids": set(), "tests": set(), "total_samples": defaultdict(int)}
        rid = str(r.get("run_id", "run-0"))
        summary[key]["run_ids"].add(rid)
        name = r.get("name", "")
        summary[key]["tests"].add(name)
        s_cnt = len(r.get("samples_ns", [])) if isinstance(r.get("samples_ns"), list) else int(r.get("runs", 1))
        summary[key]["total_samples"][name] += max(s_cnt, 1)

    print()
    print("=" * 96)
    print(f"  {'Commit SHA':<16} | {'Lang':<6} | {'Run Sessions':>12} | {'Benchmarks':>10} | {'Pooled Samples/Test':>20} | {'Run IDs'}")
    print("  " + "-" * 92)
    for (commit, lang), info in summary.items():
        samples_counts = list(info["total_samples"].values())
        min_s = min(samples_counts) if samples_counts else 0
        max_s = max(samples_counts) if samples_counts else 0
        samp_str = f"{min_s}" if min_s == max_s else f"{min_s}..{max_s}"
        rids = ", ".join(sorted(info["run_ids"])[:4])
        if len(info["run_ids"]) > 4:
            rids += f" (+{len(info['run_ids']) - 4} more)"
        print(
            f"  {commit:<16} | {lang:<6} | {len(info['run_ids']):>12} | {len(info['tests']):>10} | {samp_str:>20} | {rids}"
        )
    print("=" * 96)


def inspect_test(
    records: List[Dict[str, Any]],
    pattern: str,
    commit: Optional[str],
    latest_run: bool = False,
    run_id: Optional[str] = None,
) -> None:
    pat = pattern.lower()
    matched = [
        r for r in records
        if pat in r.get("name", "").lower()
        and match_commit(str(r.get("commit", "unknown")), commit)
        and (run_id is None or str(r.get("run_id", "")) == run_id)
    ]
    if not matched:
        print(f"No benchmark records matching '{pattern}'" + (f" at commit '{commit}'" if commit else ""))
        return

    grouped: Dict[Tuple[str, str, str], List[Dict[str, Any]]] = defaultdict(list)
    for r in matched:
        key = (str(r.get("commit", "unknown")), str(r.get("lang", "elixir")), r["name"])
        grouped[key].append(r)

    print()
    for (c_sha, lang, name), raw_recs in grouped.items():
        recs = deduplicate_by_run_id(raw_recs, latest_run=latest_run)
        pooled = compute_pooled_stats(recs)
        print("=" * 110)
        print(f"  Benchmark : {name}")
        print(f"  Commit    : {c_sha} | Lang: {lang} | Invocations: {pooled['num_invocations']} | Total Pooled Samples: {pooled['runs']}")
        print(
            f"  Stats (ns): Median={pooled['median_ns']:.2f} | Mean={pooled['mean_ns']:.2f} ± {pooled['stddev_ns']:.2f} "
            f"(CV={pooled['cv_pct']:.2f}%, Var={pooled['variance_ns2']:.2f})"
        )
        print(
            f"  Quantiles : Min={pooled['min_ns']:.0f} | IQR={pooled['iqr_ns']:.2f} | "
            f"p95={pooled['p95_ns']:.0f} | p99={pooled['p99_ns']:.0f} | Max={pooled['max_ns']:.0f}"
        )
        print(f"  Samples   : {[round(x) for x in pooled['samples_ns']]}")
        for idx, r in enumerate(recs, 1):
            print(
                f"    Run #{idx} ({r.get('run_id', '?')}): "
                f"median={r.get('median_ns', r.get('ns_per_op', 0)):.1f} ns/op, "
                f"samples={[round(x) for x in r.get('samples_ns', [])]}"
            )
    print("=" * 110)


def load_all_history() -> List[Dict[str, Any]]:
    records = load_jsonl_file(HISTORY_JSONL)
    if not records:
        records = load_jsonl_file(ODIN_JSONL) + load_jsonl_file(ELIXIR_JSONL)
    return records


def slugify_bench_name(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")
    return slug[:60].rstrip("_") or "bench"


def strip_odin_code_line(line: str, in_block_comment: bool) -> Tuple[str, bool]:
    out: List[str] = []
    i = 0
    n = len(line)
    in_string = False
    while i < n:
        ch = line[i]
        nxt = line[i + 1] if i + 1 < n else ""
        if in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment = False
                i += 2
            else:
                i += 1
            continue
        if in_string:
            if ch == "\\" and i + 1 < n:
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == "/" and nxt == "/":
            break
        if ch == "/" and nxt == "*":
            in_block_comment = True
            i += 2
            continue
        if ch == '"':
            in_string = True
            out.append(" ")
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out), in_block_comment


def strip_elixir_code_line(line: str) -> str:
    out: List[str] = []
    i = 0
    n = len(line)
    in_string = False
    while i < n:
        ch = line[i]
        if in_string:
            if ch == "\\" and i + 1 < n:
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == "#":
            break
        if ch == '"':
            in_string = True
            out.append(" ")
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def scan_elixir_harness() -> Dict[int, Dict[str, Any]]:
    if not os.path.exists(BENCH_ELIXIR_PATH):
        return {}
    lines = open(BENCH_ELIXIR_PATH, encoding="utf-8").read().splitlines()
    tuple_re = re.compile(r'^\s*\{(\d+),\s*"([^"]+)",\s*(\d+),\s*$')
    results: Dict[int, Dict[str, Any]] = {}
    i = 0
    n = len(lines)
    while i < n:
        m = tuple_re.match(lines[i])
        if m:
            rank = int(m.group(1))
            name = m.group(2)
            start_line = i + 1
            j = i + 1
            block_depth = 0
            saw_fn = False
            while j < n:
                cleaned = strip_elixir_code_line(lines[j])
                if re.search(r"\bfn\b", cleaned):
                    saw_fn = True
                    block_depth += len(re.findall(r"\bfn\b", cleaned))
                # Match block-opening `do` keywords, avoiding `, do:` keyword lists
                cleaned_no_kw = re.sub(r"\bdo:", " ", cleaned)
                block_depth += len(re.findall(r"(?<![A-Za-z0-9_])do(?=\s|$)", cleaned_no_kw))
                block_depth -= len(re.findall(r"(?<![A-Za-z0-9_])end(?=\s|[,\}\)\.]|$)", cleaned_no_kw))
                if saw_fn and block_depth <= 0 and "}" in cleaned:
                    end_line = j + 1
                    results[rank] = {
                        "rank": rank,
                        "name": name,
                        "file": "benchmarks/bench_elixir.exs",
                        "start_line": start_line,
                        "end_line": end_line,
                        "lines": lines[i : j + 1],
                    }
                    i = j
                    break
                j += 1
        i += 1
    return results


def scan_odin_client_harness() -> Tuple[Dict[int, Dict[str, Any]], Optional[Dict[str, Any]]]:
    if not os.path.exists(BENCH_ODIN_PATH):
        return {}, None
    lines = open(BENCH_ODIN_PATH, encoding="utf-8").read().splitlines()
    comment_re = re.compile(r"^\s*//\s*#(\d+):\s*(.+)$")
    if_rank_re = re.compile(r"^\s*if\s+r(\d+)\s*\{")
    run_bench_re = re.compile(r'^\s*run_bench\((\d+),\s*"([^"]+)"')
    proc_bm25_re = re.compile(r"^bench_raw_bm25_search\s*::\s*proc\b")

    results: Dict[int, Dict[str, Any]] = {}
    bm25_helper: Optional[Dict[str, Any]] = None

    def scan_brace_block(start_idx: int) -> int:
        depth = 0
        opened = False
        in_comment = False
        for k in range(start_idx, len(lines)):
            cleaned, in_comment = strip_odin_code_line(lines[k], in_comment)
            opens = cleaned.count("{")
            closes = cleaned.count("}")
            if opens > 0:
                opened = True
            depth += opens - closes
            if opened and depth <= 0:
                return k
        return start_idx

    for idx, line in enumerate(lines):
        if proc_bm25_re.match(line):
            end_idx = scan_brace_block(idx)
            bm25_helper = {
                "name": "bench_raw_bm25_search",
                "file": "benchmarks/bench_client.odin",
                "start_line": idx + 1,
                "end_line": end_idx + 1,
                "lines": lines[idx : end_idx + 1],
            }

    i = 0
    n = len(lines)
    while i < n:
        mc = comment_re.match(lines[i])
        if mc:
            rank = int(mc.group(1))
            start_idx = i
            j = i + 1
            matched_end = None
            while j < n and j <= i + 12:
                if run_bench_re.match(lines[j]) or if_rank_re.match(lines[j]):
                    matched_end = scan_brace_block(j)
                    # Check if next line is record_samples for inline block
                    if matched_end + 1 < n and "record_samples(" in lines[matched_end + 1]:
                        matched_end += 1
                    break
                j += 1
            if matched_end is not None:
                results[rank] = {
                    "rank": rank,
                    "name": CATALOG_BY_RANK.get(rank, {}).get("name", mc.group(2)),
                    "file": "benchmarks/bench_client.odin",
                    "start_line": start_idx + 1,
                    "end_line": matched_end + 1,
                    "lines": lines[start_idx : matched_end + 1],
                }
                i = matched_end
        i += 1
    return results, bm25_helper


def parse_elixir_lib_functions() -> Dict[Tuple[str, str], Dict[str, Any]]:
    target_files = [
        "lib/xitdb.ex",
        "lib/xitdb/cursor.ex",
        "lib/xitdb/tx_compiler.ex",
        "lib/xitdb/pull.ex",
        "lib/xitdb/selector.ex",
        "lib/xitdb/collection.ex",
        "lib/xitdb/nif.ex",
        "lib/xitdb/ash/search.ex",
    ]
    def_re = re.compile(r"^(\s*)defp?\s+([a-zA-Z_][a-zA-Z0-9_?!]*)\b")
    procs: Dict[Tuple[str, str], Dict[str, Any]] = {}

    for rel_path in target_files:
        full_path = os.path.join(ROOT_DIR, rel_path)
        if not os.path.exists(full_path):
            continue
        lines = open(full_path, encoding="utf-8").read().splitlines()
        n = len(lines)
        i = 0
        while i < n:
            m = def_re.match(lines[i])
            if not m:
                i += 1
                continue
            fname = m.group(2)
            start_idx = i
            j = i
            has_block = False
            depth = 0
            while j < n:
                cleaned = strip_elixir_code_line(lines[j])
                # Inline `, do:` expression
                if not has_block and re.search(r",\s*do:", cleaned):
                    end_idx = j
                    break
                if re.search(r"(?<![A-Za-z0-9_])do(?=\s|$)", re.sub(r"\bdo:", " ", cleaned)):
                    has_block = True
                cleaned_no_kw = re.sub(r"\bdo:", " ", cleaned)
                depth += len(re.findall(r"(?<![A-Za-z0-9_])(do|fn)(?=\s|$)", cleaned_no_kw))
                depth -= len(re.findall(r"(?<![A-Za-z0-9_])end(?=\s|$|[,\}\)\.])", cleaned_no_kw))
                if has_block and depth <= 0:
                    end_idx = j
                    break
                j += 1
            else:
                end_idx = n - 1

            key = (rel_path, fname)
            if key not in procs:
                procs[key] = {
                    "name": fname,
                    "file": rel_path,
                    "start_line": start_idx + 1,
                    "end_line": end_idx + 1,
                    "lines": lines[start_idx : end_idx + 1],
                }
            else:
                prev = procs[key]
                # Expand contiguous/multi-clause spans into a single block when adjacent
                if start_idx + 1 - prev["end_line"] <= 4:
                    prev["end_line"] = end_idx + 1
                    prev["lines"] = lines[prev["start_line"] - 1 : end_idx + 1]
            i = end_idx + 1
    return procs


def parse_odin_procs_in_file(abs_path: str, rel_path: str) -> Dict[str, Dict[str, Any]]:
    if not os.path.exists(abs_path):
        return {}
    lines = open(abs_path, encoding="utf-8").read().splitlines()
    proc_re = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s*::\s*proc(?:\s+"[^"]+")?\s*\(')
    procs: Dict[str, Dict[str, Any]] = {}
    i = 0
    n = len(lines)
    while i < n:
        m = proc_re.match(lines[i])
        if m and "---" not in lines[i]:
            name = m.group(1)
            depth = 0
            opened = False
            in_comment = False
            end_idx = i
            for k in range(i, n):
                cleaned, in_comment = strip_odin_code_line(lines[k], in_comment)
                if "---" in cleaned and not opened:
                    end_idx = -1
                    break
                opens = cleaned.count("{")
                closes = cleaned.count("}")
                if opens > 0:
                    opened = True
                depth += opens - closes
                if opened and depth <= 0:
                    end_idx = k
                    break
            if end_idx >= i and opened:
                procs[name] = {
                    "name": name,
                    "file": rel_path,
                    "start_line": i + 1,
                    "end_line": end_idx + 1,
                    "lines": lines[i : end_idx + 1],
                }
                i = end_idx + 1
                continue
        i += 1
    return procs


def parse_odin_library_procs() -> Dict[str, Dict[str, Any]]:
    all_procs: Dict[str, Dict[str, Any]] = {}
    if not os.path.isdir(ODIN_LIB_DIR):
        return all_procs
    for fname in sorted(os.listdir(ODIN_LIB_DIR)):
        if fname.endswith(".odin"):
            rel_path = f"native/xitdb-odin/xitdb/{fname}"
            abs_path = os.path.join(ODIN_LIB_DIR, fname)
            all_procs.update(parse_odin_procs_in_file(abs_path, rel_path))
    return all_procs


TRIVIAL_NIF_HELPERS = {
    "make_atom",
    "make_binary",
    "make_bytes_binary",
    "make_ok",
    "make_err",
    "make_xitdb_err",
    "get_string_from_binary",
    "get_atom_string",
    "get_handle",
    "acquire_rlock",
    "acquire_wlock",
    "is_container_tag",
    "is_pointer_tag",
    "tag_to_atom_name",
    "resolve_slot_arg",
    "make_map_safe",
    "term_to_key_string",
    "term_to_kind_string",
    "is_supported_col_kind",
    "get_term_float",
}


def compute_benchmark_slice(
    entry: Dict[str, Any],
    elixir_harness: Dict[int, Dict[str, Any]],
    odin_harness: Dict[int, Dict[str, Any]],
    bm25_helper: Optional[Dict[str, Any]],
    elixir_lib_procs: Dict[Tuple[str, str], Dict[str, Any]],
    nif_procs: Dict[str, Dict[str, Any]],
    odin_lib_procs: Dict[str, Dict[str, Any]],
) -> Dict[str, Any]:
    rank = entry["rank"]
    ex_h = elixir_harness.get(rank)
    od_h = odin_harness.get(rank)

    ex_funcs: List[Dict[str, Any]] = []
    seen_ex: Set[Tuple[str, str]] = set()
    for fpath, fname in entry.get("elixir_entries", []):
        if (fpath, fname) in elixir_lib_procs and (fpath, fname) not in seen_ex:
            ex_funcs.append(elixir_lib_procs[(fpath, fname)])
            seen_ex.add((fpath, fname))

    nif_list: List[Dict[str, Any]] = []
    seen_nif: Set[str] = set()
    call_re = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(")
    xitdb_call_re = re.compile(r"\bxitdb\.([A-Za-z_][A-Za-z0-9_]*)\b")

    core_seeds: List[str] = []
    seen_core_seeds: Set[str] = set()

    def add_core_seed(pname: str) -> None:
        if pname in odin_lib_procs and pname not in seen_core_seeds:
            seen_core_seeds.add(pname)
            core_seeds.append(pname)

    # Seed from Raw Odin harness (+ bm25_helper for #26)
    od_scan_lines: List[str] = []
    if od_h:
        od_scan_lines.extend(od_h["lines"])
    if rank == 26 and bm25_helper:
        od_scan_lines.extend(bm25_helper["lines"])
    for ln in od_scan_lines:
        cleaned, _ = strip_odin_code_line(ln, False)
        for m in xitdb_call_re.finditer(cleaned):
            add_core_seed(m.group(1))

    # Primary NIF entrypoints + BFS helper procs inside xitdb_nif.odin (up to 8 procs)
    nif_bfs: List[str] = list(entry.get("nif_entries", []))
    while nif_bfs and len(nif_list) < 8:
        nname = nif_bfs.pop(0)
        if nname in seen_nif or nname not in nif_procs:
            continue
        p = nif_procs[nname]
        nif_list.append(p)
        seen_nif.add(nname)
        in_c = False
        for ln in p["lines"]:
            cleaned, in_c = strip_odin_code_line(ln, in_c)
            for xm in xitdb_call_re.finditer(cleaned):
                add_core_seed(xm.group(1))
            for cm in call_re.finditer(cleaned):
                callee = cm.group(1)
                if (
                    callee in nif_procs
                    and callee not in seen_nif
                    and callee not in TRIVIAL_NIF_HELPERS
                    and not callee.startswith("odin_nif_")
                ):
                    nif_bfs.append(callee)

    # BFS over xitdb core Odin library procs (max depth 2, cap 12 procs)
    core_procs: List[Dict[str, Any]] = []
    visited_core: Set[str] = set()
    bfs_q: List[Tuple[str, int]] = [(s, 0) for s in core_seeds]
    while bfs_q and len(core_procs) < 12:
        pname, depth = bfs_q.pop(0)
        if pname in visited_core or pname not in odin_lib_procs:
            continue
        visited_core.add(pname)
        cp = odin_lib_procs[pname]
        core_procs.append(cp)
        if depth < 2:
            in_c = False
            for ln in cp["lines"]:
                cleaned, in_c = strip_odin_code_line(ln, in_c)
                for cm in call_re.finditer(cleaned):
                    callee = cm.group(1)
                    if callee in odin_lib_procs and callee not in visited_core:
                        bfs_q.append((callee, depth + 1))

    return {
        "rank": rank,
        "group": entry["group"],
        "name": entry["name"],
        "slug": slugify_bench_name(entry["name"]),
        "elixir_harness": ex_h,
        "odin_harness": od_h,
        "odin_helper": bm25_helper if rank == 26 else None,
        "elixir_funcs": ex_funcs,
        "nif_procs": nif_list,
        "core_procs": core_procs,
    }


def build_code_map() -> Dict[str, Dict[str, Any]]:
    elixir_harness = scan_elixir_harness()
    odin_harness, bm25_helper = scan_odin_client_harness()
    nif_procs = parse_odin_procs_in_file(NIF_ODIN_PATH, "native/xitdb_nif.odin")

    code_map: Dict[str, Dict[str, Any]] = {}
    for entry in BENCHMARK_CATALOG:
        rank = entry["rank"]
        name = entry["name"]
        slug = slugify_bench_name(name)
        ex_h = elixir_harness.get(rank)
        od_h = odin_harness.get(rank)
        nif_name = entry["nif_entries"][0] if entry.get("nif_entries") else None
        nif_p = nif_procs.get(nif_name) if nif_name else None

        item: Dict[str, Any] = {
            "rank": rank,
            "group": entry["group"],
            "slice_doc": f"slices/{rank:02d}_{slug}.md",
        }
        if ex_h:
            item["elixir_bench"] = f"bench_elixir.exs#L{ex_h['start_line']}-L{ex_h['end_line']}"
        if od_h:
            item["odin_bench"] = f"bench_client.odin#L{od_h['start_line']}-L{od_h['end_line']}"
        if nif_p:
            item["nif_entry"] = f"../native/xitdb_nif.odin#L{nif_p['start_line']}-L{nif_p['end_line']}"
            item["nif_proc"] = nif_p["name"]
        code_map[name] = item
    return code_map


def fmt_ns_human(ns: float) -> str:
    if ns >= 1_000_000.0:
        return f"{ns / 1_000_000.0:.2f} ms"
    if ns >= 1000.0:
        return f"{ns / 1000.0:.2f} µs"
    return f"{ns:.1f} ns"


def generate_all_slices() -> List[Dict[str, Any]]:
    os.makedirs(SLICES_DIR, exist_ok=True)
    elixir_harness = scan_elixir_harness()
    odin_harness, bm25_helper = scan_odin_client_harness()
    elixir_lib_procs = parse_elixir_lib_functions()
    nif_procs = parse_odin_procs_in_file(NIF_ODIN_PATH, "native/xitdb_nif.odin")
    odin_lib_procs = parse_odin_library_procs()

    odin_rows = {r["name"]: r for r in pool_by_lang_and_test(load_jsonl_file(ODIN_JSONL), "odin")}
    elixir_rows = {r["name"]: r for r in pool_by_lang_and_test(load_jsonl_file(ELIXIR_JSONL), "elixir")}

    slices_meta: List[Dict[str, Any]] = []
    for entry in BENCHMARK_CATALOG:
        sl = compute_benchmark_slice(
            entry,
            elixir_harness,
            odin_harness,
            bm25_helper,
            elixir_lib_procs,
            nif_procs,
            odin_lib_procs,
        )
        rank = sl["rank"]
        name = sl["name"]
        fname = f"{rank:02d}_{sl['slug']}.md"
        fpath = os.path.join(SLICES_DIR, fname)

        o = odin_rows.get(name)
        e = elixir_rows.get(name)

        md: List[str] = []
        md.append(f"# #{rank}: `{name}`")
        md.append("")
        md.append("[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)")
        md.append("")
        md.append(f"**Group:** `{sl['group']}` — {GROUP_RANGES.get(sl['group'], '')}")
        md.append("")

        if o or e:
            md.append("## Latest 1v1 Metrics")
            md.append("")
            if o and e:
                ratio = e["median_ns"] / o["median_ns"] if o["median_ns"] > 0 else 0.0
                z_val = welch_z_score(o, e)
                md.append("| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |")
                md.append("| :--- | ---: | ---: | ---: |")
                md.append(
                    f"| **Median (`ns/op`)** | {fmt_ns_human(e['median_ns'])} ({e['median_ns']:.1f} ns) | "
                    f"{fmt_ns_human(o['median_ns'])} ({o['median_ns']:.1f} ns) | **`{ratio:.2f}x`** NIF Ratio |"
                )
                md.append(
                    f"| **Mean ± σ (CV)** | {fmt_ns_human(e['mean_ns'])} ± {fmt_ns_human(e['stddev_ns'])} ({e['cv_pct']:.1f}%) | "
                    f"{fmt_ns_human(o['mean_ns'])} ± {fmt_ns_human(o['stddev_ns'])} ({o['cv_pct']:.1f}%) | "
                    f"Welch `z` = `{z_val:.2f}` |"
                )
                md.append(
                    f"| **p95 / Max (`ns/op`)** | {fmt_ns_human(e['p95_ns'])} / {fmt_ns_human(e['max_ns'])} | "
                    f"{fmt_ns_human(o['p95_ns'])} / {fmt_ns_human(o['max_ns'])} | "
                    f"`{e['runs']}` vs `{o['runs']}` pooled samples |"
                )
            elif e:
                md.append(f"- **Elixir Median:** `{e['median_ns']:.1f} ns/op` (`{e['runs']}` samples)")
            elif o:
                md.append(f"- **Raw Odin Median:** `{o['median_ns']:.1f} ns/op` (`{o['runs']}` samples)")
            md.append("")

        md.append("## Benchmark Harnesses (Elixir vs. Raw Odin)")
        md.append("")
        if sl["elixir_harness"]:
            eh = sl["elixir_harness"]
            el_link = f"../bench_elixir.exs#L{eh['start_line']}-L{eh['end_line']}"
            md.append(f"### Elixir Harness ([`bench_elixir.exs#L{eh['start_line']}-L{eh['end_line']}`]({el_link}))")
            md.append("")
            md.append("```elixir")
            md.extend(eh["lines"])
            md.append("```")
            md.append("")

        if sl["odin_harness"]:
            oh = sl["odin_harness"]
            od_link = f"../bench_client.odin#L{oh['start_line']}-L{oh['end_line']}"
            md.append(f"### Raw Odin Harness ([`bench_client.odin#L{oh['start_line']}-L{oh['end_line']}`]({od_link}))")
            md.append("")
            md.append("```odin")
            md.extend(oh["lines"])
            md.append("```")
            md.append("")

        if sl["odin_helper"]:
            bmh = sl["odin_helper"]
            bm_link = f"../bench_client.odin#L{bmh['start_line']}-L{bmh['end_line']}"
            md.append("<details>")
            md.append(
                f"<summary>Raw Odin BM25 Helper <code>{bmh['name']}</code> "
                f"(<a href=\"{bm_link}\">bench_client.odin#L{bmh['start_line']}-L{bmh['end_line']}</a>)</summary>"
            )
            md.append("")
            md.append("```odin")
            md.extend(bmh["lines"])
            md.append("```")
            md.append("")
            md.append("</details>")
            md.append("")

        if sl["elixir_funcs"] or sl["nif_procs"]:
            md.append("## Elixir Wrapper & NIF Bridge")
            md.append("")
            for ef in sl["elixir_funcs"]:
                rel = ef["file"]
                link = f"../../{rel}#L{ef['start_line']}-L{ef['end_line']}"
                md.append("<details>")
                md.append(
                    f"<summary>Elixir <code>{ef['name']}</code> — "
                    f"<a href=\"{link}\">{rel}#L{ef['start_line']}-L{ef['end_line']}</a></summary>"
                )
                md.append("")
                md.append("```elixir")
                md.extend(ef["lines"])
                md.append("```")
                md.append("")
                md.append("</details>")
                md.append("")

            for np_ in sl["nif_procs"]:
                rel = np_["file"]
                link = f"../../{rel}#L{np_['start_line']}-L{np_['end_line']}"
                md.append("<details>")
                md.append(
                    f"<summary>NIF <code>{np_['name']}</code> — "
                    f"<a href=\"{link}\">{rel}#L{np_['start_line']}-L{np_['end_line']}</a></summary>"
                )
                md.append("")
                md.append("```odin")
                md.extend(np_["lines"])
                md.append("```")
                md.append("")
                md.append("</details>")
                md.append("")

        if sl["core_procs"]:
            md.append("## Reachable `xitdb` Core Procedures")
            md.append("")
            for cp in sl["core_procs"]:
                rel = cp["file"]
                bname = os.path.basename(rel)
                link = f"../../{rel}#L{cp['start_line']}-L{cp['end_line']}"
                md.append("<details>")
                md.append(
                    f"<summary><code>xitdb.{cp['name']}</code> — "
                    f"<a href=\"{link}\">{bname}#L{cp['start_line']}-L{cp['end_line']}</a></summary>"
                )
                md.append("")
                md.append("```odin")
                md.extend(cp["lines"])
                md.append("```")
                md.append("")
                md.append("</details>")
                md.append("")

        with open(fpath, "w", encoding="utf-8") as f:
            f.write("\n".join(md).rstrip() + "\n")

        slices_meta.append(
            {
                "rank": rank,
                "group": sl["group"],
                "name": name,
                "fname": fname,
                "elixir_harness": sl["elixir_harness"],
                "odin_harness": sl["odin_harness"],
                "nif_procs": sl["nif_procs"],
                "core_count": len(sl["core_procs"]),
            }
        )

    # Generate benchmarks/slices/README.md index
    idx_md: List[str] = [
        "# Benchmark Code Slices (`#1–#26`)",
        "",
        "[← Back to Benchmarks Overview](../README.md)",
        "",
        "Each slice links the exact **Elixir Harness** (`bench_elixir.exs`), **Raw Odin Baseline** (`bench_client.odin`), "
        "**Elixir Client / NIF Wrapper** (`lib/` + `native/xitdb_nif.odin`), and reachable **`xitdb` Core Odin Engine** "
        "(`native/xitdb-odin/xitdb/*.odin`) source ranges.",
        "",
        "| # | Group | Benchmark & Code Slice | Elixir Harness | Raw Odin Harness | Primary NIF Entrypoint | Core Procs |",
        "| ---: | :--- | :--- | :--- | :--- | :--- | ---: |",
    ]
    for sm in slices_meta:
        eh = sm["elixir_harness"]
        oh = sm["odin_harness"]
        ex_cell = (
            f"[`#L{eh['start_line']}-L{eh['end_line']}`](../bench_elixir.exs#L{eh['start_line']}-L{eh['end_line']})"
            if eh
            else "—"
        )
        od_cell = (
            f"[`#L{oh['start_line']}-L{oh['end_line']}`](../bench_client.odin#L{oh['start_line']}-L{oh['end_line']})"
            if oh
            else "—"
        )
        if sm["nif_procs"]:
            np0 = sm["nif_procs"][0]
            nif_cell = f"[`{np0['name']}`](../../{np0['file']}#L{np0['start_line']}-L{np0['end_line']})"
        else:
            nif_cell = "—"
        idx_md.append(
            f"| {sm['rank']} | `{sm['group']}` | [`{sm['name']}`]({sm['fname']}) | "
            f"{ex_cell} | {od_cell} | {nif_cell} | {sm['core_count']} |"
        )
    idx_md.append("")
    with open(os.path.join(SLICES_DIR, "README.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(idx_md))

    return slices_meta


def resolve_diff_target(git_ref: Optional[str]) -> Tuple[List[str], str]:
    if git_ref and git_ref != "auto":
        return [git_ref], git_ref
    status = subprocess.run(
        ["git", "status", "--porcelain", "--", "lib/", "native/", "benchmarks/"],
        cwd=ROOT_DIR,
        capture_output=True,
        text=True,
        check=False,
    )
    if status.returncode == 0 and status.stdout.strip():
        return ["HEAD"], "working tree vs HEAD"
    return ["HEAD~1..HEAD"], "last commit (HEAD~1..HEAD)"


def extract_enclosing_procs(rel_path: str, changed_lines: Set[int]) -> Set[str]:
    abs_path = os.path.join(ROOT_DIR, rel_path)
    if not os.path.exists(abs_path) or not changed_lines:
        return set()
    matched: Set[str] = set()
    if rel_path.endswith(".odin"):
        procs = parse_odin_procs_in_file(abs_path, rel_path)
        for pname, pinfo in procs.items():
            for ln in changed_lines:
                if pinfo["start_line"] <= ln <= pinfo["end_line"]:
                    matched.add(pname)
    elif rel_path.endswith((".ex", ".exs")):
        lines = open(abs_path, encoding="utf-8").read().splitlines()
        def_re = re.compile(r"^\s*defp?\s+([a-zA-Z_][a-zA-Z0-9_?!]*)\b")
        sorted_ln = sorted(changed_lines)
        for target_ln in sorted_ln:
            for idx in range(min(target_ln - 1, len(lines) - 1), -1, -1):
                m = def_re.match(lines[idx])
                if m:
                    matched.add(m.group(1))
                    break
    elif rel_path.endswith(".c"):
        lines = open(abs_path, encoding="utf-8").read().splitlines()
        c_re = re.compile(r"^(?:static\s+)?[A-Za-z_][A-Za-z0-9_*\s]+\b([A-Za-z_][A-Za-z0-9_]*)\s*\(")
        for target_ln in sorted(changed_lines):
            for idx in range(min(target_ln - 1, len(lines) - 1), -1, -1):
                m = c_re.match(lines[idx])
                if m and m.group(1) not in ("if", "for", "while", "switch"):
                    matched.add(m.group(1))
                    break
    return matched


NIF_PROC_ATTRIBUTION: Dict[str, Tuple[List[str], List[str]]] = {
    "odin_nif_slot_get_key": (["access"], ["3-hop lazy HAMT", "Sorted_Map B+Tree key"]),
    "odin_nif_select": (["access"], ["Single-call selector"]),
    "parse_escaped_quoted": (["access"], ["Single-call selector"]),
    "parse_escaped_bracketed_string": (["access"], ["Single-call selector"]),
    "parse_escaped_ident_or_bracket": (["access"], ["Single-call selector"]),
    "parse_escaped_steps": (["access"], ["Single-call selector"]),
    "parse_escaped_selector": (["access"], ["Single-call selector"]),
    "odin_nif_slot_get_index": (["access"], ["Array_List random index", "Linked_Array_List random index"]),
    "odin_nif_slot_count": (["enumerable"], ["Enum.count/1"]),
    "odin_nif_slot_contains": (["enumerable"], ["Enum.member?/2"]),
    "odin_nif_slot_slice": (["enumerable"], ["Enum.slice/2"]),
    "odin_nif_slot_entries": (["enumerable"], ["Stream.take(10)", "Enum.to_list/1"]),
    "odin_nif_slot_materialize": (["enumerable"], ["Materialize:"]),
    "materialize_slot": (["enumerable"], ["Materialize:"]),
    "odin_nif_transact": (["transactions"], []),
    "odin_nif_moment_slot": (["time_travel"], ["as_of(db, m)"]),
    "odin_nif_history_of": (["time_travel"], ["history_of"]),
    "odin_nif_diff_moments": (["time_travel"], ["diff_moments"]),
    "odin_nif_compact": (["time_travel"], ["compact/1"]),
    "odin_nif_pull": (["queries"], ["Datomic pull"]),
    "pull_value_to_term": (["queries"], ["Datomic pull"]),
    "odin_nif_query_datalog": (["queries"], ["Datalog"]),
    "odin_nif_open": (["queries"], ["Buffered_File"]),
    "odin_nif_close": (["queries"], ["Buffered_File"]),
    "odin_nif_sync": (["queries"], ["Buffered_File"]),
    "odin_nif_info": (["queries"], ["Buffered_File"]),
    "odin_nif_sorted_map_seek": (["queries"], ["Sorted_Map B+Tree prefix seek"]),
    "odin_nif_bm25_search": (["queries"], ["BM25 corpus search"]),
    "collect_postings_into_map": (["queries"], ["BM25 corpus search"]),
    "bm25_heap_push": (["queries"], ["BM25 corpus search"]),
    "read_arena_string": (["queries"], ["BM25 corpus search"]),
    "read_cursor_nonneg_int": (["queries"], ["BM25 corpus search"]),
    "read_hash_map_nonneg_int": (["queries"], ["BM25 corpus search"]),
    "resolve_snapshot_root_cursor": (["queries"], ["BM25 corpus search"]),
    "parse_bm25_opts": (["queries"], ["BM25 corpus search"]),
}


def map_changes_to_benchmarks(git_ref: Optional[str] = None) -> Dict[str, Any]:
    diff_args, diff_label = resolve_diff_target(git_ref)
    cmd = ["git", "diff", "--unified=0"] + diff_args + ["--", "lib/", "native/", "benchmarks/"]
    diff_res = subprocess.run(cmd, cwd=ROOT_DIR, capture_output=True, text=True, check=False)
    if diff_res.returncode != 0 and diff_args == ["HEAD~1..HEAD"]:
        diff_res = subprocess.run(
            ["git", "diff", "--unified=0", "HEAD", "--", "lib/", "native/", "benchmarks/"],
            cwd=ROOT_DIR,
            capture_output=True,
            text=True,
            check=False,
        )

    changed_files: List[str] = []
    changed_lines_by_file: Dict[str, Set[int]] = defaultdict(set)
    cur_file: Optional[str] = None
    hunk_re = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")

    for line in diff_res.stdout.splitlines():
        if line.startswith("+++ b/"):
            cur_file = line[6:]
            if cur_file not in changed_files:
                changed_files.append(cur_file)
        elif line.startswith("+++ /dev/null"):
            cur_file = None
        elif cur_file and line.startswith("@@ "):
            hm = hunk_re.match(line)
            if hm:
                start = int(hm.group(1))
                count = int(hm.group(2)) if hm.group(2) is not None else 1
                if count == 0:
                    changed_lines_by_file[cur_file].add(max(start, 1))
                else:
                    for ln in range(start, start + count):
                        changed_lines_by_file[cur_file].add(ln)

    if diff_label == "working tree vs HEAD":
        st = subprocess.run(
            ["git", "status", "--porcelain", "--", "lib/", "native/", "benchmarks/"],
            cwd=ROOT_DIR,
            capture_output=True,
            text=True,
            check=False,
        )
        for ln in st.stdout.splitlines():
            if len(ln) >= 4:
                path = ln[3:].strip().strip('"')
                if path not in changed_files and not path.endswith(".jsonl") and not path.endswith(".md"):
                    changed_files.append(path)

    groups_set: Set[str] = set()
    filters_set: Set[str] = set()
    reasons: List[str] = []
    procs_by_file: Dict[str, List[str]] = {}
    broad_group_only: Set[str] = set()

    elixir_harness = scan_elixir_harness()
    odin_harness, bm25_helper = scan_odin_client_harness()

    for rel_path in changed_files:
        if (
            rel_path.endswith(".jsonl")
            or rel_path.endswith(".md")
            or rel_path in ("benchmarks/compare_1v1.py", "benchmarks/update_readme.sh")
        ):
            continue

        clines = changed_lines_by_file.get(rel_path, set())
        procs = sorted(extract_enclosing_procs(rel_path, clines))
        if procs:
            procs_by_file[rel_path] = procs

        if rel_path == "benchmarks/bench_elixir.exs":
            matched_ranks = []
            for rank, hinfo in elixir_harness.items():
                if any(hinfo["start_line"] <= ln <= hinfo["end_line"] for ln in clines):
                    matched_ranks.append(rank)
            if matched_ranks:
                for r in matched_ranks:
                    cat = CATALOG_BY_RANK[r]
                    groups_set.add(cat["group"])
                    filters_set.add(cat["name"])
                reasons.append(f"{rel_path}: modified benchmark(s) #{', #'.join(str(r) for r in matched_ranks)}")
            else:
                groups_set.update(ALL_GROUPS)
                broad_group_only.update(ALL_GROUPS)
                reasons.append(f"{rel_path}: harness/fixture helpers modified")

        elif rel_path == "benchmarks/bench_client.odin":
            matched_ranks = []
            for rank, hinfo in odin_harness.items():
                if any(hinfo["start_line"] <= ln <= hinfo["end_line"] for ln in clines):
                    matched_ranks.append(rank)
            if bm25_helper and any(bm25_helper["start_line"] <= ln <= bm25_helper["end_line"] for ln in clines):
                matched_ranks.append(26)
            if matched_ranks:
                for r in sorted(set(matched_ranks)):
                    cat = CATALOG_BY_RANK[r]
                    groups_set.add(cat["group"])
                    filters_set.add(cat["name"])
                reasons.append(f"{rel_path}: modified benchmark(s) #{', #'.join(str(r) for r in sorted(set(matched_ranks)))}")
            else:
                groups_set.update(ALL_GROUPS)
                broad_group_only.update(ALL_GROUPS)
                reasons.append(f"{rel_path}: harness/fixture helpers modified")

        elif rel_path == "native/xitdb_nif.odin":
            matched_any = False
            for p in procs:
                if p in NIF_PROC_ATTRIBUTION:
                    gs, fs = NIF_PROC_ATTRIBUTION[p]
                    groups_set.update(gs)
                    if fs:
                        filters_set.update(fs)
                    else:
                        broad_group_only.update(gs)
                    matched_any = True
                elif p.startswith(("write_", "validate_", "decode_")) or p.endswith("_callback"):
                    groups_set.add("transactions")
                    broad_group_only.add("transactions")
                    matched_any = True
                elif p.startswith("nif_dl_"):
                    groups_set.add("queries")
                    filters_set.add("Datalog")
                    matched_any = True
                elif p in ("slot_to_term", "read_key_cursor_string", "acquire_rlock", "acquire_wlock"):
                    groups_set.update(ALL_GROUPS)
                    broad_group_only.update(ALL_GROUPS)
                    matched_any = True
            if matched_any:
                reasons.append(f"{rel_path}: procs {', '.join(procs) or 'top-level'} -> {', '.join(sorted(groups_set))}")
            else:
                groups_set.update(ALL_GROUPS)
                broad_group_only.update(ALL_GROUPS)
                reasons.append(f"{rel_path}: general NIF changes -> full suite")

        elif rel_path.startswith("native/xitdb-odin"):
            groups_set.update(ALL_GROUPS)
            broad_group_only.update(ALL_GROUPS)
            reasons.append(f"{rel_path}: core Odin submodule changed -> full client suite")

        elif rel_path == "native/nif_entry.c":
            groups_set.update(ALL_GROUPS)
            broad_group_only.update(ALL_GROUPS)
            reasons.append(f"{rel_path}: C NIF entry/helpers changed -> full client suite")

        elif rel_path == "lib/xitdb/cursor.ex":
            matched_any = False
            for p in procs:
                if p in ("fetch", "nif_slot_get", "from_nif_tuple", "unwrap_nif_value"):
                    groups_set.add("access")
                    broad_group_only.add("access")
                    matched_any = True
                elif p in ("count", "member?", "slice", "reduce", "do_reduce", "unwrap_entry"):
                    groups_set.add("enumerable")
                    if p == "count":
                        filters_set.add("Enum.count/1")
                    elif p == "member?":
                        filters_set.add("Enum.member?/2")
                    elif p == "slice":
                        filters_set.add("Enum.slice/2")
                    else:
                        filters_set.update(["Stream.take(10)", "Enum.to_list/1"])
                    matched_any = True
                elif p in ("get_and_update", "pop"):
                    groups_set.add("transactions")
                    filters_set.add("Incremental put_in")
                    matched_any = True
            if not matched_any:
                groups_set.update(["access", "enumerable", "transactions"])
                broad_group_only.update(["access", "enumerable", "transactions"])
            reasons.append(f"{rel_path}: cursor functions {', '.join(procs) or 'module'}")

        elif rel_path == "lib/xitdb.ex":
            matched_any = False
            for p in procs:
                if p in ("select", "select!", "do_select"):
                    groups_set.add("access")
                    filters_set.add("Single-call selector")
                    matched_any = True
                elif p in ("materialize", "empty_cursor_default"):
                    groups_set.add("enumerable")
                    filters_set.add("Materialize:")
                    matched_any = True
                elif p in ("transact", "transact!", "transact_ops", "insert_at", "delete_at", "fork"):
                    groups_set.add("transactions")
                    broad_group_only.add("transactions")
                    matched_any = True
                elif p in ("as_of", "history_of", "diff_moments", "compact", "compact!"):
                    groups_set.add("time_travel")
                    broad_group_only.add("time_travel")
                    matched_any = True
                elif p in ("pull", "pull!", "do_nif_pull", "query", "query!", "do_query", "open", "sync", "info", "close"):
                    groups_set.add("queries")
                    broad_group_only.add("queries")
                    matched_any = True
            if not matched_any:
                groups_set.update(ALL_GROUPS)
                broad_group_only.update(ALL_GROUPS)
            reasons.append(f"{rel_path}: client API {', '.join(procs) or 'module'}")

        elif rel_path in ("lib/xitdb/tx_compiler.ex", "lib/xitdb/collection.ex"):
            groups_set.add("transactions")
            broad_group_only.add("transactions")
            reasons.append(f"{rel_path}: transaction/collection compilation")

        elif rel_path == "lib/xitdb/selector.ex":
            groups_set.update(["access", "time_travel"])
            filters_set.update(["Single-call selector", "history_of"])
            reasons.append(f"{rel_path}: selector parser")

        elif rel_path == "lib/xitdb/pull.ex":
            groups_set.add("queries")
            filters_set.add("Datomic pull")
            reasons.append(f"{rel_path}: pull pattern compiler")

        elif rel_path.startswith("lib/xitdb/ash/search") or rel_path == "lib/xitdb/ash/indexer.ex":
            groups_set.add("queries")
            filters_set.update(["Sorted_Map B+Tree prefix seek", "BM25 corpus search"])
            reasons.append(f"{rel_path}: search/index module")

        elif rel_path.startswith("lib/xitdb/dsl"):
            groups_set.update(["transactions", "queries"])
            broad_group_only.update(["transactions", "queries"])
            reasons.append(f"{rel_path}: DSL compiler/runtime")

        elif rel_path.startswith("lib/"):
            groups_set.update(ALL_GROUPS)
            broad_group_only.update(ALL_GROUPS)
            reasons.append(f"{rel_path}: Elixir library module changed")

    if not groups_set:
        ordered_groups = list(ALL_GROUPS)
        filter_str = ""
        reasons = ["No specific client/NIF slice matched (or clean diff) -> full client benchmark suite (#1–#26)"]
    else:
        ordered_groups = [g for g in ALL_GROUPS if g in groups_set]
        # Drop narrow filter if any affected group needs full group coverage
        if len(ordered_groups) == len(ALL_GROUPS) or (broad_group_only & groups_set):
            filter_str = ""
        else:
            filter_str = "|".join(sorted(filters_set))

    return {
        "diff_label": diff_label,
        "changed_files": changed_files,
        "procs_by_file": procs_by_file,
        "odin_groups": ordered_groups,
        "elixir_groups": ordered_groups,
        "filter": filter_str,
        "reasons": reasons,
    }


def print_benchmark_plan(plan: Dict[str, Any]) -> None:
    print()
    print("=" * 96)
    print("  Xitdb Benchmark Diff-Analysis Plan")
    print("=" * 96)
    print(f"  Diff Target   : {plan['diff_label']}")
    print(f"  Changed Files : {', '.join(plan['changed_files']) if plan['changed_files'] else '(none)'}")
    if plan["procs_by_file"]:
        proc_parts = [f"{fp}: {', '.join(ps)}" for fp, ps in plan["procs_by_file"].items()]
        print(f"  Modified Procs: {'; '.join(proc_parts)}")
    print("  Attribution   :")
    for r in plan["reasons"]:
        print(f"    - {r}")
    print(f"  Odin Groups   : {','.join(plan['odin_groups']) or '(none)'}")
    print(f"  Elixir Groups : {','.join(plan['elixir_groups']) or '(none)'}")
    print(f"  Name Filter   : {plan['filter'] or '(all in selected groups)'}")
    print("  Command       : ./benchmarks/compare_1v1.py --affected")
    print("=" * 96)


def main() -> None:
    parser = argparse.ArgumentParser(description="Xitdb Client Multi-Run Statistical Benchmark Runner & Analyzer")
    parser.add_argument("--runs", type=int, default=5, help="In-process measured trials per test (default: 5)")
    parser.add_argument("--warmup", type=int, default=1, help="In-process warmup passes before trials (default: 1)")
    parser.add_argument("--commit", type=str, default=None, help="Git commit SHA to tag or query")
    parser.add_argument("--run-id", type=str, default=None, help="Run session identifier")
    parser.add_argument("--latest-run", dest="latest_run", action="store_true", help="Isolate the most recent run_id per commit when analyzing/comparing")
    parser.add_argument("--pool-runs", dest="latest_run", action="store_false", help="Explicitly pool all run_ids sharing the target commit SHA (default)")
    parser.set_defaults(latest_run=False)
    parser.add_argument("--append", action="store_true", help="Append to odin.jsonl/elixir.jsonl to accumulate multiple runs")
    parser.add_argument("--no-history", action="store_true", help="Do not append to benchmarks/history.jsonl")
    parser.add_argument("--from-jsonl", action="store_true", help="Analyze existing JSONL files without re-running binaries")
    parser.add_argument(
        "--compare-commits",
        nargs=2,
        metavar=("SHA_A", "SHA_B"),
        help="Compare benchmark distributions between two git commit SHAs",
    )
    parser.add_argument(
        "--lang",
        choices=["odin", "elixir", "both"],
        default=None,
        help="Language to run/compare (default: both for runs, elixir for --compare-commits)",
    )
    parser.add_argument("--list-commits", action="store_true", help="List all commits and run sessions in history")
    parser.add_argument("--inspect", type=str, default=None, help="Inspect all runs and sample distributions for matching tests")
    parser.add_argument(
        "--groups",
        type=str,
        default=None,
        help="Comma-separated benchmark groups: access,enumerable,transactions,time_travel,queries",
    )
    parser.add_argument("--filter", type=str, default=None, help="Pipe- or comma-separated benchmark name substrings")
    parser.add_argument("--plan", nargs="?", const="auto", default=None, metavar="GIT_REF", help="Show git-diff affected benchmark plan")
    parser.add_argument("--plan-json", nargs="?", const="auto", default=None, metavar="GIT_REF", help="Emit git-diff plan as JSON")
    parser.add_argument(
        "--affected",
        nargs="?",
        const="auto",
        default=None,
        metavar="GIT_REF",
        help="Run only benchmarks affected by git changes",
    )
    parser.add_argument("--code-map-json", action="store_true", help="Print JSON mapping benchmarks to slice docs and line ranges")
    parser.add_argument("--generate-slices", action="store_true", help="Generate per-benchmark code slices in benchmarks/slices/")

    args = parser.parse_args()

    if args.plan_json is not None:
        print(json.dumps(map_changes_to_benchmarks(args.plan_json)))
        return

    if args.plan is not None:
        print_benchmark_plan(map_changes_to_benchmarks(args.plan))
        return

    if args.code_map_json:
        print(json.dumps(build_code_map()))
        return

    if args.generate_slices:
        slices_meta = generate_all_slices()
        print(f"Generated {len(slices_meta)} benchmark slices in benchmarks/slices/ and benchmarks/slices/README.md")
        return

    if args.list_commits:
        list_commits(load_all_history())
        return

    if args.inspect:
        inspect_test(load_all_history(), args.inspect, args.commit, latest_run=args.latest_run, run_id=args.run_id)
        return

    if args.compare_commits:
        sha_a, sha_b = args.compare_commits
        records = load_all_history()
        cmp_lang = args.lang or "elixir"
        if cmp_lang in ("odin", "both"):
            compare_commits(records, sha_a, sha_b, "odin", latest_run=args.latest_run, run_id=args.run_id)
        if cmp_lang in ("elixir", "both"):
            compare_commits(records, sha_a, sha_b, "elixir", latest_run=args.latest_run, run_id=args.run_id)
        return

    commit_sha = args.commit or current_git_commit()
    run_id = args.run_id or f"run-{int(time.time())}"
    run_lang = args.lang or "both"

    odin_groups = args.groups
    elixir_groups = args.groups
    bench_filter = args.filter

    if args.affected is not None:
        plan = map_changes_to_benchmarks(args.affected)
        print_benchmark_plan(plan)
        if not odin_groups:
            odin_groups = ",".join(plan["odin_groups"])
        if not elixir_groups:
            elixir_groups = ",".join(plan["elixir_groups"])
        if not bench_filter and plan["filter"]:
            bench_filter = plan["filter"]

    if not args.from_jsonl:
        base_flags = [
            "--runs", str(args.runs),
            "--warmup", str(args.warmup),
            "--commit", commit_sha,
            "--run-id", run_id,
        ]
        if args.append:
            base_flags.append("--append")
        if args.no_history:
            base_flags.append("--no-history")
        if bench_filter:
            base_flags.extend(["--filter", bench_filter])

        if run_lang in ("odin", "both"):
            odin_flags = list(base_flags)
            if odin_groups:
                odin_flags.extend(["--groups", odin_groups])
            odin_cmd = [
                "odin", "run", "benchmarks",
                "-collection:xitdb=native/xitdb-odin/xitdb",
                "-o:speed", "-microarch:native",
                "--",
            ] + odin_flags
            run_cmd(odin_cmd, "Raw Odin Client Benchmarks")

        if run_lang in ("elixir", "both"):
            elixir_flags = list(base_flags)
            if elixir_groups:
                elixir_flags.extend(["--groups", elixir_groups])
            elixir_cmd = ["mix", "run", "benchmarks/bench_elixir.exs", "--"] + elixir_flags
            run_cmd(elixir_cmd, "Elixir Wrapper Client Benchmarks")

    snapshot_commit = (
        args.commit
        if (args.from_jsonl and not args.affected and not args.groups and not args.filter)
        else None
    )
    analysis_run_id = args.run_id if args.from_jsonl else None
    odin_records = load_jsonl_file(ODIN_JSONL)
    elixir_records = load_jsonl_file(ELIXIR_JSONL)
    odin_rows = pool_by_lang_and_test(odin_records, "odin", snapshot_commit, latest_run=args.latest_run, run_id=analysis_run_id)
    elixir_rows = pool_by_lang_and_test(elixir_records, "elixir", snapshot_commit, latest_run=args.latest_run, run_id=analysis_run_id)
    print_1v1_comparison(odin_rows, elixir_rows)


if __name__ == "__main__":
    main()
