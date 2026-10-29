<!-- SPDX-License-Identifier: Apache-2.0 -->
# K3 当前项目状态

核查时间：2026-10-29 16:07:14（Asia/Shanghai）。这是一次远程只读快照，不代表之后的设备状态。

同日后续另建隔离目录进行了源码编译和 RFsim 功能验证，未覆盖本页的历史观察。新部署入口与后续证据见 [复现审计](REPRODUCIBILITY_AUDIT.md) 和 [从零教程](../tutorials/reproduction/README.md)。

## 现场版本和运行状态

| 项目 | 本次观察 |
|---|---|
| 平台与内核 | riscv64；6.18.3-k3-sctp+ |
| 外层项目 | 0abdce3ff7f5840d64b783632eb419ea6bf54ae5，main，存在本地修改 |
| OAI | c6698f7dda869e0ab92e232da08d1a91385eb044，rvv_modify，九个源码文件有未提交差异 |
| 核心网父仓库 | 6cd16eb65b3f1f92ccc330dfe6f0bacf99372682，AMF/SMF/UPF 子目录存在本地修改 |
| 选用的 gNB 构建 | ext/openairinterface5g/cmake_targets/phy-fixed-build-20260922 |
| gNB / nrUE | 两者均无进程，本次没有启动或测试 UE |
| AMF / SMF / UPF | 各一个进程；AMF 的 SCTP 38412 端口在监听 |
| iperf | 一个服务进程仍在运行，不代表有业务或本次正在测速 |
| UE 自动恢复 / 转发 | 对应 systemd 服务仍为 active；不等于 UE 已连接 |

当前不是“所有实验相关服务已停止”的状态。历史 failed systemd 单元仍存在，本次没有清理或重启。
进程和监听检查不证明 N4 association、UE 注册、PDU、吞吐或长期稳定性通过。

## 快照与现场差异

`k3-deployment-guard.py --check-snapshot` 与 `--check` 均通过，覆盖 39 个项目拥有的部署文件。
2026-09-22 冻结快照的 4064 项中，缺失为 0、快照内容不符为 0；与当前现场相比有 23 项不同。
这些差异属于后续工作区变化，不能覆盖旧 manifest 来伪造“仍与历史基线完全相同”。

最近结果目录更新集中于 2026-10-27 的 51 RB 实机/RFsim 诊断。本次没有重测，也没有仅凭目录名发布新的速率或稳定性结论。
完整公开元数据见 [核查清单](../snapshots/k3/20261029/manifest.json)，原始日志与现场配置留在本地。

## 本次仓库同步

- 同步当前 AMF 候选选择、部署完整性保护、独立 RU 启动辅助和受控重启脚本。新机没有本地 deployment manifest 时，保护检查失败是预期行为，不应为了启动而自动重建快照。
- 新增 [独立 DFT 框架](../benchmarks/dft/README.md)，保留原算法调用和统计边界，不上传历史原始 JSON 或二进制。
- 保存 [OAI 现场差异补丁](../snapshots/k3/20261029/README.md)，不直接改写已发布 vendor 快照。
- 现场 AI 接收机源文件是单工作者实现，发布目录另有四工作者离线候选；本次没有用现场旧实现覆盖候选，也没有把候选报告成当前在线版本。

教程新部署使用官方 OAI `207aac94d13e714abac8062ebf869805f2acd6dc`，与这里的现场 OAI `c6698f7` 不同。
两条路线必须按自己的源代码、补丁和配置验收，不能混称一个已验证版本。

本次没有改变 K3 上的文件、服务选择或射频状态；仅导出审阅范围内的源码到本地并更新公开仓库。
