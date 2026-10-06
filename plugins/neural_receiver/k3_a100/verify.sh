#!/usr/bin/env bash
set -euo pipefail

backend=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
library="$backend/build/libreceiver_a100_native_h24_b4_b256_hcache_power.so"
weights="$backend/../models/k3_native_joint_h24.weights"
test -f "$library"
test -f "$weights"

# Numerical gate only. When a gNB is active, timing printed by the validator
# is contaminated by concurrent work and must not be treated as a benchmark.
sudo -n env PYTHONDONTWRITEBYTECODE=1 \
  XSAI_RECEIVER_NATIVE_WEIGHTS="$weights" \
  XSAI_RECEIVER_LLR_GAIN=4 XSAI_RECEIVER_H_INTERP=1 \
  python3 "$backend/tests/validate_native_joint_receiver.py" \
  "$library" "$weights" --rb 12 --rb 24 --repeats 3
