#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Benchmark odgi stats across .og, .gfa, and .gfaz inputs.

Usage:
  $(basename "$0") \
    --og <graph.og> \
    --gfa <graph.gfa> \
    --gfaz <graph.gfaz> \
    [--odgi <path/to/odgi>] \
    [--threads <N>] \
    [--runs <N>] \
    [--out-dir <dir>] \
    [--prefix <name>] \
    [--include-heavy]

Outputs:
  <out-dir>/<prefix>.tsv
  <out-dir>/<prefix>_summary.md
  <out-dir>/<prefix>_compare.md
  <out-dir>/<prefix>_outputs/...

Notes:
  - Uses /usr/bin/time if available (captures max RSS in KB).
  - Output matching compares mode-wise stdout among og/gfa/gfaz.
  - For -f / -f -y modes, matching is skipped (file sizes are expected to differ by input format).
USAGE
}

ODGI_BIN="./bin/odgi"
THREADS="$(nproc 2>/dev/null || echo 1)"
RUNS=3
OUT_DIR="./benchmarks"
PREFIX="stats_inputs_benchmark"
INCLUDE_HEAVY=0
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
    --include-heavy)
      INCLUDE_HEAVY=1; shift ;;
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

echo -e "mode\tcompare_kind\tinput\trun\twall_sec\tuser_sec\tsys_sec\tmax_rss_kb\texit_code\tstdout_file\tstderr_file" > "$TSV"

# mode_id|compare_kind|arg_string
# compare_kind: exact | sort_body | multiqc_ignore_filesize | skip
MODES=(
  "default|exact|"
  "summarize|exact|-S"
  "self_loops|exact|-L"
  "base_content|exact|-b"
  "file_size|skip|-f"
  "default_yaml|exact|-y"
  "summarize_yaml|exact|-S -y"
  "self_loops_yaml|exact|-L -y"
  "base_content_yaml|exact|-b -y"
  "file_size_yaml|skip|-f -y"
  "weak_components|exact|-W"
  "pangenome_classes|sort_body|-a !,0"
  "mean_links_length|exact|-l"
  "sum_path_node_distances|exact|-s"
  "weighted_feedback_arc|exact|-w"
  "weighted_reversing_join|exact|-j"
  "links_length_per_nuc|exact|-q"
  "multiqc|multiqc_ignore_filesize|-m"
)

if [[ "$INCLUDE_HEAVY" -eq 1 ]]; then
  MODES+=(
    "nondeterministic_edges|exact|-N"
  )
fi

run_one() {
  local mode="$1"
  local compare_kind="$2"
  local input_name="$3"
  local input_file="$4"
  local run_id="$5"
  local arg_string="$6"

  local stdout_file="$OUT_RUN_DIR/${mode}__${input_name}__run${run_id}.out"
  local stderr_file="$OUT_RUN_DIR/${mode}__${input_name}__run${run_id}.err"
  local time_file="$OUT_RUN_DIR/${mode}__${input_name}__run${run_id}.time"

  rm -f "$stdout_file" "$stderr_file" "$time_file"

  local ec=0
  if [[ -n "$TIME_BIN" ]]; then
    set +e
    # shellcheck disable=SC2086
    "$TIME_BIN" -f "WALL=%e\nUSER=%U\nSYS=%S\nRSS_KB=%M" -o "$time_file" \
      "$ODGI_BIN" stats -i "$input_file" -t "$THREADS" $arg_string \
      >"$stdout_file" 2>"$stderr_file"
    ec=$?
    set -e

    local wall user sys rss
    wall="$(awk -F= '/^WALL=/{print $2}' "$time_file" | tail -n1)"
    user="$(awk -F= '/^USER=/{print $2}' "$time_file" | tail -n1)"
    sys="$(awk -F= '/^SYS=/{print $2}' "$time_file" | tail -n1)"
    rss="$(awk -F= '/^RSS_KB=/{print $2}' "$time_file" | tail -n1)"

    echo -e "${mode}\t${compare_kind}\t${input_name}\t${run_id}\t${wall:-NA}\t${user:-NA}\t${sys:-NA}\t${rss:-NA}\t${ec}\t${stdout_file}\t${stderr_file}" >> "$TSV"
  else
    set +e
    # shellcheck disable=SC2086
    { time "$ODGI_BIN" stats -i "$input_file" -t "$THREADS" $arg_string ; } \
      >"$stdout_file" 2>"$stderr_file"
    ec=$?
    set -e

    local real_t user_t sys_t
    real_t="$(awk '/^real/{print $2}' "$stderr_file" | tail -n1)"
    user_t="$(awk '/^user/{print $2}' "$stderr_file" | tail -n1)"
    sys_t="$(awk '/^sys/{print $2}' "$stderr_file" | tail -n1)"

    echo -e "${mode}\t${compare_kind}\t${input_name}\t${run_id}\t${real_t:-NA}\t${user_t:-NA}\t${sys_t:-NA}\tNA\t${ec}\t${stdout_file}\t${stderr_file}" >> "$TSV"
  fi
}

