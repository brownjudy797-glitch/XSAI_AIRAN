#!/usr/bin/env bash
set -euo pipefail

backend=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out=${K3_PLUGIN_BUILD_DIR:-$backend/build}
library="$out/libdemapper_a100_rvv.so"
weights="$backend/../models/demapper_a100.weights"
test -f "$library"
test -f "$weights"
mkdir -p "$out"

gcc -O2 -Wall -Wextra -Werror -march=rv64gc -mabi=lp64d \
  "$backend/tests/run_on_k3_a100.c" -o "$out/run_on_k3_a100"
gcc -O2 -Wall -Wextra -Werror \
  "$backend/tests/test_demapper_a100.c" -ldl \
  -o "$out/test_demapper_a100"

sudo -n env XSAI_DEMAPPER_WEIGHTS="$weights" \
  "$out/run_on_k3_a100" "$out/test_demapper_a100" "$library"
