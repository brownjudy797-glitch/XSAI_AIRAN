<!-- SPDX-License-Identifier: Apache-2.0 -->
> 与当前 K3 比较请使用 [统一快照复现流程](../reproduction/README.md)，并在 ARM64 上单独验收。本页保留旧 `207aac9` 路线，不能与现场 `c6698f7` 混合比较。

# 在 ARM64 Ubuntu 上复现 OAI RFsim 模块热点时间实验

本教程已整理为仓库下载版（2026-10-29）：保留原操作步骤，补丁和长脚本统一按版本分发、下载时检查 SHA256。
[返回教程入口](../README.md) · [工具来源与版本](../assets/20261029/README.md)
语法、补丁应用与失败停止逻辑已在本地检查；平台编译、射频、核心网和性能结果仍需在对应设备现场验证。

本文用于在一台 ARM64（`aarch64`）Ubuntu计算机上复现与 K3相同的 OAI 5G NR RFsim  
热点时间实验。本文只运行 CPU版 OAI，不启动 Docker、5G核心网、RIC或  
NVIDIA插件。

> 本文是 ARM64专用指导。不要执行 K3指导中的 RV64移植补丁和  
`configure-system.k3.sh`。
>

## 实验固定条件
```text
模式：OAI原生gNB + nrUE
射频：RFsim
协议模式：--phy-test --noS1

频段：n78
带宽：106 PRB
numerology：1（30 kHz）
中心频率：3319680000 Hz
预热：20秒
测量：120秒
场景：理想信道、AWGN
每个场景：5轮
```

ARM64与 K3使用相同 OAI提交、无线参数、运行顺序和统计方法。两端采用各自  
架构的原生编译优化，因此结果表示“各平台正常CPU实现的性能”，不是相同  
机器指令之间的比较。

## 第1步：检查 ARM64计算机
以下命令都在 ARM64 Ubuntu终端中执行：

```bash
uname -m
nproc
lscpu | grep -E 'Model name|Socket|Core|Thread|NUMA'
```

`uname -m` 必须输出：

```text
aarch64
```

建议至少具有8个逻辑 CPU和16 GB内存。查看 CPU编号：

```bash
lscpu -e=CPU,CORE,SOCKET,NODE,ONLINE
```

普通 ARM64 机器可先使用 CPU 0–7。如果机器不足8个逻辑 CPU，或 CPU 0–7  
跨越多个 NUMA 节点、性能簇或效率簇，应通过 `CPU_SET` 选择同一类型的核心。

### DGX Spark 的绑核与频率
DGX Spark 是异构 CPU，不能直接把 CPU 0–7 当成8个 Cortex-A725。先执行：

```bash
lscpu -e=CPU,CORE,MAXMHZ,MINMHZ,MHZ
```

在本次验证使用的 DGX Spark 上，最高频率为 2808 MHz 的逻辑 CPU 是 A725，  
最高频率为 3900 MHz 的逻辑 CPU 是 X925；对应关系为：

```text
A725：CPU 0–4、10–14
X925：CPU 5–9、15–19
```

本实验从 A725 中选择8个逻辑 CPU：

```text
CPU_SET=0-4,10-12
```

不同固件的 CPU 编号可能不同，必须以本机 `lscpu -e` 输出为准，不要直接照搬  
上述编号。需要复现本文的 DGX Spark 频率条件时，把选中的8个 A725 临时固定为  
2.15 GHz：

```bash
for c in 0 1 2 3 4 10 11 12; do
  echo 2150000 | sudo tee /sys/devices/system/cpu/cpu$c/cpufreq/scaling_max_freq >/dev/null
  echo 2150000 | sudo tee /sys/devices/system/cpu/cpu$c/cpufreq/scaling_min_freq >/dev/null
done
```

验证8个核心的最低、最高和当前频率：

