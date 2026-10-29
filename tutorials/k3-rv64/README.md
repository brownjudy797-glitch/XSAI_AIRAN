<!-- SPDX-License-Identifier: Apache-2.0 -->
# 在 RISC-V K3 上部署完整 Sionna RK/OAI 5G 系统 — 仓库下载版（2026-10-29）

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

```latex
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

```latex
Built target nr-softmodem
Built target nr-uesoftmodem
Built target rfsimulator
```

生成的程序位于：

```latex
$HOME/sionna-rk/ext/openairinterface5g/cmake_targets/ran_build/build
```

## 第 5 步：启动单板 RFsim
本节使用 **【K3补丁新增】** 的 `run-k3-rfsim.sh`，它不是官方 Sionna-RK  
启动脚本。

先启动 gNB：

```bash
cd "$HOME/sionna-rk"
./scripts/run-k3-rfsim.sh gnb-start
```

再启动 nrUE：

```bash
./scripts/run-k3-rfsim.sh ue-start
```

查看运行状态：

```bash
./scripts/run-k3-rfsim.sh check
```

查看 UE 日志：

```bash
./scripts/run-k3-rfsim.sh ue-log
```

日志出现下面内容，表示 RFsim 同步成功：

```latex
Initial sync successful
UE synchronized!
```

按 `Ctrl+C` 只会退出日志查看。实验结束后执行：

```bash
./scripts/run-k3-rfsim.sh stop
```

## 第 6 步：准备自动热点实验
第 5 步的双终端方式只用于首次确认 RFsim 能够同步。正式实验由一个脚本  
自动启动 gNB 和 nrUE，不再使用固定的 gNB 165 秒、UE 150 秒人工操作。

`run-k3-hotspot-experiment.sh` 属于 **【本实验新增】**，不属于官方仓库。  
按照附录 B 的命令，在 K3终端中直接生成脚本。生成后确认语法正确：

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

```latex
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

```latex
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

## 附录 B：生成自动热点实验脚本
下面的脚本属于 **【本实验新增】**。在 K3 Ubuntu终端中完整复制并执行下面的  
代码块，它会直接创建脚本，不需要从作者电脑复制任何文件。

```bash
cd "$HOME/sionna-rk"

cat > scripts/run-k3-hotspot-experiment.sh <<'K3_HOTSPOT_SCRIPT'
#!/usr/bin/env bash
# K3 RFsim hotspot experiment launcher (systemd-isolated revision).
set -euo pipefail

ROOT="${SIONNA_RK_ROOT:-$HOME/sionna-rk}"
OAI="$ROOT/ext/openairinterface5g"
BUILD="$OAI/cmake_targets/ran_build/build"
RESULTS_DIR="${RESULTS_DIR:-$ROOT/results}"
GNB_IDEAL="$OAI/ci-scripts/conf_files/gnb.sa.band78.106prb.rfsim.conf"
GNB_AWGN="$ROOT/config/rfsim/gnb.sa.band78.106prb.awgn.conf"
UE_CONF="$OAI/targets/PROJECTS/GENERIC-NR-5GC/CONF/ue.conf"
CPU_SET="${CPU_SET:-0-7}"
MEASURE_SECONDS="${MEASURE_SECONDS:-120}"
WARMUP_SECONDS="${WARMUP_SECONDS:-20}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-30}"
SYNC_TIMEOUT="${SYNC_TIMEOUT:-20}"
SYNC_ATTEMPTS="${SYNC_ATTEMPTS:-3}"

MODE="${1:-}"
REPEATS="${2:-1}"
START_RUN="${3:-1}"

usage() {
  echo "Usage: $0 ideal|awgn|pair [repeat-count] [start-number]"
  echo "Example: $0 pair 5"
}

die() { echo "ERROR: $*" >&2; exit 1; }

