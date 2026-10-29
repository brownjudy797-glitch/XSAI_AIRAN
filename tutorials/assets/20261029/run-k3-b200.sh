#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ROOT="${SIONNA_RK_ROOT:-$HOME/sionna-rk}"
ENV_FILE="$ROOT/config/b200/.env"
DEFAULT_BUILD="$ROOT/ext/openairinterface5g/cmake_targets/ran_build/build"
BUILD="$DEFAULT_BUILD"
GNB_BIN="$BUILD/nr-softmodem"
GNB_TEMPLATE="$ROOT/config/common/gnb.sa.band78.24prbs.conf"
RUNTIME_DIR="$ROOT/.runtime/k3-b200"
RUNTIME_CONF="$RUNTIME_DIR/gnb.conf"
UNIT="k3-b200-gnb.service"
OPT_LOG="$ROOT/.runtime/k3-b200/optimization.log"
CORE_PREFIX="${K3_CN5G_PREFIX:-/opt/sionna-rk-k3/cn5g}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
active() { sudo systemctl is-active --quiet "$UNIT"; }

ensure_core() {
    if ! pgrep -x upf >/dev/null || ! pgrep -x smf >/dev/null || ! pgrep -x amf >/dev/null; then
        sudo "$CORE_PREFIX/scripts/start-cn5g.sh"
    fi
}

record() {
    mkdir -p "$(dirname "$OPT_LOG")"
    printf '%s %s\n' "$(date --iso-8601=seconds)" "$*" | tee -a "$OPT_LOG"
}

apply_host_tuning() {
    # Keep the B210 xHCI interrupt away from the eight A100 PHY cores. Retain
    # the kernel's RT safety budget so management/network tasks cannot starve.
    sudo sysctl -q -w kernel.sched_rt_runtime_us=950000
    local irq
    irq=$(awk '/xhci-hcd:usb5$/ {gsub(":", "", $1); print $1; exit}' /proc/interrupts)
    if [ -n "$irq" ] && [ -e "/proc/irq/$irq/smp_affinity" ]; then
        echo 80 | sudo tee "/proc/irq/$irq/smp_affinity" >/dev/null
        record "host-tuning rt_runtime_us=950000 b210_xhci_irq=$irq irq_affinity=cpu7"
    else
        record "host-tuning rt_runtime_us=950000 b210_xhci_irq=not-found"
    fi
}

load_env() {
    [ -r "$ENV_FILE" ] || die "Missing $ENV_FILE"
    set -a
    set +u
    # This is the project-owned shell-style environment file used by Compose.
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set -u
    set +a
}

valid_ipv4() {
    local ip=$1 part
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a parts <<< "$ip"
    for part in "${parts[@]}"; do
        (( part >= 0 && part <= 255 )) || return 1
    done
}

select_gnb_ip() {
    if [ -n "${GNB_IP:-}" ]; then
        printf '%s\n' "$GNB_IP"
        return
    fi
    ip -4 route get "$AMF_IP" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}

preflight() {
    load_env
    # K3_GNB_BUILD is defined by the project .env, so resolve it only after
    # load_env. This keeps the original build as the automatic fallback.
    BUILD="${K3_GNB_BUILD:-$DEFAULT_BUILD}"
    GNB_BIN="$BUILD/nr-softmodem"
    [ "$(uname -m)" = "riscv64" ] || die "This launcher is for the RV64 K3; detected $(uname -m)."
    [ -x "$GNB_BIN" ] || die "Missing $GNB_BIN; build the native OAI gNB first."
    [ -x "$CORE_PREFIX/scripts/start-cn5g.sh" ] || die "Missing native CN5G launcher: $CORE_PREFIX/scripts/start-cn5g.sh"
    [ -r "$GNB_TEMPLATE" ] || die "Missing gNB template: $GNB_TEMPLATE"
    command -v uhd_find_devices >/dev/null || die "uhd_find_devices is missing; install/build UHD for riscv64."
    command -v uhd_usrp_probe >/dev/null || die "uhd_usrp_probe is missing; install/build UHD for riscv64."
    [ -n "${USRP_SERIAL:-}" ] || die "Set USRP_SERIAL in $ENV_FILE"
    [ -n "${AMF_IP:-}" ] || die "Set AMF_IP in $ENV_FILE to the external 5G Core AMF address."
    valid_ipv4 "$AMF_IP" || die "AMF_IP is not a valid IPv4 address: $AMF_IP"
    RESOLVED_GNB_IP=$(select_gnb_ip)
    [ -n "$RESOLVED_GNB_IP" ] || die "Could not select a K3 source address for AMF $AMF_IP; set GNB_IP explicitly."
    valid_ipv4 "$RESOLVED_GNB_IP" || die "GNB_IP is not a valid IPv4 address: $RESOLVED_GNB_IP"
    ip -4 addr show | grep -qw "$RESOLVED_GNB_IP" || die "GNB_IP $RESOLVED_GNB_IP is not assigned to this K3."
    uhd_find_devices 2>&1 | grep -Fq "$USRP_SERIAL" || die "USRP $USRP_SERIAL was not found by UHD."
}

