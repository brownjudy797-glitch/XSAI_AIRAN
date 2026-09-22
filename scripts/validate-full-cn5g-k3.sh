#!/usr/bin/env bash
set -uo pipefail

ROOT="${SIONNA_RK_ROOT:-$HOME/sionna-rk}"
RESULTS="$ROOT/results/cn5g-k3"
NS="cn5g-ue"
UE_IP="12.1.1.130"
UPF_IP="12.1.1.1"
SERVER_IP="${IPERF_SERVER_IP:-10.17.116.247}"
SECONDS_PER_TEST="${IPERF_SECONDS:-10}"
STAMP="$(date +%Y%m%d-%H%M%S)"
SUMMARY="$RESULTS/validation-$STAMP.txt"

mkdir -p "$RESULTS"
exec > >(tee "$SUMMARY") 2>&1

echo "K3 CN5G validation: $STAMP"
echo "============================================================"
"$ROOT/scripts/status-full-cn5g-k3.sh"

if ! sudo ip netns exec "$NS" ip link show oaitun_ue1 >/dev/null 2>&1; then
  echo "FAIL: oaitun_ue1 is unavailable; start the full stack first."
  exit 1
fi

echo
echo "[1/3] UE -> UPF ping"
sudo ip netns exec "$NS" ping -I oaitun_ue1 -c 5 -W 3 "$UPF_IP" || true

echo
echo "[2/3] UE -> Internet ping"
sudo ip netns exec "$NS" ping -I oaitun_ue1 -c 5 -W 3 8.8.8.8 || true

if [[ "${RUN_IPERF:-yes}" != "yes" ]]; then
  echo
  echo "[3/3] iperf3 skipped (RUN_IPERF=${RUN_IPERF:-no})"
  echo "Summary: $SUMMARY"
  exit 0
fi

cleanup_iperf() {
  sudo pkill -x iperf3 2>/dev/null || true
}
trap cleanup_iperf EXIT

run_iperf() {
  local direction="$1"
  local reverse=()
  [[ "$direction" == "downlink" ]] && reverse=(-R)

  cleanup_iperf
  iperf3 -s -B "$SERVER_IP" -D \
    --pidfile "/tmp/iperf3-cn5g-$direction.pid" \
    --logfile "$RESULTS/iperf3-server-$direction-$STAMP.txt"
  sleep 2
  sudo ip netns exec "$NS" iperf3 \
    -c "$SERVER_IP" -B "$UE_IP" \
    -t "$SECONDS_PER_TEST" -O 2 --connect-timeout 15000 \
    "${reverse[@]}" | tee "$RESULTS/iperf3-$direction-$STAMP.txt"
  cleanup_iperf
}

echo
echo "[3/3] iperf3 uplink (${SECONDS_PER_TEST}s)"
run_iperf uplink || true
sleep "${IPERF_COOLDOWN_SECONDS:-10}"

echo
echo "[3/3] iperf3 downlink (${SECONDS_PER_TEST}s)"
run_iperf downlink || true

echo
echo "Validation finished."
echo "Summary: $SUMMARY"
