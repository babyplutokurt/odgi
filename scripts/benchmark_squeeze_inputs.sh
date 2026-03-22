#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Benchmark and validate odgi squeeze across .og, .gfa, and .gfaz inputs.

Usage:
  $(basename "$0") \
    --og <graph.og> \
    --gfa <graph.gfa> \
    --gfaz <graph.gfaz> \
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

Notes:
  - Uses /usr/bin/time if available (captures max RSS in KB).
  - Compares squeezed outputs via:
      1) odgi stats (-S -L -b -y)
      2) sorted path-name list (odgi paths -L)
  - Includes mixed-list and suffix checks.
USAGE
}

ODGI_BIN="./bin/odgi"
THREADS="$(nproc 2>/dev/null || echo 1)"
RUNS=3
OUT_DIR="./benchmarks"
PREFIX="squeeze_inputs_benchmark"
OG_FILE=""
GFA_FILE=""
GFAZ_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --odgi)
      ODGI_BIN="$2"; shift 2 ;;
    --og)
      OG_FILE="$2"; shift 2 ;;
    --gfa)
      GFA_FILE="$2"; shift 2 ;;
    --gfaz)
      GFAZ_FILE="$2"; shift 2 ;;
    --threads)
      THREADS="$2"; shift 2 ;;
    --runs)
      RUNS="$2"; shift 2 ;;
    --out-dir)
      OUT_DIR="$2"; shift 2 ;;
    --prefix)
      PREFIX="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1 ;;
  esac
done

if [[ -z "$OG_FILE" || -z "$GFA_FILE" || -z "$GFAZ_FILE" ]]; then
  echo "error: --og, --gfa, and --gfaz are required" >&2
  usage
  exit 1
fi

if [[ ! -x "$ODGI_BIN" ]]; then
  echo "error: odgi binary not executable: $ODGI_BIN" >&2
  exit 1
fi
if [[ ! -f "$OG_FILE" ]]; then
  echo "error: .og file not found: $OG_FILE" >&2
  exit 1
fi
if [[ ! -f "$GFA_FILE" ]]; then
  echo "error: .gfa file not found: $GFA_FILE" >&2
  exit 1
fi
if [[ ! -f "$GFAZ_FILE" ]]; then
  echo "error: .gfaz file not found: $GFAZ_FILE" >&2
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

echo -e "mode\tinput\trun\twall_sec\tuser_sec\tsys_sec\tmax_rss_kb\texit_code\tout_og\tstdout_file\tstderr_file\tstats_file\tpaths_file" > "$TSV"

write_list_file() {
  local list_file="$1"
  shift
  : > "$list_file"
  for input in "$@"; do
    echo "$input" >> "$list_file"
  done
}

postprocess_output() {
  local out_og="$1"
  local stats_file="$2"
  local paths_file="$3"
  "$ODGI_BIN" stats -i "$out_og" -S -L -b -y > "$stats_file"
  "$ODGI_BIN" paths -i "$out_og" -L | LC_ALL=C sort > "$paths_file"
}

run_squeeze_case() {
  local mode="$1"
  local input="$2"
  local run_id="$3"
  local squeeze_args="$4"
  local list_file="$5"

  local out_og="$OUT_RUN_DIR/${mode}__${input}__run${run_id}.og"
  local stdout_file="$OUT_RUN_DIR/${mode}__${input}__run${run_id}.out"
  local stderr_file="$OUT_RUN_DIR/${mode}__${input}__run${run_id}.err"
  local time_file="$OUT_RUN_DIR/${mode}__${input}__run${run_id}.time"
  local stats_file="$OUT_RUN_DIR/${mode}__${input}__run${run_id}.stats"
  local paths_file="$OUT_RUN_DIR/${mode}__${input}__run${run_id}.paths"

  rm -f "$out_og" "$stdout_file" "$stderr_file" "$time_file" "$stats_file" "$paths_file"

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
    postprocess_output "$out_og" "$stats_file" "$paths_file"
  fi

  echo -e "${mode}\t${input}\t${run_id}\t${wall:-NA}\t${user:-NA}\t${sys:-NA}\t${rss:-NA}\t${ec}\t${out_og}\t${stdout_file}\t${stderr_file}\t${stats_file}\t${paths_file}" >> "$TSV"
}

echo "Running squeeze benchmark: runs=$RUNS threads=$THREADS"
echo "  og:   $OG_FILE"
echo "  gfa:  $GFA_FILE"
echo "  gfaz: $GFAZ_FILE"

single_og_list="$OUT_RUN_DIR/list_single_og.txt"
single_gfa_list="$OUT_RUN_DIR/list_single_gfa.txt"
single_gfaz_list="$OUT_RUN_DIR/list_single_gfaz.txt"
mixed_gfa_list="$OUT_RUN_DIR/list_mixed_og_gfa.txt"
mixed_gfaz_list="$OUT_RUN_DIR/list_mixed_og_gfaz.txt"

