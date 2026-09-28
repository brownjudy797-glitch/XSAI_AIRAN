# K3 SpaceMIT neural demapper

Spark-compatible FP16 neural demapper for the SpaceMIT K3 A100 cluster.  This
directory is self-contained for the demapper microbenchmark: clone the
repository on a K3, install the vendor runtime, build, and run.

## Scope

The model and plugin implement the demapper boundary only:

```text
IQ/magnitude -> FP16 [N,2] -> SpaceMIT EP/A100
             -> 2->32->32->4 MLP -> int16 LLR (scale 8)
```

The standalone benchmark includes RVV preprocessing, `Ort::Session::Run`, A100
inference and LLR quantization. It does not include FFT, channel estimation,
resource extraction or LDPC.

## 1. Install the SpaceMIT runtime

The commands below target a `riscv64` K3 image whose SpaceMIT K3 PPA is already
configured:

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential \
  spacemit-onnxruntime \
  python3-spacemit-ort
```

Verify the provider and TCM before cloning or building:

```bash
python3 - <<'PY'
import onnxruntime as ort
import spacemit_ort

providers = ort.get_available_providers()
print("onnxruntime:", ort.__version__)
print("providers:", providers)
assert "SpaceMITExecutionProvider" in providers
PY

spacemit-tcm-smi
```

An idle board should report `runtime=available` and `available_blocks=8/8`.

## 2. Clone and install

```bash
cd /home/ubuntu
git clone --depth 1 \
  https://github.com/brownjudy797-glitch/XSAI_AIRAN.git
cd XSAI_AIRAN/plugins/neural_demapper_spacemit

chmod +x install.sh run_smoke.sh
./install.sh
```

`INSTALL_COMPLETE` means the fixed 3312-RE model, plugin and benchmark were
built successfully. The repository is currently private, so `git clone`
requires GitHub authentication on the K3.

## 3. Run

Functional smoke test:

```bash
./run_smoke.sh 100
```

Initial timing sample:

```bash
./run_smoke.sh 2000
```

A valid run prints all of the following:

```text
affinity=8;9;10;11;12;13;14;15
scale=8
A100_DEMAPPER nb_re=3312 iterations=...
```

TCM must return to `available_blocks=8/8` after the process exits.

## 4. OAI integration boundary

The plugin exports `demapper_init`, `demapper_init_thread`,
`demapper_compute_llr`, batch/multi-ULSCH entry points, and
`demapper_shutdown`. An OAI build with the demapper loader can load it using:

```bash
--loader.demapper.shlibpath /absolute/path/to/plugins/neural_demapper_spacemit/build \
--loader.demapper.shlibversion _spacemit_ep_scale8
```

This repository directory does not claim that the standalone smoke is a full
receiver result. `nr_ulsim` validation must separately freeze seed, SNR, PRB,
MCS, layers, frame count and LDPC iterations, then report BLER, false positives
and full RX wall time.

## Reproducibility

- Spark model: FP16 `[N,2] -> [N,4]`, MLP `2->32->32->4`.
- K3 LLR output scale: 8.
- Default A100 worker affinity: CPU8-15.
- Smoke benchmark: 20 warmups followed by the requested measured iterations.
- Timing clock: `CLOCK_MONOTONIC`.

See `docs/` for the installation/call/measurement review, current optimization
issues, and Stage-18 fixed-session cache results.
