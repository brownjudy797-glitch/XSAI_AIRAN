#!/usr/bin/env bash
set -euo pipefail

ROOT="${SIONNA_RK_ROOT:-$HOME/sionna-rk}"
OAI="${OAI_ROOT:-$ROOT/ext/openairinterface5g}"
BUILD="${OAI_BUILD:-$OAI/cmake_targets/ran_build/build}"
RUN_ID="${1:-$(date +%Y%m%d-%H%M%S)}"
OUT_ROOT="${RFSIM_RESULTS_ROOT:-$HOME/k3-rfsim-results}"
RUN_DIR="$OUT_ROOT/$RUN_ID"

GNB_REL="ci-scripts/conf_files/gnb.sa.band78.106prb.rfsim.conf"
UE_REL="targets/PROJECTS/GENERIC-NR-5GC/CONF/ue.conf"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(uname -m)" = riscv64 ] || die "Expected riscv64, got $(uname -m)"
[ -d "$OAI/.git" ] || die "OAI repository not found: $OAI"
[ -x "$BUILD/nr-softmodem" ] || die "Missing $BUILD/nr-softmodem"
[ -x "$BUILD/nr-uesoftmodem" ] || die "Missing $BUILD/nr-uesoftmodem"
[ ! -e "$RUN_DIR" ] || die "Run directory already exists: $RUN_DIR"

mkdir -p "$RUN_DIR/ideal" "$RUN_DIR/awgn-minus95"

# Export clean configuration files from the current OAI commit. This avoids
# modifying or depending on dirty repository-owned configuration files.
git -C "$OAI" show "HEAD:$GNB_REL" >"$RUN_DIR/ideal/gnb.conf"
git -C "$OAI" show "HEAD:$UE_REL" >"$RUN_DIR/ideal/ue.conf"
# This OAI revision's generic UE file includes a SAT_LEO_TRANS model. Remove
# it so both the ideal baseline and the AWGN experiment have explicit models.
sed -i '/^[[:space:]]*@include[[:space:]]*"channelmod_rfsimu_LEO_satellite.conf"/d' \
  "$RUN_DIR/ideal/ue.conf"
cp "$RUN_DIR/ideal/gnb.conf" "$RUN_DIR/awgn-minus95/gnb.conf"
cp "$RUN_DIR/ideal/ue.conf" "$RUN_DIR/awgn-minus95/ue.conf"

cat >>"$RUN_DIR/awgn-minus95/gnb.conf" <<'EOF'

channelmod = {
  max_chan = 10;
  modellist = "modellist_rfsimu_1";
  modellist_rfsimu_1 = (
    { model_name = "rfsimu_channel_enB0"; type = "AWGN"; ploss_dB = 0; noise_power_dB = -100; forgetfact = 0; offset = 0; ds_tdl = 0; },
    { model_name = "rfsimu_channel_ue0";  type = "AWGN"; ploss_dB = 0; noise_power_dB = -95;  forgetfact = 0; offset = 0; ds_tdl = 0; }
  );
};
EOF

{
  printf 'run_id=%s\n' "$RUN_ID"
  printf 'created=%s\n' "$(date --iso-8601=seconds)"
  printf 'host=%s\n' "$(hostname)"
  printf 'kernel=%s\n' "$(uname -r)"
  printf 'outer_root=%s\n' "$ROOT"
  printf 'outer_branch=%s\n' "$(git -C "$ROOT" branch --show-current 2>/dev/null || true)"
  printf 'outer_commit=%s\n' "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
  printf 'oai_root=%s\n' "$OAI"
  printf 'oai_commit=%s\n' "$(git -C "$OAI" rev-parse HEAD)"
  printf 'build=%s\n' "$BUILD"
  printf 'gnb_sha256=%s\n' "$(sha256sum "$BUILD/nr-softmodem" | awk '{print $1}')"
  printf 'ue_sha256=%s\n' "$(sha256sum "$BUILD/nr-uesoftmodem" | awk '{print $1}')"
  printf 'cpu_meas_source=%s\n' "$(grep -m1 'int cpu_meas_enabled' "$OAI/common/utils/time_meas.c" | xargs)"
} >"$RUN_DIR/manifest.txt"

printf '%s\n' "$RUN_DIR" >"$OUT_ROOT/LATEST"
printf 'Prepared: %s\n' "$RUN_DIR"
printf 'Manifest:\n'
cat "$RUN_DIR/manifest.txt"
