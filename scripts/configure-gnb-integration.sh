#!/usr/bin/env bash
# Configure only: no installation, radio discovery or service changes.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $# == 1 && "$1" = /* && -f "$1/adapters/oai/include/xsai_dfts_adapter.h" ]] || {
  echo 'Usage: configure-gnb-integration.sh ABSOLUTE_PREPARED_OAI_SOURCE' >&2
  exit 2
}
source_dir=$(realpath "$1")
[[ "$source_dir" != */ext/openairinterface5g ]] || {
  echo 'Refusing the live ext tree; use prepare-oai-worktree.sh first' >&2; exit 2;
}
build="$root/.build/gnb-integration"
mkdir -p "$build"
cmake -S "$source_dir" -B "$build" \
  -DCMAKE_C_COMPILER=/usr/bin/gcc-16 -DCMAKE_CXX_COMPILER=/usr/bin/g++-16 \
  '-DCMAKE_C_FLAGS=-march=rv64gcv_zba_zbb_zbs -mabi=lp64d -mrvv-vector-bits=scalable' \
  '-DCMAKE_CXX_FLAGS=-march=rv64gcv_zba_zbb_zbs -mabi=lp64d -mrvv-vector-bits=scalable' \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DOAI_USRP=ON -DOAI_SIMU=ON \
  -DOAI_RF_EMULATOR=ON -DOAI_VRTSIM=ON -DENABLE_AVX2RVV=OFF -DENABLE_PLUGINS=ON \
  2>&1 | tee "$build/integration-configure.log"
