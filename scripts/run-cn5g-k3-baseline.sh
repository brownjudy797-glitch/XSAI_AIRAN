#!/usr/bin/env bash
set -uo pipefail

ROOT="${SIONNA_RK_ROOT:-$HOME/sionna-rk}"
NS="cn5g-ue"
UE_IP="12.1.1.130"
SERVER_IP="${IPERF_SERVER_IP:-10.17.116.247}"
ROUNDS="${1:-5}"
DURATION="${DURATION_SECONDS:-10}"
WARMUP="${WARMUP_SECONDS:-20}"
COOLDOWN="${COOLDOWN_SECONDS:-30}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/results/cn5g-k3/baseline-$STAMP"
SUMMARY="$OUT/summary.tsv"

mkdir -p "$OUT"

if ! sudo ip netns exec "$NS" ip link show oaitun_ue1 >/dev/null 2>&1; then
  echo "ERROR: full stack/PDU session is not active." >&2
  exit 1
fi

cleanup_iperf() { sudo pkill -x iperf3 2>/dev/null || true; }
trap cleanup_iperf EXIT INT TERM

{
  echo "timestamp=$STAMP"
  echo "rounds=$ROUNDS"
  echo "duration_seconds=$DURATION"
  echo "warmup_seconds=$WARMUP"
  echo "cooldown_seconds=$COOLDOWN"
  echo "kernel=$(uname -r)"
  echo "architecture=$(uname -m)"
  echo "allowed_cpus=$(awk '/Cpus_allowed_list/{print $2}' /proc/self/status)"
  echo "oai_commit=$(git -C "$ROOT/ext/openairinterface5g" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "sionna_rk_commit=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  for p in /sys/devices/system/cpu/cpufreq/policy*; do
    echo "$(basename "$p")_governor=$(cat "$p/scaling_governor" 2>/dev/null || echo unknown)"
    echo "$(basename "$p")_max_khz=$(cat "$p/scaling_max_freq" 2>/dev/null || echo unknown)"
  done
  sha256sum "$ROOT/config/cn5g-k3/"*.yaml "$ROOT/config/cn5g-k3/gnb-rfsim.conf" "$ROOT/ext/oai-cn5g-fed/docker-compose/ran-conf/nr-ue.conf"
} >"$OUT/metadata.txt"

printf 'round\tdirection\tsender_mbps\treceiver_mbps\tretransmits\tcur_freq_khz\ttemperature_mC\n' >"$SUMMARY"

echo "Warm-up ${WARMUP}s..."
sudo ip netns exec "$NS" ping -I oaitun_ue1 -i 1 -w "$WARMUP" 12.1.1.1 >"$OUT/warmup-ping.txt" 2>&1 || true

run_one() {
  local round="$1"
  local direction="$2"
  local reverse=()
  local json="$OUT/${direction}-run${round}.json"
  local server_log="$OUT/${direction}-run${round}-server.log"
  local freq temp

  [[ "$direction" == "downlink" ]] && reverse=(-R)
  cleanup_iperf
  iperf3 -s -B "$SERVER_IP" -D --logfile "$server_log"
  sleep 2
  sudo ip netns exec "$NS" iperf3 -c "$SERVER_IP" -B "$UE_IP" \
    -t "$DURATION" -O 2 --connect-timeout 15000 --json "${reverse[@]}" >"$json" || true
  cleanup_iperf

  freq="$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null || echo unknown)"
  temp="$(awk 'FNR==1{print $1; exit}' /sys/class/thermal/thermal_zone*/temp 2>/dev/null || echo unknown)"
  jq -r --arg round "$round" --arg direction "$direction" --arg freq "$freq" --arg temp "$temp" '
    [$round, $direction,
     ((.end.sum_sent.bits_per_second // 0) / 1000000),
     ((.end.sum_received.bits_per_second // 0) / 1000000),
     (.end.sum_sent.retransmits // 0), $freq, $temp] | @tsv
  ' "$json" >>"$SUMMARY"
}

for round in $(seq 1 "$ROUNDS"); do
  echo "[$round/$ROUNDS] uplink"
  run_one "$round" uplink
  sleep "$COOLDOWN"
  echo "[$round/$ROUNDS] downlink"
  run_one "$round" downlink
  [[ "$round" -lt "$ROUNDS" ]] && sleep "$COOLDOWN"
done

echo "Baseline completed: $OUT"
column -t -s $'\t' "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