```bash
for c in 0 1 2 3 4 10 11 12; do
  printf 'CPU %s: min=%s max=%s current=%s\n' "$c" \
    "$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_min_freq)" \
    "$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_max_freq)" \
    "$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq)"
done
```

三项都应为 `2150000` 或非常接近。该设置通常在重启后失效；每批实验开始前都要  
重新验证。其他 ARM64 处理器不应使用这组 DGX Spark 专用编号。

## 第2步：下载并固定 Sionna-RK版本
```bash
(
set -e
sudo apt update
sudo apt install -y git curl ca-certificates
test ! -e "$HOME/sionna-rk" || {
    echo "已有 sionna-rk 目录，请先检查版本和本地修改，再决定复用或新建实验目录。"
    exit 1
}
cd "$HOME"
git clone --recurse-submodules https://github.com/NVlabs/sionna-rk.git
cd "$HOME/sionna-rk"

git checkout 0abdce3
git switch -c arm64-hotspot-baseline
git submodule update --init --recursive
)
```

如果分支已经存在：

```bash
git switch arm64-hotspot-baseline
```

这里不应用 K3 RV64补丁。

## 第3步：准备相同版本的 OAI源码
使用 **【官方仓库】** 的 `quickstart-oai.sh` 准备 Sionna-RK指定的 OAI源码，  
但暂时不构建 Docker镜像：

```bash
cd "$HOME/sionna-rk"

./scripts/quickstart-oai.sh \
  --no-build \
  --source "$HOME/sionna-rk" \
  --dest "$HOME/sionna-rk/ext/openairinterface5g"
```

仅在新的 OAI 目录执行准备步骤；本版去掉了 `--clean`。已有源码时先记录 `git status`，不要通过清理或强制重置重做安装。

确认 OAI提交：

```bash
git -C ext/openairinterface5g rev-parse HEAD
```

用于与 K3对比时，应为：

```text
207aac94d13e714abac8062ebf869805f2acd6dc
```

如果提交不同，先停止，不要生成跨版本对比数据。

Sionna-RK补丁会让OAI从 `plugins` 子目录加载插件。确认该目录指向仓库顶层的  
插件目录；如果缺失，按官方 `quickstart-oai.sh` 的方式补建符号链接：

```bash
test -e "$HOME/sionna-rk/ext/openairinterface5g/plugins" || ln -s "$HOME/sionna-rk/plugins" "$HOME/sionna-rk/ext/openairinterface5g/plugins"
```

检查：

```bash
readlink -f "$HOME/sionna-rk/ext/openairinterface5g/plugins"
```

### ARM64 CPU-only插件链接补丁
Sionna-RK原插件构建文件在 `ENABLE_CUDA=OFF` 时不编译神经接收机和CUDA信道  
仿真，但OAI仍会引用这些插件的入口函数，最终可能出现  
`is_channel_emulation_enabled`、`load_receiver_lib` 等未定义符号。本实验使用  
配套的 **【本实验新增】** `arm64-cpu-only-plugins.patch` 增加无GPU桩函数；  
它只关闭Sionna CUDA/TensorRT插件，不替换OAI传统PHY算法，也不影响RFsim的  
理想/AWGN信道模型。

先按附录 A 下载并校验补丁，再执行以下可重复检查的步骤：

```bash
(
set -e
cd "$HOME/sionna-rk"
patch="$HOME/sionna-rk/arm64-cpu-only-plugins.patch"
if git apply --reverse --check --ignore-space-change "$patch" >/dev/null 2>&1; then
    echo "CPU-only 插件补丁已经完整应用。"
else
    git apply --check --ignore-space-change "$patch"
    git apply --ignore-space-change "$patch"
    git apply --reverse --check --ignore-space-change "$patch"
    echo "CPU-only 插件补丁应用并检查通过。"
fi
)
```

验证：

```bash
grep -nE 'CPU-only plugin|cpu_only_stubs' plugins/CMakeLists.txt
test -f plugins/common/src/cpu_only_stubs.c && echo "CPU-only stubs: OK"
```

