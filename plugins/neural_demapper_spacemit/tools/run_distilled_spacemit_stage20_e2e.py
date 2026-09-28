"""Full BLER/RX gate for the reliability-conditioned A100 demapper."""
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
PLUGIN = W / "build/libdemapper_distilled_spacemit_ep.so"
DYNAMIC = W / "models/distilled_demapper.dynamic.fp16.onnx"
FIXED = W / "models/distilled_demapper.6624x2.fp16.onnx"
FRAMES = 500
SEEDS = (2609271, 2609272, 2609273)
SNRS = (5.5, 6.0, 6.5, 7.0)

assert all(path.is_file() for path in (BINARY, PLUGIN, DYNAMIC, FIXED))
for process in ("nr-softmodem", "nr_ulsim_spacemit_batch"):
    assert subprocess.run(["pgrep", "-f", rf"(^|/){process}( |$)"],
                          stdout=subprocess.DEVNULL).returncode == 1

out = Path(tempfile.mkdtemp(prefix="distilled-spacemit-stage20-", dir=W / "results"))
rows = []
print(f"RESULT_DIR={out}", flush=True)
for seed in SEEDS:
    for snr in SNRS:
        dest = out / f"seed-{seed}-snr-{snr:g}"
        dest.mkdir()
        env = {k: v for k, v in os.environ.items() if not k.startswith("XSAI_")}
        env.update({
            "OAI_RNGSEED": str(seed),
            "XSAI_TEST_RX_WALL": "1",
            "XSAI_SPACEMIT_BATCH": "1",
            "XSAI_SPACEMIT_EP_THREADS": "8",
            "XSAI_SPACEMIT_EP_AFFINITY": "8;9;10;11;12;13;14;15",
            "XSAI_SPACEMIT_EP_STREAMS": "1",
            "XSAI_SPACEMIT_EP_USE_GLOBAL_INTRA_THREAD": "1",
            "XSAI_DISTILLED_ONNX": str(DYNAMIC),
            "XSAI_DISTILLED_FIXED_MODEL": str(FIXED),
            "XSAI_SPACEMIT_REUSE_3312_IO": "1",
            "LD_LIBRARY_PATH": f"{W}/oai-ulsch-build:{W}/build",
        })
        command = [
            "taskset", "-c", "0-3", str(BINARY),
            "-n", str(FRAMES), "-R", "24", "-r", "24", "-m", "10",
            "-C", "4", "-Y", "0,1,2,3", "-v", "1",
            "-s", f"{snr:g}", "-S", f"{snr:g}", "-P",
            "--loader.demapper.shlibpath", str(W / "build"),
            "--loader.demapper.shlibversion", "_distilled_spacemit_ep",
        ]
        with (dest / "run.log").open("w") as stream:
            proc = subprocess.run(command, cwd=dest, env=env, stdout=stream,
                                  stderr=subprocess.STDOUT, timeout=180)
        log = (dest / "run.log").read_text()
        result = re.search(
            rf"n_errors \((\d+)/{FRAMES}\).*false_positive (\d+)/{FRAMES}", log)
        counter = re.search(
            r"DISTILLED_SPACEMIT_EP calls=(\d+) batch_calls=(\d+) "
            r"fallback_axes=(\d+) rejected=(\d+)", log)
        timing = re.findall(
            r"RX_WALL stage=(\S+) count=(\d+) warmup=10 avg_us=(\S+) "
            r"p50_us=(\S+) p95_us=(\S+) p99_us=(\S+) max_us=(\S+)", log)
        assert proc.returncode in (0, 1) and result and counter and len(timing) == 2, log[-5000:]
        assert tuple(map(int, counter.groups()[:2])) == (6000, 500)
        assert int(counter[4]) == 0
        stages = {
            item[0]: dict(zip(
                ("count", "avg_us", "p50_us", "p95_us", "p99_us", "max_us"),
                (int(item[1]), *map(float, item[2:])),
            )) for item in timing
        }
        row = {
            "seed": seed, "snr_db": snr, "frames": FRAMES,
            "failures": int(result[1]), "bler": int(result[1]) / FRAMES,
            "false_positives": int(result[2]),
            "logical_symbol_calls": int(counter[1]),
            "physical_a100_runs": int(counter[2]),
            "fallback_axes": int(counter[3]), "rejected": int(counter[4]),
            "timing": stages,
        }
        rows.append(row)
        (out / "results.partial.json").write_text(json.dumps(rows, indent=2) + "\n")
        print(json.dumps(row), flush=True)

summary = []
for snr in SNRS:
    selected = [r for r in rows if r["snr_db"] == snr]
    rx = [r["timing"]["FFT_rotation_to_RX_return"] for r in selected]
    summary.append({
        "snr_db": snr,
        "frames": sum(r["frames"] for r in selected),
        "failures": sum(r["failures"] for r in selected),
        "bler": sum(r["failures"] for r in selected) /
                sum(r["frames"] for r in selected),
        "false_positives": sum(r["false_positives"] for r in selected),
        "mean_rx_us": statistics.mean(t["avg_us"] for t in rx),
        "mean_p99_us": statistics.mean(t["p99_us"] for t in rx),
        "max_rx_us": max(t["max_us"] for t in rx),
    })

payload = {
    "scope": "reliability-conditioned FP16 MLP on A100 in complete nr_ulsim RX",
    "configuration": {
        "frames_per_seed_snr": FRAMES, "seeds": SEEDS, "snrs_db": SNRS,
        "mcs": 10, "prb": 24, "layers": 1, "harq_rounds": 1,
        "a100_threads": 8, "a100_affinity": "8;9;10;11;12;13;14;15",
        "llr_scale": 4,
    },
    "sha256": {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
               for path in (BINARY, PLUGIN, DYNAMIC, FIXED)},
    "rows": rows,
    "summary": summary,
}
(out / "results.json").write_text(json.dumps(payload, indent=2) + "\n")
print(json.dumps({"summary": summary}, indent=2), flush=True)
print(f"COMPLETE={out}", flush=True)
