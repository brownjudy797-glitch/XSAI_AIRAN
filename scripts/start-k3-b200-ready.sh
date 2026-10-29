#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

root=/home/ubuntu/sionna-rk
unit=k3-b200-gnb.service
case "${1:-normal}" in
  normal) export K3_GNB_CONTINUOUS_TX=0 ;;
  continuous) export K3_GNB_CONTINUOUS_TX=1 ;;
  *) printf 'Usage: %s [normal|continuous]\n' "$0" >&2; exit 2 ;;
esac

bash "$root/scripts/run-k3-b200.sh" start
pid=$(systemctl show "$unit" -p MainPID --value)
[[ $pid =~ ^[1-9][0-9]*$ && -d /proc/$pid/task ]] || {
  printf 'gNB has no live main process\n' >&2
  exit 1
}

ru_tids=()
for attempt in {1..15}; do
  mapfile -t ru_tids < <(
    for task in /proc/"$pid"/task/*; do
      [[ -r "$task/comm" ]] || continue
      [[ $(<"$task/comm") == ru_thread ]] && printf '%s\n' "${task##*/}"
    done | sort -n
  )
  ((${#ru_tids[@]} >= 5)) && break
  sleep 1
done
((${#ru_tids[@]} >= 5)) || {
  printf 'Only %s RU threads appeared; gNB startup needs inspection\n' "${#ru_tids[@]}" >&2
  exit 1
}

declare -A before=()
for tid in "${ru_tids[@]:1}"; do
  before[$tid]=$(awk '{print $14+$15}' "/proc/$pid/task/$tid/stat")
done
sleep 1

cores=(3 4)
index=0
while read -r delta tid; do
  [[ -n $tid ]] || continue
  sudo -n taskset -pc "${cores[index]}" "$tid" >/dev/null
  printf 'RU helper tid=%s cpu=%s tick_delta=%s\n' "$tid" "${cores[index]}" "$delta"
  ((index += 1))
  ((index >= ${#cores[@]})) && break
done < <(
  for tid in "${ru_tids[@]:1}"; do
    [[ -r /proc/$pid/task/$tid/stat ]] || continue
    ticks=$(awk '{print $14+$15}' "/proc/$pid/task/$tid/stat")
    printf '%s %s\n' "$((ticks - before[$tid]))" "$tid"
  done | sort -k1,1nr
)

printf 'gNB ready: pid=%s, RU threads=%s, main RU tid=%s\n' "$pid" "${#ru_tids[@]}" "${ru_tids[0]}"
