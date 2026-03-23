#!/usr/bin/env python3
"""Benchmark ODGI subcommands across .og, .gfa, and .gfaz inputs."""

from __future__ import annotations

import argparse
import hashlib
import os
import shlex
import statistics
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List


@dataclass(frozen=True)
class CommandConfig:
    name: str
    args: List[str]
    output_kind: str  # stdout | file | graph | flatten | explode | none
    output_ext: str = ""
    compare_mode: str = "exact"  # exact | sort_lines | none


COMMANDS: Dict[str, CommandConfig] = {
    "bin": CommandConfig("bin", ["-n", "1000"], "stdout"),
    "break": CommandConfig("break", [], "graph", ".og"),
    "chop": CommandConfig("chop", ["-c", "32"], "graph", ".og"),
    "cover": CommandConfig("cover", ["-n", "1"], "graph", ".og", compare_mode="none"),
    "crush": CommandConfig("crush", [], "graph", ".og"),
    "extract": CommandConfig("extract", [], "graph", ".og"),
    "layout": CommandConfig("layout", [], "file", ".lay", compare_mode="none"),
    "stats": CommandConfig("stats", ["-S"], "stdout"),
    "view": CommandConfig("view", ["-g"], "stdout"),
    "validate": CommandConfig("validate", [], "none", compare_mode="none"),
    "degree": CommandConfig("degree", ["-S"], "stdout"),
    "depth": CommandConfig("depth", ["-S"], "stdout"),
    "matrix": CommandConfig("matrix", [], "stdout"),
    "paths": CommandConfig("paths", ["-L"], "stdout", compare_mode="sort_lines"),
    "stepindex": CommandConfig("stepindex", [], "file", ".stpidx", compare_mode="none"),
    "unitig": CommandConfig("unitig", [], "stdout", compare_mode="none"),
    "pathindex": CommandConfig("pathindex", [], "file", ".xp", compare_mode="none"),
    "flatten": CommandConfig("flatten", [], "flatten"),
    "flip": CommandConfig("flip", [], "graph", ".og"),
    "groom": CommandConfig("groom", [], "graph", ".og"),
    "explode": CommandConfig("explode", [], "explode"),
    "normalize": CommandConfig("normalize", [], "graph", ".og"),
    "unchop": CommandConfig("unchop", [], "graph", ".og"),
    "overlap": CommandConfig("overlap", [], "stdout"),
    "prune": CommandConfig("prune", [], "graph", ".og"),
    "similarity": CommandConfig("similarity", [], "stdout"),
    "sort": CommandConfig("sort", ["-b"], "graph", ".og"),
    "tips": CommandConfig("tips", [], "stdout"),
    "untangle": CommandConfig("untangle", [], "stdout"),
    # "kmers": CommandConfig("kmers", ["-k", "31", "-c"], "stdout"),
}

INPUTS = ("og", "gfa", "gfaz")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonicalize_bytes(data: bytes, mode: str) -> bytes:
    if mode == "exact":
        return data
    if mode == "sort_lines":
        lines = data.decode("utf-8", errors="surrogateescape").splitlines()
        lines.sort()
        return ("\n".join(lines) + ("\n" if lines else "")).encode(
            "utf-8", errors="surrogateescape"
        )
    if mode == "none":
        return b""
    raise ValueError(f"unsupported compare mode: {mode}")


def median_or_na(values: List[float]) -> str:
    if not values:
        return "NA"
    return f"{statistics.median(values):.6f}"


def mean_or_na(values: List[float]) -> str:
    if not values:
        return "NA"
    return f"{statistics.mean(values):.6f}"


def best_or_na(values: List[float]) -> str:
    if not values:
        return "NA"
    return f"{min(values):.6f}"


def parse_time_metrics(time_path: Path) -> Dict[str, str]:
    metrics: Dict[str, str] = {}
    if not time_path.exists():
        return metrics
    for line in time_path.read_text().splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        metrics[key.strip()] = value.strip()
    return metrics


def build_parser() -> argparse.ArgumentParser:
    command_choices = ["all", *sorted(COMMANDS)]
    parser = argparse.ArgumentParser(
        description="Benchmark ODGI subcommands across .og, .gfa, and .gfaz inputs."
    )
    parser.add_argument(
        "--commands",
        nargs="+",
        choices=command_choices,
        default=["all"],
        help="Subcommands to benchmark. Use 'all' to run the full supported set.",
    )
    parser.add_argument("--og", required=True, help="Input .og file.")
    parser.add_argument("--gfa", required=True, help="Input .gfa file.")
    parser.add_argument("--gfaz", required=True, help="Input .gfaz file.")
    parser.add_argument("--odgi", default="./bin/odgi", help="Path to the odgi binary.")
    parser.add_argument(
        "--threads",
        type=int,
        default=max(1, os.cpu_count() or 1),
        help="Thread count passed to odgi.",
    )
    parser.add_argument("--runs", type=int, default=3, help="Number of runs per input format.")
    parser.add_argument("--out-dir", default="./benchmarks", help="Directory for benchmark outputs.")
    parser.add_argument(
        "--prefix",
        default="input_formats_benchmark",
        help="Filename prefix for benchmark artifacts.",
    )
    parser.add_argument(
        "--keep-artifacts",
        action="store_true",
        help="Keep per-run stdout/stderr/output files.",
    )
    return parser


