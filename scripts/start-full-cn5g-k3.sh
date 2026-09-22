#!/usr/bin/env bash
set -euo pipefail

ROOT="${SIONNA_RK_ROOT:-$HOME/sionna-rk}"
RUN="$ROOT/run/cn5g-k3"
LOG="$ROOT/logs/cn5g-k3"
OAI="$ROOT/ext/openairinterface5g"
BUILD="$OAI/cmake_targets/ran_build/build"
UE_CONF="$ROOT/ext/oai-cn5g-fed/docker-compose/ran-conf/nr-ue.conf"
NS="cn5g-ue"
HOST_VETH="cn5g-ue-host"
NS_VETH="cn5g-ue-ns"
CPU_SET="${CPU_SET:-0-7}"

mkdir -p "$RUN" "$LOG"

if pgrep -x nr-softmodem >/dev/null || pgrep -x nr-uesoftmodem >/dev/null; then
  echo "ERROR: gNB or nrUE is already running; use stop-full-cn5g-k3.sh first." >&2
  exit 1
fi

systemctl is-active --quiet mysql || sudo systemctl start mysql
"$ROOT/scripts/start-cn5g-k3.sh"

sudo sysctl -q -w net.ipv4.ip_forward=1
sudo iptables -C FORWARD -i tun0 -o wlP4p1s0 -j ACCEPT 2>/dev/null \
  || sudo iptables -A FORWARD -i tun0 -o wlP4p1s0 -j ACCEPT
sudo iptables -C FORWARD -i wlP4p1s0 -o tun0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
  || sudo iptables -A FORWARD -i wlP4p1s0 -o tun0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo iptables -t nat -C POSTROUTING -s 12.1.1.0/24 -o wlP4p1s0 -j MASQUERADE 2>/dev/null \
  || sudo iptables -t nat -A POSTROUTING -s 12.1.1.0/24 -o wlP4p1s0 -j MASQUERADE

sudo nohup taskset -c "$CPU_SET" "$BUILD/nr-softmodem" \
  -O "$ROOT/config/cn5g-k3/gnb-rfsim.conf" \
  --rfsim --rfsimulator.serveraddr server \
  --gNBs.[0].min_rxtxtime 6 --T_stdout 1 \
  >"$LOG/gnb.log" 2>&1 </dev/null &
echo $! >"$RUN/gnb.pid"

for _ in $(seq 1 30); do
  grep -q "Received NGSetupResponse" "$LOG/gnb.log" 2>/dev/null && break
  sleep 1
done
grep -q "Received NGSetupResponse" "$LOG/gnb.log" 2>/dev/null \
  || { echo "ERROR: gNB did not complete NG Setup; see $LOG/gnb.log" >&2; exit 1; }

sudo ip netns delete "$NS" 2>/dev/null || true
sudo ip link delete "$HOST_VETH" 2>/dev/null || true
sudo ip netns add "$NS"
sudo ip link add "$HOST_VETH" type veth peer name "$NS_VETH"
sudo ip link set "$NS_VETH" netns "$NS"
sudo ip address add 192.168.72.1/30 dev "$HOST_VETH"
sudo ip link set "$HOST_VETH" up
sudo ip netns exec "$NS" ip address add 192.168.72.2/30 dev "$NS_VETH"
sudo ip netns exec "$NS" ip link set lo up
sudo ip netns exec "$NS" ip link set "$NS_VETH" up
sudo ip netns exec "$NS" ip route add default via 192.168.72.1

sudo nohup ip netns exec "$NS" taskset -c "$CPU_SET" "$BUILD/nr-uesoftmodem" \
  -O "$UE_CONF" --rfsim --rfsimulator.serveraddr 192.168.72.1 \
  -r 106 --numerology 1 --band 78 -C 3319680000 \
  --ue-rxgain 140 --ue-txgain 0 --T_stdout 1 \
  >"$LOG/nrue.log" 2>&1 </dev/null &
echo $! >"$RUN/nrue.pid"

for _ in $(seq 1 45); do
  sudo ip netns exec "$NS" ip link show oaitun_ue1 >/dev/null 2>&1 && break
  sleep 1
done
sudo ip netns exec "$NS" ip link show oaitun_ue1 >/dev/null 2>&1 \
  || { echo "ERROR: UE did not establish a PDU session; see $LOG/nrue.log" >&2; exit 1; }

echo "Full K3 5G stack is running."
echo "CPU set: $CPU_SET"
echo "UE: 12.1.1.130 (namespace $NS)"
echo "Test: sudo ip netns exec $NS ping -I oaitun_ue1 -c 5 12.1.1.1"