[[ "$MODE" =~ ^(ideal|awgn|pair)$ ]] || { usage; exit 1; }
[[ "$REPEATS" =~ ^[1-9][0-9]*$ ]] || die "repeat-count must be a positive integer"
[[ "$START_RUN" =~ ^[1-9][0-9]*$ ]] || die "start-number must be a positive integer"
[[ "$SYNC_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "SYNC_TIMEOUT must be a positive integer"
[[ "$SYNC_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || die "SYNC_ATTEMPTS must be a positive integer"
[[ -x "$BUILD/nr-softmodem" ]] || die "nr-softmodem not found: $BUILD"
[[ -x "$BUILD/nr-uesoftmodem" ]] || die "nr-uesoftmodem not found: $BUILD"
[[ -f "$GNB_IDEAL" && -f "$UE_CONF" ]] || die "OAI RFsim configuration is missing"

prepare_awgn_config() {
  [[ -f "$GNB_AWGN" ]] && return 0
  mkdir -p "$(dirname "$GNB_AWGN")"
  cp "$GNB_IDEAL" "$GNB_AWGN"
  cat >>"$GNB_AWGN" <<'AWGN_CONFIG'

channelmod = {
  max_chan = 10;
  modellist = "modellist_rfsimu_1";
  modellist_rfsimu_1 = (
    { model_name = "rfsimu_channel_enB0"; type = "AWGN"; ploss_dB = 0; noise_power_dB = -100; forgetfact = 0; offset = 0; ds_tdl = 0; },
    { model_name = "rfsimu_channel_ue0";  type = "AWGN"; ploss_dB = 0; noise_power_dB = -95;  forgetfact = 0; offset = 0; ds_tdl = 0; }
  );
};
AWGN_CONFIG
  echo "Created AWGN configuration: $GNB_AWGN"
}

if [[ "$MODE" == awgn || "$MODE" == pair ]]; then
  prepare_awgn_config
fi

mkdir -p "$RESULTS_DIR"

# Authenticate once so background processes never stop to request a password.
sudo -v

GNB_PID=""
UE_PID=""
GNB_UNIT=""
UE_UNIT=""

stop_unit() {
  local unit="$1"
  [[ -n "$unit" ]] || return 0
  sudo systemctl stop "$unit" 2>/dev/null || true
  sudo systemctl reset-failed "$unit" 2>/dev/null || true
}

stop_oai_process() {
  local name="$1"
  pgrep -x "$name" >/dev/null || return 0
  sudo pkill -INT -x "$name" 2>/dev/null || true
  for _ in $(seq 1 10); do
    pgrep -x "$name" >/dev/null || return 0
    sleep 1
  done
  sudo pkill -KILL -x "$name" 2>/dev/null || true
}

if pgrep -x nr-softmodem >/dev/null || pgrep -x nr-uesoftmodem >/dev/null; then
  echo "Found stale OAI processes; stopping them before the experiment"
  stop_oai_process nr-uesoftmodem
  stop_oai_process nr-softmodem
  pgrep -x nr-softmodem >/dev/null && die "could not stop the existing gNB"
  pgrep -x nr-uesoftmodem >/dev/null && die "could not stop the existing nrUE"
fi

cleanup() {
  stop_unit "$UE_UNIT"
  stop_unit "$GNB_UNIT"
  stop_oai_process nr-uesoftmodem
  stop_oai_process nr-softmodem
}
trap cleanup EXIT INT TERM

wait_for_gnb() {
  local log="$1"
  for _ in $(seq 1 60); do
    if ss -ltn 2>/dev/null | grep -qE '[:.]4043[[:space:]]'; then
      return 0
    fi
    if ! sudo systemctl is-active --quiet "$GNB_UNIT"; then
      die "gNB exited before RFsim became ready; see $log"
    fi
    sleep 0.5
  done
  die "RFsim port 4043 did not become ready; see $log"
}

wait_for_sync() {
  local log="$1"
  for _ in $(seq 1 "$SYNC_TIMEOUT"); do
    if grep -q 'UE synchronized!' "$log" 2>/dev/null; then
      return 0
    fi
    # sudo/taskset may briefly change the observable PID/process name while it
    # hands execution to nr-uesoftmodem.  Treating that transition as process
    # death races with UE startup and makes the EXIT trap kill a healthy UE.
    # Only fail early for an explicit fatal marker; otherwise let the complete
    # synchronization timeout decide the result.
    if grep -Eqi 'segmentation fault|assertion .* failed|fatal error|core dumped' "$log" 2>/dev/null; then
      return 2
    fi
    sleep 1
  done
  return 1
}

capture_stats() {
  local source_file="$1"
  local target_file="$2"
  local final_marker="$3"
  local tmp_file="${target_file}.tmp"

  for _ in $(seq 1 15); do
    if sudo test -s "$source_file" 2>/dev/null; then
      sudo cp "$source_file" "$tmp_file"
      sudo chown "$USER:$(id -gn)" "$tmp_file"
      if grep -q "$final_marker" "$tmp_file" 2>/dev/null; then
        mv "$tmp_file" "$target_file"
        return 0
      fi
      rm -f "$tmp_file"
    fi
    sleep 1
  done
  die "could not capture a complete statistics snapshot from $source_file"
}

append_window_rows() {
  local side="$1"
  local start_file="$2"
  local end_file="$3"
  local output_file="$4"
  local experiment_date="$5"
  local channel="$6"
  local run_no="$7"
  local measure_start="$8"
  local measure_end="$9"

  LC_ALL=C awk -v side="$side" \
    -v experiment_date="$experiment_date" \
    -v channel="$channel" \
    -v run_no="$run_no" \
    -v measure_start="$measure_start" \
    -v measure_end="$measure_end" '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function parse(line, p, c, f) {
      c = index(line, ":")
      if (c == 0) return 0
      parsed_name = trim(substr(line, 1, c - 1))
      if (split(substr(line, c + 1), f, ";") < 3) return 0
      parsed_avg = f[1]
      parsed_count = f[2]
      parsed_max = f[3]
      gsub(/[^0-9.eE+-]/, "", parsed_avg)
      gsub(/[^0-9]/, "", parsed_count)
      gsub(/[^0-9.eE+-]/, "", parsed_max)
      return parsed_name != "" && parsed_avg != "" && parsed_count != "" && parsed_max != ""
    }
    NR == FNR {
      if (parse($0)) {
        start_avg[parsed_name] = parsed_avg + 0
        start_count[parsed_name] = parsed_count + 0
      }
      next
    }
    {
      if (!parse($0) || !(parsed_name in start_count)) next
      delta_count = (parsed_count + 0) - start_count[parsed_name]
      if (delta_count <= 0) next
      delta_total = (parsed_avg + 0) * (parsed_count + 0) \
                    - start_avg[parsed_name] * start_count[parsed_name]
      window_avg = delta_total / delta_count
      csv_name = parsed_name
      gsub(/"/, "\"\"", csv_name)
      printf "%s,%s,%d,%s,%s,%s,\"%s\",%.6f,%d,%.6f,%d,%.6f,%d,%.6f\n", \
             experiment_date, channel, run_no, measure_start, measure_end, \
             side, csv_name, window_avg, delta_count, \
             start_avg[parsed_name], start_count[parsed_name], \
             parsed_avg + 0, parsed_count + 0, parsed_max + 0
    }
  ' "$start_file" "$end_file" >>"$output_file"
}

build_window_csv() {
  local prefix="$1"
  local experiment_date="$2"
  local channel="$3"
  local run_no="$4"
  local measure_start="$5"
  local measure_end="$6"
  local output_file="$prefix-window-stats.csv"

  echo 'experiment_date,channel,run,measure_start,measure_end,side,module,window_avg_us,window_calls,start_avg_us,start_calls,end_avg_us,end_calls,end_cumulative_max_us' >"$output_file"
  append_window_rows gNB "$prefix-start-nrL1_stats.log" "$prefix-end-nrL1_stats.log" "$output_file" "$experiment_date" "$channel" "$run_no" "$measure_start" "$measure_end"
  append_window_rows nrUE "$prefix-start-nrL1_UE_stats-0.log" "$prefix-end-nrL1_UE_stats-0.log" "$output_file" "$experiment_date" "$channel" "$run_no" "$measure_start" "$measure_end"
  [[ $(wc -l <"$output_file") -gt 1 ]] || die "window statistics contain no positive call-count deltas"
}

run_once() {
  local channel="$1"
  local run_no="$2"
  local prefix="$RESULTS_DIR/${channel}-run${run_no}"
  local gnb_conf="$GNB_IDEAL"
  local -a channel_args=()

  if [[ "$channel" == awgn ]]; then
    gnb_conf="$GNB_AWGN"
    channel_args=(--rfsimulator.options chanmod)
  fi

  for suffix in gnb.log nrue.log nrL1_stats.log nrL1_UE_stats-0.log \
                start-nrL1_stats.log start-nrL1_UE_stats-0.log \
                end-nrL1_stats.log end-nrL1_UE_stats-0.log \
                window-stats.csv metadata.txt; do
    [[ ! -e "$prefix-$suffix" ]] || die "Result already exists: $prefix-$suffix"
  done

  echo "[$channel run $run_no] cleaning old statistics"
  sudo rm -f "$BUILD/nrL1_stats.log" "$BUILD/nrL1_UE_stats-0.log"

  echo "[$channel run $run_no] starting gNB"
  GNB_UNIT="k3-hotspot-${channel}-run${run_no}-gnb.service"
  : >"$prefix-gnb.log"
  stop_unit "$GNB_UNIT"
  sudo systemd-run --quiet --unit="$GNB_UNIT" --service-type=exec --collect \
    --working-directory="$BUILD" \
    --property="AllowedCPUs=$CPU_SET" \
    --property=LimitMEMLOCK=infinity \
    --property=TasksMax=infinity \
    --property="StandardOutput=append:$prefix-gnb.log" \
    --property="StandardError=append:$prefix-gnb.log" \
    "$BUILD/nr-softmodem" \
      -O "$gnb_conf" \
      --rfsim \
      --rfsimulator.serveraddr server \
      "${channel_args[@]}" \
      --phy-test \
      --noS1 \
      --gNBs.[0].min_rxtxtime 6 \
      --T_stdout 1 \
      -q
  GNB_PID="$(sudo systemctl show -p MainPID --value "$GNB_UNIT")"
  wait_for_gnb "$prefix-gnb.log"

  local sync_attempt=1
  : >"$prefix-nrue.log"
  while :; do
    echo "[$channel run $run_no] starting nrUE (sync attempt $sync_attempt/$SYNC_ATTEMPTS)"
    printf '\n===== nrUE synchronization attempt %d/%d =====\n' \
      "$sync_attempt" "$SYNC_ATTEMPTS" >>"$prefix-nrue.log"
    UE_UNIT="k3-hotspot-${channel}-run${run_no}-nrue-a${sync_attempt}.service"
    stop_unit "$UE_UNIT"
    sudo systemd-run --quiet --unit="$UE_UNIT" --service-type=exec --collect \
      --working-directory="$BUILD" \
      --property="AllowedCPUs=$CPU_SET" \
      --property=LimitMEMLOCK=infinity \
      --property=TasksMax=infinity \
      --property="StandardOutput=append:$prefix-nrue.log" \
      --property="StandardError=append:$prefix-nrue.log" \
      "$BUILD/nr-uesoftmodem" \
        -O "$UE_CONF" \
        --rfsim \
        --rfsimulator.serveraddr 127.0.0.1 \
        --phy-test \
        --noS1 \
        -r 106 \
        --numerology 1 \
        --band 78 \
        -C 3319680000 \
        --ue-rxgain 140 \
        --ue-txgain 0 \
        --T_stdout 1 \
        -q
    UE_PID="$(sudo systemctl show -p MainPID --value "$UE_UNIT")"

    local sync_rc=0
    if wait_for_sync "$prefix-nrue.log"; then
      break
    else
      sync_rc=$?
    fi
    if (( sync_rc == 2 )); then
      die "nrUE reported a fatal error before synchronization; see $prefix-nrue.log"
    fi
    if (( sync_attempt >= SYNC_ATTEMPTS )); then
      die "nrUE did not synchronize after $SYNC_ATTEMPTS attempts; see $prefix-nrue.log"
    fi
    echo "[$channel run $run_no] synchronization attempt $sync_attempt timed out; restarting nrUE"
    stop_unit "$UE_UNIT"
    UE_UNIT=""
    stop_oai_process nr-uesoftmodem
    UE_PID=""
    sleep 2
    sync_attempt=$((sync_attempt + 1))
  done
  local sync_time
  sync_time="$(date --iso-8601=seconds)"
  echo "[$channel run $run_no] synchronized; warm-up ${WARMUP_SECONDS}s"
  sleep "$WARMUP_SECONDS"

  echo "[$channel run $run_no] capturing start snapshots"
  capture_stats "$BUILD/nrL1_stats.log" "$prefix-start-nrL1_stats.log" 'feptx_total:'
  capture_stats "$BUILD/nrL1_UE_stats-0.log" "$prefix-start-nrL1_UE_stats-0.log" 'OFDM_MOD_STATS:'
  local measure_start
  measure_start="$(date --iso-8601=seconds)"
  echo "[$channel run $run_no] measuring ${MEASURE_SECONDS}s"
  sleep "$MEASURE_SECONDS"

  echo "[$channel run $run_no] capturing end snapshots"
  capture_stats "$BUILD/nrL1_stats.log" "$prefix-end-nrL1_stats.log" 'feptx_total:'
  capture_stats "$BUILD/nrL1_UE_stats-0.log" "$prefix-end-nrL1_UE_stats-0.log" 'OFDM_MOD_STATS:'
  local measure_end
  measure_end="$(date --iso-8601=seconds)"
  local experiment_date="${measure_start%%T*}"

  build_window_csv "$prefix" "$experiment_date" "$channel" "$run_no" "$measure_start" "$measure_end"

  stop_unit "$UE_UNIT"
  UE_UNIT=""
  stop_oai_process nr-uesoftmodem
  UE_PID=""
  stop_unit "$GNB_UNIT"
  GNB_UNIT=""
  stop_oai_process nr-softmodem
  GNB_PID=""

  [[ -f "$BUILD/nrL1_stats.log" ]] || die "gNB statistics were not generated"
  [[ -f "$BUILD/nrL1_UE_stats-0.log" ]] || die "nrUE statistics were not generated"
  sudo cp "$BUILD/nrL1_stats.log" "$prefix-nrL1_stats.log"
  sudo cp "$BUILD/nrL1_UE_stats-0.log" "$prefix-nrL1_UE_stats-0.log"
  sudo chown "$USER:$(id -gn)" "$prefix-nrL1_stats.log" "$prefix-nrL1_UE_stats-0.log"

  {
    echo "experiment_date=$experiment_date"
    echo "channel=$channel"
    echo "run=$run_no"
    echo "sync_time=$sync_time"
    echo "measure_start=$measure_start"
    echo "measure_end=$measure_end"
    echo "warmup_seconds=$WARMUP_SECONDS"
    echo "measure_seconds=$MEASURE_SECONDS"
    echo "sync_timeout_seconds=$SYNC_TIMEOUT"
    echo "sync_attempts_used=$sync_attempt"
    echo "statistics_scope=two_snapshot_window_difference"
    echo "maximum_scope=process_cumulative_at_end_snapshot"
    echo "cpu_set=$CPU_SET"
    echo "launcher=systemd-transient-service"
    echo "kernel=$(uname -r)"
    echo "gnb_binary_sha256=$(sha256sum "$BUILD/nr-softmodem" | awk '{print $1}')"
    echo "nrue_binary_sha256=$(sha256sum "$BUILD/nr-uesoftmodem" | awk '{print $1}')"
    echo "sionna_rk_commit=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "oai_commit=$(git -C "$OAI" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "gnb_config_sha256=$(sha256sum "$gnb_conf" | awk '{print $1}')"
    echo "ue_config_sha256=$(sha256sum "$UE_CONF" | awk '{print $1}')"
  } >"$prefix-metadata.txt"

  echo "[$channel run $run_no] completed: $prefix-*"
}

LAST_RUN=$((START_RUN + REPEATS - 1))
for run_no in $(seq "$START_RUN" "$LAST_RUN"); do
  if [[ "$MODE" == ideal || "$MODE" == pair ]]; then
    run_once ideal "$run_no"
  fi
  if [[ "$MODE" == pair ]]; then
    echo "Cooling down for ${COOLDOWN_SECONDS}s"
    sleep "$COOLDOWN_SECONDS"
  fi
  if [[ "$MODE" == awgn || "$MODE" == pair ]]; then
    run_once awgn "$run_no"
  fi
  if [[ "$run_no" -lt "$LAST_RUN" ]]; then
    echo "Cooling down for ${COOLDOWN_SECONDS}s"
    sleep "$COOLDOWN_SECONDS"
  fi
done

trap - EXIT INT TERM
echo "All requested runs completed. Results: $RESULTS_DIR"
K3_HOTSPOT_SCRIPT

chmod +x scripts/run-k3-hotspot-experiment.sh
bash -n scripts/run-k3-hotspot-experiment.sh \
  && echo "脚本创建成功，语法检查通过"
```

必须使用带单引号的 `<<'K3_HOTSPOT_SCRIPT'`，这样 Bash不会在创建文件时提前  
展开脚本中的 `$HOME`、变量或命令替换。

## 附录 C：统一安装全部 gNB 细粒度计时
如果只拿到了本指导，没有单独取得 `add-oai-timer.sh`，可在当前 Ubuntu  
终端完整复制并执行下面的代码块来生成脚本：

```bash
cd "$HOME/sionna-rk"

cat > add-oai-timer.sh <<'ADD_OAI_TIMER_SCRIPT'
#!/bin/bash
# ============================================================================
#  add-oai-timer.sh —— OAI 计时器一键添加（纯 Shell，零依赖）
#
#  把《OAI 计时器添加指南》里的手工步骤工具化：一条命令加上 gNB FEP 的
#  "投递器 / 任务 / 符号" 三层耗时统计。
#
#  七个预设（均已在 K3 上验证）：
#     rx-symbol   RX 单符号 DFT       → symbol_dft (RX)          262.9 µs
#     tx-symbol   TX 单符号 IDFT      → symbol_idft (TX)         267.5 µs
#     rx-task     RX 任务级（3符号）  → feprx_task (3 symbols)   773.3 µs
#     pusch-native PUSCH 原生子计时   → 信道估计/初始化/符号处理
#     fep-native  FEP 原生调度计时    → RX/TX wait/wakeup
#     ldpc-prof   UL LDPC 内部细分    → cnProc/bnProc/缓冲处理等
#     dlsch-enc   DLSCH 编码内部细分  → 分段/编码/速率匹配/交织
#
#  用法
#   ----
#     ./add-oai-timer.sh --list                   # 看有哪些预设
#     ./add-oai-timer.sh --check                  # 检查源码能否匹配（不改文件）
#     ./add-oai-timer.sh --verify                 # 看当前已加了哪些
#     ./add-oai-timer.sh --preset all             # 预览改动（默认 dry-run）
#     ./add-oai-timer.sh --preset all --apply     # 真正应用
#     ./add-oai-timer.sh --preset all --apply --build   # 应用 + 编译
#     ./add-oai-timer.sh --rollback               # 列出备份
#     ./add-oai-timer.sh --rollback <时间戳>       # 回滚
#     OAI_DIR=/path/to/oai ./add-oai-timer.sh ... # 手动指定源码目录
#
#  这个脚本要放在哪里？
#   -------------------
#   本脚本不会修改自己所在的目录，它只改 OAI 源码里的 3 个文件：
#       openair1/PHY/defs_RU.h
#       openair1/SCHED_NR/nr_ru_procedures.c
#       executables/nr-gnb.c
#   所以放哪里都行，只要能「找到」OAI 源码：
#
#     [推荐] 放在项目的 scripts/ 下（自动向上找 ../ext/openairinterface5g）
#              ~/sionna-rk/scripts/add-oai-timer.sh
#
#     [也可以] 放在任意目录，用 --oai-dir 指定源码位置
#              ~/add-oai-timer.sh --oai-dir ~/sionna-rk/ext/openairinterface5g --check
#
#   自动探测顺序（都不中时会提示用 --oai-dir）：
#       脚本所在目录/../ext/openairinterface5g
#       脚本所在目录/ext/openairinterface5g
#       脚本所在目录/openairinterface5g
#       ~/sionna-rk/ext/openairinterface5g
#       ~/openairinterface5g
#
#   提示：别把脚本放进 OAI 源码目录内（会污染 git status）。
#
#  安全设计
#   --------
#     * 默认 dry-run：不加 --apply 绝不写文件
#     * 自动备份到 ~/.oai-timer-backups/<时间戳>/
#     * 幂等：已存在的计时器自动跳过（按精确 marker 判断）
#     * 锚点唯一性检查：重复匹配则报错中止（防误改）
#     * 原子性：任一编辑失败 → 自动恢复本次已改的文件
# ============================================================================

set -uo pipefail

BACKUP_ROOT="${HOME}/.oai-timer-backups"
OAI_DIR="${OAI_DIR:-}"
PRESET=""
DO_APPLY=0
DO_BUILD=0
RB_TS=""
TS=""

TX_FILES=(
    "openair1/PHY/defs_RU.h"
    "openair1/SCHED_NR/nr_ru_procedures.c"
    "executables/nr-gnb.c"
    # ldpc-prof 预设涉及的文件（FEP 预设不碰它们）
    "openair1/PHY/CODING/nrLDPC_decoder/nrLDPC_decoder.c"
    "openair1/PHY/CODING/nrLDPC_decoder/nrLDPC_types.h"
    "openair1/PHY/CODING/nrLDPC_coding/nrLDPC_coding_interface.h"
    "openair1/PHY/CODING/nrLDPC_coding/nrLDPC_coding_segment/nrLDPC_coding_segment_decoder.c"
    "openair1/PHY/defs_gNB.h"
    "openair1/PHY/NR_TRANSPORT/nr_ulsch_decoding.c"
)

if [ -t 1 ]; then
    R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; D=$'\033[2m'; N=$'\033[0m'
else
    R=""; G=""; Y=""; C=""; D=""; N=""
fi

ok()   { echo "  ${G}✅${N} $*"; }
info() { echo "  $*"; }
warn() { echo "  ${Y}⚠️ ${N} $*"; }
err()  { echo "  ${R}❌${N} $*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# 文本编辑工具
# ---------------------------------------------------------------------------

# 在「匹配正则的最后一行」之后插入若干行
# 用法: ins_after <file> <ereg> <line> [line...]
ins_after() {
    local file="$1" pat="$2"; shift 2
    local n; n=$(grep -nE "$pat" "$file" | tail -1 | cut -d: -f1)
    [ -z "$n" ] && { err "锚点未找到: /$pat/ 于 $(basename "$file")"; return 1; }
    local lf; lf=$(mktemp); printf '%s\n' "$@" > "$lf"
    local tmp; tmp=$(mktemp)
    awk -v n="$n" -v lf="$lf" '
        { print }
        NR == n { while ((getline l < lf) > 0) print l }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
    rm -f "$lf"
}

# 把唯一匹配某正则的整行替换掉
# 用法: sub_line <file> <ereg> <newline>
# 注意：不用 `awk -v pat=` 传正则 —— awk 会吃掉反斜杠转义（如 `\(` 变 `(`）。
#       改为先由 grep 定位行号，再让 awk 按 NR 替换。
sub_line() {
    local file="$1" pat="$2" new="$3"
    local cnt; cnt=$(grep -cE "$pat" "$file")
    [ "$cnt" -eq 0 ] && { err "待替换行未找到: /$pat/ 于 $(basename "$file")"; return 1; }
    [ "$cnt" -gt 1 ] && { err "/$pat/ 匹配 $cnt 行（要求唯一）于 $(basename "$file")"; return 1; }
    local n; n=$(grep -nE "$pat" "$file" | head -1 | cut -d: -f1)
    local tmp; tmp=$(mktemp)
    awk -v n="$n" -v new="$new" 'NR == n { print new; next } { print }' "$file" > "$tmp" \
        && mv "$tmp" "$file"
}

# 在「第 n 行」之前插入若干行
# 用法: ins_before_n <file> <n> <line> [line...]
ins_before_n() {
    local file="$1" n="$2"; shift 2
    local lf; lf=$(mktemp); printf '%s\n' "$@" > "$lf"
    local tmp; tmp=$(mktemp)
    awk -v n="$n" -v lf="$lf" '
        NR == n { while ((getline l < lf) > 0) print l }
        { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
    rm -f "$lf"
}

# 在「匹配正则的第一行」之前插入若干行
# 用法: ins_before <file> <ereg> <line> [line...]
ins_before() {
    local file="$1" pat="$2"; shift 2
    local n; n=$(grep -nE "$pat" "$file" | head -1 | cut -d: -f1)
    [ -z "$n" ] && { err "锚点未找到: /$pat/ 于 $(basename "$file")"; return 1; }
    ins_before_n "$file" "$n" "$@"
}

has() { grep -qF "$2" "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 三个预设
#
# 每个 preset 函数签名：preset_xxx <root>       root = OAI 源码根目录
# 返回 0 = 成功（含跳过），非 0 = 失败
# ---------------------------------------------------------------------------

F_DEFS_REL="openair1/PHY/defs_RU.h"
F_PROC_REL="openair1/SCHED_NR/nr_ru_procedures.c"
F_GNB_REL="executables/nr-gnb.c"
F_DEFS_GNB_REL="openair1/PHY/defs_gNB.h"

# ---- ① RX 单符号 DFT ------------------------------------------------------
preset_rx_symbol() {
    local root="$1"
    local fdef="$root/$F_DEFS_REL" fproc="$root/$F_PROC_REL" fgnb="$root/$F_GNB_REL"

    # 字段
    if has "$fdef" "time_stats_t symbol_dft_stats;"; then
        echo "      [rx-symbol] defs_RU.h：已存在，跳过"
    else
        ins_after "$fdef" '^  time_stats_t ofdm_demod_stats;$' \
            '  /// Timing statistics (single-symbol DFT, diagnostic)' \
            '  time_stats_t symbol_dft_stats;' || return 1
    fi

    # 计时点：符号循环
    if has "$fproc" "start_meas(&ru->symbol_dft_stats)"; then
        echo "      [rx-symbol] nr_ru_procedures.c：已存在，跳过"
    else
        # 1) for 行加花括号（原为单语句循环）
        sub_line "$fproc" '^  for \(int l = startSymbol; l <= endSymbol; l\+\+\) *$' \
            '  for (int l = startSymbol; l <= endSymbol; l++) {' || return 1
        # 2) 调用之前：start
        ins_before "$fproc" '^      nr_slot_fep_ul\(fp,$' \
            '      // 只对符号 0 计时：拆分后仅 p=0 那份的 startSymbol==0，' \
            '      // 保证同一时刻只有一个 worker 写该 time_stats_t（避免多线程竞态）' \
            '      if (l == 0)' \
            '        start_meas(&ru->symbol_dft_stats);' || return 1
        # 3) 调用之后：stop + 闭合花括号
        ins_after "$fproc" '^                     ru->N_TA_offset\);$' \
            '      if (l == 0)' \
            '        stop_meas(&ru->symbol_dft_stats);' \
            '  }' || return 1
    fi

    # 打印
    if has "$fgnb" '"symbol_dft (RX)"'; then
        echo "      [rx-symbol] nr-gnb.c：已存在，跳过"
    else
        ins_after "$fgnb" 'print_meas_log\(&ru->ofdm_demod_stats, "feprx"' \
            '  output += print_meas_log(&ru->symbol_dft_stats, "symbol_dft (RX)", NULL, NULL, output, end - output);' || return 1
    fi
}

# ---- ② TX 单符号 IDFT -----------------------------------------------------
preset_tx_symbol() {
    local root="$1"
    local fdef="$root/$F_DEFS_REL" fproc="$root/$F_PROC_REL" fgnb="$root/$F_GNB_REL"

    # 字段（插在 ofdm_mod_stats 之前）
    if has "$fdef" "time_stats_t symbol_idft_stats;"; then
        echo "      [tx-symbol] defs_RU.h：已存在，跳过"
    else
        local n; n=$(grep -n '^  time_stats_t ofdm_mod_stats;$' "$fdef" | cut -d: -f1)
        [ -z "$n" ] && { err "[tx-symbol] defs_RU.h 里找不到 ofdm_mod_stats"; return 1; }
        # 若上一行是该字段的说明注释，则插到注释之前，避免把注释与新字段隔开
        local at="$n"
        if [ "$n" -gt 1 ] && sed -n "$((n-1))p" "$fdef" | grep -qE '^  ///'; then
            at=$((n-1))
        fi
        ins_before_n "$fdef" "$at" \
            '  /// Timing statistics (single-symbol IDFT, diagnostic)' \
            '  time_stats_t symbol_idft_stats;' || return 1
    fi

    # 计时点：符号 0 那次 PHY_ofdm_mod 调用（用状态机精确定位，避免误匹配）
    if has "$fproc" "start_meas(&ru->symbol_idft_stats)"; then
        echo "      [tx-symbol] nr_ru_procedures.c：已存在，跳过"
    else
        local tmp; tmp=$(mktemp)
        awk '
            # 武装：遇到「符号 0 用长 CP」的条件行
            /\/\/ case where first symbol in slot has longer prefix/ { armed = 1 }
            # 命中：紧接着的 PHY_ofdm_mod(slot_offsetF, ...) —— 即符号 0 那次调用
            armed && /PHY_ofdm_mod\(&ru->common\.txdataF_BF\[aa\]\[slot_offsetF\],/ {
                print "        // 只对符号 0 计时：aa==0 保证同一时刻只有一个 worker 写该 time_stats_t（避免多线程竞态）"
                print "        if (aa == 0)"
                print "          start_meas(&ru->symbol_idft_stats);"
                armed = 0; inblk = 1
            }
            { print }
            # 该次调用结束（第一次遇到 CYCLIC_PREFIX); ）
            inblk && /CYCLIC_PREFIX\);/ {
                print "        if (aa == 0)"
                print "          stop_meas(&ru->symbol_idft_stats);"
                inblk = 0
            }
        ' "$fproc" > "$tmp" && mv "$tmp" "$fproc"
        # 校验确实插进去了
        has "$fproc" "start_meas(&ru->symbol_idft_stats)" || {
            err "[tx-symbol] nr_ru_procedures.c 插入失败（锚点模式未命中）"; return 1; }
    fi

    # 打印
    if has "$fgnb" '"symbol_idft (TX)"'; then
        echo "      [tx-symbol] nr-gnb.c：已存在，跳过"
    else
        ins_after "$fgnb" 'print_meas_log\(&ru->txdataF_copy_stats, "txdataF_copy"' \
            '    output += print_meas_log(&ru->symbol_idft_stats, "symbol_idft (TX)", NULL, NULL, output, end - output);' || return 1
    fi
}

# ---- ③ RX 任务级（3 符号）------------------------------------------------
preset_rx_task() {
    local root="$1"
    local fdef="$root/$F_DEFS_REL" fproc="$root/$F_PROC_REL" fgnb="$root/$F_GNB_REL"

    # 字段
    if has "$fdef" "time_stats_t feprx_task_stats;"; then
        echo "      [rx-task] defs_RU.h：已存在，跳过"
    else
        ins_after "$fdef" '^  time_stats_t ofdm_demod_stats;$' \
            '  /// Timing statistics (RX FEP task, 3 symbols, diagnostic)' \
            '  time_stats_t feprx_task_stats;' || return 1
    fi

    # 计时点：包住整个符号循环
    if has "$fproc" "start_meas(&ru->feprx_task_stats)"; then
        echo "      [rx-task] nr_ru_procedures.c：已存在，跳过"
    else
        ins_after "$fproc" '^  int offset = \(slot % RU_RX_SLOT_DEPTH\)' \
            '  // 只对 p=0 那份任务计时（覆盖整个符号循环）：aid/beam/startSymbol 都是函数参数，' \
            '  // 天然只有一个 worker 满足条件（与 TX 的 aa==0 && first_symbol==0 完全对称）' \
            '  if (aid == 0 && beam == 0 && startSymbol == 0)' \
            '    start_meas(&ru->feprx_task_stats);' || return 1
        ins_before "$fproc" 'VCD_SIGNAL_DUMPER_FUNCTIONS_PHY_PROCEDURES_RU_FEPRX\+aid, 0\);$' \
            '  if (aid == 0 && beam == 0 && startSymbol == 0)' \
            '    stop_meas(&ru->feprx_task_stats);' || return 1
    fi

    # 打印
    if has "$fgnb" '"feprx_task (3 symbols)"'; then
        echo "      [rx-task] nr-gnb.c：已存在，跳过"
    else
        ins_after "$fgnb" 'print_meas_log\(&ru->ofdm_demod_stats, "feprx"' \
            '  output += print_meas_log(&ru->feprx_task_stats, "feprx_task (3 symbols)", NULL, NULL, output, end - output);' || return 1
    fi
}

# 预设名 → 函数
# ---- ④ LDPC 译码内部 11 项细分（ldpc-prof）----------------------------------
# 实测（run23）：cnProc 占 LDPC 的 57.2%；平均迭代 3 轮（进度表 §31）
# ★★ 这是唯一一个改了「gNB/UE 共用头文件」的预设 —— 应用后必须同时重编译两个二进制
F_LDPC_DEC_REL="openair1/PHY/CODING/nrLDPC_decoder/nrLDPC_decoder.c"
F_LDPC_TYPES_REL="openair1/PHY/CODING/nrLDPC_decoder/nrLDPC_types.h"
F_LDPC_IFACE_REL="openair1/PHY/CODING/nrLDPC_coding/nrLDPC_coding_interface.h"
F_LDPC_SEG_REL="openair1/PHY/CODING/nrLDPC_coding/nrLDPC_coding_segment/nrLDPC_coding_segment_decoder.c"
F_ULSCH_REL="openair1/PHY/NR_TRANSPORT/nr_ulsch_decoding.c"

preset_ldpc_prof() {
    local root="$1"
    local fdec="$root/$F_LDPC_DEC_REL"     ftypes="$root/$F_LDPC_TYPES_REL"
    local fiface="$root/$F_LDPC_IFACE_REL" fseg="$root/$F_LDPC_SEG_REL"
    local fgnbdef="$root/$F_DEFS_GNB_REL"  fulsch="$root/$F_ULSCH_REL"
    local fgnb="$root/$F_GNB_REL"

    # ① 打开宏（原本被定义为「空」，会禁用全部 32 处计时点）
    if has "$fdec" "【OAI-LDPC-PROF】原为「空定义」"; then
        echo "      [ldpc-prof] nrLDPC_decoder.c：已存在，跳过"
    else
        sub_line "$fdec" '^//#define NR_LDPC_PROFILER_DETAIL\(a\) a$' \
            '#define NR_LDPC_PROFILER_DETAIL(a) a' || return 1
        sub_line "$fdec" '^#define NR_LDPC_PROFILER_DETAIL\(a\)$' \
            '//#define NR_LDPC_PROFILER_DETAIL(a)   // 【OAI-LDPC-PROF】原为「空定义」，会禁用全部 32 处细分计时点' || return 1
    fi

    # ② 11 项合并辅助函数（放在 #ifndef CODEGEN 内 → 锚在结构体尾部）
    if has "$ftypes" "merge_ldpc_detail_stats(t_nrLDPC_time_stats *dst"; then
        echo "      [ldpc-prof] nrLDPC_types.h：已存在，跳过"
    else
        ins_after "$ftypes" '^} t_nrLDPC_time_stats;$' \
            '' \
            '/**' \
            '   【OAI-LDPC-PROF】把一组 LDPC 细分统计合并到另一组。' \
            '   语义与 merge_meas() 一致：trials / diff / diff_square 累加，max 取较大者。' \
            '   用途：逐码块的统计 → gNB 级汇总。' \
            ' */' \
            'static inline void merge_ldpc_detail_stats(t_nrLDPC_time_stats *dst, const t_nrLDPC_time_stats *src)' \
            '{' \
            '    merge_meas(&dst->llr2llrProcBuf, &src->llr2llrProcBuf);' \
            '    merge_meas(&dst->llr2CnProcBuf,  &src->llr2CnProcBuf);' \
            '    merge_meas(&dst->cnProc,         &src->cnProc);' \
            '    merge_meas(&dst->cnProcPc,       &src->cnProcPc);' \
            '    merge_meas(&dst->bnProcPc,       &src->bnProcPc);' \
            '    merge_meas(&dst->bnProc,         &src->bnProc);' \
            '    merge_meas(&dst->cn2bnProcBuf,   &src->cn2bnProcBuf);' \
            '    merge_meas(&dst->bn2cnProcBuf,   &src->bn2cnProcBuf);' \
            '    merge_meas(&dst->llrRes2llrOut,  &src->llrRes2llrOut);' \
            '    merge_meas(&dst->llr2bit,        &src->llr2bit);' \
            '    merge_meas(&dst->total,          &src->total);' \
            '}' || return 1
    fi

    # ③a 显式 include（防循环 include 时类型不可见）
    if has "$fiface" 'PHY/CODING/nrLDPC_decoder/nrLDPC_types.h"'; then
        echo "      [ldpc-prof] nrLDPC_coding_interface.h（include）：已存在，跳过"
    else
        ins_after "$fiface" '^#include "PHY/defs_gNB.h"$' \
            '// 【OAI-LDPC-PROF】本文件用到 t_nrLDPC_time_stats。与 defs_gNB.h 存在循环 include，' \
            '// 故显式包含，保证该类型在任何包含顺序下都可见。' \
            '#include "PHY/CODING/nrLDPC_decoder/nrLDPC_types.h"' || return 1
    fi

    # ③b 段参数加「指针」（★ 不能内嵌 528 字节）
    if has "$fiface" 't_nrLDPC_time_stats *ldpc_detail;'; then
        echo "      [ldpc-prof] nrLDPC_coding_interface.h（字段）：已存在，跳过"
    else
        ins_before "$fiface" '^} nrLDPC_segment_decoding_parameters_t;$' \
            '  /// 【OAI-LDPC-PROF】指向"LDPC 译码内部细分统计"的存储槽（cnProc/bnProc/total 等 11 项）' \
            '  /// ★ 这里用「指针」而不是内嵌结构体：本结构体 gNB/UE 共用，UE 侧是栈上变长数组' \
            '  ///   （segments[nb_dlsch][max_num_segments]），内嵌 528 字节会撑大该数组并踩坏相邻' \
            '  ///   的调度参数（实测导致 UE 断言崩溃）。用指针只增 8 字节；为 NULL 时表示不采集。' \
            '  t_nrLDPC_time_stats *ldpc_detail;' || return 1
    fi

    # ④a 任务参数加指针
    if has "$fseg" 't_nrLDPC_time_stats *p_ldpc_detail;'; then
        echo "      [ldpc-prof] segment_decoder.c（字段）：已存在，跳过"
    else
        ins_before "$fseg" '^} nrLDPC_decoding_parameters_t;$' \
            '  /// 【OAI-LDPC-PROF】指向本 segment 的细分统计存储槽（由 prepare 阶段接线；可为 NULL）' \
            '  t_nrLDPC_time_stats *p_ldpc_detail;' || return 1
    fi

    # ④b 把「收集到局部变量」改成「写进所属 segment 的存储槽」
    if has "$fseg" 'p_procTime = rdata->p_ldpc_detail'; then
        echo "      [ldpc-prof] segment_decoder.c（收集）：已存在，跳过"
    else
        ins_before "$fseg" '^  t_nrLDPC_time_stats procTime = \{0\};$' \
            '  // 【OAI-LDPC-PROF】原本用局部变量收集细分计时，函数返回即丢弃，数据永远看不到。' \
            '  // 现改为写入「所属 segment 的存储槽」——每 segment 只被一个线程写，无竞态。' \
            '  // 若未接线（p_ldpc_detail == NULL，例如 UE 侧），退回局部变量：不影响功能，只是不采集。' || return 1
        sub_line "$fseg" '^  t_nrLDPC_time_stats procTime = \{0\};$' \
            '  t_nrLDPC_time_stats procTime_fallback = {0};' || return 1
        sub_line "$fseg" '^  t_nrLDPC_time_stats \*p_procTime = &procTime;$' \
            '  t_nrLDPC_time_stats *p_procTime = rdata->p_ldpc_detail ? rdata->p_ldpc_detail : &procTime_fallback;' || return 1
    fi

    # ④c 接线（取「指针值」，不是取地址）
    if has "$fseg" 'rdata->p_ldpc_detail = nrLDPC_TB_decoding_parameters'; then
        echo "      [ldpc-prof] segment_decoder.c（接线）：已存在，跳过"
    else
        ins_after "$fseg" '^    rdata->p_ts_ldpc_decode = &nrLDPC_TB_decoding_parameters->segments\[r\]\.ts_ldpc_decode;$' \
            '    // 【OAI-LDPC-PROF】接线：这里取的是「指针值」——存储由调用者（gNB）分配；' \
            '    // 为 NULL 时该 segment 不采集细分数据（UE 侧即走此路径，零开销）' \
            '    rdata->p_ldpc_detail = nrLDPC_TB_decoding_parameters->segments[r].ldpc_detail;' || return 1
    fi

    # ⑤ gNB 级汇总字段
    if has "$fgnbdef" 't_nrLDPC_time_stats ldpc_detail;'; then
        echo "      [ldpc-prof] defs_gNB.h：已存在，跳过"
    else
        ins_after "$fgnbdef" '^  time_stats_t ts_ldpc_decode;$' \
            '  /// 【OAI-LDPC-PROF】LDPC 译码内部细分统计的 gNB 级汇总' \
            '  /// （cnProc / bnProc / 缓冲转换 / total 等 11 项，由 nr_ulsch_decoding.c 逐码块合并而来）' \
            '  t_nrLDPC_time_stats ldpc_detail;' || return 1
    fi

    # ⑥a 静态存储（★ 不能在栈上）
    if has "$fulsch" 'static t_nrLDPC_time_stats ldpc_detail_store'; then
        echo "      [ldpc-prof] nr_ulsch_decoding.c（存储）：已存在，跳过"
    else
        ins_after "$fulsch" '^  memset\(segments, 0, sizeof\(segments\)\);$' \
            '' \
            '  // 【OAI-LDPC-PROF】LDPC 译码细分统计的存储槽。' \
            '  // ★ 用 static（不在栈上）：上面 segments[] 是栈上变长数组，若把 528 字节的统计内嵌进去' \
            '  //   会大幅撑大 VLA —— UE 侧正是因此崩溃。这里改为「结构体里只放指针 + 存储单独放」。' \
            '  // ★ 用 static 是安全的：本函数由 L1 RX 线程串行调用（每个 slot 一次），无并发写。' \
            '  #define OAI_LDPC_DETAIL_MAX_PUSCH 8' \
            '  #define OAI_LDPC_DETAIL_MAX_SEG   32' \
            '  static t_nrLDPC_time_stats ldpc_detail_store[OAI_LDPC_DETAIL_MAX_PUSCH][OAI_LDPC_DETAIL_MAX_SEG];' || return 1
    fi

    # ⑥b 逐码块分配存储槽
    if has "$fulsch" 'segment_parameters->ldpc_detail = &ldpc_detail_store'; then
        echo "      [ldpc-prof] nr_ulsch_decoding.c（分配）：已存在，跳过"
    else
        ins_after "$fulsch" '^      reset_meas\(&segment_parameters->ts_ldpc_decode\);$' \
            '      // 【OAI-LDPC-PROF】分配并清零本码块的细分统计槽；越界则不采集（不影响功能）' \
            '      if (pusch_id < OAI_LDPC_DETAIL_MAX_PUSCH && r < OAI_LDPC_DETAIL_MAX_SEG) {' \
            '        segment_parameters->ldpc_detail = &ldpc_detail_store[pusch_id][r];' \
            '        memset(segment_parameters->ldpc_detail, 0, sizeof(t_nrLDPC_time_stats));' \
            '      } else {' \
            '        segment_parameters->ldpc_detail = NULL;' \
            '      }' || return 1
    fi

    # ⑥c 合并到 gNB 级汇总
    if has "$fulsch" 'merge_ldpc_detail_stats(&phy_vars_gNB->ldpc_detail'; then
        echo "      [ldpc-prof] nr_ulsch_decoding.c（合并）：已存在，跳过"
    else
        ins_after "$fulsch" '^      merge_meas\(&phy_vars_gNB->ts_ldpc_decode, &nrLDPC_segment_decoding_parameters\.ts_ldpc_decode\);$' \
            '      // 【OAI-LDPC-PROF】把本码块的 11 项细分统计合并到 gNB 级汇总' \
            '      if (nrLDPC_segment_decoding_parameters.ldpc_detail)' \
            '        merge_ldpc_detail_stats(&phy_vars_gNB->ldpc_detail, nrLDPC_segment_decoding_parameters.ldpc_detail);' || return 1
    fi

    # ⑦ 打印 11 行
    if has "$fgnb" '"UL LDPC total"'; then
        echo "      [ldpc-prof] nr-gnb.c：已存在，跳过"
    else
        ins_after "$fgnb" 'print_meas_log\(&gNB->ts_ldpc_decode, "UL segments decoding"' \
            '  // 【OAI-LDPC-PROF】"UL segments decoding" 的内部细分（11 项）：' \
            '  //   输入装载 → 迭代主体(cnProc/bnProc) → 缓冲转换 → 输出 → total' \
            '  //   ★ cnProc/bnProc 每轮迭代计一次，故 calls ÷ (UL segments decoding).calls ≈ 平均迭代轮数' \
            '  output += print_meas_log(&gNB->ldpc_detail.llr2llrProcBuf, "UL LDPC llr2llrProcBuf", NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->ldpc_detail.llr2CnProcBuf,  "UL LDPC llr2CnProcBuf",  NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->ldpc_detail.cnProc,         "UL LDPC cnProc",         NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->ldpc_detail.cnProcPc,       "UL LDPC cnProcPc",       NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->ldpc_detail.bnProcPc,       "UL LDPC bnProcPc",       NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->ldpc_detail.bnProc,         "UL LDPC bnProc",         NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->ldpc_detail.cn2bnProcBuf,   "UL LDPC cn2bnProcBuf",   NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->ldpc_detail.bn2cnProcBuf,   "UL LDPC bn2cnProcBuf",   NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->ldpc_detail.llrRes2llrOut,  "UL LDPC llrRes2llrOut",  NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->ldpc_detail.llr2bit,        "UL LDPC llr2bit",        NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->ldpc_detail.total,          "UL LDPC total",          NULL, NULL, output, end - output);' || return 1
    fi
}

# ---- ⑤ DLSCH 编码细分（dlsch-enc）------------------------------------------
# 2026-09-12 加的（进度表 §11 + 后续）；run23 实测 parity 占 encoding 61.4%
# ★ 最轻的预设：字段/计时代码/指针链 OAI 原生全通，只缺 dump 里的 6 行打印
preset_dlsch_enc() {
    local root="$1"
    local fgnb="$root/$F_GNB_REL"

    if has "$fgnb" '"DLSCH segmentation"'; then
        echo "      [dlsch-enc] nr-gnb.c：已存在，跳过"
    else
        ins_after "$fgnb" 'print_meas_log\(&gNB->dlsch_encoding_stats, "DLSCH encoding"' \
            '  output += print_meas_log(&gNB->dlsch_segmentation_stats,   "DLSCH segmentation",   NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->tinput,  "LDPC enc input",  NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->tparity, "LDPC enc parity", NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->toutput, "LDPC enc output", NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->dlsch_rate_matching_stats,  "DLSCH rate matching",  NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->dlsch_interleaving_stats,   "DLSCH interleaving",   NULL, NULL, output, end - output);' || return 1
    fi
}

# ---- ⑥ PUSCH inner-receiver 原生子计时打印（pusch-native）-----------------
# 四个 time_stats_t 字段及 start/stop 测量点均为 OAI 原生代码；这里只补打印与清零。
# antenna processing 嵌套在 channel estimation 中，统计结果不能直接相加。
preset_pusch_native() {
    local root="$1" fgnb="$root/$F_GNB_REL"
    if has "$fgnb" '"PUSCH channel estimation"'; then
        echo "      [pusch-native] nr-gnb.c：打印项已存在，跳过"
    else
        ins_after "$fgnb" 'print_meas_log\(&gNB->rx_pusch_stats, "PUSCH inner-receiver"' \
            '  output += print_meas_log(&gNB->ulsch_channel_estimation_stats, "PUSCH channel estimation", NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->pusch_channel_estimation_antenna_processing_stats, "PUSCH channel-estimation antenna processing", NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->rx_pusch_init_stats, "PUSCH initialization", NULL, NULL, output, end - output);' \
            '  output += print_meas_log(&gNB->rx_pusch_symbol_processing_stats, "PUSCH symbol processing", NULL, NULL, output, end - output);' || return 1
    fi
    if has "$fgnb" 'reset_meas(&gNB->ulsch_channel_estimation_stats)'; then
        echo "      [pusch-native] nr-gnb.c：清零项已存在，跳过"
    else
        ins_after "$fgnb" 'reset_meas\(&gNB->rx_pusch_stats\);' \
            '  reset_meas(&gNB->ulsch_channel_estimation_stats);' \
            '  reset_meas(&gNB->pusch_channel_estimation_antenna_processing_stats);' \
            '  reset_meas(&gNB->rx_pusch_init_stats);' \
            '  reset_meas(&gNB->rx_pusch_symbol_processing_stats);' || return 1
    fi
}

# ---- FEP 原生调度计时打印（fep-native）------------------------------------
# 字段与测量点均为 OAI 原生代码；只把四项 wait/wakeup 输出到 nrL1_stats.log。
preset_fep_native() {
    local root="$1" fgnb="$root/$F_GNB_REL"
    if has "$fgnb" '"ofdm_demod wait"'; then
        echo "      [fep-native] RX wait/wakeup 已存在，跳过"
    else
        ins_after "$fgnb" 'print_meas_log\(&ru->ofdm_demod_stats, "feprx"' \
            '    output += print_meas_log(&ru->ofdm_demod_wait_stats, "ofdm_demod wait", NULL, NULL, output, end - output);' \
            '    output += print_meas_log(&ru->ofdm_demod_wakeup_stats, "ofdm_demod wakeup", NULL, NULL, output, end - output);' || return 1
    fi
    if has "$fgnb" '"ofdm_mod wait"'; then
        echo "      [fep-native] TX wait/wakeup 已存在，跳过"
    else
        ins_after "$fgnb" 'print_meas_log\(&ru->ofdm_total_stats,"feptx_total"' \
            '    output += print_meas_log(&ru->ofdm_mod_wait_stats, "ofdm_mod wait", NULL, NULL, output, end - output);' \
            '    output += print_meas_log(&ru->ofdm_mod_wakeup_stats, "ofdm_mod wakeup", NULL, NULL, output, end - output);' || return 1
    fi
}

run_preset() {
    local p="$1" root="$2"
    case "$p" in
        rx-symbol) preset_rx_symbol "$root" ;;
        tx-symbol) preset_tx_symbol "$root" ;;
        rx-task)   preset_rx_task   "$root" ;;
        pusch-native) preset_pusch_native "$root" ;;
        fep-native) preset_fep_native "$root" ;;
        ldpc-prof) preset_ldpc_prof "$root" ;;
        dlsch-enc) preset_dlsch_enc "$root" ;;
        *) err "未知预设：$p"; return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# 备份 / 回滚
