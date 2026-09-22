#!/usr/bin/env bash
set -u

ROOT="${SIONNA_RK_ROOT:-$HOME/sionna-rk}"
LOG="$ROOT/logs/cn5g-k3"

"$ROOT/scripts/status-cn5g-k3.sh"

for item in "gNB:nr-softmodem" "nrUE:nr-uesoftmodem"; do
  name="${item%%:*}"
  process="${item##*:}"
  if pgrep -x "$process" >/dev/null; then
    echo "$name: running"
  else
    echo "$name: stopped"
  fi
done

if sudo -n ip netns exec cn5g-ue ip link show oaitun_ue1 >/dev/null 2>&1; then
  echo "UE PDU: active"
  sudo -n ip netns exec cn5g-ue ip -br addr show oaitun_ue1
else
  echo "UE PDU: inactive"
fi

grep -q "Received NGSetupResponse" "$LOG/gnb.log" 2>/dev/null \
  && echo "N2 NG Setup: confirmed" || echo "N2 NG Setup: not confirmed"
grep -q "Received PDU Session Establishment Accept" "$LOG/nrue.log" 2>/dev/null \
  && echo "PDU Session Accept: confirmed" || echo "PDU Session Accept: not confirmed"