canonicalize() {
  local compare_kind="$1"
  local src="$2"
  local dst="$3"

  case "$compare_kind" in
    exact)
      cp "$src" "$dst"
      ;;
    sort_body)
      if [[ -s "$src" ]]; then
        {
          head -n 1 "$src"
          tail -n +2 "$src" | LC_ALL=C sort
        } > "$dst"
      else
        : > "$dst"
      fi
      ;;
    multiqc_ignore_filesize)
      # In -m output, file_size_in_bytes is format-dependent (.og/.gfa/.gfaz).
      # Remove it before comparison to check metric parity.
      grep -v '^file_size_in_bytes:[[:space:]]' "$src" > "$dst" || true
      ;;
    skip)
      cp "$src" "$dst"
      ;;
    *)
      echo "error: unknown compare kind: $compare_kind" >&2
      exit 1
      ;;
  esac
}

echo "Running benchmark: runs=$RUNS threads=$THREADS"
echo "  og:   $OG_FILE"
echo "  gfa:  $GFA_FILE"
echo "  gfaz: $GFAZ_FILE"
echo "  include_heavy: $INCLUDE_HEAVY"

for mode_def in "${MODES[@]}"; do
  IFS='|' read -r mode compare_kind arg_string <<< "$mode_def"
  echo "[mode] $mode   args='${arg_string}'"
  for r in $(seq 1 "$RUNS"); do
    echo "  [run $r/$RUNS] input=og"
    run_one "$mode" "$compare_kind" "og" "$OG_FILE" "$r" "$arg_string"
    echo "  [run $r/$RUNS] input=gfa"
    run_one "$mode" "$compare_kind" "gfa" "$GFA_FILE" "$r" "$arg_string"
    echo "  [run $r/$RUNS] input=gfaz"
    run_one "$mode" "$compare_kind" "gfaz" "$GFAZ_FILE" "$r" "$arg_string"
  done

done