## 第4步：原生编译 CPU版 OAI
安装基础工具：

```bash
sudo apt update
sudo apt install -y \
  build-essential cmake ninja-build pkg-config \
  git curl ca-certificates python3 python3-pip python3-venv
```

先运行本节下方带 `-I` 的命令安装 OAI 依赖并完成首次构建，再执行附录 C  
的统一计时脚本流程。该流程会生成 `add-oai-timer.sh`，检查源码锚点、安装  
全部计时项，并重新编译 `nr-softmodem`、`nr-uesoftmodem` 和 RFsim 插件。  
完成附录 C 后回到本节，继续检查编译产物。

首次部署必须先执行以下构建命令。依赖安装和首次构建完成后，再按计时附录检查、应用计时项并重新编译：

```bash
cd "$HOME/sionna-rk/ext/openairinterface5g"

./cmake_targets/build_oai \
  -I \
  -w SIMU \
  --gNB \
  --nrUE \
  --cmake-opt -DASN1C_EXEC=/opt/asn1c/bin/asn1c \
  --cmake-opt -DENABLE_CUDA=OFF
```

`-I` 只用于首次安装依赖。如果设备已经存在  
`/opt/asn1c/bin/asn1c`，或者 `-I` 因访问 GitHub失败而中断，可以去掉 `-I`，  
但必须把 `ASN1C_EXEC` 明确传给 CMake：

```bash
./cmake_targets/build_oai \
  -w SIMU \
  --gNB \
  --nrUE \
  --cmake-opt -DASN1C_EXEC=/opt/asn1c/bin/asn1c \
  --cmake-opt -DENABLE_CUDA=OFF
```

统一脚本会输出与 K3 相同的细粒度字段。`PUSCH channel estimation`、  
`PUSCH channel-estimation antenna processing`、`PUSCH initialization` 和  
`PUSCH symbol processing` 均嵌套在 `PUSCH inner-receiver` 内；LDPC 和 DLSCH  
内部字段也存在父子包含关系，不能与外层项直接相加。

这里使用 RFsim所需的 `SIMU`后端，不构建 USRP支持，也不启用 CUDA。  
ARM64的 NEON/Advanced SIMD能力由编译器和 OAI构建系统根据本机环境处理。

检查产物：

```bash
cd "$HOME/sionna-rk/ext/openairinterface5g/cmake_targets/ran_build/build"

file nr-softmodem nr-uesoftmodem
ldd nr-softmodem | grep 'not found' || true
ldd nr-uesoftmodem | grep 'not found' || true
```

`file` 应显示 `ARM aarch64`，两条 `ldd` 命令不应列出缺失库。

## 第5步：固定实验前状态
确认没有旧 OAI进程：

```bash
pgrep -a nr-softmodem || true
pgrep -a nr-uesoftmodem || true
```

关闭其他高负载程序。记录当前调频策略：

```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true
```

同一批正式实验期间不要改变 BIOS性能设置、CPU调频策略、绑核范围和后台负载。  
DGX Spark 还应再次确认实验核心均为 A725 且频率为 2.15 GHz。

## 第6步：下载自动实验脚本
按照附录 B，在 ARM64 Ubuntu终端中执行下载与校验代码块，安装：

```text
$HOME/sionna-rk/scripts/run-arm64-hotspot-experiment.sh
```

然后检查：

```bash
bash -n "$HOME/sionna-rk/scripts/run-arm64-hotspot-experiment.sh" \
  && echo "脚本语法检查通过"
```

所有结果统一保存在：

```text
$HOME/sionna-rk/results-arm64
```

## 第7步：理解脚本参数
命令格式：

```bash
./scripts/run-arm64-hotspot-experiment.sh 模式 重复次数 起始编号
```