write_list_file "$single_og_list" "$OG_FILE"
write_list_file "$single_gfa_list" "$GFA_FILE"
write_list_file "$single_gfaz_list" "$GFAZ_FILE"
write_list_file "$mixed_gfa_list" "$OG_FILE" "$GFA_FILE"
write_list_file "$mixed_gfaz_list" "$OG_FILE" "$GFAZ_FILE"

for r in $(seq 1 "$RUNS"); do
  echo "[run $r/$RUNS] mode=single_noopt input=og"
  run_squeeze_case "single_noopt" "og" "$r" "" "$single_og_list"
  echo "[run $r/$RUNS] mode=single_noopt input=gfa"
  run_squeeze_case "single_noopt" "gfa" "$r" "" "$single_gfa_list"
  echo "[run $r/$RUNS] mode=single_noopt input=gfaz"
  run_squeeze_case "single_noopt" "gfaz" "$r" "" "$single_gfaz_list"

  echo "[run $r/$RUNS] mode=single_opt input=og"
  run_squeeze_case "single_opt" "og" "$r" "-O" "$single_og_list"
  echo "[run $r/$RUNS] mode=single_opt input=gfa"
  run_squeeze_case "single_opt" "gfa" "$r" "-O" "$single_gfa_list"
  echo "[run $r/$RUNS] mode=single_opt input=gfaz"
  run_squeeze_case "single_opt" "gfaz" "$r" "-O" "$single_gfaz_list"

  echo "[run $r/$RUNS] mode=single_suffix input=og"
  run_squeeze_case "single_suffix" "og" "$r" "-s #" "$single_og_list"
  echo "[run $r/$RUNS] mode=single_suffix input=gfa"
  run_squeeze_case "single_suffix" "gfa" "$r" "-s #" "$single_gfa_list"
  echo "[run $r/$RUNS] mode=single_suffix input=gfaz"
  run_squeeze_case "single_suffix" "gfaz" "$r" "-s #" "$single_gfaz_list"

  echo "[run $r/$RUNS] mode=mixed_suffix input=og_gfa"
  run_squeeze_case "mixed_suffix" "og_gfa" "$r" "-s #" "$mixed_gfa_list"
  echo "[run $r/$RUNS] mode=mixed_suffix input=og_gfaz"
  run_squeeze_case "mixed_suffix" "og_gfaz" "$r" "-s #" "$mixed_gfaz_list"
done

awk -F'\t' '
BEGIN {
  print "# squeeze Benchmark Summary"
  print ""
  print "| mode | input | runs | avg_wall_sec | best_wall_sec | avg_rss_kb | avg_user_sec | avg_sys_sec | failures |"
  print "|---|---|---:|---:|---:|---:|---:|---:|---:|"
}
NR > 1 {
  mode = $1
  input = $2
  key = mode "\t" input
  if ($8 != 0) fail[key]++
  if ($4 != "NA") {
    wall_sum[key] += $4
    wall_n[key] += 1
    if (!(key in wall_best) || $4 < wall_best[key]) wall_best[key] = $4
  }
  if ($7 != "NA") { rss_sum[key] += $7; rss_n[key] += 1 }
  if ($5 != "NA") { user_sum[key] += $5; user_n[key] += 1 }
  if ($6 != "NA") { sys_sum[key] += $6; sys_n[key] += 1 }
  seen[key] = 1
}
END {
  mode_order[1] = "single_noopt"
  mode_order[2] = "single_opt"
  mode_order[3] = "single_suffix"
  mode_order[4] = "mixed_suffix"
  input_order[1] = "og"
  input_order[2] = "gfa"
  input_order[3] = "gfaz"
  input_order[4] = "og_gfa"
  input_order[5] = "og_gfaz"

  for (mi = 1; mi <= 4; mi++) {
    mode = mode_order[mi]
    for (ii = 1; ii <= 5; ii++) {
      input = input_order[ii]
      key = mode "\t" input
      if (!(key in seen)) continue
      aw = (wall_n[key] ? wall_sum[key] / wall_n[key] : "NA")
      bw = (wall_n[key] ? wall_best[key] : "NA")
      ar = (rss_n[key] ? rss_sum[key] / rss_n[key] : "NA")
      au = (user_n[key] ? user_sum[key] / user_n[key] : "NA")
      as = (sys_n[key] ? sys_sum[key] / sys_n[key] : "NA")
      fails = (key in fail ? fail[key] : 0)
      runs = (key in wall_n ? wall_n[key] : 0)
      printf("| %s | %s | %d | %s | %s | %s | %s | %s | %d |\n", mode, input, runs, aw, bw, ar, au, as, fails)
    }
  }
}
' "$TSV" > "$SUMMARY"