write_runtime_config() {
    mkdir -p "$RUNTIME_DIR"
    cp "$GNB_TEMPLATE" "$RUNTIME_CONF"
    sed -Ei \
        -e 's#tracking_area_code[[:space:]]*=[[:space:]]*[^;]+;#tracking_area_code  = 0xa000;#' \
        -e 's#plmn_list[[:space:]]*=[[:space:]]*\(\{[[:space:]]*mcc[[:space:]]*=[[:space:]]*[0-9]+;[[:space:]]*mnc[[:space:]]*=[[:space:]]*[0-9]+;[[:space:]]*mnc_length[[:space:]]*=[[:space:]]*[0-9]+;#plmn_list = ({ mcc = 208; mnc = 95; mnc_length = 2;#' \
        -e "s#(amf_ip_address[[:space:]]*=[[:space:]]*\\(\\{[[:space:]]*ipv4[[:space:]]*=[[:space:]]*)\"[^\"]+\"#\\1\"$AMF_IP\"#" \
        -e "s#(GNB_IPV4_ADDRESS_FOR_NG_AMF[[:space:]]*=[[:space:]]*)\"[^\"]+\"#\\1\"$RESOLVED_GNB_IP\"#" \
        -e "s#(GNB_IPV4_ADDRESS_FOR_NGU[[:space:]]*=[[:space:]]*)\"[^\"]+\"#\\1\"$RESOLVED_GNB_IP\"#" \
        "$RUNTIME_CONF"
    grep -Fq "ipv4 = \"$AMF_IP\"" "$RUNTIME_CONF" || die "Failed to write AMF_IP to runtime config."
    [ "$(grep -Fc "\"$RESOLVED_GNB_IP\"" "$RUNTIME_CONF")" -ge 2 ] || die "Failed to write GNB_IP to runtime config."
}

start_gnb() {
    preflight
    ensure_core
    local allowed_cpus="${K3_GNB_ALLOWED_CPUS:-8-15}"
    active && die "$UNIT is already active."
    pgrep -x nr-softmodem >/dev/null && die "An unmanaged nr-softmodem process is already running."
    write_runtime_config
    apply_host_tuning
    record "start kernel=$(uname -r) build=$BUILD usrp=$USRP_SERIAL amf=$AMF_IP gnb_ip=$RESOLVED_GNB_IP thread_pool=${K3_GNB_THREAD_POOL:-default} l1_rx=-1 l1_tx=-1 ru_pool=-1x5 ru_thread=-1 allowed_cpus=$allowed_cpus"

    args=(
        "$GNB_BIN" -O "$RUNTIME_CONF"
        --RUs.[0].sdr_addrs "serial=$USRP_SERIAL"
        --continuous-tx
        --telnetsrv
        --reorder-thread-disable 1
        --log_config.global_log_options level,nocolor,time
    )
    if [ -n "${K3_GNB_THREAD_POOL:-}" ]; then
        args+=(--thread-pool "$K3_GNB_THREAD_POOL")
    fi
    if [ -n "${GNB_EXTRA_OPTIONS:-}" ]; then
        read -r -a extra <<< "$GNB_EXTRA_OPTIONS"
        args+=("${extra[@]}")
    fi

    sudo systemctl reset-failed "$UNIT" 2>/dev/null || true
    sudo systemd-run \
        --unit="$UNIT" \
        --service-type=exec \
        --property=Restart=no \
        --property=KillMode=mixed \
        --property=TimeoutStopSec=10 \
        --property="AllowedCPUs=$allowed_cpus" \
        --property=LimitMEMLOCK=infinity \
        --property=Nice=-20 \
        --property=TasksMax=infinity \
        --working-directory="$BUILD" \
        "${args[@]}"
    sleep 3
    active || {
        sudo journalctl -u "$UNIT" -n 120 --no-pager
        die "Native B200 gNB failed to start."
    }
    echo "Native K3 B200 gNB started."
    echo "AMF: $AMF_IP; K3 N2/N3 address: $RESOLVED_GNB_IP; USRP: $USRP_SERIAL"
    echo "Logs: $0 log"
}

case "${1:-}" in
    check)
        preflight
        ensure_core
        write_runtime_config
        echo "Preflight passed. Runtime config: $RUNTIME_CONF"
        ;;
    start) start_gnb ;;
    status)
        sudo "$CORE_PREFIX/scripts/status-cn5g.sh"
        sudo systemctl --no-pager --full status "$UNIT" || true
        sudo journalctl -u "$UNIT" --no-pager | grep -E 'Received NGSetupResponse|associated AMF|No UHD Devices|RuntimeError|ERROR' | tail -20 || true
        ;;
    log) exec sudo journalctl -fu "$UNIT" -n 100 ;;
    stop)
        sudo systemctl stop "$UNIT" 2>/dev/null || true
        sudo "$CORE_PREFIX/scripts/stop-cn5g.sh"
        echo "Native K3 B200 gNB and CN5G stopped."
        ;;
    *)
        echo "Usage: $0 check|start|status|log|stop"
        exit 2
        ;;
esac
