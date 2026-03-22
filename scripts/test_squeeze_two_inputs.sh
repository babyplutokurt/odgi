#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Run a focused 2-input squeeze test (e.g. chrY + chr1) across og/gfa/gfaz.

Usage:
  $(basename "$0") \
    --a-og <chrY.og>   --a-gfa <chrY.gfa>   --a-gfaz <chrY.gfaz> \
    --b-og <chr1.og>   --b-gfa <chr1.gfa>   --b-gfaz <chr1.gfaz> \
    [--odgi <path/to/odgi>] \
    [--threads <N>] \
    [--runs <N>] \
    [--out-dir <dir>] \
    [--prefix <name>]

Outputs:
  <out-dir>/<prefix>.tsv
  <out-dir>/<prefix>_summary.md
  <out-dir>/<prefix>_compare.md
  <out-dir>/<prefix>_outputs/...

What it executes:
  1) noopt   : odgi squeeze (two inputs)
  2) opt     : odgi squeeze -O (two inputs)
  3) suffix  : odgi squeeze -s '#' (two inputs)

For each mode it runs:
  - og list   : [A.og,   B.og]
  - gfa list  : [A.gfa,  B.gfa]
  - gfaz list : [A.gfaz, B.gfaz]

Parity checks (run1):
  - odgi stats -S -L -b -y
  - sorted path names (odgi paths -L)
USAGE
}

ODGI_BIN="./bin/odgi"
THREADS="$(nproc 2>/dev/null || echo 1)"
RUNS=1
OUT_DIR="./benchmarks"
PREFIX="squeeze_two_inputs"

A_OG=""
A_GFA=""
A_GFAZ=""
B_OG=""
B_GFA=""
B_GFAZ=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --odgi) ODGI_BIN="$2"; shift 2 ;;
    --a-og) A_OG="$2"; shift 2 ;;
    --a-gfa) A_GFA="$2"; shift 2 ;;
    --a-gfaz) A_GFAZ="$2"; shift 2 ;;
    --b-og) B_OG="$2"; shift 2 ;;
    --b-gfa) B_GFA="$2"; shift 2 ;;
    --b-gfaz) B_GFAZ="$2"; shift 2 ;;
    --threads) THREADS="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

for f in "$A_OG" "$A_GFA" "$A_GFAZ" "$B_OG" "$B_GFA" "$B_GFAZ"; do
  if [[ -z "$f" ]]; then
    echo "error: all --a-* and --b-* inputs are required" >&2
    usage
    exit 1
  fi
  if [[ ! -f "$f" ]]; then
    echo "error: file not found: $f" >&2
    exit 1
  fi
done

if [[ ! -x "$ODGI_BIN" ]]; then
  echo "error: odgi binary not executable: $ODGI_BIN" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
OUT_BASE="$OUT_DIR/${PREFIX}"
OUT_RUN_DIR="${OUT_BASE}_outputs"
mkdir -p "$OUT_RUN_DIR"

TSV="${OUT_BASE}.tsv"
SUMMARY="${OUT_BASE}_summary.md"
COMPARE="${OUT_BASE}_compare.md"

TIME_BIN=""
if command -v /usr/bin/time >/dev/null 2>&1; then
  TIME_BIN="/usr/bin/time"
fi

echo -e "mode\tformat\trun\twall_sec\tuser_sec\tsys_sec\tmax_rss_kb\texit_code\tout_og\tstats_file\tpaths_file\tstdout_file\tstderr_file" > "$TSV"

write_list_file() {
  local list_file="$1"
  local first="$2"
  local second="$3"
  cat > "$list_file" <<EOF
$first
$second
EOF
}

collect_outputs() {
  local out_og="$1"
  local stats_file="$2"
  local paths_file="$3"
  "$ODGI_BIN" stats -i "$out_og" -S -L -b -y > "$stats_file"
  "$ODGI_BIN" paths -i "$out_og" -L | LC_ALL=C sort > "$paths_file"
}