def validate_args(args: argparse.Namespace) -> None:
    odgi_bin = Path(args.odgi)
    if not odgi_bin.is_file() or not os.access(odgi_bin, os.X_OK):
        raise SystemExit(f"error: odgi binary not executable: {odgi_bin}")
    if not Path("/usr/bin/time").is_file():
        raise SystemExit("error: /usr/bin/time is required to capture peak RSS")
    for name in INPUTS:
        path = Path(getattr(args, name))
        if not path.is_file():
            raise SystemExit(f"error: .{name} file not found: {path}")


def resolve_commands(selected: List[str]) -> List[str]:
    if "all" in selected:
        return list(COMMANDS)
    return selected


def detect_first_path_name(odgi_bin: Path, og_input: Path, threads: int) -> str:
    cmd = [str(odgi_bin), "paths", "-i", str(og_input), "-L", "-t", str(threads)]
    completed = subprocess.run(cmd, capture_output=True, check=True)
    for line in completed.stdout.decode("utf-8", errors="replace").splitlines():
        if line.strip():
            return line.strip()
    raise SystemExit("error: could not detect a path name from the .og input for overlap benchmarking")


def detect_path_names(odgi_bin: Path, og_input: Path, threads: int) -> List[str]:
    cmd = [str(odgi_bin), "paths", "-i", str(og_input), "-L", "-t", str(threads)]
    completed = subprocess.run(cmd, capture_output=True, check=True)
    names = [
        line.strip()
        for line in completed.stdout.decode("utf-8", errors="replace").splitlines()
        if line.strip()
    ]
    if not names:
        raise SystemExit("error: could not detect any path names from the .og input")
    return names


def build_invocation(
    odgi_bin: Path,
    cfg: CommandConfig,
    input_path: Path,
    threads: int,
    base: str,
    run_dir: Path,
    context: Dict[str, str],
) -> tuple[List[str], List[Path]]:
    cmd = [str(odgi_bin), cfg.name, "-i", str(input_path), "-t", str(threads)]
    output_paths: List[Path] = []

    if cfg.output_kind == "file":
        out_path = run_dir / f"{base}{cfg.output_ext}"
        cmd += ["-o", str(out_path)]
        output_paths.append(out_path)
    elif cfg.output_kind == "graph":
        out_path = run_dir / f"{base}{cfg.output_ext}"
        cmd += ["-o", str(out_path)]
        output_paths.append(out_path)
    elif cfg.output_kind == "flatten":
        fasta_path = run_dir / f"{base}.fa"
        bed_path = run_dir / f"{base}.bed"
        cmd += ["-f", str(fasta_path), "-b", str(bed_path), "-n", input_path.stem]
        output_paths.extend([fasta_path, bed_path])
    elif cfg.output_kind == "explode":
        prefix = run_dir / f"{base}__component"
        cmd += ["-p", str(prefix)]

    if cfg.name == "extract":
        cmd += ["-r", context["extract_path_range"]]
    if cfg.name == "overlap":
        cmd += ["-r", context["first_path_name"]]
    elif cfg.name == "tips":
        cmd += ["-q", context["tips_query_path"], "-r", context["tips_target_path"]]
    elif cfg.name == "untangle":
        cmd += ["-q", context["untangle_query_path"], "-r", context["untangle_target_path"]]

    cmd += cfg.args
    return cmd, output_paths


def compute_compare_hash(
    odgi_bin: Path,
    cfg: CommandConfig,
    stdout_path: Path,
    output_paths: List[Path],
) -> str:
    if cfg.compare_mode == "none":
        return ""
    if cfg.output_kind == "stdout":
        if not stdout_path.exists():
            return ""
        return sha256_bytes(canonicalize_bytes(stdout_path.read_bytes(), cfg.compare_mode))
    if cfg.output_kind == "graph":
        if not output_paths or not output_paths[0].exists():
            return ""
        completed = subprocess.run(
            [str(odgi_bin), "view", "-i", str(output_paths[0]), "-g"],
            capture_output=True,
            check=True,
        )
        return sha256_bytes(completed.stdout)
    if cfg.output_kind == "flatten":
        blobs: List[bytes] = []
        for path in output_paths:
            if not path.exists():
                return ""
            blobs.append(path.name.encode("utf-8") + b"\n" + path.read_bytes())
        return sha256_bytes(b"\n====\n".join(blobs))
    if cfg.output_kind == "explode":
        blobs: List[bytes] = []
        for path in sorted(output_paths):
            if not path.exists():
                return ""
            completed = subprocess.run(
                [str(odgi_bin), "view", "-i", str(path), "-g"],
                capture_output=True,
                check=True,
            )
            blobs.append(path.name.encode("utf-8") + b"\n" + completed.stdout)
        return sha256_bytes(b"\n====\n".join(blobs))
    if cfg.output_kind == "file":
        if not output_paths or not output_paths[0].exists():
            return ""
        return sha256_bytes(output_paths[0].read_bytes())
    return ""


