#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODIN_JSONL="${SCRIPT_DIR}/odin.jsonl"
ELIXIR_JSONL="${SCRIPT_DIR}/elixir.jsonl"
HISTORY_JSONL="${SCRIPT_DIR}/history.jsonl"
README_MD="${SCRIPT_DIR}/README.md"
TARGET_COMMIT=""
LATEST_RUN="true"
TARGET_RUN_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --latest-run)
            LATEST_RUN="true"
            shift
            ;;
        --pool-runs)
            LATEST_RUN="false"
            shift
            ;;
        --run-id)
            if [[ $# -lt 2 ]]; then
                echo "Error: --run-id requires a value" >&2
                exit 1
            fi
            TARGET_RUN_ID="$2"
            shift 2
            ;;
        --run-id=*)
            TARGET_RUN_ID="${1#*=}"
            shift
            ;;
        --commit)
            if [[ $# -lt 2 ]]; then
                echo "Error: --commit requires a value" >&2
                exit 1
            fi
            TARGET_COMMIT="$2"
            shift 2
            ;;
        --commit=*)
            TARGET_COMMIT="${1#*=}"
            shift
            ;;
        *)
            if [[ -z "${TARGET_COMMIT}" ]]; then
                TARGET_COMMIT="$1"
            fi
            shift
            ;;
    esac
done

if [[ ! -f "${ODIN_JSONL}" ]]; then
    echo "Error: ${ODIN_JSONL} not found. Run './benchmarks/compare_1v1.py' first." >&2
    exit 1
fi

if [[ ! -f "${ELIXIR_JSONL}" ]]; then
    echo "Error: ${ELIXIR_JSONL} not found. Run './benchmarks/compare_1v1.py' first." >&2
    exit 1
fi

INPUT_FILES=()
if [[ -f "${HISTORY_JSONL}" ]]; then
    INPUT_FILES+=("${HISTORY_JSONL}")
fi
INPUT_FILES+=("${ODIN_JSONL}" "${ELIXIR_JSONL}")

"${SCRIPT_DIR}/compare_1v1.py" --generate-slices >/dev/null
CODE_MAP_JSON=$("${SCRIPT_DIR}/compare_1v1.py" --code-map-json 2>/dev/null || echo "{}")
PLAN_JSON=$("${SCRIPT_DIR}/compare_1v1.py" --plan-json 2>/dev/null || echo "{}")