run_case() {
  local mode="$1"
  local format="$2"
  local squeeze_args="$3"
  local list_file="$4"
  local run_id="$5"

  local out_og="$OUT_RUN_DIR/${mode}__${format}__run${run_id}.og"
  local stats_file="$OUT_RUN_DIR/${mode}__${format}__run${run_id}.stats"
  local paths_file="$OUT_RUN_DIR/${mode}__${format}__run${run_id}.paths"
  local stdout_file="$OUT_RUN_DIR/${mode}__${format}__run${run_id}.out"
  local stderr_file="$OUT_RUN_DIR/${mode}__${format}__run${run_id}.err"
  local time_file="$OUT_RUN_DIR/${mode}__${format}__run${run_id}.time"

  rm -f "$out_og" "$stats_file" "$paths_file" "$stdout_file" "$stderr_file" "$time_file"

  local ec=0
  if [[ -n "$TIME_BIN" ]]; then
    set +e
    # shellcheck disable=SC2086
    "$TIME_BIN" -f "WALL=%e\nUSER=%U\nSYS=%S\nRSS_KB=%M" -o "$time_file" \
      "$ODGI_BIN" squeeze -f "$list_file" -o "$out_og" -t "$THREADS" $squeeze_args \
      >"$stdout_file" 2>"$stderr_file"
    ec=$?
    set -e
  else
    set +e
    # shellcheck disable=SC2086
    { time "$ODGI_BIN" squeeze -f "$list_file" -o "$out_og" -t "$THREADS" $squeeze_args ; } \
      >"$stdout_file" 2>"$stderr_file"
    ec=$?
    set -e
  fi

  local wall="NA" user="NA" sys="NA" rss="NA"
  if [[ -n "$TIME_BIN" ]]; then
    wall="$(awk -F= '/^WALL=/{print $2}' "$time_file" | tail -n1)"
    user="$(awk -F= '/^USER=/{print $2}' "$time_file" | tail -n1)"
    sys="$(awk -F= '/^SYS=/{print $2}' "$time_file" | tail -n1)"
    rss="$(awk -F= '/^RSS_KB=/{print $2}' "$time_file" | tail -n1)"
  fi

  if [[ "$ec" -eq 0 ]]; then
    collect_outputs "$out_og" "$stats_file" "$paths_file"
  fi

  echo -e "${mode}\t${format}\t${run_id}\t${wall:-NA}\t${user:-NA}\t${sys:-NA}\t${rss:-NA}\t${ec}\t${out_og}\t${stats_file}\t${paths_file}\t${stdout_file}\t${stderr_file}" >> "$TSV"
}

list_og="$OUT_RUN_DIR/list_og.txt"
list_gfa="$OUT_RUN_DIR/list_gfa.txt"
list_gfaz="$OUT_RUN_DIR/list_gfaz.txt"

write_list_file "$list_og" "$A_OG" "$B_OG"
write_list_file "$list_gfa" "$A_GFA" "$B_GFA"
write_list_file "$list_gfaz" "$A_GFAZ" "$B_GFAZ"

echo "Running 2-input squeeze test: runs=$RUNS threads=$THREADS"
for r in $(seq 1 "$RUNS"); do
  for mode in noopt opt suffix; do
    case "$mode" in
      noopt) args="" ;;
      opt) args="-O" ;;
      suffix) args="-s #" ;;
    esac
    echo "[run $r/$RUNS] mode=$mode format=og"
    run_case "$mode" "og" "$args" "$list_og" "$r"
    echo "[run $r/$RUNS] mode=$mode format=gfa"
    run_case "$mode" "gfa" "$args" "$list_gfa" "$r"
    echo "[run $r/$RUNS] mode=$mode format=gfaz"
    run_case "$mode" "gfaz" "$args" "$list_gfaz" "$r"
  done
done