compare_exact() {
  local a="$1"
  local b="$2"
  if diff -u "$a" "$b" >/dev/null 2>&1; then
    echo "match"
  else
    echo "mismatch"
  fi
}

suffix_check_single() {
  local paths_file="$1"
  if [[ ! -s "$paths_file" ]]; then
    echo "empty"
    return
  fi
  if awk 'substr($0, length($0)-1, 2) != "#0" { bad=1 } END { exit bad }' "$paths_file"; then
    echo "ok"
  else
    echo "bad"
  fi
}

suffix_check_mixed() {
  local paths_file="$1"
  if [[ ! -s "$paths_file" ]]; then
    echo "empty"
    return
  fi
  if awk '
    {
      if ($0 ~ /#0$/) has0=1
      else if ($0 ~ /#1$/) has1=1
      else bad=1
    }
    END { exit (bad || !has0 || !has1) ? 1 : 0 }
  ' "$paths_file"; then
    echo "ok"
  else
    echo "bad"
  fi
}

row_for() {
  local mode="$1"
  local input="$2"
  awk -F'\t' -v m="$mode" -v i="$input" '$1==m && $2==i && $3==1 { print; exit }' "$TSV"
}

{
  echo "# squeeze Output Comparison"
  echo
  echo "| mode | compare_kind | og_vs_gfa | og_vs_gfaz | extra_check | note |"
  echo "|---|---|---|---|---|---|"

  for mode in single_noopt single_opt single_suffix; do
    og_row="$(row_for "$mode" "og")"
    gfa_row="$(row_for "$mode" "gfa")"
    gfaz_row="$(row_for "$mode" "gfaz")"

    og_stats="$(echo "$og_row" | awk -F'\t' '{print $12}')"
    gfa_stats="$(echo "$gfa_row" | awk -F'\t' '{print $12}')"
    gfaz_stats="$(echo "$gfaz_row" | awk -F'\t' '{print $12}')"

    og_paths="$(echo "$og_row" | awk -F'\t' '{print $13}')"
    gfa_paths="$(echo "$gfa_row" | awk -F'\t' '{print $13}')"
    gfaz_paths="$(echo "$gfaz_row" | awk -F'\t' '{print $13}')"

    stats_og_gfa="$(compare_exact "$og_stats" "$gfa_stats")"
    stats_og_gfaz="$(compare_exact "$og_stats" "$gfaz_stats")"
    paths_og_gfa="$(compare_exact "$og_paths" "$gfa_paths")"
    paths_og_gfaz="$(compare_exact "$og_paths" "$gfaz_paths")"

    extra="-"
    note="stats and path-list must match"
    if [[ "$mode" == "single_suffix" ]]; then
      extra="og:$(suffix_check_single "$og_paths"), gfa:$(suffix_check_single "$gfa_paths"), gfaz:$(suffix_check_single "$gfaz_paths")"
      note="single graph with -s # should end all names with #0"
    fi

    echo "| ${mode}_stats | exact | ${stats_og_gfa} | ${stats_og_gfaz} | ${extra} | ${note} |"
    echo "| ${mode}_paths | exact | ${paths_og_gfa} | ${paths_og_gfaz} | ${extra} | ${note} |"
  done

  mixed_gfa_row="$(row_for "mixed_suffix" "og_gfa")"
  mixed_gfaz_row="$(row_for "mixed_suffix" "og_gfaz")"

  mixed_gfa_stats="$(echo "$mixed_gfa_row" | awk -F'\t' '{print $12}')"
  mixed_gfaz_stats="$(echo "$mixed_gfaz_row" | awk -F'\t' '{print $12}')"
  mixed_gfa_paths="$(echo "$mixed_gfa_row" | awk -F'\t' '{print $13}')"
  mixed_gfaz_paths="$(echo "$mixed_gfaz_row" | awk -F'\t' '{print $13}')"

  mixed_stats_cmp="$(compare_exact "$mixed_gfa_stats" "$mixed_gfaz_stats")"
  mixed_paths_cmp="$(compare_exact "$mixed_gfa_paths" "$mixed_gfaz_paths")"
  mixed_extra="og+gfa:$(suffix_check_mixed "$mixed_gfa_paths"), og+gfaz:$(suffix_check_mixed "$mixed_gfaz_paths")"

  echo "| mixed_suffix_stats | exact | ${mixed_stats_cmp} | ${mixed_stats_cmp} | ${mixed_extra} | compare mixed og+gfa vs og+gfaz |"
  echo "| mixed_suffix_paths | exact | ${mixed_paths_cmp} | ${mixed_paths_cmp} | ${mixed_extra} | compare mixed og+gfa vs og+gfaz |"
} > "$COMPARE"

echo "Wrote: $TSV"
echo "Wrote: $SUMMARY"
echo "Wrote: $COMPARE"