# ---------------------------------------------------------------------------

backup_all() {
    local bdir="$1" root="$2"
    local rel
    for rel in "${TX_FILES[@]}"; do
        mkdir -p "$bdir/$(dirname "$rel")"
        cp -p "$root/$rel" "$bdir/$rel" 2>/dev/null || true
    done
}

rollback_to() {
    local ts="$1"
    local bdir="$BACKUP_ROOT/$ts"
    [ -d "$bdir" ] || { err "找不到备份：$bdir"; return 1; }
    local n=0 rel
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        cp -p "$bdir/$rel" "$OAI_DIR/$rel" && n=$((n+1))
    done < <(cd "$bdir" && find . -type f | sed 's|^\./||')
    ok "已从备份 $ts 恢复 $n 个文件"
    echo "     重新编译：cd $OAI_DIR/cmake_targets/ran_build/build && make -j8 nr-softmodem"
}

# ---------------------------------------------------------------------------
# 子命令
# ---------------------------------------------------------------------------

cmd_list() {
    cat <<EOF

可用的计时器预设：

  1. rx-symbol    RX 单符号 DFT 计时器   →  symbol_dft (RX)          [262.9 µs]
                  ⚠️  需用 if (l == 0) 绕过竞态（l 是循环变量，5 个 worker 会并发）

  2. tx-symbol    TX 单符号 IDFT 计时器  →  symbol_idft (TX)         [267.5 µs]
                  ★ 天然无竞态（aa / first_symbol 都是函数参数）

  3. rx-task      RX 任务级（3 符号）    →  feprx_task (3 symbols)   [773.3 µs]
                  ★ 天然无竞态；补上它才能算出 RX 的调度开销

  4. pusch-native PUSCH 原生 4 项子计时   →  channel estimation/init/symbol processing
                  ★ 只补打印和清零，不向热点路径新增 start_meas/stop_meas

  5. fep-native   FEP 原生调度 4 项       →  RX/TX wait/wakeup
                  ★ 线程调度统计，不能与 FFT/IFFT 算法耗时直接相加

  6. ldpc-prof    LDPC 内部 11 项细分     →  UL LDPC cnProc/bnProc…  [cnProc 占 57%]
                  ★★ 改了 gNB/UE 共用头文件 → 应用后必须同时编译 gNB 和 UE，
                     否则两个二进制结构体布局不一致 → 崩溃（断言/段错误，进度表 §31）
                     用 --apply --build 会自动处理

  7. dlsch-enc    DLSCH 编码细分(6项)    →  seg/enc-parity/rate-match… [parity 占 61%]
                  ★ 最轻的预设：1 文件 6 行 —— 字段与指针链 OAI 原生全通，只缺打印

  另有：--preset all    依次应用以上全部七个

  OAI 源码目录：${OAI_DIR:-（未找到 —— 请用 OAI_DIR=... 或 --oai-dir 指定）}

EOF
}

