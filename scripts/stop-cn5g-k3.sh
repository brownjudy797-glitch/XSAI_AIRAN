#!/usr/bin/env bash
set -u

ROOT="${SIONNA_RK_ROOT:-$HOME/sionna-rk}"
RUN="$ROOT/run/cn5g-k3"

signal_all() {
  local signal=$1 name
  for name in amf smf upf; do
    sudo pkill "-$signal" -x "$name" 2>/dev/null || true
  done
}

wait_all_gone() {
  local attempts=$1
  for _ in $(seq 1 "$attempts"); do
    ! pgrep -x amf >/dev/null &&
      ! pgrep -x smf >/dev/null &&
      ! pgrep -x upf >/dev/null && return 0
    sleep 0.2
  done
  return 1
}

signal_all INT
wait_all_gone 15 || {
  signal_all TERM
  wait_all_gone 15 || {
    signal_all KILL
    wait_all_gone 15 || true
  }
}

# Older launchers recorded/killed the sudo wrapper instead of the real NF.
# Once the named NF processes are gone, remove any orphaned wrapper/monitor
# processes whose command line still points at these exact project binaries.
for pattern in \
  '/oai-amf/build/amf/build/amf -c' \
  '/oai-smf/build/smf/build/smf -c' \
  '/oai-upf/build/upf/build/upf -c'; do
  sudo pkill -TERM -f "$pattern" 2>/dev/null || true
done

for name in amf smf upf; do
  rm -f "$RUN/$name.pid"
  if ! pgrep -x "$name" >/dev/null; then
    sudo rm -f "/run/${name}00.pid"
  fi
done

sudo ip link delete tun0 2>/dev/null || true
sudo ip link delete cn5g-upf 2>/dev/null || true
sudo ip link delete cn5g-gnb 2>/dev/null || true
echo "CN5G stopped"