def run_case(
    odgi_bin: Path,
    cfg: CommandConfig,
    input_name: str,
    input_path: Path,
    run_id: int,
    threads: int,
    run_dir: Path,
    context: Dict[str, str],
    keep_artifacts: bool,
) -> Dict[str, str]:
    base = f"{cfg.name}__{input_name}__run{run_id}"
    stdout_path = run_dir / f"{base}.stdout"
    stderr_path = run_dir / f"{base}.stderr"
    time_path = run_dir / f"{base}.time"
    cmd, output_paths = build_invocation(odgi_bin, cfg, input_path, threads, base, run_dir, context)

    timed_cmd = [
        "/usr/bin/time",
        "-f",
        "WALL=%e\nUSER=%U\nSYS=%S\nRSS_KB=%M",
        "-o",
        str(time_path),
    ] + cmd

    with stdout_path.open("wb") as stdout_handle, stderr_path.open("wb") as stderr_handle:
        completed = subprocess.run(timed_cmd, stdout=stdout_handle, stderr=stderr_handle)

    if completed.returncode == 0 and cfg.output_kind == "explode":
        explode_prefix = run_dir / f"{base}__component"
        output_paths = sorted(run_dir.glob(f"{explode_prefix.name}.*.og"))

    metrics = parse_time_metrics(time_path)

    compare_hash = ""
    if completed.returncode == 0:
        compare_hash = compute_compare_hash(odgi_bin, cfg, stdout_path, output_paths)

    row = {
        "command": cfg.name,
        "input": input_name,
        "run": str(run_id),
        "wall_sec": metrics.get("WALL", "NA"),
        "user_sec": metrics.get("USER", "NA"),
        "sys_sec": metrics.get("SYS", "NA"),
        "max_rss_kb": metrics.get("RSS_KB", "NA"),
        "exit_code": str(completed.returncode),
        "compare_sha256": compare_hash,
        "stdout_file": str(stdout_path),
        "stderr_file": str(stderr_path),
        "output_files": ";".join(str(path) for path in output_paths),
    }

    if not keep_artifacts:
        for path in [stdout_path, stderr_path, time_path, *output_paths]:
            if path.exists():
                path.unlink()

    return row


def write_tsv(tsv_path: Path, rows: List[Dict[str, str]]) -> None:
    headers = [
        "command",
        "input",
        "run",
        "wall_sec",
        "user_sec",
        "sys_sec",
        "max_rss_kb",
        "exit_code",
        "compare_sha256",
        "stdout_file",
        "stderr_file",
        "output_files",
    ]
    with tsv_path.open("w", encoding="utf-8") as handle:
        handle.write("\t".join(headers) + "\n")
        for row in rows:
            handle.write("\t".join(row.get(h, "") for h in headers) + "\n")


def write_summary(summary_path: Path, rows: List[Dict[str, str]], commands: List[str]) -> None:
    with summary_path.open("w", encoding="utf-8") as handle:
        handle.write("# Input Format Benchmark Summary\n\n")
        handle.write(
            "| command | input | runs | median_wall_sec | avg_wall_sec | best_wall_sec | median_rss_kb | avg_rss_kb | failures |\n"
        )
        handle.write("|---|---|---:|---:|---:|---:|---:|---:|---:|\n")
        for command in commands:
            for input_name in INPUTS:
                subset = [
                    row
                    for row in rows
                    if row["command"] == command and row["input"] == input_name
                ]
                if not subset:
                    continue
                wall_values = [
                    float(row["wall_sec"])
                    for row in subset
                    if row["wall_sec"] != "NA" and row["exit_code"] == "0"
                ]
                rss_values = [
                    float(row["max_rss_kb"])
                    for row in subset
                    if row["max_rss_kb"] != "NA" and row["exit_code"] == "0"
                ]
                failures = sum(1 for row in subset if row["exit_code"] != "0")
                handle.write(
                    f"| {command} | {input_name} | {len(subset)} | "
                    f"{median_or_na(wall_values)} | {mean_or_na(wall_values)} | {best_or_na(wall_values)} | "
                    f"{median_or_na(rss_values)} | {mean_or_na(rss_values)} | {failures} |\n"
                )