# 检查一个预设的锚点是否就位
# 返回 0 = 可应用（或已存在），1 = 锚点有问题
check_preset() {
    local p="$1"
    local fdef="$OAI_DIR/$F_DEFS_REL" fproc="$OAI_DIR/$F_PROC_REL" fgnb="$OAI_DIR/$F_GNB_REL"
    local rc=0

    chk() {   # chk <tag> <file> <marker> <锚点正则> <说明>
        local tag="$1" f="$2" mk="$3" pat="$4" desc="$5"
        if has "$f" "$mk"; then
            info "$tag $desc：${D}已存在${N}"
        elif grep -qE "$pat" "$f"; then
            ok   "$tag $desc：可插入"
        else
            err  "$tag $desc：锚点缺失 → /$pat/"
            rc=1
        fi
    }

    case "$p" in
      rx-symbol)
        chk "[rx-symbol]" "$fdef"  "time_stats_t symbol_dft_stats;"  '^  time_stats_t ofdm_demod_stats;$'      "defs_RU.h"
        chk "[rx-symbol]" "$fproc" "start_meas(&ru->symbol_dft_stats)" '^  for \(int l = startSymbol; l <= endSymbol; l\+\+\) *$' "nr_ru_procedures.c"
        chk "[rx-symbol]" "$fgnb"  '"symbol_dft (RX)"'                'ofdm_demod_stats, "feprx"'               "nr-gnb.c"
        ;;
      tx-symbol)
        chk "[tx-symbol]" "$fdef"  "time_stats_t symbol_idft_stats;" "time_stats_t ofdm_mod_stats;"            "defs_RU.h"
        chk "[tx-symbol]" "$fproc" "start_meas(&ru->symbol_idft_stats)" 'case where first symbol in slot has longer prefix' "nr_ru_procedures.c"
        chk "[tx-symbol]" "$fgnb"  '"symbol_idft (TX)"'               'txdataF_copy_stats, "txdataF_copy"'      "nr-gnb.c"
        ;;
      rx-task)
        chk "[rx-task]" "$fdef"  "time_stats_t feprx_task_stats;"  '^  time_stats_t ofdm_demod_stats;$'          "defs_RU.h"
        chk "[rx-task]" "$fproc" "start_meas(&ru->feprx_task_stats)" 'slot % RU_RX_SLOT_DEPTH'                  "nr_ru_procedures.c"
        chk "[rx-task]" "$fgnb"  '"feprx_task (3 symbols)"'          'ofdm_demod_stats, "feprx"'                 "nr-gnb.c"
        ;;
      pusch-native)
        chk "[pusch-native]" "$fgnb" '"PUSCH channel estimation"' 'print_meas_log\(&gNB->rx_pusch_stats, "PUSCH inner-receiver"' "nr-gnb.c（打印）"
        chk "[pusch-native]" "$fgnb" 'reset_meas(&gNB->ulsch_channel_estimation_stats)' 'reset_meas\(&gNB->rx_pusch_stats\);' "nr-gnb.c（清零）"
        ;;
      fep-native)
        chk "[fep-native]" "$fgnb" '"ofdm_demod wait"' 'print_meas_log\(&ru->ofdm_demod_stats, "feprx"' "nr-gnb.c（RX）"
        chk "[fep-native]" "$fgnb" '"ofdm_mod wait"' 'print_meas_log\(&ru->ofdm_total_stats,"feptx_total"' "nr-gnb.c（TX）"
        ;;
        ldpc-prof)
          chk "[ldpc-prof]" "$OAI_DIR/$F_LDPC_DEC_REL"   "【OAI-LDPC-PROF】原为「空定义」"                       '^//#define NR_LDPC_PROFILER_DETAIL\(a\) a$'            "nrLDPC_decoder.c（宏）"
          chk "[ldpc-prof]" "$OAI_DIR/$F_LDPC_TYPES_REL" "merge_ldpc_detail_stats(t_nrLDPC_time_stats *dst"      '^} t_nrLDPC_time_stats;$'                              "nrLDPC_types.h"
          chk "[ldpc-prof]" "$OAI_DIR/$F_LDPC_IFACE_REL" 'PHY/CODING/nrLDPC_decoder/nrLDPC_types.h"'             '^#include "PHY/defs_gNB.h"$'                          "iface.h（include）"
          chk "[ldpc-prof]" "$OAI_DIR/$F_LDPC_IFACE_REL" 't_nrLDPC_time_stats \*ldpc_detail;'                   '^} nrLDPC_segment_decoding_parameters_t;$'             "iface.h（字段）"
          chk "[ldpc-prof]" "$OAI_DIR/$F_LDPC_SEG_REL"   't_nrLDPC_time_stats \*p_ldpc_detail;'                 '^} nrLDPC_decoding_parameters_t;$'                    "seg_dec.c（字段）"
          chk "[ldpc-prof]" "$OAI_DIR/$F_LDPC_SEG_REL"   'p_procTime = rdata->p_ldpc_detail'                     '^  t_nrLDPC_time_stats procTime = \{0\};$'           "seg_dec.c（收集）"
          chk "[ldpc-prof]" "$OAI_DIR/$F_LDPC_SEG_REL"   'rdata->p_ldpc_detail = nrLDPC_TB_decoding_parameters'  'p_ts_ldpc_decode = &nrLDPC_TB_decoding_parameters'     "seg_dec.c（接线）"
          chk "[ldpc-prof]" "$OAI_DIR/$F_DEFS_GNB_REL"   't_nrLDPC_time_stats ldpc_detail;'                      '^  time_stats_t ts_ldpc_decode;$'                     "defs_gNB.h"
          chk "[ldpc-prof]" "$OAI_DIR/$F_ULSCH_REL"      'static t_nrLDPC_time_stats ldpc_detail_store'          '^  memset\(segments, 0, sizeof\(segments\)\);$'    "ulsch.c（存储）"
          chk "[ldpc-prof]" "$OAI_DIR/$F_ULSCH_REL"      'segment_parameters->ldpc_detail = &ldpc_detail_store'  'reset_meas\(&segment_parameters->ts_ldpc_decode\);'  "ulsch.c（分配）"
          chk "[ldpc-prof]" "$OAI_DIR/$F_ULSCH_REL"      'merge_ldpc_detail_stats\(&phy_vars_gNB->ldpc_detail'  'merge_meas\(&phy_vars_gNB->ts_ldpc_decode'           "ulsch.c（合并）"
          chk "[ldpc-prof]" "$fgnb"                      '"UL LDPC total"'                                       'ts_ldpc_decode, "UL segments decoding"'               "nr-gnb.c"
          ;;
        dlsch-enc)
          chk "[dlsch-enc]" "$fgnb" '"DLSCH segmentation"' 'print_meas_log\(&gNB->dlsch_encoding_stats, "DLSCH encoding"' "nr-gnb.c"
          ;;
    esac
    return $rc
}

