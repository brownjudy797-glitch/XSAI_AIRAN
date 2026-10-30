#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
root=${SIONNA_RK_ROOT:-$HOME/sionna-rk}
if pgrep -x nr-softmodem >/dev/null; then
  echo 'gNB already running; keep it and inspect its current invocation.'
  exit 0
fi
python3 "$root/scripts/archive-k3-runtime-logs.py" --root "$root"
exec bash "$root/scripts/start-k3-b200-ready.sh" "${1:-normal}"
