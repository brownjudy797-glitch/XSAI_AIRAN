#!/usr/bin/env bash
# Bounded observer; does not restart OAI or alter its settings.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
id=${1:?run ID required}
seconds=${2:-1200}
[[ $id =~ ^[a-zA-Z0-9_-]+$ && $seconds =~ ^[0-9]+$ ]] || exit 2
(( seconds >= 5 && seconds <= 7200 )) || exit 2
out="$ROOT/results/field/$id"
mkdir -p "$out"
exec 9>"$out/collector.lock"
flock -n 9 || exit 3
[[ ! -e "$out/snapshot.txt" ]] || { echo 'Run ID already exists'; exit 3; }
date -u --iso-8601=seconds > "$out/start-utc.txt"
{
  uname -a
  git -c safe.directory="$ROOT/ext/openairinterface5g" -C "$ROOT/ext/openairinterface5g" rev-parse HEAD
  git -c safe.directory="$ROOT/ext/openairinterface5g" -C "$ROOT/ext/openairinterface5g" status --short
  sha256sum "$ROOT/ext/openairinterface5g/cmake_targets/ran_build/build/nr-softmodem"
  lsusb -t
  ip -br address
  ip route
  systemctl show k3-b200-gnb.service -p MainPID -p InvocationID -p AllowedCPUs
  for c in {0..7}; do
    grep . /sys/devices/system/cpu/cpu$c/cpufreq/{scaling_governor,scaling_cur_freq} || true
  done
} > "$out/snapshot.txt" 2>&1
cp "$ROOT/.runtime/k3-b200/gnb.conf" "$out/gnb.conf"
git -c safe.directory="$ROOT/ext/openairinterface5g" -C "$ROOT/ext/openairinterface5g" diff --stat > "$out/code-diff-stat.txt"
pids=()
cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  wait || true
  date -u --iso-8601=seconds > "$out/end-utc.txt"
}
trap cleanup EXIT
# The controller ends a bounded collection with systemctl stop.  Treat that
# expected TERM as a successful end; cleanup still flushes all evidence files.
trap 'exit 0' INT TERM
timeout "$seconds" journalctl -fu k3-b200-gnb.service -n 0 -o short-iso > "$out/gnb.log" 2>&1 & pids+=("$!")
timeout "$seconds" pidstat -t -u -w -C nr-softmodem 1 > "$out/threads.txt" 2>&1 & pids+=("$!")
timeout "$seconds" tail -n 0 -F "$ROOT/logs/cn5g-k3/amf.log" "$ROOT/logs/cn5g-k3/smf.log" "$ROOT/logs/cn5g-k3/upf.log" > "$out/core.log" 2>&1 & pids+=("$!")
sleep "$seconds"
