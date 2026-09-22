#!/bin/bash
#
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
set -e  # Stop script on any error

# K3 native B200 deployment: stop the radio gNB and local native 5G Core
# through the same public stop_system.sh entry point used by Sionna-RK.
if [[ "$(uname -m)" == "riscv64" ]] && \
   { [[ "${1:-}" == "b200" ]] || systemctl is-active --quiet k3-b200-gnb.service; }; then
    exec "$(dirname "${BASH_SOURCE[0]}")/run-k3-b200.sh" stop
fi

configs_dir=$(realpath $(dirname "${BASH_SOURCE[0]}")/../config)

echo "Shutting down network"

cd "${configs_dir}/common"
docker compose down
