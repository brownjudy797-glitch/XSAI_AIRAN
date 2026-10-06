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