cmd_check() {
    local presets="$1" rc=0 p
    echo
    echo "检查源码匹配情况（OAI 目录：$OAI_DIR）"
    echo
    for p in $presets; do
        check_preset "$p" || rc=1
    done
    echo
    if [ "$rc" -eq 0 ]; then
        ok "检查通过 —— 锚点就位，可以安全执行 --apply"
    else
        err "检查未通过 —— 请勿使用 --apply"
    fi
    echo
    return $rc
}

cmd_verify() {
    local fdef="$OAI_DIR/$F_DEFS_REL" fproc="$OAI_DIR/$F_PROC_REL" fgnb="$OAI_DIR/$F_GNB_REL"
    echo
    echo "当前源码里的计时器状态（OAI 目录：$OAI_DIR）"
    echo
    local one
    one() {   # one <name> <desc> <m1> <m2> <m3>
        local name="$1" desc="$2" m1="$3" m2="$4" m3="$5"
        local d=0
        has "$fdef"  "$m1" && d=$((d+1))
        has "$fproc" "$m2" && d=$((d+1))
        has "$fgnb"  "$m3" && d=$((d+1))
        local s
        if   [ "$d" -eq 3 ]; then s="${G}✅ 全部添加（3/3）${N}"
        elif [ "$d" -eq 0 ]; then s="${R}❌ 未添加（0/3）${N}"
        else                      s="${Y}⚠️  部分（$d/3）${N}"; fi
        echo "  ── $name"
        echo "     $desc"
        echo "     状态：$s"
        printf '     明细：%s defs_RU.h   %s nr_ru_procedures.c   %s nr-gnb.c\n' \
            "$(has "$fdef"  "$m1" && echo ✅ || echo ❌)" \
            "$(has "$fproc" "$m2" && echo ✅ || echo ❌)" \
            "$(has "$fgnb"  "$m3" && echo ✅ || echo ❌)"
        echo
    }
    one rx-symbol "RX 单符号 DFT"     "time_stats_t symbol_dft_stats;"  "start_meas(&ru->symbol_dft_stats)"  '"symbol_dft (RX)"'
    one tx-symbol "TX 单符号 IDFT"    "time_stats_t symbol_idft_stats;" "start_meas(&ru->symbol_idft_stats)" '"symbol_idft (TX)"'
    one rx-task   "RX 任务级（3 符号）" "time_stats_t feprx_task_stats;" "start_meas(&ru->feprx_task_stats)"  '"feprx_task (3 symbols)"'

      # ldpc-prof：7 文件 → 逐文件检查（每文件一个代表性 marker）
      local -a LDPC_CHK=(
        "$OAI_DIR/$F_LDPC_DEC_REL|【OAI-LDPC-PROF】原为「空定义」|nrLDPC_decoder.c"
        "$OAI_DIR/$F_LDPC_TYPES_REL|merge_ldpc_detail_stats(t_nrLDPC_time_stats *dst|nrLDPC_types.h"
        "$OAI_DIR/$F_LDPC_IFACE_REL|t_nrLDPC_time_stats *ldpc_detail;|nrLDPC_coding_interface.h"
        "$OAI_DIR/$F_LDPC_SEG_REL|p_procTime = rdata->p_ldpc_detail|nrLDPC_coding_segment_decoder.c"
        "$OAI_DIR/$F_DEFS_GNB_REL|t_nrLDPC_time_stats ldpc_detail;|defs_gNB.h"
        "$OAI_DIR/$F_ULSCH_REL|static t_nrLDPC_time_stats ldpc_detail_store|nr_ulsch_decoding.c"
        "$OAI_DIR/$F_GNB_REL|\"UL LDPC total\"|nr-gnb.c"
      )
      local hit=0 detail="" entry ff mm nn
      for entry in "${LDPC_CHK[@]}"; do
          ff="${entry%%|*}"; mm="${entry#*|}"; nn="${mm##*|}"; mm="${mm%|*}"
          if has "$ff" "$mm"; then hit=$((hit+1)); detail="$detail ✅ $nn"
          else                    detail="$detail ❌ $nn"; fi
      done
      local ls
      if   [ "$hit" -eq 7 ]; then ls="${G}✅ 全部添加（7/7 文件）${N}"
      elif [ "$hit" -eq 0 ]; then ls="${R}❌ 未添加（0/7 文件）${N}"
      else                        ls="${Y}⚠️  部分（$hit/7 文件）${N}"; fi
      echo "  ── ldpc-prof"
      echo "     LDPC 译码内部 11 项细分"
      echo "     状态：$ls"
      echo "     明细：$detail"
      echo

      # dlsch-enc：1 文件 6 行
      if has "$fgnb" '"DLSCH segmentation"' && has "$fgnb" '"DLSCH rate matching"'; then
          echo "  ── dlsch-enc"
          echo "     DLSCH 编码细分（6 项）"
          echo "     状态：${G}✅ 已添加（1/1 文件）${N}"
          echo "     明细：✅ nr-gnb.c"
      else
          echo "  ── dlsch-enc"
          echo "     DLSCH 编码细分（6 项）"
          echo "     状态：${R}❌ 未添加${N}"
          echo "     明细：❌ nr-gnb.c"
      fi
      echo
    echo "  跑一轮实验即可看数据："
    echo "     cd ~/sionna-rk && ./scripts/run-k3-hotspot-experiment.sh ideal 1 <新编号>"
    echo
}

