#!/usr/bin/env bash
# Short, passive thread/scheduler collector for an already-running K3 gNB.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
id=${1:?run ID required}
seconds=${2:-60}
[[ $id =~ ^[a-zA-Z0-9_-]+$ && $seconds =~ ^[0-9]+$ ]] || exit 2
(( seconds >= 10 && seconds <= 600 )) || exit 2

unit=k3-b200-gnb.service
pid=$(systemctl show "$unit" -p MainPID --value)
[[ $pid =~ ^[1-9][0-9]*$ && -d /proc/$pid/task ]] || {
  echo "gNB is not running" >&2
  exit 3
}

out="$ROOT/results/field/$id"
mkdir -p "$out"
[[ ! -e "$out/start-utc.txt" ]] || {
  echo "Run ID already exists" >&2
  exit 3
}

start_epoch=$(date +%s)
date -u --iso-8601=ns > "$out/start-utc.txt"
printf 'pid=%s\nseconds=%s\n' "$pid" "$seconds" > "$out/run.txt"
ps -T -p "$pid" -o pid,tid,psr,cls,rtprio,pri,ni,pcpu,stat,comm,wchan:32 > "$out/threads-start.txt"
cat /proc/pressure/cpu > "$out/cpu-pressure-start.txt"
cat /proc/interrupts > "$out/interrupts-start.txt"

pidstat -t -u -w -p "$pid" 1 "$seconds" > "$out/pidstat.txt" &
pidstat_pid=$!

{
  echo 'utc_ns,tid,comm,exec_ns,runqueue_wait_ns,timeslices'
  for ((sample=0; sample<seconds; sample++)); do
    now=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
    for task in /proc/"$pid"/task/*; do
      tid=${task##*/}
      read -r exec_ns wait_ns slices < "$task/schedstat" || continue
      comm=$(tr ',' '_' < "$task/comm")
      printf '%s,%s,%s,%s,%s,%s\n' "$now" "$tid" "$comm" "$exec_ns" "$wait_ns" "$slices"
    done
    sleep 1
  done
} > "$out/schedstat.csv"

wait "$pidstat_pid" || true
end_epoch=$(date +%s)
date -u --iso-8601=ns > "$out/end-utc.txt"
ps -T -p "$pid" -o pid,tid,psr,cls,rtprio,pri,ni,pcpu,stat,comm,wchan:32 > "$out/threads-end.txt"
cat /proc/pressure/cpu > "$out/cpu-pressure-end.txt"
cat /proc/interrupts > "$out/interrupts-end.txt"
sudo journalctl -u "$unit" --since "@$start_epoch" --until "@$end_epoch" --no-pager -o short-iso > "$out/gnb.log"
sudo journalctl -k --since "@$start_epoch" --until "@$end_epoch" --no-pager -o short-iso > "$out/kernel.log"

echo "$out"