| 参数 | 内容 | 含义 |
| --- | --- | --- |
| 模式 | `ideal` | 只运行理想信道 |
| 模式 | `awgn` | 只运行 AWGN信道 |
| 模式 | `pair` | 每轮依次运行理想和 AWGN |
| 重复次数 | 正整数 | 本次运行几轮，默认1 |
| 起始编号 | 正整数 | 第一轮编号，默认1 |


脚本为保护原始数据，不会覆盖已有结果。若提示 `Result already exists`，  
请把第三个参数改为尚未使用的编号；不要用 `rm -rf results-arm64/*` 清空整批结果。

脚本会先检查并清理后台残留的 gNB/nrUE 进程，然后自动启动 gNB和 nrUE、等待完整同步、预热20秒、保存起点和终点快照、  
计算120秒窗口统计、正常停止进程并归档结果。它也会自动生成 AWGN配置：

```text
$HOME/sionna-rk/config/rfsim/gnb.sa.band78.106prb.awgn.conf
```

## 第8步：先完成第一轮
运行一次理想信道：

```bash
cd "$HOME/sionna-rk"
./scripts/run-arm64-hotspot-experiment.sh ideal 1 1
```

在本文验证的 DGX Spark 上必须显式使用8个 A725：

```bash
CPU_SET=0-4,10-12 ./scripts/run-arm64-hotspot-experiment.sh ideal 1 1
```

检查：

```bash
grep -E 'Initial sync successful|UE synchronized' \
  results-arm64/ideal-run1-nrue.log
ls -lh results-arm64/ideal-run1-*
```

理想信道成功后运行一次 AWGN：

```bash
./scripts/run-arm64-hotspot-experiment.sh awgn 1 1
```

DGX Spark 使用：

```bash
CPU_SET=0-4,10-12 ./scripts/run-arm64-hotspot-experiment.sh awgn 1 1
```

检查：

```bash
grep -E 'Initial sync successful|UE synchronized' \
  results-arm64/awgn-run1-nrue.log

grep -E 'Random channel .* activated' \
  results-arm64/awgn-run1-gnb.log
```

## 第9步：完成第2至第5轮
第一轮两种信道都成功后执行：

```bash
./scripts/run-arm64-hotspot-experiment.sh pair 4 2
```

DGX Spark 使用：

```bash
CPU_SET=0-4,10-12 ./scripts/run-arm64-hotspot-experiment.sh pair 4 2
```

默认顺序：

```text
ideal-2 → AWGN-2 → ideal-3 → AWGN-3 → ideal-4 → AWGN-4 → ideal-5 → AWGN-5
```

默认每次运行之间等待30秒。如果 ARM64散热或睿频变化明显，可以改为60秒：

```bash
COOLDOWN_SECONDS=60 ./scripts/run-arm64-hotspot-experiment.sh pair 4 2
```

DGX Spark 延长冷却时间时使用：

```bash
CPU_SET=0-4,10-12 COOLDOWN_SECONDS=60 ./scripts/run-arm64-hotspot-experiment.sh pair 4 2
```

## 第10步：检查结果
检查10次同步：

```bash
cd "$HOME/sionna-rk"

grep -H -E 'Initial sync successful|UE synchronized' \
  results-arm64/ideal-run*-nrue.log \
  results-arm64/awgn-run*-nrue.log
```

每轮正式比较使用：

| 文件模式 | 内容 |
| --- | --- |
| `ideal-runN-window-stats.csv` | 理想信道严格窗口统计 |
| `awgn-runN-window-stats.csv` | AWGN信道严格窗口统计 |


每轮还会保存 `start-*` 和 `end-*` 两组OAI原始快照。不带快照前缀的  
`nrL1_stats.log` 和 `nrL1_UE_stats-0.log` 是进程退出时的累计统计，用于审计。  
CSV中的 `window_avg_us` 和 `window_calls` 是正式窗口结果；  
`end_cumulative_max_us` 不是窗口最大值。`gnb.log`、`nrue.log` 和  
`metadata.txt` 也必须保留。

以 `ideal-run1` 为例，完整文件说明如下：

