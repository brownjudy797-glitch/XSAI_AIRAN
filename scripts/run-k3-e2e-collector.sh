#!/usr/bin/env bash
set -euo pipefail

ROOT="${SIONNA_RK_ROOT:-$HOME/sionna-rk}"
RESULT_ROOT="${E2E_RESULT_ROOT:-$ROOT/results/e2e}"
ACTION="${1:-}"
RUN_ID="${2:-}"
INTERVAL="${E2E_SAMPLE_INTERVAL:-1}"
ENABLE_PERF="${E2E_ENABLE_PERF:-1}"
LIGHTWEIGHT="${E2E_LIGHTWEIGHT:-0}"
BUILD="${E2E_GNB_BUILD:-$ROOT/ext/openairinterface5g/cmake_targets/ran_build/build}"

die() { echo "ERROR: $*" >&2; exit 1; }
safe_id() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
run_dir() { printf '%s/%s' "$RESULT_ROOT" "$RUN_ID"; }

# Keep the PHY snapshot rule identical to run-k3-hotspot-experiment.sh: retry
# until the periodically rewritten stats file is complete through feptx_total.
capture_stats() {
  local source_file="$1" target_file="$2" final_marker="$3"
  local tmp_file="${target_file}.tmp"
  for _ in $(seq 1 15); do
    if sudo -n test -s "$source_file" 2>/dev/null; then
      sudo -n cp "$source_file" "$tmp_file"
      sudo -n chown "$(id -u):$(id -g)" "$tmp_file"
      if grep -q "$final_marker" "$tmp_file" 2>/dev/null; then
        mv "$tmp_file" "$target_file"
        return 0
      fi
      rm -f "$tmp_file"
    fi
    sleep 1
  done
  die "could not capture a complete statistics snapshot from $source_file"
}

