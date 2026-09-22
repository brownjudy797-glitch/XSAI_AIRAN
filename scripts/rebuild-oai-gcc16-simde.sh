#!/usr/bin/env bash
set -euo pipefail

ROOT=/home/ubuntu/sionna-rk
OAI="$ROOT/ext/openairinterface5g"
LOG="$ROOT/.runtime/k3-b200/oai-gcc16-simde-build.log"

cd "$OAI"

export CFLAGS="-march=rv64gcv_zba_zbb_zbs -mabi=lp64d"
export CXXFLAGS="$CFLAGS"
export CC=/usr/bin/gcc-16
export CXX=/usr/bin/g++-16

args=(
  -C
  -d ran_build_rvv
  -w USRP
  --gNB
  --nrUE
  --cmake-opt "-DENABLE_PLUGINS=ON"
  --cmake-opt "-DENABLE_CUDA=OFF"
  --cmake-opt "-DENABLE_DGX_OPTIMIZATIONS=OFF"
  --cmake-opt "-DAVX2=OFF"
  --cmake-opt "-DAVX512=OFF"
  --build-tool-opt "-j8"
)

exec ./cmake_targets/build_oai "${args[@]}" >"$LOG" 2>&1
