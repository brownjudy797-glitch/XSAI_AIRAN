#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if [[ $(uname -m) != riscv64 ]]; then
  echo "ERROR: this package must be built on a riscv64 K3" >&2
  exit 1
fi

required_packages=(build-essential spacemit-onnxruntime python3-spacemit-ort spacemit-tcm)
missing_packages=()
for package in "${required_packages[@]}"; do
  if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
    missing_packages+=("$package")
  fi
done

if ((${#missing_packages[@]})); then
  echo "ERROR: missing packages: ${missing_packages[*]}" >&2
  echo "Install them first with apt, then rerun this script." >&2
  exit 2
fi

python3 - <<'PY'
import onnxruntime as ort
import spacemit_ort

providers = ort.get_available_providers()
print("onnxruntime:", ort.__version__)
print("providers:", providers)
if "SpaceMITExecutionProvider" not in providers:
    raise SystemExit("SpaceMITExecutionProvider is not registered")
PY

(cd "$root" && sha256sum -c MODEL_SHA256SUMS)

mkdir -p "$root/build" "$root/models"

python3 "$root/tools/make_fixed_batch_onnx.py" \
  "$root/models/neural_demapper.2xfloat16.onnx" \
  "$root/models/neural_demapper.3312xfloat16.onnx" \
  --batch 3312

(cd "$root" && bash tools/build_spacemit_ep_k3.sh src/demapper_spacemit_ep.cpp)

gcc -O3 "$root/tests/bench_demapper_a100.c" \
  -ldl -o "$root/build/bench_demapper_a100"

test -x "$root/build/bench_demapper_a100"
test -s "$root/build/libdemapper_spacemit_ep_scale8.so"
test -s "$root/models/neural_demapper.3312xfloat16.onnx"

echo "INSTALL_COMPLETE"
echo "Next: $root/run_smoke.sh 100"
