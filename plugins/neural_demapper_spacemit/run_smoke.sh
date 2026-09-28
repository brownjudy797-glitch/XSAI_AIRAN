#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
iterations=${1:-100}

if ! [[ $iterations =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: $0 [positive_iterations]" >&2
  exit 2
fi

if pgrep -x nr-softmodem >/dev/null; then
  echo "ERROR: nr-softmodem is running; refusing offline benchmark" >&2
  exit 3
fi

required_files=(
  "$root/models/neural_demapper.2xfloat16.onnx"
  "$root/models/neural_demapper.3312xfloat16.onnx"
  "$root/build/libdemapper_spacemit_ep_scale8.so"
  "$root/build/bench_demapper_a100"
)
for path in "${required_files[@]}"; do
  if [[ ! -s $path ]]; then
    echo "ERROR: missing build artifact: $path" >&2
    echo "Run $root/install.sh first." >&2
    exit 4
  fi
done

export XSAI_SPARK_ONNX="$root/models/neural_demapper.2xfloat16.onnx"
export XSAI_SPACEMIT_EP_THREADS=8
export XSAI_SPACEMIT_EP_AFFINITY='8;9;10;11;12;13;14;15'
export XSAI_SPACEMIT_EP_STREAMS=1
export XSAI_SPACEMIT_EP_USE_GLOBAL_INTRA_THREAD=1
export XSAI_SPACEMIT_FIXED_MODEL="$root/models/neural_demapper.3312xfloat16.onnx"
export XSAI_SPACEMIT_REUSE_3312_IO=1

echo "TCM_BEFORE"
spacemit-tcm-smi | head -2

taskset -c 0 "$root/build/bench_demapper_a100" \
  "$root/build/libdemapper_spacemit_ep_scale8.so" \
  3312 "$iterations"

echo "TCM_AFTER"
spacemit-tcm-smi | head -2
