#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Benchmark odgi pathindex on .og vs .gfaz inputs.

Usage:
  $(basename "$0") \
    --og <graph.og> \
    --gfaz <graph.gfaz> \
    [--odgi <path/to/odgi>] \
    [--threads <N>] \
    [--runs <N>] \
    [--out-dir <dir>] \
    [--prefix <name>] \
    [--keep-index]

Outputs:
  <out-dir>/<prefix>.tsv       Per-run metrics
  <out-dir>/<prefix>_summary.md Summary table with averages/best

Notes:
  - Uses /usr/bin/time if available (captures max RSS). Falls back to shell time.
  - Index outputs are written under <out-dir> and removed unless --keep-index.
USAGE
}

ODGI_BIN="./bin/odgi"
THREADS="$(nproc 2>/dev/null || echo 1)"
RUNS=3
OUT_DIR="./benchmarks"
PREFIX="pathindex_benchmark"
KEEP_INDEX=0
OG_FILE=""
GFAZ_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --odgi)
      ODGI_BIN="$2"; shift 2 ;;
    --og)
      OG_FILE="$2"; shift 2 ;;
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
    --keep-index)
      KEEP_INDEX=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1 ;;
  esac
done

if [[ -z "$OG_FILE" || -z "$GFAZ_FILE" ]]; then
  echo "error: --og and --gfaz are required" >&2
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
if [[ ! -f "$GFAZ_FILE" ]]; then
  echo "error: .gfaz file not found: $GFAZ_FILE" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
TSV="$OUT_DIR/${PREFIX}.tsv"
SUMMARY="$OUT_DIR/${PREFIX}_summary.md"

TIME_BIN=""
if command -v /usr/bin/time >/dev/null 2>&1; then
  TIME_BIN="/usr/bin/time"
fi

echo -e "mode\trun\twall_sec\tuser_sec\tsys_sec\tmax_rss_kb\tout_xp\texit_code" > "$TSV"

run_one() {
  local mode="$1"
  local input="$2"
  local run_id="$3"
  local out_xp="$OUT_DIR/${PREFIX}_${mode}_run${run_id}.xp"
  local log="$OUT_DIR/${PREFIX}_${mode}_run${run_id}.log"
  local time_txt="$OUT_DIR/${PREFIX}_${mode}_run${run_id}.time"

  rm -f "$out_xp" "$log" "$time_txt"

  local ec=0
  if [[ -n "$TIME_BIN" ]]; then
    set +e
    "$TIME_BIN" -f "WALL=%e\nUSER=%U\nSYS=%S\nRSS_KB=%M" \
      "$ODGI_BIN" pathindex -i "$input" -o "$out_xp" -t "$THREADS" -P \
      >"$log" 2>"$time_txt"
    ec=$?
    set -e
    local wall user sys rss
    wall="$(awk -F= '/^WALL=/{print $2}' "$time_txt" | tail -n1)"
    user="$(awk -F= '/^USER=/{print $2}' "$time_txt" | tail -n1)"
    sys="$(awk -F= '/^SYS=/{print $2}' "$time_txt" | tail -n1)"
    rss="$(awk -F= '/^RSS_KB=/{print $2}' "$time_txt" | tail -n1)"
    echo -e "${mode}\t${run_id}\t${wall:-NA}\t${user:-NA}\t${sys:-NA}\t${rss:-NA}\t${out_xp}\t${ec}" >> "$TSV"
  else
    set +e
    { time "$ODGI_BIN" pathindex -i "$input" -o "$out_xp" -t "$THREADS" -P ; } \
      >"$log" 2>"$time_txt"
    ec=$?
    set -e
    local real_t user_t sys_t
    real_t="$(awk '/^real/{print $2}' "$time_txt" | tail -n1)"
    user_t="$(awk '/^user/{print $2}' "$time_txt" | tail -n1)"
    sys_t="$(awk '/^sys/{print $2}' "$time_txt" | tail -n1)"
    echo -e "${mode}\t${run_id}\t${real_t:-NA}\t${user_t:-NA}\t${sys_t:-NA}\tNA\t${out_xp}\t${ec}" >> "$TSV"
  fi

  if [[ "$KEEP_INDEX" -eq 0 ]]; then
    rm -f "$out_xp"
  fi
}

echo "Running benchmark: runs=$RUNS threads=$THREADS"
echo "  og:   $OG_FILE"
echo "  gfaz: $GFAZ_FILE"

for r in $(seq 1 "$RUNS"); do
  echo "[run $r/$RUNS] mode=og"
  run_one "og" "$OG_FILE" "$r"
  echo "[run $r/$RUNS] mode=gfaz"
  run_one "gfaz" "$GFAZ_FILE" "$r"
done

awk -F'\t' '
BEGIN {
  print "# pathindex Benchmark Summary"
  print ""
  print "| mode | runs | avg_wall_sec | best_wall_sec | avg_rss_kb | avg_user_sec | avg_sys_sec |"
  print "|---|---:|---:|---:|---:|---:|---:|"
}
NR > 1 {
  mode = $1
  if ($8 != 0) failed[mode]++
  if ($3 != "NA") {
    wall_sum[mode] += $3; wall_n[mode] += 1
    if (!(mode in wall_best) || $3 < wall_best[mode]) wall_best[mode] = $3
  }
  if ($6 != "NA") { rss_sum[mode] += $6; rss_n[mode] += 1 }
  if ($4 != "NA") { user_sum[mode] += $4; user_n[mode] += 1 }
  if ($5 != "NA") { sys_sum[mode] += $5; sys_n[mode] += 1 }
}
END {
  modes[1] = "og"; modes[2] = "gfaz"
  for (i = 1; i <= 2; i++) {
    m = modes[i]
    aw = (wall_n[m] ? wall_sum[m] / wall_n[m] : "NA")
    bw = (wall_n[m] ? wall_best[m] : "NA")
    ar = (rss_n[m] ? rss_sum[m] / rss_n[m] : "NA")
    au = (user_n[m] ? user_sum[m] / user_n[m] : "NA")
    as = (sys_n[m] ? sys_sum[m] / sys_n[m] : "NA")
    runs = wall_n[m]
    printf("| %s | %d | %s | %s | %s | %s | %s |\n", m, runs, aw, bw, ar, au, as)
    if (failed[m] > 0) {
      print ""
      printf("Warning: %d run(s) failed for mode %s.\n", failed[m], m)
    }
  }
}
' "$TSV" > "$SUMMARY"

echo "Wrote: $TSV"
echo "Wrote: $SUMMARY"