# Performance summary
awk -F'\t' '
BEGIN {
  print "# stats Benchmark Summary"
  print ""
  print "| mode | input | runs | avg_wall_sec | best_wall_sec | avg_rss_kb | avg_user_sec | avg_sys_sec | failures |"
  print "|---|---|---:|---:|---:|---:|---:|---:|---:|"
}
NR > 1 {
  mode = $1
  input = $3
  key = mode "\t" input

  if ($9 != 0) fail[key]++

  if ($5 != "NA") {
    wall_sum[key] += $5
    wall_n[key] += 1
    if (!(key in wall_best) || $5 < wall_best[key]) wall_best[key] = $5
  }
  if ($8 != "NA") { rss_sum[key] += $8; rss_n[key] += 1 }
  if ($6 != "NA") { user_sum[key] += $6; user_n[key] += 1 }
  if ($7 != "NA") { sys_sum[key] += $7; sys_n[key] += 1 }

  mode_seen[mode] = 1
  input_seen[input] = 1
}
END {
  input_order[1] = "og"
  input_order[2] = "gfa"
  input_order[3] = "gfaz"

  # Print in first-seen mode order
  for (row = 2; row <= NR; row++) {
    # noop
  }

  # Build stable mode list by rescanning file order
  while ((getline line < ARGV[1]) > 0) {
    if (line ~ /^mode\t/) continue
    split(line, a, "\t")
    m = a[1]
    if (!(m in mode_out)) {
      mode_out[m] = ++mode_count
      modes[mode_count] = m
    }
  }
  close(ARGV[1])

  for (mi = 1; mi <= mode_count; mi++) {
    m = modes[mi]
    for (ii = 1; ii <= 3; ii++) {
      inp = input_order[ii]
      key = m "\t" inp
      if (!(key in wall_n) && !(key in fail)) continue

      aw = (wall_n[key] ? wall_sum[key] / wall_n[key] : "NA")
      bw = (wall_n[key] ? wall_best[key] : "NA")
      ar = (rss_n[key] ? rss_sum[key] / rss_n[key] : "NA")
      au = (user_n[key] ? user_sum[key] / user_n[key] : "NA")
      as = (sys_n[key] ? sys_sum[key] / sys_n[key] : "NA")
      runs = wall_n[key] + 0
      f = fail[key] + 0
      printf("| %s | %s | %d | %s | %s | %s | %s | %s | %d |\n", m, inp, runs, aw, bw, ar, au, as, f)
    }
  }
}
' "$TSV" > "$SUMMARY"

# Output comparison summary (run1 only, og as reference)
{
  echo "# stats Output Comparison"
  echo
  echo "| mode | compare_kind | og_vs_gfa | og_vs_gfaz | note |"
  echo "|---|---|---|---|---|"

  for mode_def in "${MODES[@]}"; do
    IFS='|' read -r mode compare_kind arg_string <<< "$mode_def"

    if [[ "$compare_kind" == "skip" ]]; then
      echo "| ${mode} | ${compare_kind} | skipped | skipped | expected to differ (file size depends on input file) |"
      continue
    fi

    og_out="$OUT_RUN_DIR/${mode}__og__run1.out"
    gfa_out="$OUT_RUN_DIR/${mode}__gfa__run1.out"
    gfaz_out="$OUT_RUN_DIR/${mode}__gfaz__run1.out"

    og_can="$OUT_RUN_DIR/${mode}__og__run1.canon"
    gfa_can="$OUT_RUN_DIR/${mode}__gfa__run1.canon"
    gfaz_can="$OUT_RUN_DIR/${mode}__gfaz__run1.canon"

    canonicalize "$compare_kind" "$og_out" "$og_can"
    canonicalize "$compare_kind" "$gfa_out" "$gfa_can"
    canonicalize "$compare_kind" "$gfaz_out" "$gfaz_can"

    og_vs_gfa="match"
    og_vs_gfaz="match"

    if ! cmp -s "$og_can" "$gfa_can"; then
      og_vs_gfa="mismatch"
    fi
    if ! cmp -s "$og_can" "$gfaz_can"; then
      og_vs_gfaz="mismatch"
    fi

    note=""
    if [[ "$compare_kind" == "sort_body" ]]; then
      note="body lines sorted before compare"
    elif [[ "$compare_kind" == "multiqc_ignore_filesize" ]]; then
      note="file_size_in_bytes ignored for cross-format compare"
    fi
    echo "| ${mode} | ${compare_kind} | ${og_vs_gfa} | ${og_vs_gfaz} | ${note} |"
  done
} > "$COMPARE"

echo "Wrote: $TSV"
echo "Wrote: $SUMMARY"
echo "Wrote: $COMPARE"