metadata() {
  local out="$1"
  {
    echo "collected_at=$(date --iso-8601=seconds)"
    echo "hostname=$(hostname)"
    echo "kernel=$(uname -r)"
    echo "architecture=$(uname -m)"
    echo "sionna_rk_commit=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "oai_commit=$(git -C "$BUILD" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "gnb_binary_sha256=$(sha256sum "$BUILD/nr-softmodem" 2>/dev/null | awk '{print $1}' || echo missing)"
    echo "gnb_build=$BUILD"
    echo "gnb_service_active=$(systemctl is-active k3-b200-gnb.service 2>/dev/null || true)"
    echo "amf_pid=$(pgrep -x amf | paste -sd, -)"
    echo "smf_pid=$(pgrep -x smf | paste -sd, -)"
    echo "upf_pid=$(pgrep -x upf | paste -sd, -)"
    ip -4 -brief address
    lscpu
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
      [[ -d "$p" ]] || continue
      echo "$(basename "$p") governor=$(cat "$p/scaling_governor" 2>/dev/null || echo unknown) min_khz=$(cat "$p/scaling_min_freq" 2>/dev/null || echo unknown) max_khz=$(cat "$p/scaling_max_freq" 2>/dev/null || echo unknown)"
    done
    lsusb -t 2>/dev/null || true
  } >"$out"
}

worker() {
  local out="$1"
  local gnb_pid
  mkdir -p "$out"
  metadata "$out/metadata-start.txt"
  cp -f "$ROOT/.runtime/k3-b200/gnb.conf" "$out/gnb.conf" 2>/dev/null || true
  capture_stats "$BUILD/nrL1_stats.log" "$out/nrL1_stats-start.log" 'feptx_total:'
  date --iso-8601=seconds >"$out/measure-start.txt"
  systemctl show k3-b200-gnb -p InvocationID >"$out/service-start.txt"
  printf 'timestamp,policy,cur_khz,temperature_mC\n' >"$out/frequency-temperature.csv"

  gnb_pid="$(pgrep -o -x nr-softmodem || true)"
  [[ -n "$gnb_pid" ]] || die "nr-softmodem is not running"
  sudo -n cat "/proc/$gnb_pid/maps" >"$out/gnb-maps-start.txt"
  if [[ "$LIGHTWEIGHT" != 1 ]]; then
    pidstat -h -u -r -w -p "$(pgrep -d, -x nr-softmodem || echo SELF)" "$INTERVAL" >"$out/pidstat-gnb.txt" 2>&1 & echo $! >"$out/pidstat.pid"
    mpstat -P ALL "$INTERVAL" >"$out/mpstat.txt" 2>&1 & echo $! >"$out/mpstat.pid"
    sar -n DEV "$INTERVAL" >"$out/sar-net.txt" 2>&1 & echo $! >"$out/sar.pid"
  fi
  journalctl -fu k3-b200-gnb.service -n 0 --no-pager >"$out/gnb-journal.log" 2>&1 & echo $! >"$out/journal.pid"
  touch "$out/READY"

  if [[ "$ENABLE_PERF" == 1 ]] && command -v perf >/dev/null 2>&1; then
    # Do not run perf stat on hardware cycles concurrently: on this K3 PMU it
    # starves perf record and yields an empty hotspot profile. pidstat/mpstat
    # already cover process and scheduler counters for the same window.
    sudo -n sh -c 'echo $$ >"$1"; exec perf record -F 49 -g -p "$2" -o "$3" -- sleep 86400' \
      sh "$out/perf-record.pid" "$gnb_pid" "$out/perf.data" >"$out/perf-record.log" 2>&1 &
  fi

  while [[ ! -e "$out/STOP" ]]; do
    local now temp p
    if [[ "$LIGHTWEIGHT" == 1 ]]; then
      sleep "$INTERVAL"
      continue
    fi
    now="$(date --iso-8601=seconds)"
    temp="$(awk 'FNR==1{print $1; exit}' /sys/class/thermal/thermal_zone*/temp 2>/dev/null || echo unknown)"
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
      [[ -d "$p" ]] || continue
      printf '%s,%s,%s,%s\n' "$now" "$(basename "$p")" "$(cat "$p/scaling_cur_freq" 2>/dev/null || echo unknown)" "$temp" >>"$out/frequency-temperature.csv"
    done
    sleep "$INTERVAL"
  done

  capture_stats "$BUILD/nrL1_stats.log" "$out/nrL1_stats-end.log" 'feptx_total:'
  date --iso-8601=seconds >"$out/measure-end.txt"
  systemctl show k3-b200-gnb -p InvocationID >"$out/service-end.txt"
  # End the synthetic sleep command first. This lets perf exit normally and
  # flush its counters/samples instead of leaving an empty or corrupt file.
  for file in "$out"/perf-*.pid; do
    [[ -s "$file" ]] || continue
    root_pid="$(cat "$file")"
    leaf_pid="$root_pid"
    while child_pid="$(pgrep -P "$leaf_pid" | head -1 || true)" && [[ -n "$child_pid" ]]; do
      leaf_pid="$child_pid"
    done
    [[ "$leaf_pid" != "$root_pid" ]] && sudo -n kill -TERM "$leaf_pid" 2>/dev/null || true
  done
  sleep 3
  [[ -e "$out/perf.data" ]] && sudo -n chown "$(id -u):$(id -g)" "$out/perf.data" 2>/dev/null || true
  for file in "$out"/*.pid; do
    [[ -s "$file" ]] || continue
    [[ "$(basename "$file")" == "collector.pid" ]] && continue
    if [[ "$(basename "$file")" == perf-* ]]; then
      sudo -n kill -INT "$(cat "$file")" 2>/dev/null || true
    else
      kill "$(cat "$file")" 2>/dev/null || true
    fi
    rm -f "$file"
  done
  sleep 2
  if [[ -s "$out/perf.data" ]]; then
    sudo -n perf report --stdio --no-children -i "$out/perf.data" \
      --percent-limit 0.5 >"$out/perf-report-flat.txt" 2>&1 || true
    sudo -n perf report --stdio -i "$out/perf.data" \
      --percent-limit 0.5 >"$out/perf-report-callgraph.txt" 2>&1 || true
  fi
  metadata "$out/metadata-end.txt"
  ip -s link >"$out/ip-link-end.txt"
  ss -s >"$out/ss-summary-end.txt"
  cp -f "$ROOT/logs/cn5g-k3/"{amf,smf,upf}.log "$out/" 2>/dev/null || true
  sha256sum "$out"/* >"$out/SHA256SUMS" 2>/dev/null || true
  rm -f "$out/collector.pid"
  date --iso-8601=seconds >"$out/COMPLETE"
}

case "$ACTION" in
  start)
    [[ -n "$RUN_ID" ]] && safe_id "$RUN_ID" || die "Usage: $0 start RUN_ID"
    out="$(run_dir)"
    [[ ! -e "$out" ]] || die "Result already exists: $out"
    mkdir -p "$out"
    nohup "$0" worker "$RUN_ID" >"$out/collector.log" 2>&1 </dev/null &
    echo $! >"$out/collector.pid"
    for _ in $(seq 1 30); do
      [[ -e "$out/READY" ]] && break
      kill -0 "$(cat "$out/collector.pid")" 2>/dev/null || die "Collector failed; see $out/collector.log"
      sleep 1
    done
    [[ -e "$out/READY" ]] || die "Collector readiness timeout"
    echo "$out"
    ;;
  worker)
    [[ -n "$RUN_ID" ]] && safe_id "$RUN_ID" || die "Invalid RUN_ID"
    worker "$(run_dir)"
    ;;
  stop)
    [[ -n "$RUN_ID" ]] && safe_id "$RUN_ID" || die "Usage: $0 stop RUN_ID"
    out="$(run_dir)"; [[ -d "$out" ]] || die "Unknown run: $RUN_ID"
    touch "$out/STOP"
    for _ in $(seq 1 120); do [[ -e "$out/COMPLETE" ]] && break; sleep 1; done
    [[ -e "$out/COMPLETE" ]] || die "Collector did not stop cleanly"
    echo "$out"
    ;;
  *) die "Usage: $0 start|stop RUN_ID" ;;
esac