cmd_apply() {
    local presets="$1"

    echo
    if [ "$DO_APPLY" -eq 0 ]; then
        echo "──────────────────────────────────────────────────────────────────────"
        echo "  DRY-RUN 模式 —— 只预览，不会改动任何文件"
        echo "  确认无误后加 ${C}--apply${N} 真正执行"
        echo "──────────────────────────────────────────────────────────────────────"
        echo
        echo "  将对以下 3 个文件做修改（OAI 目录：$OAI_DIR）"
        echo
        local p
        for p in $presets; do
            echo "  ${C}[$p]${N}"
            check_preset "$p" || { echo; err "锚点检查未通过，请先修好再应用"; return 1; }
            echo
        done
        echo "  ⇒ 用 ${C}--check${N} 可看到逐文件的匹配详情。"
        echo "  ⇒ 确认后执行： $0 --preset $(echo "$presets" | tr ' ' ',') --apply"
        echo
        return 0
    fi

    # ── 真正应用 ──
    TS="$(date +%Y%m%d-%H%M%S)"
    local bdir="$BACKUP_ROOT/$TS"
    mkdir -p "$bdir"

    echo "开始应用（OAI 目录：$OAI_DIR）"
    echo
    backup_all "$bdir" "$OAI_DIR"
    local nbf; nbf=$(find "$bdir" -type f 2>/dev/null | wc -l)
    ok "已备份 $nbf 个文件 → $bdir"
    echo

    local p
    for p in $presets; do
        echo "  ${C}[$p]${N}"
        if ! run_preset "$p" "$OAI_DIR"; then
            echo
            err "预设 $p 失败 —— 正在恢复…"
            rollback_to "$TS"
            die "已恢复到改动前的状态。"
        fi
        echo
    done

    ok "应用完成"
    echo "     备份：$bdir"
    echo "     回滚：$0 --rollback $TS"
    echo

    if [ "$DO_BUILD" -eq 1 ]; then
        case "$presets" in
            *ldpc-prof*) do_build 1 ;;   # 改了共用头文件 → 必须连 UE 一起编
            *)           do_build 0 ;;
        esac
    fi
}

