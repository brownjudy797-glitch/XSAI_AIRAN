# XSAI_AIRAN

K3 的 sionna-rk / OAI A 版真实空口端到端实验项目。K3 本地路径仍为 `/home/ubuntu/sionna-rk`。

本仓库保存 2026-09-22 实机工作树快照：外层部署脚本、A 版源码及现有 PHY 计时修改。`vendor/openairinterface5g` 是实机 A 版源码；部署时需放到 `ext/openairinterface5g`。上游许可证及版权声明随源码保留，参见各目录 LICENSE 和 README.upstream.md。

## 当前验证状态

UE 修复候选单独保存在 `patches/k3-ue-release-candidate.patch`，没有并入 vendor 基线。候选干净启动后通过 10 分钟、59 次低负载 Ping；快速断开重连仍出现有 IP 但用户面不通。不能称为完整稳定性验收通过，尚未完成 10 次重连和 30 分钟验证。

## 部署材料

- `scripts/`：K3 构建、运行、采集脚本。
- `docs/` 和 `tutorials/`：实验与现场 Quickstart。
- `config/**/*.example`：配置模板；按本地环境填写，订户和 SIM 信息需另行配置。
- `SOURCE_SNAPSHOT.json`：来源版本和运行候选标识。

此快照不是新机器一键安装包。运行脚本中的 K3 路径、网卡与基线检查需配合本地部署；`.baseline` 不上传，不能把该目录缺失误认为可以跳过校验。不会上传运行日志、数据库、SIM 配置、构建产物、`.env` 或基线备份。继承的 CI 放在 `.github/workflows-reference`，尚未配置运行。
