# K3 项目架构

本地项目名 `sionna-rk`，发布仓库名 `XSAI_AIRAN`。当前先完成工程边界与独立验证入口；端到端连接修复另行处理。

更新：A 版 DFT/IDFT 内核已提供原样抽离方案和版本专用接入补丁，详见 [DFT 迁移说明](DFTS_MIGRATION.md)。下面复数乘法接口的独立开关仍只适用于该接口；DFT 的现有选择条件另见迁移说明。

| 层次 | 目录 | 职责 |
|---|---|---|
| 基线 | 发布版 `vendor/openairinterface5g`；实机 `ext/openairinterface5g` | 保存 A 版和已有计时改动，协议栈与默认算法归 OAI |
| 算子 | `plugins/rvv_phy/include` | 独立 RVV 实现，不依赖 OAI 大结构体 |
| 适配 | `adapters/oai/include` | 明确输入布局、溢出语义及回退约定，后续接入点调用这里 |
| 补丁 | `patches/` | 上游集成补丁与实验候选独立保存；不要向已经修改过的 A 版重复应用总补丁 |
| 构建检查 | `architecture/`、`scripts/check-phy-architecture.sh` | 独立编译并测试算子/适配层，不构建或启动 gNB |
| 部署 | `scripts/`、`config/` | 保留原生编译和 systemd 部署，配置示例不包含订户数据 |

## 当前实现与边界

新增 `xsai_oai_try_cmul_q15x8()` 是编译期选择的薄适配接口。RVV 启用时调用现有复数乘法算子；关闭时返回 false，输出保持不变，由调用方继续执行 OAI 原路径。接口以 8 个交织 Q15 复数为输入、独立 int32 数组为输出，不分配内存。

原 A 基线不直接修改；DFT 迁移通过版本专用补丁在新开发目录中接入。历史总补丁与 A 实现有差异，不能混用。当前没有动态 DFT/IDFT 插件，也没有重写完整 DFT；采用 header-only 集成，以后需要运行时切换时再定义带版本号的动态库 ABI。

## 构建与检查

在 K3 项目根目录运行：

```sh
bash scripts/check-phy-architecture.sh reference
bash scripts/check-phy-architecture.sh rvv
```

第二项要求 GCC 16+ 和 RISC-V V。测试包含 INT16_MIN 边界及确定性随机向量，对照标量表达式检查复数乘法的位级结果；reference 模式检查回退契约。此测试不是 PHY 性能或端到端验收。

## 发布源码与实机路径

发布库保留 vendor 快照，避免覆盖正在使用的 ext 源码。新开发目录通过以下命令准备：

```sh
bash scripts/prepare-oai-worktree.sh /absolute/new/oai-A-work
```

脚本拒绝已存在目录，不应用 UE 候选补丁、不安装依赖、不启动服务。OAI 的外部依赖、工具链及核心网仍按原部署材料准备；这不是一键新机安装工具。`SOURCE_SNAPSHOT.json` 记录 A 版来源，运行候选和基线不能混称为同一版本。

## 后续接入规则

每个新算子先通过独立正确性检查，再添加最小 OAI 适配补丁，接着测量模块耗时，最后才做系统验证。不能仅因启用了 RVV 就声称加速。连接修复补丁与算法补丁分别测试与发布，旧 A 基线可随时对照。
