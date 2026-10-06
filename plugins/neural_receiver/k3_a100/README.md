# K3 A100 neural receiver backend

This backend is separate from the Spark CUDA/TensorRT receiver in the parent
directory. It uses the same OAI `receiver` loader but runs native RISC-V vector
inference on a K3 A100 worker. Source was copied from
`.work-neural-receiver-a100/src` without changing the live implementation.

Build on K3 from this directory with `bash build.sh`. Set `OAI_ROOT` and
`OAI_BUILD` only if the default paths differ. The resulting library is in
`build/`; it is not selected automatically. The matching model is copied to
`../models/k3_native_joint_h24.weights`; set `XSAI_RECEIVER_NATIVE_WEIGHTS` to
that absolute path at runtime. The existing OAI receiver hook is also required.
The default build uses `-Ofast`, matching the validated live binary. Run
`bash verify.sh` for an isolated 12/24-RB numerical check. Its latency numbers
are not a performance gate while the online gNB is running.

The current implementation accepts at most 24 RB, 16-QAM, one layer and its
supported DMRS pattern. Other grants fall back to conventional OAI handling.
Do not treat a successful build as a 51/106-RB or over-the-air validation.

At packaging time, the K3 service still loaded the
`.work-neural-receiver-a100/build` library. A later deployment must inspect
the actual loader path; changeover needs separate timing and end-to-end gates.

## Published model and verification record

`../models/k3_native_joint_h24.weights` is the 4→24→24→4 native receiver
weight export from our Spark-side synthetic training script
(`train_k3_native_joint.py`, using `--hidden 24`), **not** a copy of the
upstream Sionna-RK neural receiver weights. The original on Spark is
`/home/airan/sionna-rk/.work-k3-native-joint/models/k3_native_joint_h24.weights`;
its SHA-256 matches this published file:
`ef5e66384d5b35a38de33c53a604d920f24e06991b19b69ff281b9eea3af7bfe`.
The training script uses synthetic samples, but the original training stdout,
loss history, exact command and environment lockfile were not retained.
This is a reproducible inference artifact, not a claim of exact retraining.

On K3 (2026-10-04), `bash build.sh` produced SHA-256
`3389a84978056bb44b77db6c6fcdd9ec1e9343da42168147afc81743daaa6ab8`,
identical to the original experiment binary. `bash verify.sh` passed 12/24 RB
with zero LLR sign mismatches and maximum absolute difference 1 against its
NumPy reference. The check ran alongside the online gNB, so its printed
latency is not a formal performance result.

## Isolated stage profiling

Build an **offline-only** profiled candidate with `K3NRX_PROFILE=1` and a
distinct `K3NRX_OUTPUT_NAME` when invoking `build.sh`; do not replace the
library loaded by a running gNB. Its shutdown summary separates channel-cache
construction, input packing, dense layers and LLR quantization. The regular
`verify.sh` continues to use the unprofiled build.

On K3 with no gNB running (2026-10-06), 100 repeated 24-RB calls had zero LLR
sign mismatches and maximum absolute LLR difference 1. The profiled A100
inference average was about 368 µs: channel cache 66 µs, input packing 43 µs,
dense layers 200 µs and quantization 22 µs; the remainder includes worker
handoff and measurement overhead. Python call wall time (~466 µs) is not a
PHY/PUSCH deadline measurement. An 8-output dense variant did not show a
meaningful overall speedup in the isolated check. These observations do not
clear the earlier 3 Mbps real-time gate or the 51/106-RB support gate.

## Experimental A100 worker-pool candidates

`K3NRX_WORKERS=2` or `4` builds a separate candidate that divides one PUSCH's
REs across A100 CPU8–9 or CPU8–11. The four-worker binary activates only one
worker at 1 RB, two below 24 RB, and four at 24 RB; idle workers remain
allocated but do no inference. Each active worker builds only its portion of
the channel cache. The default remains the original single-worker library;
the build script refuses to give a multiworker build its stable filename.

On an isolated K3 with gNB stopped, set `OAI_ROOT` to the matching OAI source
tree and run `bash verify_multiworker.sh 2` or `bash verify_multiworker.sh 4`.
Each builds into its own `build/workers-N/` directory and checks 1/5/12/24 RB
against the NumPy oracle. It does not start, stop or reconfigure gNB/CN5G.

The 2026-10-06 deterministic OAI `nr_ulsim` gate used TDL-B `B,l,56`, MCS 10,
1,000 frames and matched seed/weights for each single/quad pair:

| Case | Single CRC errors | Quad CRC errors | Single RX PUSCH | Quad RX PUSCH |
|---|---:|---:|---:|---:|
| 24 RB, 12 dB, seed 2609307 | 149 | 149 | 662.86 µs | 448.72 µs |
| 12 RB, 12 dB, seed 2609307 | 192 | 192 | 407.89 µs | 331.17 µs |
| 24 RB, 10 dB, seed 2609308 | 282 | 282 | 661.09 µs | 445.92 µs |

The two-worker 24-RB candidate measured 523.56 µs RX PUSCH in the first
case. NumPy checks had zero LLR sign mismatches and maximum absolute difference
1 for 1/5/12/24 RB; a 1,000-call 24-RB stress check passed. Workers reported
their CPU8–11 affinity and TCM stayed 8/8 free. The default single-worker
library rebuilt to the prior SHA-256 above.

**These are offline averages, not a real-link 3 Mbps or tail-deadline pass.**
The 24-RB quad mean is below a 0.5 ms slot, but its maximum plugin time and
OAI scheduling tails still need gates. Keep both candidates out of the live
gNB until real-link, multi-SNR/seed and resource-contention tests pass. Neither
candidate extends the receiver beyond 24 RB.
