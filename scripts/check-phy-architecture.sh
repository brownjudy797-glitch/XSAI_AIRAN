#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mode=${1:-reference}
case "$mode" in reference) enabled=OFF;; rvv) enabled=ON;; *) echo 'Usage: check-phy-architecture.sh reference|rvv' >&2; exit 2;; esac
build="$root/.build/phy-$mode"
cmake -S "$root/architecture" -B "$build" -DCMAKE_C_COMPILER="${CC:-gcc-16}" -DXSAI_ENABLE_RVV="$enabled"
cmake --build "$build" -j 2
ctest --test-dir "$build" --output-on-failure
