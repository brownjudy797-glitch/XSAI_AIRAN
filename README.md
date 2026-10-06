# AIRAN / XSAI_AIRAN

基于 Sionna Research Kit 与 OpenAirInterface (OAI) 的 5G NR 实验项目，重点是把真实空口 gNB、5G 核心网和 AI 物理层插件运行在进迭时空 K3 上，并研究 X100/A100 异构调度与物理层耗时。GitHub 仓库名为 `XSAI_AIRAN`；实验机上的工程路径仍是 `/home/ubuntu/sionna-rk`。

本仓库是**源码、适配器、模型、脚本和可复现实验说明**，不是包含 SIM 数据、数据库、编译产物和设备配置的一键镜像。首次接触请先读 [项目与环境指南](docs/K3_PROJECT_GUIDE.md)；已经部署好 K3 的读者可看 [真实 UE 接入教程](tutorials/quickstart/README.md)。

## 项目包含什么

```text
Windows/Quectel UE ⇄ 5G 空口 ⇄ B210 ⇄ K3 gNB (OAI)
                                            ├─ X100：常规 L1/实时线程
                                            ├─ A100：AI 接收机工作线程
                                            └─ CN5G：AMF / SMF / UPF
```

| 模块 | 位置 | 作用 |
|---|---|---|
| OAI A 版快照 | `vendor/openairinterface5g/` | gNB/UE 代码与实验基线；实机部署在 `ext/openairinterface5g/` |
| Sionna-RK 插件 | `plugins/` | 原有 CUDA/TensorRT 插件和 K3 A100 后端 |
| K3 神经接收机 | [`plugins/neural_receiver/k3_a100/`](plugins/neural_receiver/k3_a100/README.md) | 接收 IQ 与导频信息，在 A100 上生成 16-QAM 软比特 |
| K3 神经解调器 | [`plugins/neural_demapper/k3_a100/`](plugins/neural_demapper/k3_a100/README.md) | 仅替换均衡后的 LLR 计算；LDPC 译码仍由 OAI 完成 |
| 其他解调候选 | [`plugins/neural_demapper_spacemit/`](plugins/neural_demapper_spacemit/README.md) | SpaceMIT EP/蒸馏模型实验，不等同于正在演示的接收机 |
| RVV 算子与 OAI 适配 | `plugins/rvv_phy/`、`adapters/oai/` | 独立物理层算子、回退契约和测试 |
| 构建、部署与测量 | `scripts/`、`config/`、`patches/` | 工具脚本、**示例**配置和可选补丁 |
| 文档与教程 | `docs/`、`tutorials/` | 架构、实验边界、复现和现场操作 |

## 当前验证边界（截至 2026-10-05）

- **真实链路**：K3 + B210 + CN5G + Windows UE 曾完成端到端连接和用户面访问；这不代表任意新设备克隆后即能运行。现场仍须重新检查射频、订阅、版本及日志。
- **下行速率调查**：原非连续发送配置在 1.8 Mbps 左右出现稳定性边界；启用 `--continuous-tx` 后，2.5 Mbps/120 秒对照达到目标、零 UDP 丢包。详情与条件见 [实验状态](docs/EXPERIMENT_STATUS.md)。
- **AI 接收机**：K3 A100 原生后端完成 12/24 RB 的数值检查和短时实机演示；24 RB 是当前 gNB 配置和代码上限，**不是 B210 的硬件上限**。51/106 RB 尚未适配。3 Mbps 上行实时吞吐门禁未通过。
- **AI 解调器**：K3 RVV 后端完成加载、回退和 16-QAM 单次推理检查；它与接收机是不同插件，本次在线演示只启用接收机。项目没有宣称完成独立神经 LDPC 译码器。
- **统一计时**：接收机内部分为输入、A100 推理、LLR 输出和总耗时；传统路径与插件路径必须按同一 PUSCH/窗口口径比较。在线混合 RB 日志不能当作固定 24 RB 的独立性能门禁。
- **XSAI 迁移**：K3 的 OAI 移植经验可供分析，但香山 XSAI 的可运行性尚未完成验证。

这些结论是特定硬件、版本和配置下的实验记录，不是产品性能保证；详见 [实验状态与证据口径](docs/EXPERIMENT_STATUS.md)。

