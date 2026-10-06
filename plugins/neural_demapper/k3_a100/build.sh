#!/usr/bin/env bash
set -euo pipefail

backend=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out=${K3_PLUGIN_BUILD_DIR:-$backend/build}
mkdir -p "$out"

g++ -O3 -fPIC -shared -std=gnu++17 -Wall -Wextra -Werror \
  -march=rv64gcv_zba_zbb_zbs -mabi=lp64d -mrvv-vector-bits=scalable \
  "$backend/src/demapper_a100_rvv.cpp" -lpthread \
  -o "$out/libdemapper_a100_rvv.so"
sha256sum "$out/libdemapper_a100_rvv.so"
readelf -Ws "$out/libdemapper_a100_rvv.so" |
  grep -E 'demapper_(init|init_thread|shutdown|compute_llr)$'