do_build() {
    # $1 = "1" → 同时编 nr-uesoftmodem
    #   ⚠️ 只要改了「gNB 和 UE 共用」的头文件/结构体（如 ldpc-prof 预设改的
    #      nrLDPC_coding_interface.h / nrLDPC_types.h），就**必须**一起编两个二进制，
    #      否则二者结构体布局不一致 → 运行期崩溃，症状与 LDPC 看似无关（进度表 §31）。
    local with_ue="${1:-0}"
    local bdir="$OAI_DIR/cmake_targets/ran_build/build"
    [ -d "$bdir" ] || { warn "构建目录不存在，跳过编译：$bdir"; return 1; }
    local jobs; jobs=$(nproc 2>/dev/null || echo 4)
    # RFsim experiments also require the runtime plugin.  Building only the
    # executables can leave a valid gNB binary that exits at startup because
    # librfsimulator.so is absent from the build directory.
    local targets="nr-softmodem rfsimulator"
    [ "$with_ue" = "1" ] && targets="nr-softmodem nr-uesoftmodem rfsimulator"
    echo "开始编译（make -j${jobs} ${targets}）…"
    if [ "$with_ue" = "1" ]; then
        echo "     ⚠️  本次同时编译 gNB + UE —— 因为改动了共用头文件，两者必须一起更新，"
        echo "        否则运行期会崩溃（详情见进度表 §31）"
    fi
    echo
    ( cd "$bdir" && make "-j${jobs}" $targets 2>&1 | tail -10 )
    echo
    local b
    for b in $targets; do
        [ -f "$bdir/$b" ] && ok "$b  sha256[:16] = $(sha256sum "$bdir/$b" | cut -c1-16)"
    done
    echo "     ⚠️  记录这些 sha：与旧数据不可直接比较"
    echo
}

