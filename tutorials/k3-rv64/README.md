<!-- SPDX-License-Identifier: Apache-2.0 -->
> 新机器请先看 [与当前 K3 对齐的复现流程](../reproduction/README.md)。本页保留旧 `207aac9` 移植路线，不等同于现场 `c6698f7`；不要混用补丁、构建目录和计时脚本。

# 在 RISC-V K3 上部署完整 Sionna RK/OAI 5G 系统 — 仓库下载版（2026-10-29）

本教程已整理为仓库下载版（2026-10-29）：保留原操作步骤，补丁和长脚本统一按版本分发、下载时检查 SHA256。
[返回教程入口](../README.md) · [工具来源与版本](../assets/20261029/README.md)
语法、补丁应用与失败停止逻辑已在本地检查；平台编译、射频、核心网和性能结果仍需在对应设备现场验证。


补丁由 [XSAI_AIRAN](https://github.com/brownjudy797-glitch/XSAI_AIRAN) 的版本目录分发，
第 3 步直接下载、校验并应用，无需复制大型 diff 或手工处理 Tab。
应用前检查适用性，应用后反向检查完整性；重复执行会识别已经应用的状态。

补丁的应用目标是官方 `NVlabs/sionna-rk` 的 `0abdce3` 工作区，通常为 `$HOME/sionna-rk`。
`XSAI_AIRAN` 在本流程中负责分发补丁和教程；不要把该补丁直接应用到它当前的源码根目录。
本版保留原教程的全部阶段与附录 B/C。补丁在指定基线上通过检查和试应用；编译和运行需在 K3 上继续验证。
正文主要覆盖 RAN/RFsim，核心网和 nearRT-RIC 仍为后续阶段，尚未给出完整移植命令。

本文面向第一次接触 Linux、Sionna RK 和 OpenAirInterface 的读者。所有命令  
默认在 **K3 的 Ubuntu 终端**中执行，不是在 Windows PowerShell 中执行。

官方 Sionna RK 主要面向 NVIDIA DGX Spark 和 Jetson。K3 是 RISC-V 平台，  
因此只能复用项目和 OAI 的 CPU 路径，不能直接套用 CUDA、Docker 镜像或  
NVIDIA 平台配置。本文会在每一步明确区分官方步骤与 K3 修改。

## 文件来源标记
本文中的脚本分为四类：

+ **【官方仓库】**：下载 Sionna-RK 后原本就存在；
+ **【官方文件，K3补丁修改】**：官方原文件被 K3补丁修改；
+ **【K3补丁新增】**：官方仓库中不存在，应用 K3补丁后才会生成；
+ **【本实验新增】**：为热点时间实验另外编写，不属于官方仓库或原 K3补丁。

本文不会把补丁新增脚本写成官方功能。执行某个新增脚本前，必须先完成对应  
补丁或文件的放置步骤。

## 最终目标
在 RISC-V 上原生运行图中的全部软件组件：

```text
MySQL
OAI-AMF
OAI-SMF
OAI-UPF
OAI-gNB
OAI-nrUE
OAI external data network
nearRT-RIC
```

迁移分为四个阶段：

1. 编译并运行 OAI gNB/nrUE，先用 RFsim 验证 RAN；
2. 原生编译 MySQL、AMF、SMF 和 UPF，组成 RISC-V 5G Core；
3. 配置 external data network，验证 UE 用户面通信；
4. 原生编译 nearRT-RIC，并通过 E2 接入 gNB。

其中 MySQL 可以直接使用 Ubuntu 的 RISC-V 软件包；其他 OAI 和 RIC 组件需要  
逐个检查源码、依赖和架构相关代码。本文不使用 x86/ARM 容器镜像代替移植。

## 第 1 步：下载 Sionna RK
### 1.1 确认当前终端是 K3
```bash
whoami
uname -m
pwd
```

预期：

+ `uname -m` 输出 `riscv64`；
+ 用户名不要求必须是 `ubuntu`；
+ 后续使用 `$HOME` 表示当前用户的主目录，不写死 `/home/ubuntu`。

如果 `uname -m` 输出 `x86_64`，说明当前终端是普通 x86 电脑，不是 K3，  
请先 SSH 到 K3 再继续。

### 1.2 安装下载工具
```bash
sudo apt update
sudo apt install -y git curl ca-certificates
```

用下面的命令确认 Git 可用：

```bash
git --version
```

### 1.3 检查是否已经下载过
```bash
ls -ld "$HOME/sionna-rk"
```

+ 如果提示 `No such file or directory`，继续执行 1.4。
+ 如果能看到该目录，**不要再次 clone，也不要删除目录**。直接执行 1.5。

### 1.4 从官方仓库下载
```bash
cd "$HOME"
git clone --recurse-submodules https://github.com/NVlabs/sionna-rk.git
```

该命令只创建项目需要的 `$HOME/sionna-rk` 目录。`--recurse-submodules`  
很重要，因为 OAI 等依赖以 Git submodule 形式存在。

如果下载过程中断，不要重新创建另一个目录。进入现有目录补全：

```bash
cd "$HOME/sionna-rk"
git submodule update --init --recursive
```

### 1.5 验证下载结果
```bash
cd "$HOME/sionna-rk"
ls
```

能看到 `Makefile`、`scripts`、`plugins` 和 `ext`，说明下载完成。

## 第 2 步：在 K3 上移植 OAI
### 2.1 固定已验证的 Sionna-RK 版本
```bash
cd "$HOME/sionna-rk"
git checkout 0abdce3
git switch -c k3-rv64-cpu-only
```

如果提示分支已经存在，执行：

```bash
git switch k3-rv64-cpu-only
```

### 2.2 安装编译工具
```bash
sudo apt update
sudo apt install -y \
  build-essential cmake ninja-build pkg-config \
  python3 python3-pip python3-venv
```

### 2.3 启用 CPU-only 模式
```bash
export SIONNA_RK_CPU_ONLY=1
export CUDA_VISIBLE_DEVICES=""
export NVIDIA_VISIBLE_DEVICES=void
```

本阶段完成后，当前终端已准备好应用 K3 RV64 移植修改。

## 第 3 步：下载、校验并应用 K3 RV64 补丁

补丁为 **【K3 移植补丁】**，由本项目仓库提供，不属于官方原始命令。
补丁目录按日期固定，教程同时固定 SHA256；下载内容变化时会停止，不会直接应用。

### 3.1 下载并校验

在 K3 Ubuntu 终端完整执行下面的代码块。只有下载和 SHA256 校验均通过，
才会更新 `$HOME/sionna-rk-k3-rv64.patch`；下载失败时保留之前的补丁文件。

```bash
(
set -e
patch="$HOME/sionna-rk-k3-rv64.patch"
tmp=$(mktemp "$HOME/sionna-rk-k3-rv64.download.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT

curl -fL --retry 3 --connect-timeout 15 \
  "https://raw.githubusercontent.com/brownjudy797-glitch/XSAI_AIRAN/main/patches/k3-rv64/20261029/sionna-rk-k3-rv64.patch" \
  -o "$tmp"

printf '%s  %s\n' \
  'b35232cc7ec640be1b7a899fcfb9fd5887f86748376095da06b2883886d55738' "$tmp" | sha256sum --check -
mv -- "$tmp" "$patch"
echo "补丁下载并校验通过：$patch"
)
```

### 3.2 检查状态并应用

```bash
(
set -e
cd "$HOME/sionna-rk"
patch="$HOME/sionna-rk-k3-rv64.patch"

test -s "$patch" || {
    echo "错误：补丁不存在或为空，请先执行第 3.1 步。"
    exit 1
}
printf '%s  %s\n' \
  'b35232cc7ec640be1b7a899fcfb9fd5887f86748376095da06b2883886d55738' "$patch" | sha256sum --check -

if git apply --reverse --check --ignore-space-change "$patch" \
    >/dev/null 2>&1; then
    echo "检查通过：补丁已经完整应用，无需重复执行。"
else
    echo "检查补丁是否适用于当前文件……"
    git apply --check --ignore-space-change "$patch"

    backup="$HOME/Makefile.before-k3-rv64.$(date +%Y%m%d-%H%M%S).bak"
    cp -p -- Makefile "$backup"
    echo "Makefile 已备份：$backup"

    git apply --ignore-space-change "$patch"
    git apply --reverse --check --ignore-space-change "$patch"
    echo "检查通过：补丁已完整应用。"
fi

echo "可以继续第 4 步。"
)
```

首次执行时先正向检查，通过后才应用，再反向检查确认完整性。
已完整应用时直接显示成功，不会重复应用。`--reverse --check` 只检查，不撤销修改。
若工作区只应用了一部分或有不兼容修改，检查失败后会停止；保留报错及 `git diff` 排查，不要强制重置工作区。

`--ignore-space-change` 用于兼容上下文中的空白差异，不忽略代码内容差异。
补丁文件内部还包含 OAI 的内层补丁，出现 `trailing whitespace` 警告不等于应用失败；不要对整份文件自动执行空白清理。
完整性检查仅证明源码修改已应用，编译和运行仍由后续步骤验证。
如果此前已应用本版本补丁，可直接运行第 3.2 步确认状态，无需撤销或重做前两步。

本补丁涉及的主要脚本来源如下：

| 文件 | 来源 |
| --- | --- |
| `scripts/quickstart-oai.sh` | 【官方文件，K3补丁修改】 |
| `scripts/configure-system.k3.sh` | 【K3补丁新增】 |
| `scripts/build-oai-native.sh` | 【K3补丁新增】 |
| `scripts/run-k3-rfsim.sh` | 【K3补丁新增】 |


可确认补丁新增文件已经出现：

```bash
ls -l scripts/configure-system.k3.sh \
      scripts/build-oai-native.sh \
      scripts/run-k3-rfsim.sh
```

## 第 4 步：下载并编译 OAI
### 4.1 安装 K3 依赖
使用 **【K3补丁新增】** 的脚本：

```bash
cd "$HOME/sionna-rk"
./scripts/configure-system.k3.sh
```

### 4.2 下载 OAI
使用 **【官方文件，K3补丁修改】** 的脚本：

```bash
cd "$HOME/sionna-rk"
export SIONNA_RK_CPU_ONLY=1

./scripts/quickstart-oai.sh \
  --no-build \
  --source "$HOME/sionna-rk" \
  --dest "$HOME/sionna-rk/ext/openairinterface5g"
```

### 4.3 安装 OAI 依赖
使用 **【K3补丁新增】** 的脚本：

```bash
cd "$HOME/sionna-rk"
./scripts/build-oai-native.sh --install-deps ext/openairinterface5g
```

### 4.4 编译 gNB 和 nrUE
正式编译前，必须先完整执行附录 C 的统一计时脚本流程。该流程会生成  
`add-oai-timer.sh`，检查源码锚点、安装全部计时项，并重新编译 gNB、nrUE 和  
RFsim 插件。完成附录 C 后回到本节，继续检查编译产物。

如果统一计时脚本已经显示两个软调制解调器和 `rfsimulator` 编译成功，不必再次  
执行下面的全量编译。只有首次构建，或修改了其他 OAI 源码时，才使用  
**【K3补丁新增】** 的 `build-oai-native.sh`：

```bash
cd "$HOME/sionna-rk"
./scripts/build-oai-native.sh ext/openairinterface5g
```

编译完成后应看到：

```text
Built target nr-softmodem
Built target nr-uesoftmodem
Built target rfsimulator
```

生成的程序位于：

```text
$HOME/sionna-rk/ext/openairinterface5g/cmake_targets/ran_build/build
```

## 第 5 步：首次 RFsim 同步与采集

先执行附录 B 的短下载代码块安装 `scripts/run-k3-hotspot-experiment.sh`。
本版用同一实验启动器完成首轮与正式测量，避免另外维护一套不同频率的同步命令。
指定 OAI 基线的 106 PRB 配置与三平台实验脚本均采用 3319680000 Hz。

```bash
cd "$HOME/sionna-rk"
bash -n scripts/run-k3-hotspot-experiment.sh
./scripts/run-k3-hotspot-experiment.sh ideal 1 1
```

脚本等待 gNB 监听、nrUE 同步，再预热和测量，最后归档并停止本轮进程。
在本轮 nrUE 日志中检查 `Initial sync successful` 或 `UE synchronized`，并按第 8 步核对 CSV 和 metadata。
同步失败时先检查配置、频率、CPU 及二进制；不要立即连续启动五轮。
旧补丁附带的简化 `run-k3-rfsim.sh` 仍保留在源代码中，本教程的热点测量统一使用上述启动器。

## 第 6 步：准备自动热点实验
第 5 步的双终端方式只用于首次确认 RFsim 能够同步。正式实验由一个脚本  
自动启动 gNB 和 nrUE，不再使用固定的 gNB 165 秒、UE 150 秒人工操作。

`run-k3-hotspot-experiment.sh` 属于 **【本实验新增】**，不属于官方仓库。  
按附录 B 下载并校验脚本，再确认语法正确：

```bash
ls -l "$HOME/sionna-rk/scripts/run-k3-hotspot-experiment.sh"
bash -n "$HOME/sionna-rk/scripts/run-k3-hotspot-experiment.sh" \
  && echo "脚本语法检查通过"
```

脚本会自动完成：

1. 清理上一轮统计；
2. 通过临时 systemd 服务启动 gNB，等待 RFsim 端口；
3. 通过临时 systemd 服务启动 nrUE，等待同步成功；同步超时会自动重启 nrUE，默认最多尝试 3 次；
4. 完整同步后预热 20 秒，保存起点统计快照；
5. 稳定运行 120 秒，保存终点统计快照；
6. 用两个快照的累计总耗时和调用次数计算严格窗口平均值，并把实验日期、信道、轮次和测量起止时间写入 CSV 每一行；
7. 向 UE 和 gNB 发送 `SIGINT`，保存完整累计统计；
8. 记录提交号、配置哈希、内核、二进制哈希、CPU 范围及启动器类型。

脚本不再把 OAI 进程直接挂在当前终端会话下，而是使用临时 systemd 服务，并设置固定 CPU 范围、无限 memlock 和统一工作目录。这样从 SSH、K3 图形终端或字符终端启动时，gNB/nrUE 使用相同的运行环境。脚本结束或异常退出时会停止临时服务，并再次清理残留的 OAI 进程。

OAI 的 `-q` 统计从进程启动后累计。脚本通过“预热结束快照”和“测量结束快照”  
做差，排除启动、同步和预热阶段。窗口平均值写入 `window-stats.csv`。OAI只保存  
累计最大值，因此该文件最后一列仍明确标记为终点快照的进程累计最大值。  
`window-stats.csv` 的前五列为 `experiment_date`、`channel`、`run`、  
`measure_start`、`measure_end`。其中日期来自测量窗口起点，而不是文件复制时间；  
Excel 原始数据页应保留这些字段，以日期和轮次识别最新实验，不能只依赖文件名。

## 第 7 步：AWGN 配置说明
不需要手工复制配置，也不需要使用 `nano`。第一次运行 `awgn` 或 `pair` 模式时，  
实验脚本会先检查并清理后台残留的 gNB/nrUE 进程，再自动执行以下操作：

1. 复制 OAI 的理想 RFsim gNB配置；
2. 追加 AWGN信道模型；
3. 生成 `$HOME/sionna-rk/config/rfsim/gnb.sa.band78.106prb.awgn.conf`；
4. 在每轮 `metadata.txt` 中记录该配置的 SHA-256。

自动配置使用的两个噪声功率分别为 `-100 dB` 和 `-95 dB`。如果 AWGN配置文件  
已经存在，脚本会直接复用，不会覆盖。正式实验中不要在不同轮次之间修改它。

## 第 8 步：使用自动热点实验脚本
先停止第 5 步的手动实验：

```bash
cd "$HOME/sionna-rk"
./scripts/run-k3-rfsim.sh stop
```

### 8.1 命令格式
脚本只需要一个终端，格式为：

```bash
./scripts/run-k3-hotspot-experiment.sh 模式 重复次数 起始编号
```

三个参数的含义：

| 参数 | 可填写内容 | 含义 |
| --- | --- | --- |
| 模式 | `ideal` | 只运行理想信道 |
| 模式 | `awgn` | 只运行 AWGN信道 |
| 模式 | `pair` | 每轮依次运行理想信道和 AWGN信道 |
| 重复次数 | 正整数 | 本次需要运行几轮，省略时为 `1` |
| 起始编号 | 正整数 | 第一轮结果编号，省略时为 `1` |


例如：

```bash
./scripts/run-k3-hotspot-experiment.sh ideal 1 1
```

表示运行一次理想信道，结果使用 `ideal-run1-` 开头的文件名。同步默认每次等待 20 秒，最多尝试 3 次；可通过 `SYNC_TIMEOUT` 和 `SYNC_ATTEMPTS` 临时调整。  
所有结果统一保存在 `$HOME/sionna-rk/results`，脚本会自动创建这个目录，  
不会把日志直接放在项目根目录，也不会为每一轮再创建子目录。

### 8.2 先运行第一轮理想信道
```bash
cd "$HOME/sionna-rk"
./scripts/run-k3-hotspot-experiment.sh ideal 1 1
```

脚本显示 `All requested runs completed.` 后，检查同步和结果文件：

```bash
grep -E 'Initial sync successful|UE synchronized' results/ideal-run1-nrue.log
ls -lh results/ideal-run1-*
```

应当生成：

```text
results/ideal-run1-gnb.log
results/ideal-run1-nrue.log
results/ideal-run1-start-nrL1_stats.log
results/ideal-run1-start-nrL1_UE_stats-0.log
results/ideal-run1-end-nrL1_stats.log
results/ideal-run1-end-nrL1_UE_stats-0.log
results/ideal-run1-window-stats.csv
results/ideal-run1-nrL1_stats.log
results/ideal-run1-nrL1_UE_stats-0.log
results/ideal-run1-metadata.txt
```

各文件的用途如下：

| 文件 | 用途 | 正式比较是否直接使用 |
| --- | --- | --- |
| `ideal-run1-gnb.log` | gNB完整终端日志，用于检查启动、RFsim、AWGN加载和异常 | 否，用于排错和有效性检查 |
| `ideal-run1-nrue.log` | nrUE完整终端日志，用于确认 `UE synchronized!` | 否，用于同步证据和排错 |
| `ideal-run1-start-nrL1_stats.log` | 预热结束时的gNB累计统计快照 | 是，作为窗口计算起点 |
| `ideal-run1-start-nrL1_UE_stats-0.log` | 预热结束时的UE 0累计统计快照 | 是，作为窗口计算起点 |
| `ideal-run1-end-nrL1_stats.log` | 120秒测量结束时的gNB累计统计快照 | 是，作为窗口计算终点 |
| `ideal-run1-end-nrL1_UE_stats-0.log` | 120秒测量结束时的UE 0累计统计快照 | 是，作为窗口计算终点 |
| `ideal-run1-window-stats.csv` | 根据起点和终点快照计算的严格窗口平均耗时与调用次数 | **是，正式分析的主文件** |
| `ideal-run1-nrL1_stats.log` | gNB退出后保存的整轮进程累计统计 | 否，用于审计和兼容旧实验 |
| `ideal-run1-nrL1_UE_stats-0.log` | nrUE退出后保存的整轮进程累计统计 | 否，用于审计和兼容旧实验 |
| `ideal-run1-metadata.txt` | 信道、时间、CPU、内核、提交号、配置及二进制哈希 | 是，用于确认实验条件一致 |


`window-stats.csv` 每行字段如下：

| 字段 | 含义 |
| --- | --- |
| `experiment_date` | 测量窗口开始日期，格式 `YYYY-MM-DD` |
| `channel` / `run` | 信道场景与轮次编号 |
| `measure_start` / `measure_end` | 带时区的测量窗口起止时间 |
| `side` / `module` | gNB 或 nrUE，以及 OAI 原生计时项名称 |
| `window_avg_us` / `window_calls` | 严格窗口内的平均耗时和调用次数 |
| `start_*` / `end_*` | 起点、终点累计统计，用于审计差分计算 |
| `end_cumulative_max_us` | 终点快照的进程累计最大值，不是窗口最大值 |


本轮只用 `window_avg_us` 做跨平台和热点排序。父计时与子计时不能相加，等待、  
唤醒等调度项也不能与算法计算耗时相加。

### 8.2.1 gNB 计时项的物理层位置和去重规则
| 物理层位置 | 外层计时 | 直接子项或相关项 | 去重规则 |
| --- | --- | --- | --- |
| RU 接收前端 FEP | `feprx` | `symbol_dft (RX)`、`ofdm_demod wait/wakeup` | `feprx` 是外层累计计时；单符号 DFT 和线程调度项单独比较，不与外层相加 |
| gNB PUSCH 接收机 | `PUSCH inner-receiver` | 信道估计、初始化、符号处理 | 三类直接子项位于接收机内部；LDPC 不属于该外层 |
| PUSCH 信道估计 | `PUSCH channel estimation` | `PUSCH channel-estimation antenna processing` | 逐天线处理嵌套在信道估计中 |
| gNB ULSCH 译码 | `UL segments decoding` | LDPC `cnProc`、`bnProc` 和缓冲准备项 | 速率恢复和解交织是译码前置独立阶段，不包含在本项中 |
| gNB DLSCH 编码 | `DLSCH encoding` | 分段、LDPC 编码、速率匹配、交织 | 子项只用于定位内部热点，不与父项重复求和 |
| RU 发送前端 | `feptx_ofdm` | `symbol_idft (TX)`、`ofdm_mod wait/wakeup` | 父子与调度计时分开比较 |
| RU 发送预编码/搬运 | 无共同父计时用于本表求和 | `feptx_prec`、`txdataF_copy` | RU 预编码不同于 DLSCH precoding；数据复制也不是 OFDM 计算 |


应用附录 C 的统一计时脚本后，`nrL1_stats.log` 和 `window-stats.csv` 会自动多出四个 gNB  
字段：`PUSCH channel estimation`、`PUSCH channel-estimation antenna  
processing`、`PUSCH initialization`、`PUSCH symbol processing`。它们是  
`PUSCH inner-receiver` 的嵌套计时，不能直接相加。

当前 K3 编译还导出了 OAI 已有的 `DCI generation`、`ULSCH total decoding`、  
`RX phase compensation`、`SRS receive` 和 `SRS generation`。SRS 未被配置时  
对应调用次数可能为 0；这些字段同样只做横向比较，不与外层计时求和。

AWGN轮次的文件结构完全相同，只是文件名前缀由 `ideal-run1-` 变成  
`awgn-run1-`。其他轮次把 `run1` 换成对应编号。

### 8.3 再运行第一轮 AWGN信道
理想信道成功后运行：

```bash
./scripts/run-k3-hotspot-experiment.sh awgn 1 1
```

检查结果：

```bash
grep -E 'Initial sync successful|UE synchronized' results/awgn-run1-nrue.log
ls -lh results/awgn-run1-*
```

至此，`ideal-run1` 和 `awgn-run1` 组成第一轮正式对照实验。

### 8.4 继续完成第2至第5轮
第一轮两种信道都成功后，再自动运行余下四轮：

```bash
./scripts/run-k3-hotspot-experiment.sh pair 4 2
```

这里的 `pair 4 2` 表示从 `run2` 开始，共运行四轮：

```text
ideal-2 → AWGN-2 → ideal-3 → AWGN-3 → ideal-4 → AWGN-4 → ideal-5 → AWGN-5
```

每轮之间默认等待 30 秒。需要延长冷却时间时：

```bash
COOLDOWN_SECONDS=60 ./scripts/run-k3-hotspot-experiment.sh pair 4 2
```

### 8.5 补测和调整时间
例如单独补测第6轮：

```bash
./scripts/run-k3-hotspot-experiment.sh ideal 1 6
./scripts/run-k3-hotspot-experiment.sh awgn 1 6
```

最后一个参数 `6` 表示从 `run6` 开始编号。

脚本不会覆盖已有结果。如果文件已经存在，使用第三个参数指定新的起始编号。

默认预热20秒、测量120秒。临时调整时可以执行：

```bash
WARMUP_SECONDS=30 MEASURE_SECONDS=180 \
  ./scripts/run-k3-hotspot-experiment.sh ideal 1 6
```

同一组正式对照实验必须使用相同的预热时间和测量时间。

### 8.6 检查全部结果
检查五轮是否全部同步：

```bash
cd "$HOME/sionna-rk"
grep -H -E 'Initial sync successful|UE synchronized' \
  results/ideal-run*-nrue.log results/awgn-run*-nrue.log
```

正式比较优先读取每轮的窗口差分文件：

| 文件 | 内容 |
| --- | --- |
| `results/ideal-run1-window-stats.csv` | 理想信道严格测量窗口统计 |
| `results/awgn-run1-window-stats.csv` | AWGN信道严格测量窗口统计 |


直接查看：

```bash
column -s, -t results/ideal-run1-window-stats.csv | less -S
column -s, -t results/awgn-run1-window-stats.csv | less -S
```

`start-*` 是预热结束快照，`end-*` 是120秒结束快照。`window_avg_us` 和  
`window_calls` 是两个快照差分后的正式结果。`end_cumulative_max_us` 只是从进程  
启动到终点快照的累计最大值，不能当作严格120秒窗口最大值。

不带 `start-`、`end-` 的 `nrL1_stats.log` 和 `nrL1_UE_stats-0.log` 是进程退出时  
保存的OAI累计原始文件，用于审计和兼容旧结果，不作为窗口平均值的主要来源。  
统计项名称由OAI输出，报告中的中文属于人工解释。

`gnb.log` 和 `nrue.log` 用于检查启动、同步、AWGN加载和错误，不是主要耗时表；  
`metadata.txt` 用于核对提交号、配置哈希、测量时间和 CPU范围。它们也必须保留，  
但不要与上面四份物理层统计文件混淆。

正式比较时，每个模块分别报告五轮平均值、标准差、最小值和最大值，并同时  
检查调用次数。固定运行时间只能统一测量条件，不能保证每轮调用次数完全相同。

## 后续阶段：完整 RISC-V 5G 系统
完成 RAN/RFsim 验证后，继续按以下顺序部署：

1. MySQL；
2. OAI-AMF；
3. OAI-SMF；
4. OAI-UPF；
5. external data network；
6. nearRT-RIC 和 E2 接口；
7. gNB 接入 5G Core，完成注册、PDU Session 和双向用户面验证。

## 附录 A：补丁下载位置与校验信息

补丁已作为独立文件保存，无需在终端粘贴 diff。生成式旧附录 A 已由第 3.1 步的下载命令取代。

| 项目 | 内容 |
|---|---|
| 分发仓库 | [brownjudy797-glitch/XSAI_AIRAN](https://github.com/brownjudy797-glitch/XSAI_AIRAN) |
| 补丁版本 | `20261029` |
| 应用基线 | `NVlabs/sionna-rk` 的 `0abdce3` |
| 补丁文件 | [sionna-rk-k3-rv64.patch](../../patches/k3-rv64/20261029/sionna-rk-k3-rv64.patch) |
| 校验文件 | [SHA256SUMS](../../patches/k3-rv64/20261029/SHA256SUMS) |
| 补丁说明 | [版本说明](../../patches/k3-rv64/20261029/README.md) |

SHA256：

```text
b35232cc7ec640be1b7a899fcfb9fd5887f86748376095da06b2883886d55738
```

本补丁修正了 Makefile 上下文中的 Tab 缩进，保留内层补丁所需空白。
本地下载版与 GitHub 版正文相同；以上相对链接按 GitHub 教程所在目录组织，本地可使用第 3.1 步的完整下载 URL。

## 附录 B：下载自动热点实验脚本
下面的脚本属于 **【本实验新增】**。在 K3 Ubuntu终端中完整复制并执行下面的  
代码块，它会直接创建脚本，不需要从作者电脑复制任何文件。

```bash
cd "$HOME/sionna-rk"

(
set -e
target="$HOME/sionna-rk/scripts/run-k3-hotspot-experiment.sh"
mkdir -p -- "$(dirname "$target")"
tmp=$(mktemp "${target}.download.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
curl -fL --retry 3 --connect-timeout 15 \
  "https://raw.githubusercontent.com/brownjudy797-glitch/XSAI_AIRAN/main/tutorials/assets/20261029/run-k3-hotspot-experiment.sh" -o "$tmp"
printf '%s  %s\n' '2cab94d83e3b91214707282429b551997e22145246aa3e489b709f213441992d' "$tmp" | sha256sum --check -
mv -- "$tmp" "$target"
chmod 0755 -- "$target"
)

chmod +x scripts/run-k3-hotspot-experiment.sh
bash -n scripts/run-k3-hotspot-experiment.sh \
  && echo "脚本创建成功，语法检查通过"
```

必须使用带单引号的 `<<'K3_HOTSPOT_SCRIPT'`，这样 Bash不会在创建文件时提前  
展开脚本中的 `$HOME`、变量或命令替换。

## 附录 C：统一安装全部 gNB 细粒度计时
如果只拿到了本指导，没有单独取得 `add-oai-timer.sh`，可在当前 Ubuntu  
终端执行下面的下载与校验代码块：

```bash
cd "$HOME/sionna-rk"

(
set -e
target="$HOME/sionna-rk/add-oai-timer.sh"
mkdir -p -- "$(dirname "$target")"
tmp=$(mktemp "${target}.download.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
curl -fL --retry 3 --connect-timeout 15 \
  "https://raw.githubusercontent.com/brownjudy797-glitch/XSAI_AIRAN/main/tutorials/assets/20261029/add-oai-timer.sh" -o "$tmp"
printf '%s  %s\n' '160a687c5b2bd4a209375a2aed9d28f2540c16a87b67fbf3d1fb11155b3f59e5' "$tmp" | sha256sum --check -
mv -- "$tmp" "$target"
chmod 0755 -- "$target"
)

chmod 0755 add-oai-timer.sh
```

下载命令已包含 SHA256 校验；不再需要复制 heredoc 或大型脚本正文。

这是当前 K3 热点实验的推荐入口。脚本生成后执行：

```bash
cd "$HOME/sionna-rk"
install -m 755 add-oai-timer.sh scripts/add-oai-timer.sh
bash -n scripts/add-oai-timer.sh
./scripts/add-oai-timer.sh --oai-dir "$HOME/sionna-rk/ext/openairinterface5g" --check
./scripts/add-oai-timer.sh --oai-dir "$HOME/sionna-rk/ext/openairinterface5g" --preset all --apply --build
./scripts/add-oai-timer.sh --oai-dir "$HOME/sionna-rk/ext/openairinterface5g" --verify
```

`--check` 只检查、不修改源码；`--apply` 在  
`$HOME/.oai-timer-backups/<时间戳>/` 保存备份；`--build` 必须同时生成：

```text
nr-softmodem
nr-uesoftmodem
librfsimulator.so
```

运行实验前再做一次动态库检查：

```bash
test -x "$HOME/sionna-rk/ext/openairinterface5g/cmake_targets/ran_build/build/nr-softmodem"
test -x "$HOME/sionna-rk/ext/openairinterface5g/cmake_targets/ran_build/build/nr-uesoftmodem"
test -f "$HOME/sionna-rk/ext/openairinterface5g/cmake_targets/ran_build/build/librfsimulator.so"
```

若最后一项不存在，在构建目录补编 RFsim 插件：

```bash
cd "$HOME/sionna-rk/ext/openairinterface5g/cmake_targets/ran_build/build"
make -j"$(nproc)" rfsimulator
```

统一脚本输出的是多个嵌套层级。正式热点排名只在同一层级横向比较；子项用于解释  
父项内部组成，不把父项、子项、线程等待和唤醒时间相加。