## 从哪里开始

1. **只阅读或审查代码**：先看 [架构](docs/ARCHITECTURE.md)、[项目与环境指南](docs/K3_PROJECT_GUIDE.md) 和 [`SOURCE_SNAPSHOT.json`](SOURCE_SNAPSHOT.json)。
2. **已有 K3 环境，检查真实 UE 链路**：按 [Quickstart](tutorials/quickstart/README.md) 执行只读检查，再决定是否启动。它不会创建核心网订阅或安装驱动。
3. **验证独立 PHY 算子**：在已配置 GCC 16/CMake 的 K3 上运行 `bash scripts/check-phy-architecture.sh reference`；支持 RVV 的目标再运行 `bash scripts/check-phy-architecture.sh rvv`。
4. **构建 AI 后端**：分别进入 `plugins/neural_receiver/k3_a100` 或 `plugins/neural_demapper/k3_a100`，执行 `bash build.sh`、`bash verify.sh`。默认只生成和检验 `.so`，**不会改变在线 gNB**。完整前提和命令见 [项目与环境指南](docs/K3_PROJECT_GUIDE.md)。

> 射频发射只应在获准的屏蔽、衰减或其他合规实验环境中进行。直连射频口前确认衰减方案；不要把真实 SIM 密钥、订户数据库或设备身份文件提交到仓库。

## 部署与目录约定

- 发布仓库中的 `vendor/openairinterface5g` 是 2026-09-22 A 版**快照**，不是自动更新的上游 OAI。不要直接覆盖正在运行的 `ext/openairinterface5g`。
- `scripts/prepare-oai-worktree.sh /绝对路径/新目录` 可以把快照放入一个不存在的新目录以供开发；它不安装依赖、不编译、不启动 gNB。当前实机还有后续补丁和特定编译产物，不能把该快照误称为在线状态的完整镜像。
- `config/**/*.example` 只提供格式，不包含可用订户数据。CN5G、SIM、APN、B210 序列号和网络出口参数需在目标设备本地配置。
- `plugins/neural_receiver/k3_a100` 与 `plugins/neural_demapper/k3_a100` 采用独立构建脚本。当前总 CMake 的 CUDA 插件入口尚未统一为 K3 后端自动构建；不要把“文件已在 `plugins` 下”理解为新机一键可用。
- 历史源码、原始测试日志、视频、Office 文件、临时构建和个人配置留在实验工作区，不进入此发布仓库。K3 内核与 CN5G 的独立安装材料见 [K3 移植工具仓库](https://github.com/brownjudy797-glitch/sionna-rk-k3-porting)。

## 文档索引

- [项目与环境指南](docs/K3_PROJECT_GUIDE.md)：依赖、目录、构建、验证、常见故障。
- [Baseline 实验方法](docs/BASELINE_METHOD.md)：区分 RFsim、真实 UE 与 AI/传统对照，统一记录和有效性判据。
- [AI 插件接入与观察](docs/AI_PLUGIN_INTEGRATION.md)：loader、模型、A100 线程与回退。
- [实验状态](docs/EXPERIMENT_STATUS.md)：已通过、未通过和仍待验证的项目。
- [真实 UE 接入 Quickstart](tutorials/quickstart/README.md)：已部署 K3 的现场操作。
- [架构与适配契约](docs/ARCHITECTURE.md)、[DFT 迁移说明](docs/DFTS_MIGRATION.md)。
- [发布前检查](docs/GITHUB_RELEASE_CHECKLIST.md)：隐私、依赖、许可与 GitHub 上传前核对。
- [工作区与发布仓库对应关系](docs/WORKSPACE_MAP.md)：整个 AIRAN 各目录的保留或排除依据。

## 来源与许可

Sionna-RK、OAI 及各第三方组件保留原有版权和许可；参见根目录 [`LICENSE`](LICENSE)、[`README.upstream.md`](README.upstream.md) 以及 vendor 内的许可证。本项目的 K3 实验代码与文档不改变上游许可。接收机权重由我们在 Spark 上训练，解调器权重由 NVIDIA Sionna-RK 的开源检查点转换；来源、验证边界和散列值见各插件 README。分发解调器权重时保留上游署名和 Apache-2.0 许可说明。
