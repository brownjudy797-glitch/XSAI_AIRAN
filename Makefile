##
## SPDX-FileCopyrightText: Copyright (c) 2024-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
## SPDX-License-Identifier: Apache-2.0
##

ARCH ?= $(shell uname -m)
ifeq ($(ARCH),riscv64)
CPU_ONLY ?= 1
else
CPU_ONLY ?= 0
endif
export SIONNA_RK_CPU_ONLY := $(CPU_ONLY)

GPU=
ifdef gpus
    GPU=--gpus=$(gpus)
endif
export GPU

.PHONY: doc prepare-system sionna-rk build-gnb

prepare-system:
	./scripts/configure-system.sh
	@if [ "$(CPU_ONLY)" != "1" ]; then \
		./scripts/build-custom-kernel.sh; \
		./scripts/install-custom-kernel.sh; \
		echo "Reboot to load the new kernel and continue the installation."; \
	else \
		echo "CPU-only mode: skipping NVIDIA L4T custom kernel steps."; \
	fi

sionna-rk:
	./scripts/quickstart-oai.sh
	@if [ -d config ]; then \
		echo "Config directory already exists; reusing it."; \
	else \
		./scripts/generate-configs.sh; \
	fi
	./plugins/common/build_all_plugins.sh --host
	@if [ "$(CPU_ONLY)" != "1" ]; then \
		./plugins/common/build_all_plugins.sh --container; \
	fi

build-gnb:
	@if [ "$(CPU_ONLY)" = "1" ]; then \
		./scripts/build-oai-native.sh --usrp ext/openairinterface5g; \
	else \
		./scripts/build-oai-images.sh --debug ext/openairinterface5g; \
	fi

doc: FORCE
	cd doc && ./build_docs.sh

test:
	./plugins/common/build_all_plugins.sh --host
	@if [ "$(CPU_ONLY)" != "1" ]; then \
		./plugins/common/build_all_plugins.sh --container; \
	fi
	./plugins/testing/run_all_tests.sh --host

FORCE:
