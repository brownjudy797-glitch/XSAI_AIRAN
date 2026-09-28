# GitHub clean-clone gate — 2026-09-28

## Result

Commit `f3f552035f484d1736df261d882799f4450dd78d` was cloned from GitHub into a
new K3 directory, then built without using the earlier development worktree.
Model SHA256 validation, fixed-shape generation, plugin compilation and the
standalone A100 smoke all passed.

The repository is private. This clean clone succeeded because the test K3
already had access to `brownjudy797-glitch/XSAI_AIRAN`.

## Environment

- `spacemit-onnxruntime`: 2.0.3+3
- `python3-spacemit-ort`: 2.0.3+3
- `spacemit-tcm`: 3.0.0+3
- A100 EP workers: CPU8-15
- host benchmark: X100 CPU0
- fixed shape: 3312 RE
- warmup: 20 calls per process
- measured calls: 2,000 per run
- repeats: 5

## Measurements

| Run | Mean us | P50 us | P95 us | P99 us | Max us |
|---:|---:|---:|---:|---:|---:|
| 1 | 149.143 | 150.783 | 174.198 | 205.989 | 458.849 |
| 2 | 144.480 | 142.367 | 155.616 | 167.865 | 314.190 |
| 3 | 143.681 | 138.325 | 155.741 | 169.991 | 217.029 |
| 4 | 146.486 | 150.283 | 156.741 | 168.782 | 240.195 |
| 5 | 146.768 | 150.575 | 157.075 | 168.783 | 349.105 |

Summary:

- mean of run means: **146.112 us**;
- median run mean: **146.486 us**;
- mean run P99: **176.282 us**;
- maximum retained sample: **458.849 us**.

Stage 18's unified-cache reference was 143.279 us. The clean-clone mean is
2.833 us (1.98%) slower. The model is identical and the source change only
replaced an obsolete absolute fallback model path with a repository-relative
path; the hot path is unchanged. The observed difference is therefore treated
as run-to-run/platform jitter, not a code regression, pending the same-board
alternating A/B gate.

Every run reported `available_blocks=8/8` before and after execution. No TCM
leak was observed.

## Reproduction

After `./install.sh`:

```bash
python3 tools/run_repeat_gate.py --repeats 5 --iterations 2000
```

The runner preserves each raw log and a `results.json` under the ignored local
`results/` directory.
