<!-- SPDX-License-Identifier: Apache-2.0 -->
# 从零构建与复现：与 2026-10-29 K3 对齐的 RFsim

这是新部署的首选入口。使用本仓库的 OAI 快照和已审阅现场差异，固定到 K3 的 `c6698f7` 源码系列；不再要求先克隆另一套 Sionna-RK、手工粘贴大补丁或修改系统 SIMDe。旧 K3/x86/ARM64 教程的 `207aac9` 是另一条历史基线，不能混用其计时补丁和构建目录。

本路线运行传统 CPU PHY、106 PRB、numerology 1、band 78、中心频率 3319680000 Hz，使用 `--phy-test --noS1`。不需要 B210、SIM、核心网、CUDA 或 AI 权重。通过 RFsim 不等于通过真实 UE、吞吐或 AI 实时性验收。版本与验证证据见 [复现审计](../../docs/REPRODUCIBILITY_AUDIT.md)。

## 1. 准备目标机和版本

空白板卡先按照 [SpacemiT K3 Ubuntu 镜像与烧录说明](https://github.com/spacemit-com/K3-Ubuntu-Images) 安装适配 K3 Pico-ITX 的系统，记录镜像版本与校验值。Canonical 的 [K3 安装说明](https://ubuntu.com/hardware/docs/boards/how-to/ubuntu_supported/spacemit-k3/) 区分官方 Ubuntu 与厂商镜像、固件路线；不要混用其引导步骤。本次应用复现基线为 Ubuntu 26.04，尚未验证其他系统版本，也未对当前 K3 重新烧录。

首次开机完成用户、密码、网络与时间设置，确认本地终端能访问 Ubuntu 软件源与 GitHub。需要远程操作时，在 K3 上安装 `openssh-server` 并启用 `ssh` 服务，使用本机 `ip -br address` 显示的地址从电脑连接；本文后续命令都在 K3 的普通用户终端执行，只有依赖安装和 namespace 管理使用 sudo。

K3 已验证环境是 Ubuntu 26.04.1、riscv64、GCC 16、约 31 GiB 内存。预留至少 20 GiB 空间；全量编译会产生一万余个构建任务。建议 4 个并行任务，内存或系统负载不足时用 2 个。不能用 x86 安装包替代 RISC-V 软件包。

以下命令均在目标 Ubuntu 终端执行。先克隆到新目录；已有目录不要覆盖，另选目录名。部署前记录仓库提交，后续阶段保持同一个 checkout。

```bash
sudo apt-get update
sudo apt-get install -y git ca-certificates python3
git clone --branch k3-acceptance-20261030 https://github.com/brownjudy797-glitch/XSAI_AIRAN.git "$HOME/XSAI_AIRAN-repro"
cd "$HOME/XSAI_AIRAN-repro"
git rev-parse HEAD
uname -m
. /etc/os-release; printf '%s %s\n' "$NAME" "$VERSION_ID"
df -h "$HOME"
```

使用固定发布标签 `k3-acceptance-20261030`，不要在实验中途执行 git pull。沿用已验证的 [`config/repro/20261029.json`](../../config/repro/20261029.json)：OAI/vendor、插件树、现场 overlay、SIMDe 与 ASN1C 提交以及 SIMDe 补丁散列没有改动；新版本增加验收记录、配置步骤与日志归档。准备脚本会核对源码树和文件，拒绝把本地修改误当基线。若未来 main 不再匹配该 profile，使用本次发布标签的 checkout，不能跳过检查。

## 2. 安装明确的依赖，准备独立源码

```bash
cd "$HOME/XSAI_AIRAN-repro"
bash scripts/repro-deps.sh apt
export XSAI_REPRO_WORK="$HOME/xsai-repro-20261029"
python3 scripts/reproduce.py prepare --workspace "$XSAI_REPRO_WORK"
```

工作目录必须是新目录，位于仓库和 `~/sionna-rk` 以外。脚本不会重置已有目录或在线部署；失败目录保留供排查。重复 prepare 只保留已识别目录，不覆盖源码。若准备中断，应保留原目录并选一个新名字重新执行。

GCC16 位于 Ubuntu 26.04 的 universe 仓库。若 APT 找不到 `gcc-16/g++-16`，先用 `apt-cache policy gcc-16 g++-16` 检查源和架构，必要时安装 `software-properties-common` 并执行 `sudo add-apt-repository universe`、`sudo apt-get update`；不要拿其他 Ubuntu 版本的软件包混装。现场版本是 `16-20260322-1ubuntu1`；APT 后续更新可能改变生成代码，比较结果时保留实际编译器版本。

仓库中的 `prepare-oai-worktree.sh` 只复制源码；上面的包装脚本还会检查版本、应用现场 overlay 并写工作区标记。不要再向这个目录应用旧 RV64 大补丁、CPU-only 补丁或 `add-oai-timer.sh`，这些修改已经包含在此基线。

## 3. 构建私有 SIMDe 和 ASN1C

```bash
cd "$HOME/XSAI_AIRAN-repro"
export XSAI_REPRO_WORK="$HOME/xsai-repro-20261029"
JOBS=4 bash scripts/repro-deps.sh tools "$XSAI_REPRO_WORK"
```

首次执行需要能访问 GitHub。工具仅写入 `$XSAI_REPRO_WORK/deps`，不替换 `/usr/include/simde` 或 `/opt/asn1c`。SIMDe 固定 `c7f26b7` 并应用 [K3 RVV/GCC16 修改](../../patches/dependencies/20261029/README.md)；ASN1C 固定 `940dd5f`。系统已有同名工具也不会被静默采用。重复执行核对提交和补丁方向；版本不符时停止，不自动 reset。

## 4. 编译并检验产物

```bash
cd "$HOME/XSAI_AIRAN-repro"
export XSAI_REPRO_WORK="$HOME/xsai-repro-20261029"
python3 scripts/reproduce.py build --workspace "$XSAI_REPRO_WORK" --jobs 4
python3 scripts/reproduce.py check --workspace "$XSAI_REPRO_WORK"
```

配置使用 Ninja、RelWithDebInfo、私有头文件和 ASN1C，关闭 USRP/CUDA。K3 使用 GCC16 与 `rv64gcv_zba_zbb_zbs/lp64d/scalable`；x86/ARM64 使用本机 C/C++ 编译器。产物包括 gNB、nrUE、RFsim、DFT、LDPC 和配置库。脚本检查动态依赖并写 `build-manifest.json`，不启动任何无线程序。失败后修复依赖再重跑 build；不要把旧 `ran_build` 的库复制进来补缺。

## 5. 先做一轮功能验证

```bash
cd "$HOME/XSAI_AIRAN-repro"
export XSAI_REPRO_WORK="$HOME/xsai-repro-20261029"
sudo -v
python3 scripts/repro-rfsim.py --workspace "$XSAI_REPRO_WORK" --smoke --cpus 0-7
```

CPU 列表必须存在于本机；小于 8 核的机器按 `lscpu -e=CPU,ONLINE` 改为实际范围。smoke 只做 ideal 一轮、2 秒预热和 4 秒观察。通过条件：gNB 监听、nrUE 同步、双方计时计数增长，并保存原始统计和 CSV。命令返回 0 且该轮 `metadata.json` 的 `status` 为 `passed` 才通过；仅看到进程启动不算。

每轮创建唯一网络 namespace，RFsim 在其中使用回环地址，结束只清理该 namespace 的进程。不会调用全局 `pkill`，不会停止在线核心网。若中断或失败，先阅读这次结果目录中的 gNB/nrUE 日志与 metadata；不要运行历史教程的全局清理命令。

## 6. 正式 ideal/AWGN 对照

安排专用、空闲的测量时段。脚本检测到 AMF/SMF/UPF 或其他 gNB/nrUE 时拒绝正式测量；由现有部署的操作者安排停机，不要为了通过检查直接杀进程。`--functional-only` 可在保留背景负载时检查功能，但结果会标记为功能验证，不能作为空闲平台性能结果。

```bash
cd "$HOME/XSAI_AIRAN-repro"
export XSAI_REPRO_WORK="$HOME/xsai-repro-20261029"
sudo -v
python3 scripts/repro-rfsim.py --workspace "$XSAI_REPRO_WORK" \
  --mode pair --rounds 5 --warmup 20 --seconds 120 --cpus 0-7
```

每轮依次 ideal、AWGN；AWGN 两端噪声分别为 -100/-95 dB，配置随结果保留。不要把不同 PRB、不同 CPU 集、不同编译选项、AI 插件或有后台负载的结果直接合并。

每次输出新的 `results/UTC时间-随机标识/`，包括构建散列、调用参数、配置、日志、起止统计快照、CSV 与轮次状态，不覆盖历史数据。CSV 的 `window_avg_us_estimate` 是根据两个**已舍入的累计均值 × 调用次数**做差得到的窗口估计；`end_cumulative_max_us` 是结束时累计最大值，不能当作窗口最大值或 P99。实际起止观察时间也被保存；并非严格逐调用采样或硬实时 120 秒窗口。

跨平台比较使用相同仓库提交、profile、106 PRB、信道配置、轮数与测量口径，分别保存各平台的 CPU/OS/编译器、温度和负载。x86/ARM64 的完整构建和运行尚未在本次审计重新执行；不能以 K3 通过替代其验收。

## 7. 完整 5G / B210 的后续步骤

RFsim noS1 热点路线到此完整结束。需要 SIM 注册或真实射频时，再看 [CN5G 与真实 UE 部署前提](../k3-cn5g/FROM_ZERO.md)。它补充数据库、订阅、网络映射、UHD 和验收门槛。核心网 Release 安装与旧源码布局启动器是不同安装方式，不能混用路径。nearRT-RIC 和 AI 端到端实时吞吐尚无已通过的一键复现路线。
