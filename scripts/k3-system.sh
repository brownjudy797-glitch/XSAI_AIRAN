#!/usr/bin/env bash
set -euo pipefail

ROOT="${SIONNA_RK_ROOT:-$HOME/sionna-rk}"
CN_START="$ROOT/scripts/start-cn5g-k3.sh"
CN_STOP="$ROOT/scripts/stop-cn5g-k3.sh"
CN_STATUS="$ROOT/scripts/status-cn5g-k3.sh"
GNB="$ROOT/scripts/run-k3-b200.sh"
GNB_UNIT="k3-b200-gnb.service"
CN_LOG="$ROOT/logs/cn5g-k3"

die() { echo "ERROR: $*" >&2; exit 1; }

core_ready() {
  pgrep -x upf >/dev/null &&
  pgrep -x smf >/dev/null &&
  pgrep -x amf >/dev/null &&
  grep -q "N4 ASSOCIATION SETUP RESPONSE" "$CN_LOG/smf.log" 2>/dev/null
}

wait_for_core() {
  local i
  for i in $(seq 1 30); do
    core_ready && return 0
    sleep 1
  done
  tail -n 50 "$CN_LOG/smf.log" 2>/dev/null || true
  die "5G Core did not become ready within 30 seconds"
}

gnb_ngap_ready() {
  local sctp
  sudo systemctl is-active --quiet "$GNB_UNIT" || return 1
  sctp=$(ss -H -A sctp state established 2>/dev/null) || return 1
  grep -Eq '(^|[[:space:]])[^[:space:]]*:38412([[:space:]]|$)' <<<"$sctp"
}

wait_for_gnb() {
  local i
  for i in $(seq 1 30); do
    gnb_ngap_ready && return 0
    sleep 1
  done
  sudo journalctl -u "$GNB_UNIT" -n 80 --no-pager 2>/dev/null || true
  die "gNB did not associate with AMF within 30 seconds"
}

start_all() {
  if core_ready; then
    echo "5G Core is already ready"
  else
    "$CN_START"
    wait_for_core
  fi
  echo "5G Core ready (UPF/SMF/AMF and N4)"

  if sudo systemctl is-active --quiet "$GNB_UNIT"; then
    echo "gNB is already running"
  else
    "$GNB" start
  fi
  wait_for_gnb
  echo "K3 OAI system ready (Core + N4 + gNB + NGAP)"
}

stop_all() {
  sudo systemctl stop "$GNB_UNIT" 2>/dev/null || true
  "$CN_STOP"
  echo "K3 OAI system stopped"
}

status_all() {
  "$CN_STATUS"
  if sudo systemctl is-active --quiet "$GNB_UNIT"; then
    echo "gNB: running"
  else
    echo "gNB: stopped"
  fi
  sudo journalctl -u "$GNB_UNIT" --since "5 minutes ago" --no-pager 2>/dev/null |
    grep -E "Received NGSetupResponse|associated AMF|RRC_CONNECTED|out-of-sync" | tail -n 20 || true
}

case "${1:-start}" in
  start) start_all ;;
  stop) stop_all ;;
  restart) stop_all; sleep 2; start_all ;;
  status) status_all ;;
  log) exec sudo journalctl -fu "$GNB_UNIT" -n 100 ;;
  *) echo "Usage: $0 start|stop|restart|status|log" >&2; exit 2 ;;
esac