def write_compare(compare_path: Path, rows: List[Dict[str, str]], commands: List[str]) -> None:
    grouped: Dict[str, List[Dict[str, str]]] = {}
    for row in rows:
        grouped.setdefault(row["command"], []).append(row)

    with compare_path.open("w", encoding="utf-8") as handle:
        handle.write("# Output Comparison\n\n")
        handle.write("| command | comparison | details |\n")
        handle.write("|---|---|---|\n")
        for command in commands:
            cfg = COMMANDS[command]
            subset = grouped.get(command, [])
            failures = [row for row in subset if row["exit_code"] != "0"]
            if failures:
                handle.write(f"| {command} | skipped | one or more runs failed; inspect TSV for details |\n")
                continue
            if cfg.compare_mode == "none":
                handle.write(f"| {command} | skipped | output comparison disabled for this command |\n")
                continue
            digests = {row["compare_sha256"] for row in subset if row["compare_sha256"]}
            if len(digests) == 1:
                handle.write(f"| {command} | match | all compared outputs hashed identically |\n")
            elif len(digests) == 0:
                handle.write(f"| {command} | skipped | no comparable outputs were generated |\n")
            else:
                samples = ", ".join(sorted(digests)[:3])
                handle.write(f"| {command} | mismatch | observed multiple output hashes: `{samples}` |\n")


def cleanup_artifacts(run_dir: Path) -> None:
    if not any(run_dir.iterdir()):
        run_dir.rmdir()


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    args.commands = resolve_commands(args.commands)
    validate_args(args)

    odgi_bin = Path(args.odgi).resolve()
    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    run_dir = out_dir / f"{args.prefix}_outputs"
    run_dir.mkdir(parents=True, exist_ok=True)

    inputs = {
        "og": Path(args.og).resolve(),
        "gfa": Path(args.gfa).resolve(),
        "gfaz": Path(args.gfaz).resolve(),
    }

    context: Dict[str, str] = {}
    if "overlap" in args.commands:
        context["first_path_name"] = detect_first_path_name(
            odgi_bin, inputs["og"], args.threads
        )
    if "tips" in args.commands:
        path_names = detect_path_names(odgi_bin, inputs["og"], args.threads)
        context["tips_query_path"] = path_names[0]
        context["tips_target_path"] = path_names[1] if len(path_names) > 1 else path_names[0]
    if "extract" in args.commands or "untangle" in args.commands:
        path_names = detect_path_names(odgi_bin, inputs["og"], args.threads)
        if "extract" in args.commands:
            context["extract_path_range"] = f"{path_names[0]}:0-1"
        if "untangle" in args.commands:
            context["untangle_query_path"] = path_names[0]
            context["untangle_target_path"] = path_names[1] if len(path_names) > 1 else path_names[0]

    rows: List[Dict[str, str]] = []

    print(f"Running benchmark: commands={','.join(args.commands)} runs={args.runs} threads={args.threads}")
    if "first_path_name" in context:
        print(f"Using overlap query path: {context['first_path_name']}")
    if "tips_query_path" in context:
        print(
            "Using tips query/target paths: "
            f"{context['tips_query_path']} / {context['tips_target_path']}"
        )
    if "extract_path_range" in context:
        print(f"Using extract path range: {context['extract_path_range']}")
    if "untangle_query_path" in context:
        print(
            "Using untangle query/target paths: "
            f"{context['untangle_query_path']} / {context['untangle_target_path']}"
        )

    for command in args.commands:
        cfg = COMMANDS[command]
        print(f"[command] {command} args={shlex.join(cfg.args)}")
        for run_id in range(1, args.runs + 1):
            for input_name in INPUTS:
                print(f"  [run {run_id}/{args.runs}] input={input_name}")
                rows.append(
                    run_case(
                        odgi_bin=odgi_bin,
                        cfg=cfg,
                        input_name=input_name,
                        input_path=inputs[input_name],
                        run_id=run_id,
                        threads=args.threads,
                        run_dir=run_dir,
                        context=context,
                        keep_artifacts=args.keep_artifacts,
                    )
                )

    tsv_path = out_dir / f"{args.prefix}.tsv"
    summary_path = out_dir / f"{args.prefix}_summary.md"
    compare_path = out_dir / f"{args.prefix}_compare.md"

    write_tsv(tsv_path, rows)
    write_summary(summary_path, rows, args.commands)
    write_compare(compare_path, rows, args.commands)

    if not args.keep_artifacts:
        cleanup_artifacts(run_dir)

    print(f"Wrote: {tsv_path}")
    print(f"Wrote: {summary_path}")
    print(f"Wrote: {compare_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