| 文件 | 用途 | 正式比较是否直接使用 |
| --- | --- | --- |
| `ideal-run1-gnb.log` | gNB完整运行日志 | 否，用于排错和有效性检查 |
| `ideal-run1-nrue.log` | nrUE完整运行日志和同步证据 | 否，用于排错和有效性检查 |
| `ideal-run1-start-nrL1_stats.log` | 预热结束时的gNB累计统计快照 | 是，作为窗口起点 |
| `ideal-run1-start-nrL1_UE_stats-0.log` | 预热结束时的UE 0累计统计快照 | 是，作为窗口起点 |
| `ideal-run1-end-nrL1_stats.log` | 测量结束时的gNB累计统计快照 | 是，作为窗口终点 |
| `ideal-run1-end-nrL1_UE_stats-0.log` | 测量结束时的UE 0累计统计快照 | 是，作为窗口终点 |
| `ideal-run1-window-stats.csv` | 严格窗口平均耗时和窗口调用次数 | **是，正式分析的主文件** |
| `ideal-run1-nrL1_stats.log` | gNB退出后的整轮累计统计 | 否，用于审计和兼容旧实验 |
| `ideal-run1-nrL1_UE_stats-0.log` | nrUE退出后的整轮累计统计 | 否，用于审计和兼容旧实验 |
| `ideal-run1-metadata.txt` | 平台、版本、配置、时间及二进制哈希 | 是，用于确认跨平台条件一致 |


AWGN实验仅将前缀替换为 `awgn-runN-`，文件含义不变。

### 10.1 gNB 细粒度计时的物理层位置与去重规则
| 物理层位置 | 外层计时 | 直接子项或相关项 | 分析规则 |
| --- | --- | --- | --- |
| RU 接收前端 FEP | `feprx` | `symbol_dft (RX)`、`feprx_task (3 symbols)`、`ofdm_demod wait/wakeup` | DFT、任务和调度项用于解释外层耗时，不与 `feprx` 相加 |
| gNB PUSCH 接收机 | `PUSCH inner-receiver` | 信道估计、初始化、符号处理 | 三类直接子项位于接收机内部；LDPC 不属于该外层 |
| PUSCH 信道估计 | `PUSCH channel estimation` | `PUSCH channel-estimation antenna processing` | 逐天线处理嵌套在信道估计中 |
| gNB ULSCH 译码 | `UL segments decoding` | `UL LDPC total`、`cnProc`、`bnProc`、缓冲准备项 | 速率恢复和解交织是译码前置独立阶段；LDPC 子项只在同层横向比较 |
| gNB DLSCH 编码 | `DLSCH encoding` | 分段、LDPC 编码、速率匹配、交织及编码内部项 | 子项用于定位编码热点，不与父项重复求和 |
| RU 发送前端 | `feptx_ofdm` / `feptx_total` | `symbol_idft (TX)`、`ofdm_mod wait/wakeup` | 单符号 IDFT 和调度项与父计时分开比较 |
| RU 发送预编码/搬运 | 无共同父项用于求和 | `feptx_prec`、`txdataF_copy` | RU 预编码不同于 DLSCH precoding；复制也不是 OFDM 计算 |


正式跨平台排名使用同一层级的 `window_avg_us`。调用次数为 0 的 SRS 或可选路径  
表示本轮业务没有执行该模块，不应填 0 参与平均，也不应从其他计时项推算。

## 第11步：与 K3对比前检查
两台设备必须核对：

```text
OAI提交相同
无线配置相同
预热和测量时间相同
每种场景均为5轮
调用次数接近
AWGN均成功加载
各自二进制哈希有记录
```

ARM64与 K3二进制哈希必然不同，因为架构不同。比较时主要报告：

+ 五轮平均耗时的均值和标准差；
+ ARM64相对 K3的加速比；
+ 每轮调用次数；
+ 最大耗时仅作为实时抖动参考。

不要把所有父子统计项相加，也不要只用单轮最大值判断平台性能。

