#!/usr/bin/env bash
# Build and check an offline A100 worker-pool candidate without touching gNB.
set -euo pipefail

backend=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$backend/../../.." && pwd)
workers=${1:-2}
case "$workers" in 2|4) ;; *) echo "Usage: bash verify_multiworker.sh 2|4" >&2; exit 2;; esac
weights="$backend/../models/k3_native_joint_h24.weights"
out="$backend/build/workers-$workers"
name="libreceiver_a100_native_h24_workers${workers}_candidate.so"

if pgrep -x 'nr-softmodem|nr-softmodem.re' >/dev/null; then
  echo "Stop the gNB in an approved window before timing this candidate" >&2
  exit 2
fi
test -f "$weights"
sudo -n spacemit-tcm-smi | grep -q 'available_blocks=8/8'
oai=${OAI_ROOT:-$repo/ext/openairinterface5g}
oai_build=${OAI_BUILD:-$oai/cmake_targets/ran_build/build}
OAI_ROOT="$oai" OAI_BUILD="$oai_build" \
K3_PLUGIN_BUILD_DIR="$out" \
K3NRX_WORKERS="$workers" K3NRX_OUTPUT_NAME="$name" \
  bash "$backend/build.sh"

sudo -n env PYTHONDONTWRITEBYTECODE=1 \
  XSAI_RECEIVER_NATIVE_WEIGHTS="$weights" \
  XSAI_RECEIVER_LLR_GAIN=4 XSAI_RECEIVER_H_INTERP=1 \
  python3 "$backend/tests/validate_native_joint_receiver.py" \
  "$out/$name" "$weights" \
  --rb 1 --rb 5 --rb 12 --rb 24 --repeats 100
sudo -n spacemit-tcm-smi | grep -q 'available_blocks=8/8'
