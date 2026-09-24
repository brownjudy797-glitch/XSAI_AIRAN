#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
baseline=${OAI_BASELINE:-$root/vendor/openairinterface5g}
build="$root/.build/dfts-migration"
mkdir -p "$build"
cc=${CC:-gcc-16}
flags=(-O2 -Wall -Wextra -Werror -march=rv64gcv_zba_zbb_zbs -mabi=lp64d -mrvv-vector-bits=scalable)
cmp "$baseline/openair1/PHY/TOOLS/oai_dfts_rvv.h" "$root/plugins/rvv_phy/include/oai_dfts_rvv.h"
"$cc" "${flags[@]}" -DVARIANT=before "-DKERNEL_HEADER=\"$baseline/openair1/PHY/TOOLS/oai_dfts_rvv.h\"" -c "$root/architecture/tests/dfts_variant.c" -o "$build/before.o"
"$cc" "${flags[@]}" -DVARIANT=after "-DKERNEL_HEADER=\"$root/adapters/oai/include/xsai_dfts_adapter.h\"" -c "$root/architecture/tests/dfts_variant.c" -o "$build/after.o"
"$cc" "${flags[@]}" "$root/architecture/tests/test_dfts_migration.c" "$build/before.o" "$build/after.o" -o "$build/test"
"$build/test"