## 附录 A：下载 ARM64 CPU-only 插件补丁
以下补丁属于 **【本实验新增】**，不属于 NVIDIA Sionna-RK 或 OAI 官方仓库。  
在 Sionna-RK 根目录完整执行以下命令：

```bash
cd "$HOME/sionna-rk"

(
set -e
target="$HOME/sionna-rk/arm64-cpu-only-plugins.patch"
mkdir -p -- "$(dirname "$target")"
tmp=$(mktemp "${target}.download.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
curl -fL --retry 3 --connect-timeout 15 \
  "https://raw.githubusercontent.com/brownjudy797-glitch/XSAI_AIRAN/main/tutorials/assets/20261029/cpu-only-plugins.patch" -o "$tmp"
printf '%s  %s\n' '95a29c8138c1b2cdc11d03556289ae5621a1f6c7d13311b345d1c58154e31e58' "$tmp" | sha256sum --check -
mv -- "$tmp" "$target"
)

git apply --reverse --check --ignore-space-change arm64-cpu-only-plugins.patch >/dev/null 2>&1 || git apply --check --ignore-space-change arm64-cpu-only-plugins.patch
```

检查通过后回到第 3 步运行带状态识别的应用代码块；不要再次单独执行正向应用。补丁已改为直接下载，无需复制 heredoc。

## 附录 B：下载 ARM64自动热点实验脚本
在 ARM64 Ubuntu终端完整复制并执行：

```bash
cd "$HOME/sionna-rk"

(
set -e
target="$HOME/sionna-rk/scripts/run-arm64-hotspot-experiment.sh"
mkdir -p -- "$(dirname "$target")"
tmp=$(mktemp "${target}.download.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
curl -fL --retry 3 --connect-timeout 15 \
  "https://raw.githubusercontent.com/brownjudy797-glitch/XSAI_AIRAN/main/tutorials/assets/20261029/run-arm64-hotspot-experiment.sh" -o "$tmp"
printf '%s  %s\n' 'bdce6895f0bebb13b49fc5b8fe2861ef92dd15ba2d81468bef5b42656389b6fa' "$tmp" | sha256sum --check -
mv -- "$tmp" "$target"
chmod 0755 -- "$target"
)

chmod +x scripts/run-arm64-hotspot-experiment.sh
bash -n scripts/run-arm64-hotspot-experiment.sh \
  && echo "脚本创建成功，语法检查通过"
```

下载命令已包含 SHA256 校验；不再需要复制 heredoc 或大型脚本正文。

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

这是当前 ARM64 热点实验的推荐入口，也是与 K3、x86 保持同粒度的唯一正式  
流程。脚本生成后执行：

```bash
cd "$HOME/sionna-rk"
install -m 755 add-oai-timer.sh scripts/add-oai-timer.sh
bash -n scripts/add-oai-timer.sh
./scripts/add-oai-timer.sh --oai-dir "$HOME/sionna-rk/ext/openairinterface5g" --check
./scripts/add-oai-timer.sh --oai-dir "$HOME/sionna-rk/ext/openairinterface5g" --preset all --apply --build
./scripts/add-oai-timer.sh --oai-dir "$HOME/sionna-rk/ext/openairinterface5g" --verify
```

`--build` 完成后必须存在以下三个产物：

```bash
BUILD="$HOME/sionna-rk/ext/openairinterface5g/cmake_targets/ran_build/build"
test -x "$BUILD/nr-softmodem"
test -x "$BUILD/nr-uesoftmodem"
test -f "$BUILD/librfsimulator.so"
```

`--preset all` 包含 `rx-symbol`、`tx-symbol`、`rx-task`、`pusch-native`、  
`fep-native`、`ldpc-prof` 和 `dlsch-enc`。脚本具有幂等检查，但跨 OAI 提交时  
仍必须先运行 `--check`；锚点不匹配时应停止并更新脚本，禁止强行套用。
