#!/usr/bin/env bash
set -euo pipefail

# Tutorial wrapper for the existing, path-bound K3-A-20260922 installation.
ROOT=/home/ubuntu/sionna-rk
UNIT=k3-b200-gnb.service
usage() { echo "Usage: bash k3-quickstart.sh check|start|status|stop"; }
check() {
    [[ $(uname -m) == riscv64 ]] || { echo 'ERROR: run this on K3, not Windows.' >&2; return 1; }
    for cmd in python3 systemctl lsusb; do
        command -v "$cmd" >/dev/null || { echo "ERROR: missing $cmd" >&2; return 1; }
    done
    [[ -r "$ROOT/scripts/k3-fixed-baseline.py" && -r "$ROOT/scripts/run-k3-b200.sh" ]] || {
        echo 'ERROR: fixed deployment is missing; this tutorial does not install it.' >&2; return 1;
    }
    python3 "$ROOT/scripts/k3-fixed-baseline.py" --check
    local devices
    devices=$(lsusb -d 2500:0020)
    [[ -n $devices ]] || { echo 'ERROR: B210 USB device not found.' >&2; return 1; }
    echo 'Preflight passed (version + USB enumeration only, not an RF/UE test).'
}

case "${1:-check}" in
    check) check ;;
    start)
        check
        state=$(systemctl is-active "$UNIT" 2>/dev/null || true)
        case "$state" in
            active) echo 'gNB already active; left unchanged. Continue with status and UE checks.' ;;
            activating|deactivating|reloading) echo "ERROR: service is $state; wait and inspect status." >&2; exit 1 ;;
            inactive|failed|unknown) SIONNA_RK_ROOT="$ROOT" bash "$ROOT/scripts/run-k3-b200.sh" start ;;
            *) echo "ERROR: unexpected service state: $state" >&2; exit 1 ;;
        esac
        ;;
    status) SIONNA_RK_ROOT="$ROOT" bash "$ROOT/scripts/run-k3-b200.sh" status ;;
    stop)
        echo 'Stopping gNB AND core network; current UE traffic will be interrupted.'
        SIONNA_RK_ROOT="$ROOT" bash "$ROOT/scripts/run-k3-b200.sh" stop
        ;;
    *) usage >&2; exit 2 ;;
esac
