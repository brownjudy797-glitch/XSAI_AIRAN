# AIRAN 工作区与发布仓库对应关系

AIRAN 的**实机主项目在 K3**：`/home/ubuntu/sionna-rk`。该目录同时承载运行服务、源码改动和实验产物，不适合直接执行 `git add .`。在 K3 上另设 `/home/ubuntu/airan-release` 作为独立发布检出目录。Windows 的 `AIRAN` 工作区只是同步、分析和文档整理副本，包含源码副本、离线安装包、原始实验输出和演示素材；也不应整目录上传。发布仓库保留一份可审查的主线，避免重复上传同一份 OAI/Sionna 源码。

| 原工作区内容 | 发布处理 | 理由 |
|---|---|---|
| `.research-sionna-rk/` | 选取 K3 后端源码放入 `plugins/*/k3_a100/` | 原目录是研究用源码副本；不再整体嵌套一个 Git 仓库 |
| `.work-github-oai/`、其他 OAI 副本 | 保留 `vendor/openairinterface5g/` 快照及版本说明 | 避免多个大体积、版本不明的 OAI 副本 |
| `k3-architecture/` | 架构、适配、计时补丁和经审核的状态摘要进入 `docs/`、`plugins/`、`patches/` | 原目录含大量阶段性报告、结果与构建物，不全量发布 |
| `k3-porting-kit/` | 作为独立的 [K3 移植工具仓库](https://github.com/brownjudy797-glitch/sionna-rk-k3-porting) 维护 | 内核/CN5G 的安装、回滚和版本节奏与 AI 源码不同 |
| `k3-rfsim-repro/` | 复现说明和必要脚本留在 `REPRODUCTION_GUIDE.md`、`scripts/` | 原始 RFsim 运行目录和生成数据不适合入库 |
| `oai-field-experiment/`、`k3-ue-stability/`、`k3-opt/` | 经验证的脚本、补丁和结论体现在 `scripts/`、`patches/`、`docs/` | 旧轮次数据留在工作区；避免把候选修复写成稳定基线 |
| `XSAI/` | 已有较新的 `tutorials/quickstart/`；XSAI 硬件迁移仍列为待验证 | 旧教程草稿不覆盖后续修订版 |
| `outputs/`、`output/`、演示视频与 PPT | 不发布 | 可能含身份信息、原始日志、缓存及大文件；演示材料与源码版本分开管理 |
| `.codex_tmp/`、`.work-*/`、`_archive/` | 不发布 | 临时构建、研究副本或可恢复旧快照，不属于可复现工程入口 |

“覆盖整个 AIRAN”指项目的**源码主线、依赖边界、复现实验方法和已验证结论**可以从这里找到，不等于公开实验室的全部原始数据。确需共享某一轮原始证据时，应另做去标识化、散列校验和授权审查，不直接上传整个 `results/`。
