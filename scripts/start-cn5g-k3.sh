#!/usr/bin/env bash
set -euo pipefail

ROOT="${SIONNA_RK_ROOT:-$HOME/sionna-rk}"
CFG="$ROOT/config/cn5g-k3"
RUN="$ROOT/run/cn5g-k3"
LOG="$ROOT/logs/cn5g-k3"
CN="$ROOT/ext/oai-cn5g-fed"
BASE_LIB="$CN/runtime/riscv64/lib:/usr/local/lib"
ALL_LIB="/opt/oai-boost-1.83/usr/lib/riscv64-linux-gnu:$BASE_LIB"

mkdir -p "$RUN" "$LOG"

# Keep the same database contract as Sionna-RK. Ubuntu on K3 currently ships
# MySQL 8.4 rather than the Compose image's MySQL 8.0.
sudo systemctl start mysql
for _ in $(seq 1 30); do
  sudo mysqladmin ping --silent >/dev/null 2>&1 && break
  sleep 1
done
sudo mysqladmin ping --silent >/dev/null 2>&1 \
  || { echo "ERROR: MySQL database is not ready" >&2; exit 1; }
sudo mysql -N -e "SELECT 1 FROM oai_db.users LIMIT 1" >/dev/null 2>&1 \
  || { echo "ERROR: oai_db.users is missing or unreadable" >&2; exit 1; }

for name in upf smf amf; do
  actual_pid="$(pgrep -xo "$name" 2>/dev/null || true)"
  if [[ -n "$actual_pid" ]]; then
    echo "$actual_pid" >"$RUN/$name.pid"
    echo "ERROR: $name is already running (PID $actual_pid)" >&2
    exit 1
  fi
  rm -f "$RUN/$name.pid"
done

sudo ip link delete tun0 2>/dev/null || true

for spec in "cn5g-upf 192.168.71.134/32" "cn5g-gnb 192.168.71.140/32"; do
  read -r dev addr <<< "$spec"
  if ! ip link show "$dev" >/dev/null 2>&1; then
    sudo ip link add "$dev" type dummy
  fi
  sudo ip address replace "$addr" dev "$dev"
  sudo ip link set "$dev" up
done

sudo -n nohup env LD_LIBRARY_PATH="$BASE_LIB" \
  "$CN/component/oai-upf/build/upf/build/upf" -c "$CFG/upf.yaml" \
  >"$LOG/upf.log" 2>&1 </dev/null &
echo $! > "$RUN/upf.pid"
sleep 2

sudo -n nohup env LD_LIBRARY_PATH="$ALL_LIB" \
  "$CN/component/oai-smf/build/smf/build/smf" -c "$CFG/smf.yaml" -o \
  >"$LOG/smf.log" 2>&1 </dev/null &
echo $! > "$RUN/smf.pid"
sleep 2

sudo -n nohup env LD_LIBRARY_PATH="$ALL_LIB" \
  "$CN/component/oai-amf/build/amf/build/amf" -c "$CFG/amf.yaml" -o \
  >"$LOG/amf.log" 2>&1 </dev/null &
echo $! > "$RUN/amf.pid"
sleep 3

for name in upf smf amf; do
  pid="$(cat "$RUN/$name.pid")"
  if kill -0 "$pid" 2>/dev/null; then
    echo "$name: running (PID $pid)"
  else
    echo "ERROR: $name exited; see $LOG/$name.log" >&2
    exit 1
  fi
done

grep -q "N4 ASSOCIATION SETUP RESPONSE" "$LOG/smf.log" \
  && echo "N4: SMF-UPF association established" \
  || echo "N4: association not observed yet"
