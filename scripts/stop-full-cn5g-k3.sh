#!/usr/bin/env bash
set -u

ROOT="${SIONNA_RK_ROOT:-$HOME/sionna-rk}"

sudo pkill -INT -x nr-uesoftmodem 2>/dev/null || true
sudo pkill -INT -x nr-softmodem 2>/dev/null || true
sleep 3
sudo pkill -TERM -x nr-uesoftmodem 2>/dev/null || true
sudo pkill -TERM -x nr-softmodem 2>/dev/null || true

sudo ip netns delete cn5g-ue 2>/dev/null || true
sudo ip link delete cn5g-ue-host 2>/dev/null || true

while ip rule show | grep -q "12.1.1.130.*lookup 9999"; do
  pref="$(ip rule show | awk '/12.1.1.130.*lookup 9999/{sub(/:/,"",$1); print $1; exit}')"
  sudo ip rule del pref "$pref"
done
sudo ip route flush table 9999 2>/dev/null || true

sudo iptables -D FORWARD -i tun0 -o wlP4p1s0 -j ACCEPT 2>/dev/null || true
sudo iptables -D FORWARD -i wlP4p1s0 -o tun0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
sudo iptables -t nat -D POSTROUTING -s 12.1.1.0/24 -o wlP4p1s0 -j MASQUERADE 2>/dev/null || true

"$ROOT/scripts/stop-cn5g-k3.sh"
rm -f "$ROOT/run/cn5g-k3/gnb.pid" "$ROOT/run/cn5g-k3/nrue.pid"
echo "Full K3 5G stack stopped."
