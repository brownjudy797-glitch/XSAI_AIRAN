#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Clean restart of the K3 real-RF core and the frozen 24 RB gNB baseline.
set -euo pipefail

root=/home/ubuntu/sionna-rk
mode=${1:-continuous}
case "$mode" in
  continuous|normal) ;;
  *) printf 'Usage: %s [continuous|normal]\n' "$0" >&2; exit 2 ;;
esac

sudo -n systemctl stop k3-b200-gnb.service 2>/dev/null || true

# A remaining candidate gNB must be stopped explicitly; never start two
# nr-softmodem instances against the same B210.
if pgrep -x nr-softmodem >/dev/null; then
  printf 'Another nr-softmodem is still running; stop it before clean restart.\n' >&2
  pgrep -ax nr-softmodem >&2
  exit 1
fi

bash "$root/scripts/stop-cn5g-k3.sh"
bash "$root/scripts/start-cn5g-k3.sh"
bash "$root/scripts/start-k3-b200-ready.sh" "$mode"

for name in amf smf upf; do
  count=$(pgrep -xc "$name" || true)
  [[ $count == 1 ]] || { printf 'Expected one %s process; found %s\n' "$name" "$count" >&2; exit 1; }
done

pid=$(sudo -n systemctl show k3-b200-gnb.service -p MainPID --value)
[[ $pid =~ ^[1-9][0-9]*$ && -d /proc/$pid ]] || {
  printf 'gNB service has no live main process\n' >&2
  exit 1
}

printf 'K3 core and gNB ready. Reboot the UE modem once to establish a fresh PDU session.\n'
