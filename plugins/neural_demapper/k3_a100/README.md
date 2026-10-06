# K3 A100 neural demapper backend

This backend is separate from the Spark CUDA/TensorRT demapper in the parent
directory. It preserves the OAI `demapper` loader ABI and computes LLRs; OAI
still performs LDPC decoding. Source was copied from
`.work-neural-demapper-a100/src/demapper_a100_rvv.cpp`.

Build on K3 with `bash build.sh`. The resulting library is in `build/` and is
not selected automatically. The original model weights are copied to
`../models/demapper_a100.weights`; set `XSAI_DEMAPPER_WEIGHTS` to that absolute
path at runtime. Do not substitute a receiver model or ONNX file. Run
`bash verify.sh` for a loader, fallback and one-call 16-QAM smoke test.

The current online K3 demonstration enables the receiver only, not this
demapper. Enabling both requires an explicit integration and timing test.

## Published model and verification record

`../models/demapper_a100.weights` is the K3 native export of the Spark
2→32→32→4 demapper weights, not a model trained by this K3 project. The source
checkpoint is NVIDIA Sionna-RK's tracked
`plugins/neural_demapper/models/neural_demapper_weights_y2`; the K3 export
transposes its linear-layer layout and stores FP16-rounded values in a native
container. SHA-256:
`6e07a16359018d6e5a50416603736db1a8e0388cf29ec5ce06309615d63597bd`.
Keep this model separate from the receiver weights and the distilled/SpaceMIT
EP candidates. Preserve NVIDIA attribution and the upstream Apache-2.0 license;
see the upstream [model card](https://github.com/NVlabs/sionna-rk/blob/main/plugins/neural_demapper/Modelcard_demapper.md).

On K3 (2026-10-04), `bash build.sh` produced SHA-256
`4978c24c9ba2470e1cad1d31766a76798a9a3c87515a1c9f28754d6d17aecfc6`,
identical to the original experiment binary. `bash verify.sh` passed loader,
unsupported-modulation fallback and one 16-QAM inference; it is not a full
BLER or over-the-air gate.
