#!/usr/bin/env python3
"""Run repeated standalone demapper gates and preserve raw logs plus JSON."""

from __future__ import annotations

import argparse
from datetime import datetime
import json
from pathlib import Path
import re
import statistics
import subprocess


parser = argparse.ArgumentParser()
parser.add_argument("--repeats", type=int, default=5)
parser.add_argument("--iterations", type=int, default=2000)
args = parser.parse_args()
if args.repeats < 1 or args.iterations < 1:
    parser.error("repeats and iterations must be positive")

root = Path(__file__).resolve().parents[1]
stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
output = root / "results" / f"repeat-gate-{stamp}"
output.mkdir(parents=True)

pattern = re.compile(
    r"A100_DEMAPPER nb_re=(\d+) iterations=(\d+) avg_us=([\d.]+) "
    r"p50_us=([\d.]+) p95_us=([\d.]+) p99_us=([\d.]+) max_us=([\d.]+)"
)
rows = []
for repeat in range(1, args.repeats + 1):
    proc = subprocess.run(
        [str(root / "run_smoke.sh"), str(args.iterations)],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=300,
    )
    (output / f"run-{repeat}.log").write_text(proc.stdout)
    match = pattern.search(proc.stdout)
    if proc.returncode != 0 or not match:
        raise RuntimeError(f"run {repeat} failed:\n{proc.stdout[-4000:]}")
    row = {
        "repeat": repeat,
        "nb_re": int(match.group(1)),
        "iterations": int(match.group(2)),
        **dict(zip(
            ("mean_us", "p50_us", "p95_us", "p99_us", "max_us"),
            map(float, match.groups()[2:]),
        )),
    }
    rows.append(row)
    print(json.dumps(row), flush=True)

summary = {
    "runs": len(rows),
    "iterations_per_run": args.iterations,
    "mean_of_means_us": statistics.mean(row["mean_us"] for row in rows),
    "median_mean_us": statistics.median(row["mean_us"] for row in rows),
    "mean_p99_us": statistics.mean(row["p99_us"] for row in rows),
    "maximum_us": max(row["max_us"] for row in rows),
}
payload = {"rows": rows, "summary": summary}
(output / "results.json").write_text(json.dumps(payload, indent=2) + "\n")
print(json.dumps({"summary": summary}, indent=2))
print(f"COMPLETE={output}")

