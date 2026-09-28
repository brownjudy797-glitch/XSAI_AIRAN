"""Paired end-to-end BLER and RX-latency gate for the Stage-18 A100 demapper."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import tempfile


W = Path("/home/ubuntu/sionna-rk/.work-neural-demapper-a100")
BINARY = W / "oai-ulsch-build/nr_ulsim_spacemit_batch"
PLUGIN = W / "build/libdemapper_spacemit_ep_stage18_cache_scale8.so"
MODEL = W / "models/neural_demapper.3312xfloat16.onnx"
FRAMES = 500
SEEDS = (2609271, 2609272, 2609273)
SNRS = (5.5, 6.0, 6.5, 7.0)
BACKENDS = ("conventional", "a100_stage18")

for process in ("nr-softmodem", "nr_ulsim_spacemit_batch"):
    assert subprocess.run(
        ["pgrep", "-f", rf"(^|/){process}( |$)"],
        stdout=subprocess.DEVNULL,
    ).returncode == 1, f"{process} is already running"
assert BINARY.is_file() and PLUGIN.is_file() and MODEL.is_file()

out = Path(tempfile.mkdtemp(prefix="spacemit-stage19-e2e-", dir=W / "results"))
rows: list[dict[str, object]] = []
print(f"RESULT_DIR={out}", flush=True)

for point, (seed, snr) in enumerate((s, n) for s in SEEDS for n in SNRS):
    ordered = BACKENDS[point % 2:] + BACKENDS[:point % 2]
    for order, backend in enumerate(ordered):
        dest = out / f"seed-{seed}-snr-{snr:g}-{order}-{backend}"
        dest.mkdir()
        env = {k: v for k, v in os.environ.items() if not k.startswith("XSAI_")}
        env.update({
            "OAI_RNGSEED": str(seed),
            "XSAI_TEST_RX_WALL": "1",
            "LD_LIBRARY_PATH": f"{W}/oai-ulsch-build:{W}/build",
        })
        plugin_args: list[str] = []
        if backend == "conventional":
            env["XSAI_DEFAULT_LLR_SCALE"] = ".0625"
        else:
            env.update({
                "XSAI_SPACEMIT_BATCH": "1",
                "XSAI_SPACEMIT_EP_STREAMS": "1",
                "XSAI_SPACEMIT_EP_THREADS": "8",
                "XSAI_SPACEMIT_EP_AFFINITY": "8;9;10;11;12;13;14;15",
                "XSAI_SPACEMIT_EP_USE_GLOBAL_INTRA_THREAD": "1",
                "XSAI_SPACEMIT_FIXED_MODEL": str(MODEL),
                "XSAI_SPACEMIT_REUSE_3312_IO": "1",
            })
            plugin_args = [
                "--loader.demapper.shlibpath", str(W / "build"),
                "--loader.demapper.shlibversion", "_spacemit_ep_stage18_cache_scale8",
            ]
        command = [
            "taskset", "-c", "0-3", str(BINARY),
            "-n", str(FRAMES), "-R", "24", "-r", "24", "-m", "10",
            "-C", "4", "-Y", "0,1,2,3", "-v", "1",
            "-s", f"{snr:g}", "-S", f"{snr:g}", "-P", *plugin_args,
        ]
        with (dest / "run.log").open("w") as stream:
            proc = subprocess.run(
                command, cwd=dest, env=env, stdout=stream,
                stderr=subprocess.STDOUT, timeout=180,
            )
        log = (dest / "run.log").read_text()
        result = re.search(
            rf"n_errors \((\d+)/{FRAMES}\).*false_positive (\d+)/{FRAMES}", log
        )
        timing = re.findall(
            r"RX_WALL stage=(\S+) count=(\d+) warmup=10 avg_us=(\S+) "
            r"p50_us=(\S+) p95_us=(\S+) p99_us=(\S+) max_us=(\S+)", log,
        )
        assert proc.returncode in (0, 1) and result and len(timing) == 2, log[-5000:]
        assert all(item[1] == str(FRAMES - 10) for item in timing)
        counters = None
        if backend == "a100_stage18":
            counters = re.search(
                r"SPARK_SPACEMIT_EP calls=(\d+) batch_calls=(\d+) "
                r"multi_ulsch_calls=(\d+)", log,
            )
            assert counters and tuple(map(int, counters.groups())) == (6000, 500, 0), log[-5000:]
        stages = {
            item[0]: dict(zip(
                ("count", "avg_us", "p50_us", "p95_us", "p99_us", "max_us"),
                (int(item[1]), *map(float, item[2:])),
            ))
            for item in timing
        }
        row = {
            "seed": seed,
            "snr_db": snr,
            "order": order,
            "backend": backend,
            "frames": FRAMES,
            "failures": int(result[1]),
            "bler": int(result[1]) / FRAMES,
            "false_positives": int(result[2]),
            "logical_symbol_calls": int(counters[1]) if counters else None,
            "physical_a100_runs": int(counters[2]) if counters else None,
            "timing": stages,
        }
        rows.append(row)
        (out / "results.partial.json").write_text(json.dumps(rows, indent=2) + "\n")
        print(json.dumps(row), flush=True)

summary: list[dict[str, object]] = []
for snr in SNRS:
    for backend in BACKENDS:
        selected = [r for r in rows if r["snr_db"] == snr and r["backend"] == backend]
        rx = [r["timing"]["FFT_rotation_to_RX_return"] for r in selected]
        summary.append({
            "snr_db": snr,
            "backend": backend,
            "frames": sum(int(r["frames"]) for r in selected),
            "failures": sum(int(r["failures"]) for r in selected),
            "bler": sum(int(r["failures"]) for r in selected) /
                    sum(int(r["frames"]) for r in selected),
            "false_positives": sum(int(r["false_positives"]) for r in selected),
            "mean_rx_us": statistics.mean(float(t["avg_us"]) for t in rx),
            "mean_p99_us": statistics.mean(float(t["p99_us"]) for t in rx),
            "max_rx_us": max(float(t["max_us"]) for t in rx),
        })

payload = {
    "scope": "nr_ulsim FFT/channel-estimation/equalization/demapper/unscrambling/LDPC/RX return",
    "configuration": {
        "frames_per_seed_snr_backend": FRAMES,
        "seeds": SEEDS,
        "snrs_db": SNRS,
        "mcs": 10,
        "prb": 24,
        "layers": 1,
        "harq_rounds": 1,
        "a100_threads": 8,
        "a100_affinity": "8;9;10;11;12;13;14;15",
        "llr_scale": {"conventional": 0.0625, "a100_stage18": 8},
    },
    "sha256": {
        str(path): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in (BINARY, PLUGIN, MODEL)
    },
    "rows": rows,
    "summary": summary,
}
(out / "results.json").write_text(json.dumps(payload, indent=2) + "\n")
print(json.dumps({"summary": summary}, indent=2), flush=True)
print(f"COMPLETE={out}", flush=True)
