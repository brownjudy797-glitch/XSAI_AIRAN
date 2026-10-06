#!/usr/bin/env bash
set -euo pipefail

backend=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$backend/../../.." && pwd)
oai=${OAI_ROOT:-$repo/ext/openairinterface5g}
oai_build=${OAI_BUILD:-$oai/cmake_targets/ran_build/build}
out=${K3_PLUGIN_BUILD_DIR:-$backend/build}
batch=${K3NRX_BATCH:-256}
input=${K3NRX_INPUT:-4}
hidden=${K3NRX_HIDDEN:-24}
block4=${K3NRX_BLOCK4:-1}
block8=${K3NRX_BLOCK8:-0}
profile=${K3NRX_PROFILE:-0}
hcache=${K3NRX_HCACHE:-1}
fast_math=${K3NRX_FAST_MATH:-1}
name=${K3NRX_OUTPUT_NAME:-libreceiver_a100_native_h24_b4_b256_hcache_power.so}

case "$batch" in 64|128|256) ;; *) echo "Unsupported batch: $batch" >&2; exit 2;; esac
case "$input" in 4|6) ;; *) echo "Unsupported input: $input" >&2; exit 2;; esac
case "$hidden" in 16|24|32) ;; *) echo "Unsupported hidden: $hidden" >&2; exit 2;; esac
for value in "$block4" "$block8" "$profile" "$hcache" "$fast_math"; do
  case "$value" in 0|1) ;; *) echo "Expected 0 or 1: $value" >&2; exit 2;; esac
done
case "$name" in libreceiver_a100_native*.so) ;; *) echo "Invalid output name" >&2; exit 2;; esac

mkdir -p "$out"
includes=(
  -I"$oai" -I"$oai/openair1" -I"$oai/openair2"
  -I"$oai/executables" -I"$oai/radio/COMMON" -I"$oai/common/utils"
  -I"$oai/nfapi/open-nFAPI/nfapi/public_inc"
  -I"$oai/nfapi/open-nFAPI/common/public_inc"
  -I"$oai_build" -I"$oai_build/common/utils/T" -I"$backend/src"
)
vector_arch=(-march=rv64gcv_zba_zbb_zbs -mabi=lp64d -mrvv-vector-bits=scalable)

gcc -O2 -fPIC -std=gnu11 -DMAX_NUM_CCs=1 -DNB_ANTENNAS_RX=4 \
  -DNB_ANTENNAS_TX=4 "${vector_arch[@]}" "${includes[@]}" \
  -Wno-packed-bitfield-compat \
  -c "$backend/src/nr_receiver_spacemit.c" -o "$out/nr_receiver_a100_native.o"

# HMP switching must happen before the worker executes vector instructions.
gcc -O2 -fPIC -std=gnu11 -march=rv64gc -mabi=lp64d \
  -c "$backend/src/a100_worker.c" -o "$out/a100_worker.o"

optimization=(-O3)
if [[ "$fast_math" == 1 ]]; then optimization=(-Ofast); fi
g++ "${optimization[@]}" -fPIC -std=gnu++17 \
  -DK3NRX_BATCH="$batch" -DK3NRX_INPUT="$input" -DK3NRX_HIDDEN="$hidden" \
  -DK3NRX_BLOCK4="$block4" -DK3NRX_BLOCK8="$block8" \
  -DK3NRX_PROFILE="$profile" -DK3NRX_HCACHE="$hcache" \
  "${vector_arch[@]}" "${includes[@]}" \
  -c "$backend/src/receiver_a100_native.cpp" \
  -o "$out/receiver_a100_native.o"

g++ -shared "${vector_arch[@]}" \
  "$out/nr_receiver_a100_native.o" "$out/a100_worker.o" \
  "$out/receiver_a100_native.o" -lpthread -lm -o "$out/$name"
sha256sum "$out/$name"
readelf -Ws "$out/$name" |
  grep -E 'receiver_(init|init_thread|shutdown|compute_llr|symbols_requested)$'