awk -F'\t' '
BEGIN {
  print "# squeeze 2-input Benchmark Summary"
  print ""
  print "| mode | format | runs | avg_wall_sec | best_wall_sec | avg_rss_kb | avg_user_sec | avg_sys_sec | failures |"
  print "|---|---|---:|---:|---:|---:|---:|---:|---:|"
}
NR > 1 {
  key = $1 "\t" $2
  if ($8 != 0) fail[key]++
  if ($4 != "NA") {
    wall_sum[key] += $4; wall_n[key] += 1
    if (!(key in wall_best) || $4 < wall_best[key]) wall_best[key] = $4
  }
  if ($7 != "NA") { rss_sum[key] += $7; rss_n[key] += 1 }
  if ($5 != "NA") { user_sum[key] += $5; user_n[key] += 1 }
  if ($6 != "NA") { sys_sum[key] += $6; sys_n[key] += 1 }
  seen[key] = 1
}
END {
  modes[1] = "noopt"; modes[2] = "opt"; modes[3] = "suffix"
  formats[1] = "og"; formats[2] = "gfa"; formats[3] = "gfaz"
  for (mi = 1; mi <= 3; mi++) {
    for (fi = 1; fi <= 3; fi++) {
      key = modes[mi] "\t" formats[fi]
      if (!(key in seen)) continue
      aw = (wall_n[key] ? wall_sum[key] / wall_n[key] : "NA")
      bw = (wall_n[key] ? wall_best[key] : "NA")
      ar = (rss_n[key] ? rss_sum[key] / rss_n[key] : "NA")
      au = (user_n[key] ? user_sum[key] / user_n[key] : "NA")
      as = (sys_n[key] ? sys_sum[key] / sys_n[key] : "NA")
      fails = (key in fail ? fail[key] : 0)
      runs = (key in wall_n ? wall_n[key] : 0)
      printf("| %s | %s | %d | %s | %s | %s | %s | %s | %d |\n", modes[mi], formats[fi], runs, aw, bw, ar, au, as, fails)
    }
  }
}
' "$TSV" > "$SUMMARY"

compare_file() {
  local a="$1"
  local b="$2"
  if diff -u "$a" "$b" >/dev/null 2>&1; then
    echo "match"
  else
    echo "mismatch"
  fi
}

row_for() {
  local mode="$1"
  local format="$2"
  awk -F'\t' -v m="$mode" -v f="$format" '$1==m && $2==f && $3==1 { print; exit }' "$TSV"
}

{
  echo "# squeeze 2-input Output Comparison"
  echo
  echo "| mode | compare_kind | og_vs_gfa | og_vs_gfaz | note |"
  echo "|---|---|---|---|---|"
  for mode in noopt opt suffix; do
    og_row="$(row_for "$mode" "og")"
    gfa_row="$(row_for "$mode" "gfa")"
    gfaz_row="$(row_for "$mode" "gfaz")"

    og_stats="$(echo "$og_row" | awk -F'\t' '{print $10}')"
    gfa_stats="$(echo "$gfa_row" | awk -F'\t' '{print $10}')"
    gfaz_stats="$(echo "$gfaz_row" | awk -F'\t' '{print $10}')"

    og_paths="$(echo "$og_row" | awk -F'\t' '{print $11}')"
    gfa_paths="$(echo "$gfa_row" | awk -F'\t' '{print $11}')"
    gfaz_paths="$(echo "$gfaz_row" | awk -F'\t' '{print $11}')"

    s1="$(compare_file "$og_stats" "$gfa_stats")"
    s2="$(compare_file "$og_stats" "$gfaz_stats")"
    p1="$(compare_file "$og_paths" "$gfa_paths")"
    p2="$(compare_file "$og_paths" "$gfaz_paths")"

    echo "| ${mode}_stats | exact | ${s1} | ${s2} | odgi stats -S -L -b -y |"
    echo "| ${mode}_paths | exact | ${p1} | ${p2} | sorted path names |"
  done
} > "$COMPARE"

echo "Wrote: $TSV"
echo "Wrote: $SUMMARY"
echo "Wrote: $COMPARE"