cmd_rollback() {
    [ -d "$BACKUP_ROOT" ] || die "没有备份目录：$BACKUP_ROOT"

    if [ -z "$RB_TS" ]; then
        echo
        echo "可用的备份（最新在前）："
        echo
        local d n
        for d in $(ls -1 "$BACKUP_ROOT" | sort -r); do
            n=$(find "$BACKUP_ROOT/$d" -type f 2>/dev/null | wc -l)
            echo "  $d   （$n 个文件）"
        done
        echo
        echo "用法：$0 --rollback <时间戳>"
        echo
        return 0
    fi

    rollback_to "$RB_TS" || die "回滚失败"
}

usage() {
    awk 'NR>2 && /^#/ { sub(/^# ?/, ""); print; next } NR>2 { exit }' "$0"
}

find_oai_dir() {
    local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local c
    for c in \
        "$here/../ext/openairinterface5g" \
        "$here/ext/openairinterface5g" \
        "$here/openairinterface5g" \
        "$HOME/sionna-rk/ext/openairinterface5g" \
        "$HOME/openairinterface5g"
    do
        [ -d "$c/openair1" ] && { (cd "$c" && pwd); return 0; }
    done
    return 1
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

ACTION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --list)       ACTION="list" ;;
        --check)      ACTION="check" ;;
        --verify)     ACTION="verify" ;;
        --apply)      DO_APPLY=1 ;;
        --build)      DO_BUILD=1 ;;
        --preset)     shift; PRESET="${1:-}" ;;
        --preset=*)   PRESET="${1#*=}" ;;
        --rollback)   ACTION="rollback" ;;
        --rollback=*) ACTION="rollback"; RB_TS="${1#*=}" ;;
        --oai-dir)    shift; OAI_DIR="${1:-}" ;;
        --oai-dir=*)  OAI_DIR="${1#*=}" ;;
        -h|--help)    usage; exit 0 ;;
        -*)           die "未知参数：$1（用 --help 看用法）" ;;
        *)            RB_TS="$1" ;;
    esac
    shift
done

if [ -z "$ACTION" ] && [ -z "$PRESET" ]; then
    usage; echo; exit 0
fi

# 定位 OAI 目录
if [ -n "$OAI_DIR" ]; then
    [ -d "$OAI_DIR/openair1" ] || die "指定的 OAI 目录不合法（找不到 openair1/）：$OAI_DIR"
    OAI_DIR="$(cd "$OAI_DIR" && pwd)"
else
    OAI_DIR="$(find_oai_dir)" || die "无法自动定位 OAI 源码目录。
     请用 --oai-dir 指定，例如：
       $0 --oai-dir ~/sionna-rk/ext/openairinterface5g --list"
fi

case "$ACTION" in
    list)     cmd_list ;;
    verify)   cmd_verify ;;
    rollback) cmd_rollback ;;
    check)
        if [ -z "$PRESET" ] || [ "$PRESET" = "all" ]; then
            cmd_check "rx-symbol tx-symbol rx-task pusch-native fep-native ldpc-prof dlsch-enc"
        else
            cmd_check "$PRESET"
        fi
        ;;
    "")
        case "$PRESET" in
            all)       cmd_apply "rx-symbol tx-symbol rx-task pusch-native fep-native ldpc-prof dlsch-enc" ;;
            rx-symbol|tx-symbol|rx-task|pusch-native|fep-native|ldpc-prof|dlsch-enc) cmd_apply "$PRESET" ;;
            *) die "未知预设：$PRESET（可用：rx-symbol / tx-symbol / rx-task / pusch-native / fep-native / ldpc-prof / dlsch-enc / all）" ;;
        esac
        ;;
esac
ADD_OAI_TIMER_SCRIPT

chmod 0755 add-oai-timer.sh
```

必须保留带单引号的 `<<'ADD_OAI_TIMER_SCRIPT'`，避免当前 Shell 提前展开脚本中的变量。

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

```latex
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
