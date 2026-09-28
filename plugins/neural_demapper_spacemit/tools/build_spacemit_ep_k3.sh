#!/usr/bin/env bash
set -euo pipefail

src=${1:-demapper_spacemit_ep.cpp}
mkdir -p build

flags=(
  -O3 -funroll-loops -fPIC -shared
  -march=rv64gcv_zba_zbb_zbs_zfhmin_zvfh -mabi=lp64d
  -mrvv-vector-bits=scalable
)
libs=(-lonnxruntime -lspacemit_ep -lpthread -ldl)

g++ "${flags[@]}" "$src" "${libs[@]}" \
  -o build/libdemapper_spacemit_ep.so
g++ "${flags[@]}" -DSPARK_LLR_SCALE=8 "$src" "${libs[@]}" \
  -o build/libdemapper_spacemit_ep_scale8.so

sha256sum build/libdemapper_spacemit_ep.so \
  build/libdemapper_spacemit_ep_scale8.so
