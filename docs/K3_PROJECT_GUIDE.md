# AIRAN 项目与 K3 使用指南

本文区分三件事：**阅读/构建源码**、**检查已部署的 K3**、**运行真实空口实验**。前两项不需要发射射频；最后一项需要已配置的核心网、UE/SIM 和合规实验环境。本仓库不是从空白系统到可用 5G 网络的一键安装器。

## 1. 环境与版本

| 项目 | 当前实验环境/要求 |
|---|---|
| 计算平台 | 进迭时空 K3，Ubuntu riscv64；CPU0–7 为 X100，CPU8–15 为 A100 |
| 射频 | Ettus USRP B210，USB 3.0；具体频点、带宽、功率和衰减由实验室配置决定 |
| gNB | Sionna-RK + OAI A 版；发布快照在 `vendor/openairinterface5g/`，实机源码在 `ext/openairinterface5g/` |
| 核心网 | 本地 AMF/SMF/UPF；订户数据库和 SIM 参数不在仓库中 |
| UE | 实验用 Windows/Quectel UE；须有匹配的 SIM、APN/DNN 和驱动 |
| 工具 | Bash、Git、CMake、GCC/G++ 16、Python 3、NumPy；实机还需 UHD、systemd 及 K3 内核支持 |

[`SOURCE_SNAPSHOT.json`](../SOURCE_SNAPSHOT.json) 描述 2026-09-22 发布基线，不代表以后每一次实机二进制都与它相同。硬件/内核/UHD/CN5G 的独立部署材料在 [K3 移植工具仓库](https://github.com/brownjudy797-glitch/sionna-rk-k3-porting)；请先阅读其中的预检和回滚说明。公开仓库不包含订户密钥或数据库。

## 2. 获取项目并认识目录

```bash
git clone https://github.com/brownjudy797-glitch/XSAI_AIRAN.git
cd XSAI_AIRAN
git rev-parse HEAD
```

首次阅读建议按顺序查看：

1. [`README.md`](../README.md) 和 [实验状态](EXPERIMENT_STATUS.md)：项目目标及已验证边界。
2. [架构](ARCHITECTURE.md)：OAI、插件、适配层、补丁之间的责任划分。
3. [`plugins/neural_receiver/k3_a100`](../plugins/neural_receiver/k3_a100/README.md) 与 [`plugins/neural_demapper/k3_a100`](../plugins/neural_demapper/k3_a100/README.md)：两种 AI 插件的不同入口。
4. [真实 UE Quickstart](../tutorials/quickstart/README.md)：只针对已部署的 K3。
5. [AI 插件接入与观察](AI_PLUGIN_INTEGRATION.md)：从独立构建走到运行时加载所需的检查。
6. [Baseline 实验方法](BASELINE_METHOD.md)：正式 RFsim、B210 和 AI/传统对照的变量控制、结果记录与失效判据。

路径约定：GitHub 仓库根目录记为 `REPO`；下文命令在仓库根目录执行。`vendor/` 是发布快照，`ext/` 是目标机器上准备的实际源码，`.runtime/`、`build/`、`results/` 属于本地运行产物，不能混为一谈。

## 3. 不连接射频的源码检查

在具备 GCC 16 和 CMake 的目标机上：

```bash
bash scripts/check-phy-architecture.sh reference
```

若编译器和 CPU 支持 RISC-V V，再运行：

```bash
bash scripts/check-phy-architecture.sh rvv
```

这两项只验证独立算子与回退契约，不证明 AI 模型精度、gNB 实时性或 UE 接入。旧实验的固定 SHA 值不应被当成新机器的验收值；每轮记录 `git rev-parse HEAD`、编译器版本及新产物散列值。

如需研究 A 版 OAI，请把快照放入**不存在的新目录**，不要覆盖在线源码：

```bash
bash scripts/prepare-oai-worktree.sh /absolute/path/to/new-oai-work
```

该命令只复制源码并链接本仓库插件，不安装依赖、不构建、不启动服务；OAI 的后续现场修改与二进制仍需单独核对。

## 4. K3 A100 AI 插件：构建与离线验证

以下命令假定 K3 上的项目是 `/home/ubuntu/sionna-rk`，且已存在兼容的 `ext/openairinterface5g` 和 OAI 构建目录。若位置不同，按插件 README 设置 `OAI_ROOT`、`OAI_BUILD`。编译建议在无线业务空闲时进行，以免影响在线时延。

### 神经网络接收机

```bash
cd /home/ubuntu/sionna-rk/plugins/neural_receiver/k3_a100
bash build.sh
bash verify.sh
```

`build.sh` 生成 `build/libreceiver_a100_native_h24_b4_b256_hcache_power.so`，与发布的 `k3_native_joint_h24.weights` 配套。`verify.sh` 在 A100 CPU8 上对 12/24 RB 的输出与 NumPy 参考实现比较；它**不停止 gNB，也不加载新插件进在线 gNB**。若 gNB 同时运行，脚本打印的微秒数只能作观察，不能作为独立延迟门禁。

当前接收机只处理满足源码中形状约束的单层 16-QAM PUSCH，且分配不超过 24 RB；其余走 OAI 传统路径。一个 40 MHz/30 kHz 的 106 RB 载波即使射频侧具备带宽，也不代表此插件已支持。提高载波配置前必须分别验证 OAI、UHD/USB、UE、模型形状与时隙预算。

### 神经网络解调器

```bash
cd /home/ubuntu/sionna-rk/plugins/neural_demapper/k3_a100
bash build.sh
bash verify.sh
```

`verify.sh` 检查 `.so` 加载、非 16-QAM 回退和一次 16-QAM LLR 推理。它不是完整 BLER 或真实空口验收。解调器取的是已有均衡输出，不替代信道估计/均衡；后续 LDPC 译码仍由 OAI 处理。接收机和解调器不要在同一 PUSCH 链路上未经验证地同时启用。

两套 K3 后端目前使用各自的独立 `build.sh`。仓库原有总 CMake 在启用 CUDA 时才纳入 Spark 的 neural_receiver/neural_demapper 子目录；因此在 K3 上不要假设普通顶层构建会自动编出 A100 后端。

## 5. 真实 UE 链路的安全操作顺序

仅适用于已经部署 CN5G、OAI、UHD、B210 和订户数据的实验机。请使用 [真实 UE Quickstart](../tutorials/quickstart/README.md) 的具体命令，本节只说明顺序和判据：

1. 确认目标硬件、内核、USB 3.0 B210 枚举，以及射频屏蔽/衰减方案。
2. 确认只存在一套预期的 gNB、AMF、SMF、UPF；不要在已有连接上盲目重复启动。
3. 检查 gNB 与 AMF 的 NG Setup、UE 注册、PDU 会话和 UE 侧分配的地址。
4. 先测 UE 到 UPF 的基本用户面连通，再做特定速率或 AI 插件实验。
5. 若要切换 AI 插件，先保存当前服务定义和回滚入口，在可中断业务的实验窗口执行。发布仓库的 `build.sh` / `verify.sh` 本身不会切换服务。

不要把 `ping` 成功、UDP 数据最终到达、AI 日志出现调用次数，分别误写成“高负载实时性通过”或“长期稳定性通过”。每轮结论须写明 RB/MCS、包长、时长、发/收窗口、错误/重传和服务版本。

需要形成可比较的实验结果时，按 [Baseline 实验方法](BASELINE_METHOD.md) 固定条件、先做本地冒烟，再做上下行独立负载窗口和 AI/传统 A/B；旧 RFsim 启动脚本会停止现有 OAI 进程，不能当作在线 B210 链路的无扰采集器。

## 6. 计时与性能比较

接收机插件采用 OAI 的 `time_stats_t`，记录 `input`、`a100_inference`、`llr_output`、`total`。可选补丁 [`patches/oai-neural-receiver-timing.patch`](../patches/oai-neural-receiver-timing.patch) 把字段纳入 OAI 统计结构；仅在与目标 OAI 版本匹配并通过 `git apply --check` 后，才应在**独立工作目录**应用。发布仓库不自动修改在线 OAI。

比较传统路径和 AI 路径时，统一按一个 PUSCH 的处理窗口计：传统的资源提取、信道补偿和 LLR 等模块先把累计时间相加，再除以 PUSCH 次数；AI 使用插件总累计时间除以插件调用次数。信道估计、RB/MCS、UE 流量、采样时间、CPU 绑定要保持一致。`K3_NATIVE_JOINT_RECEIVER` 的每百次抽样日志只是局部观测，不能替代 P50/P95/P99 和端到端吞吐测量。

## 7. 常见问题

| 现象 | 首先检查 |
|---|---|
| `build.sh` 找不到 OAI 头文件 | `OAI_ROOT`、`OAI_BUILD` 是否指向匹配版本；不要误指向只有 `vendor/` 而没有生成头文件的目录 |
| `verify.sh` 提示 A100 绑定失败 | K3 内核 `/proc/set_ai_thread`、`sudo -n`、CPU8 是否可用；不能在普通 x86 主机跑此门禁 |
| 插件加载但无 AI 调用 | gNB 的 loader 路径/版本、16-QAM/层数/DMRS/RB 条件；查看是否回退 OAI 传统路径 |
| 负载高时出现积压 | 比较 RX PUSCH 总时间与 0.5 ms 时隙预算，观察队列、HARQ 和 UHD Overflow；不能只看模型核心耗时 |
| UE 有 IP 但用户面不通 | 检查 PDU 会话、UPF 路由、重复服务与 UE 状态；不要反复拨号或同时启动多套核心网 |
| 24 RB 之外回退 | 当前接收机代码上限就是 24 RB；51/106 RB 尚需模型与缓冲区适配、数值及实时门禁 |

发布前先看 [GitHub 检查表](GITHUB_RELEASE_CHECKLIST.md)。