TABLES=$(jq -rn --arg target_commit "${TARGET_COMMIT}" --arg latest_run "${LATEST_RUN}" --arg target_run_id "${TARGET_RUN_ID}" --argjson code_map "${CODE_MAP_JSON}" --argjson plan "${PLAN_JSON}" '
def commify:
  tostring |
  if test("^-?[0-9]+$") then
    (if startswith("-") then "-" else "" end) as $sign |
    (ltrimstr("-") | [splits("") | select(. != "")] | reverse) as $digits |
    $sign + ([range(0; $digits | length) |
      $digits[.] + (if . > 0 and (. % 3 == 0) then "," else "" end)
    ] | reverse | join(""))
  else . end;

def nbsp:
  gsub(" "; "\u00a0");

def fmt_dec1($v):
  (($v * 10 | round) / 10 | tostring) as $s |
  if ($s | test("\\.")) then $s else $s + ".0" end;

def fmt_dec2($v):
  (($v * 100 | round) / 100 | tostring) as $s |
  if ($s | test("\\.")) then
    ($s | split(".")) as $parts |
    $parts[0] + "." + (if ($parts[1] | length) == 1 then $parts[1] + "0" else $parts[1] end)
  else
    $s + ".00"
  end;

def fmt_sigma($v):
  if $v >= 100 then ($v | round | commify) else fmt_dec1($v) end;

def fmt_us($ns):
  ($ns / 1000.0) as $us |
  if $us >= 10.0 then fmt_dec1($us)
  else fmt_dec2($us)
  end;

def fmt_ops_count($n):
  if $n >= 1000 and ($n % 1000 == 0) then (($n / 1000 | tostring) + "K")
  else ($n | commify)
  end;

def fmt_si1($v):
  if $v >= 1e8 then (($v / 1e6 | round | tostring) + "M")
  elif $v >= 1e6 then (fmt_dec1($v / 1e6) + "M")
  elif $v >= 1e5 then (($v / 1e3 | round | tostring) + "K")
  elif $v >= 1e3 then (fmt_dec1($v / 1e3) + "K")
  else ($v | round | tostring)
  end;

def fmt_si2($v):
  if $v >= 1e8 then (fmt_dec1($v / 1e6) + "M")
  elif $v >= 1e6 then (fmt_dec2($v / 1e6) + "M")
  elif $v >= 1e5 then (fmt_dec1($v / 1e3) + "K")
  elif $v >= 1e3 then (fmt_dec2($v / 1e3) + "K")
  else ($v | round | tostring)
  end;

def fmt_ops_bounds($min_ns; $max_ns):
  (1e9 / ([$max_ns, 1] | max)) as $lo_ops |
  (1e9 / ([$min_ns, 1] | max)) as $hi_ops |
  fmt_si1($lo_ops) as $lo1 |
  fmt_si1($hi_ops) as $hi1 |
  if $min_ns == $max_ns then
    [$lo1, $hi1]
  elif $lo1 != $hi1 then
    [$lo1, $hi1]
  else
    fmt_si2($lo_ops) as $lo2 |
    fmt_si2($hi_ops) as $hi2 |
    if $lo2 != $hi2 then [$lo2, $hi2] else [$lo1, $hi1] end
  end;

def fmt_kb($b):
  if $b > 0 then
    ((($b / 1024.0) * 10 | round) / 10 | tostring |
      if test("\\.") then . else . + ".0" end) + "\u00a0KB"
  else
    "—"
  end;

def fmt_ratio($o_ns; $e_ns):
  (($e_ns / ([$o_ns, 1] | max)) * 100 | round) as $pct |
  (($pct / 100 | floor | tostring) + "." + (($pct % 100) | tostring | if length == 1 then "0" + . else . end) + "x");

def percentile($sorted; $p):
  ($sorted | length) as $n |
  if $n == 0 then 0
  elif $n == 1 then $sorted[0]
  else
    ($p * ($n - 1)) as $pos |
    ($pos | floor) as $lo |
    ([$lo + 1, $n - 1] | min) as $hi |
    ($pos - $lo) as $frac |
    $sorted[$lo] + $frac * ($sorted[$hi] - $sorted[$lo])
  end;

def welch_se($a; $b):
  ((($a.variance_ns2 / ([$a.runs, 1] | max)) + ($b.variance_ns2 / ([$b.runs, 1] | max))) | sqrt);

def welch_z($a; $b):
  welch_se($a; $b) as $se |
  if $se < 1e-6 then
    (if (($a.mean_ns - $b.mean_ns) | fabs) >= 1.0 then 99.0 else 0.0 end)
  else
    (($a.mean_ns - $b.mean_ns) | fabs) / $se
  end;

def pool_records($recs):
  (if $target_run_id != "" then
     ($recs | map(select((.run_id // "") == $target_run_id)))
   else $recs end) as $filtered |
  (reduce $filtered[] as $r ({seen: {}, order: []};
    ($r.run_id // "run-0") as $rid |
    .seen[$rid] = $r |
    if (.order | index($rid)) then . else .order += [$rid] end
  ) | [.order[] as $rid | .seen[$rid]]) as $uniq_recs |
  (if $latest_run == "true" and ($uniq_recs | length) > 0 then
     [($uniq_recs | last)]
   else $uniq_recs end) as $selected_recs |
  if ($selected_recs | length) == 0 then empty else
  ($selected_recs[0]) as $first |
  ([ $selected_recs[] | if (.samples_ns | type) == "array" and (.samples_ns | length) > 0 then .samples_ns[] else .ns_per_op end ]) as $samples |
  ($samples | sort) as $sorted |
  ($sorted | length) as $n |
  percentile($sorted; 0.50) as $med |
  percentile($sorted; 0.25) as $q1 |
  percentile($sorted; 0.75) as $q3 |
  ($q3 - $q1) as $iqr |
  percentile($sorted; 0.95) as $p95 |
  percentile($sorted; 0.99) as $p99 |
  (($sorted | add) / ([$n, 1] | max)) as $mean |
  (if $n > 1 then ([ $sorted[] | (. - $mean) * (. - $mean) ] | add) / ($n - 1) else 0 end) as $var |
  ($var | sqrt) as $sd |
  (($sd / ([$mean, 1e-9] | max)) * 100.0) as $cv |
  ($sorted[0] // 0) as $min_ns |
  ($sorted[$n - 1] // 0) as $max_ns |
  (($med * ([$first.ops, 1] | max)) / 1e6) as $total_ms |
  (($first.ops * 1e9) / ([($med * ([$first.ops, 1] | max)), 1.0] | max) | round) as $ops_sec |
  {
    rank: $first.rank,
    lang: $first.lang,
    commit: ($first.commit // "unknown"),
    invocations: ($selected_recs | length),
    name: $first.name,
    ops: $first.ops,
    runs: $n,
    total_ms: $total_ms,
    ns_per_op: ($med | round),
    median_ns: $med,
    mean_ns: $mean,
    stddev_ns: $sd,
    variance_ns2: $var,
    cv_pct: $cv,
    iqr_ns: $iqr,
    p95_ns: ($p95 | round),
    p99_ns: ($p99 | round),
    min_ns: ($min_ns | round),
    max_ns: ($max_ns | round),
    ops_per_sec: $ops_sec,
    bytes_used: ([ $selected_recs[].bytes_used ] | max)
  } end;

def latest_snapshot_for_lang($all; $lang):
  ($all | map(select(.lang == $lang))) as $lang_recs |
  if ($lang_recs | length) == 0 then
    []
  elif $target_commit != "" then
    ($lang_recs
     | map(select((.commit // "unknown") == $target_commit))
     | group_by(.name)
     | map(pool_records(.) | . + {commit: $target_commit, baseline_commit: $target_commit})
     | sort_by(.rank))
  else
    (($lang_recs | map(select((.commit // "unknown") != "unknown" and (.commit // "") != ""))) as $known |
     (if ($known | length) > 0 then $known else $lang_recs end) as $scoped |
     ($scoped | last.commit // "unknown") as $overall_lc |
     (reduce $scoped[] as $r ({order: [], counts: {}};
       ($r.commit // "unknown") as $c |
       (if (.counts[$c] // null) == null then
          .order += [$c] | .counts[$c] = {}
        else . end)
       | .counts[$c][$r.name] = true
     )) as $by_commit |
     ([ $by_commit.order[] | {c: ., n: ($by_commit.counts[.] | keys | length)} ]) as $commit_sizes |
     ([$commit_sizes[].n] | max) as $max_n |
     ([$commit_sizes | to_entries[] | select(.value.n == $max_n) | .key] | last) as $full_idx |
     ($commit_sizes[$full_idx].c // $overall_lc) as $baseline_sha |
     ([$commit_sizes[$full_idx:][].c]) as $active_commits |
     ($active_commits | map($by_commit.counts[.] | keys[]) | unique) as $active_names |
     ($active_names | map({key: ., value: true}) | from_entries) as $active_set |
     $scoped
     | map(select($active_set[.name] == true))
     | group_by(.name)
     | map(
         (last.commit // "unknown") as $name_lc |
         map(select((.commit // "unknown") == $name_lc))
         | pool_records(.)
         | . + {commit: $name_lc, baseline_commit: $baseline_sha, latest_commit: $overall_lc}
       )
     | sort_by(.rank))
  end;

def distinct_commits($all; $lang):
  ($all
   | map(select(.lang == $lang and (.commit // "unknown") != "unknown" and (.commit // "") != ""))
   | reduce .[] as $r ([]; if index($r.commit) then . else . + [$r.commit] end)) as $commits |
  ($commits | map(select(endswith("-dirty") | not))) as $clean |
  if ($clean | length) > 0 then $clean else $commits end;

def pool_commit_snapshot($all; $lang; $sha):
  ($all
   | map(select(.lang == $lang and (.commit // "unknown") == $sha))
   | group_by(.name)
   | map(pool_records(.) | .commit = $sha)
   | sort_by(.rank));

def bench_link($name):
  ($code_map[$name].slice_doc // "") as $sdoc |
  if $sdoc != "" then
    "[`\($name | nbsp)`](\($sdoc))"
  else
    "`\($name | nbsp)`"
  end;

def rank_cell($row; $mode):
  (if $mode == "odin" then ($code_map[$row.name].odin_bench // "")
   elif $mode == "elixir" then ($code_map[$row.name].elixir_bench // "")
   else ($code_map[$row.name].slice_doc // "")
   end) as $href |
  (if $href != "" then "[#\($row.rank)](\($href))" else "#\($row.rank)" end) as $base |
  if ($row.commit // "") != ($row.baseline_commit // $row.commit // "") then
    "\($base)\u00a0↻"
  else
    $base
  end;

def fmt_duration_cell($ns):
  if $ns < 1000 then "\($ns | round | commify)\u00a0ns"
  elif $ns < 1000000 then "\(fmt_us($ns))\u00a0µs"
  else "\(fmt_dec2($ns / 1000000.0))\u00a0ms"
  end;

def tier_table_ns($list; $mode):
  "| # | Benchmark | Med\u00a0(`ns`) | Mean\u00a0±\u00a0σ | CV | Min\u00a0`ops/s` | Max\u00a0`ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |",
  "| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  ($list[] |
    fmt_ops_bounds(.min_ns; .max_ns) as $ops_b |
    "| \(rank_cell(.; $mode)) | \(bench_link(.name)) | **\(.ns_per_op | commify)** | \(.mean_ns | round | commify)\u00a0±\u00a0\(fmt_sigma(.stddev_ns)) | \(fmt_dec1(.cv_pct))% | \($ops_b[0]) | \($ops_b[1]) | \(.iqr_ns | round | commify) | \(.p95_ns | commify) | \(.p99_ns | commify) | \(.min_ns | commify) | \(.max_ns | commify) | \(fmt_ops_count(.ops)) |"
  );

def tier_table_us($list; $mode):
  "| # | Benchmark | Med\u00a0(`µs`) | Mean\u00a0±\u00a0σ | CV | Min\u00a0`ops/s` | Max\u00a0`ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |",
  "| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  ($list[] |
    fmt_ops_bounds(.min_ns; .max_ns) as $ops_b |
    "| \(rank_cell(.; $mode)) | \(bench_link(.name)) | **\(fmt_us(.median_ns))** | \(fmt_us(.mean_ns))\u00a0±\u00a0\(fmt_us(.stddev_ns)) | \(fmt_dec1(.cv_pct))% | \($ops_b[0]) | \($ops_b[1]) | \(fmt_us(.iqr_ns)) | \(fmt_us(.p95_ns)) | \(fmt_us(.p99_ns)) | \(fmt_us(.min_ns)) | \(fmt_us(.max_ns)) | \(fmt_ops_count(.ops)) |"
  );

def single_lang_section($sec_num; $lang_label; $mode; $flags; $sha; $list):
  ($list | map(select(.ns_per_op < 1000))) as $sub_us |
  ($list | map(select(.ns_per_op >= 1000))) as $multi_us |
  ($list | map(select(.commit != (.baseline_commit // .commit))) | length) as $selective_cnt |
  "### \($sec_num). \($lang_label) Results (`\($flags)`, Commit `\($sha)`, \($list[0].runs) samples across \($list[0].invocations) run(s))\n",
  (if $selective_cnt > 0 then
    "\n> _Note: `\($selective_cnt)` row(s) marked `↻` reflect selective/affected updates on a newer commit atop baseline `\($list[0].baseline_commit)`._\n"
   else empty end),
  (if ($sub_us | length) > 0 then
    "#### \($sec_num).1 Sub-Microsecond Fast Path (`< 1 µs`, \($sub_us | length) tests)\n",
    tier_table_ns($sub_us; $mode),
    "\n"
   else empty end),
  "#### \($sec_num).2 Multi-Microsecond Client Operations (`≥ 1 µs`, \($multi_us | length) tests)\n",
  tier_table_us($multi_us; $mode);

def compare_1v1_table($list; $ex_map; $unit):
  "| # | Benchmark | NIF\u00a0Ratio | Raw\u00a0Odin\u00a0Med\u00a0(`\($unit)`) | Elixir\u00a0Med\u00a0(`\($unit)`) | Welch\u00a0`z` | Odin\u00a0Mean\u00a0±\u00a0σ | Odin\u00a0CV | Elixir\u00a0Mean\u00a0±\u00a0σ | Elixir\u00a0CV |",
  "| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  ($list[] | . as $o | $ex_map[$o.name] as $e | select($e != null) |
    welch_z($o; $e) as $wz |
    (if $wz >= 1.96 then "`\(fmt_dec1($wz))`\u00a0★" else "`\(fmt_dec1($wz))`\u00a0~" end) as $sig_col |
    (if ($o.commit != ($o.baseline_commit // $o.commit) or $e.commit != ($e.baseline_commit // $e.commit)) then "\u00a0↻" else "" end) as $sel_mark |
    (if $unit == "µs" then
      "| \($o.rank)\($sel_mark) | \(bench_link($o.name)) | **\(fmt_ratio($o.median_ns; $e.median_ns))** | \(fmt_us($o.median_ns)) | **\(fmt_us($e.median_ns))** | \($sig_col) | \(fmt_us($o.mean_ns))\u00a0±\u00a0\(fmt_us($o.stddev_ns)) | \(fmt_dec1($o.cv_pct))% | \(fmt_us($e.mean_ns))\u00a0±\u00a0\(fmt_us($e.stddev_ns)) | \(fmt_dec1($e.cv_pct))% |"
     else
      "| \($o.rank)\($sel_mark) | \(bench_link($o.name)) | **\(fmt_ratio($o.ns_per_op; $e.ns_per_op))** | \($o.ns_per_op | commify) | **\($e.ns_per_op | commify)** | \($sig_col) | \($o.mean_ns | round | commify)\u00a0±\u00a0\(fmt_sigma($o.stddev_ns)) | \(fmt_dec1($o.cv_pct))% | \($e.mean_ns | round | commify)\u00a0±\u00a0\(fmt_sigma($e.stddev_ns)) | \(fmt_dec1($e.cv_pct))% |"
     end)
  );

def compare_commits_table($prev_sha; $curr_sha; $prev_list; $curr_list):
  (reduce $curr_list[] as $c ({}; .[$c.name] = $c)) as $curr_map |
  "| # | Benchmark | `\($prev_sha)`\u00a0Med | `\($curr_sha)`\u00a0Med | Δ% | Speedup | Welch\u00a0`z` | `\($prev_sha)`\u00a0Mean\u00a0±\u00a0σ | `\($curr_sha)`\u00a0Mean\u00a0±\u00a0σ |",
  "| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  ($prev_list[] | . as $a | $curr_map[$a.name] as $b | select($b != null) |
    (if $a.median_ns > 0 then (($b.median_ns - $a.median_ns) / $a.median_ns * 100.0) else 0.0 end) as $pct |
    (if $pct >= 0 then "+\(fmt_dec1($pct))%" else "\(fmt_dec1($pct))%" end) as $delta_col |
    (if $b.median_ns > 0 then ($a.median_ns / $b.median_ns) else 1.0 end) as $sp |
    welch_z($a; $b) as $wz |
    (if $wz >= 1.96 then "`\(fmt_dec1($wz))`\u00a0★" else "`\(fmt_dec1($wz))`\u00a0~" end) as $sig_col |
    "| \($b.rank) | \(bench_link($b.name)) | \(fmt_duration_cell($a.median_ns)) | **\(fmt_duration_cell($b.median_ns))** | \($delta_col) | **\(fmt_dec2($sp))x** | \($sig_col) | \(fmt_duration_cell($a.mean_ns))\u00a0±\u00a0\(fmt_duration_cell($a.stddev_ns)) | \(fmt_duration_cell($b.mean_ns))\u00a0±\u00a0\(fmt_duration_cell($b.stddev_ns)) |"
  );

[inputs] as $all |
latest_snapshot_for_lang($all; "odin") as $odin_list |
latest_snapshot_for_lang($all; "elixir") as $ex_list |
(reduce $ex_list[] as $e ({}; .[$e.name] = $e)) as $ex_map |
($odin_list[0].latest_commit // $odin_list[0].commit // "unknown") as $odin_sha |
($ex_list[0].latest_commit // $ex_list[0].commit // "unknown") as $ex_sha |
($odin_list | map(select($ex_map[.name] != null))) as $paired_list |
($paired_list | map(select($ex_map[.name].ns_per_op < 1000))) as $paired_sub_us |
($paired_list | map(select($ex_map[.name].ns_per_op >= 1000))) as $paired_multi_us |
distinct_commits($all; "elixir") as $ex_commits |
distinct_commits($all; "odin") as $odin_commits |

single_lang_section("1"; "Elixir Client Wrapper"; "elixir"; "mix run + priv/xitdb_nif.so -o:speed"; $ex_sha; $ex_list),
"\n",
single_lang_section("2"; "Raw Odin Baseline"; "odin"; "odin run benchmarks -o:speed -microarch:native"; $odin_sha; $odin_list),
"\n### 3. 1v1 Client Boundary Comparison (Elixir NIF Wrapper vs. Raw Odin, Commit `\($ex_sha)`)\n",
(if ($paired_sub_us | length) > 0 then
  "#### 3.1 Sub-Microsecond Fast Path (Elixir `< 1 µs`, \($paired_sub_us | length) tests)\n",
  compare_1v1_table($paired_sub_us; $ex_map; "ns"),
  "\n"
 else empty end),
"#### 3.2 Multi-Microsecond Client Operations (Elixir `≥ 1 µs`, \($paired_multi_us | length) tests)\n",
compare_1v1_table($paired_multi_us; $ex_map; "µs"),
"\n### 4. Commit-vs-Commit Progression\n",
(if ($ex_commits | length) >= 2 then
  ($ex_commits[-2]) as $prev_sha |
  ($ex_commits[-1]) as $curr_sha |
  pool_commit_snapshot($all; "elixir"; $prev_sha) as $ex_prev |
  pool_commit_snapshot($all; "elixir"; $curr_sha) as $ex_curr |
  "\n#### 4.1 Elixir Client Wrapper (`\($prev_sha)` → `\($curr_sha)`)\n",
  compare_commits_table($prev_sha; $curr_sha; $ex_prev; $ex_curr),
  "\n"
 else
  "\n_Only one Elixir commit recorded so far; run on another commit to populate commit-vs-commit progression._\n"
 end),
(if ($odin_commits | length) >= 2 then
  ($odin_commits[-2]) as $o_prev_sha |
  ($odin_commits[-1]) as $o_curr_sha |
  pool_commit_snapshot($all; "odin"; $o_prev_sha) as $od_prev |
  pool_commit_snapshot($all; "odin"; $o_curr_sha) as $od_curr |
  "\n#### 4.2 Raw Odin Baseline (`\($o_prev_sha)` → `\($o_curr_sha)`)\n",
  compare_commits_table($o_prev_sha; $o_curr_sha; $od_prev; $od_curr),
  "\n"
 else empty end),
"\n### 5. Database Storage Footprint (`bytes_used > 0`)\n",
"| # | Benchmark | Ops | Raw\u00a0Odin\u00a0Size | Elixir\u00a0Wrapper\u00a0Size |",
"| ---: | :--- | ---: | ---: | ---: |",
($odin_list[] | select(.bytes_used > 0) | . as $o | ($ex_map[$o.name] // null) as $e |
  "| \($o.rank) | \(bench_link($o.name)) | \(fmt_ops_count($o.ops)) | \(fmt_kb($o.bytes_used)) | \(if $e != null and $e.bytes_used > 0 then fmt_kb($e.bytes_used) else "—" end) |"
)
' "${INPUT_FILES[@]}")

AWK_SCRIPT='
BEGIN { in_block = 0 }
/<!-- BEGIN_BENCHMARK_TABLE -->/ {
    print
    print tables
    in_block = 1
    next
}
/<!-- END_BENCHMARK_TABLE -->/ {
    in_block = 0
}
!in_block { print }
'

awk -v tables="${TABLES}" "${AWK_SCRIPT}" "${README_MD}" > "${README_MD}.tmp"
mv "${README_MD}.tmp" "${README_MD}"
echo "Updated ${README_MD} with full client benchmark tables (Elixir Wrapper vs Raw Odin)."
