<!-- SPDX-License-Identifier: Apache-2.0 -->
# 从这里开始

先按目标选择一条路线，不需要把全部教程依次执行。命令在对应平台的 Ubuntu 终端运行。

| 你的目标 | 教程 | 是否需要 5G 核心网 |
|---|---|---|
| K3 / RISC-V 编译与 RFsim 热点测量 | [K3 RV64](k3-rv64/README.md) | 否，使用 --phy-test --noS1 |
| x86 Ubuntu 复现相同热点实验 | [x86 RFsim](x86-rfsim/README.md) | 否 |
| ARM64 / DGX Spark 复现相同热点实验 | [ARM64 RFsim](arm64-rfsim/README.md) | 否 |
| K3 安装 SCTP/CN5G，接入真实 UE | [K3 核心网与 B210](k3-cn5g/README.md) | 是 |
| 已有 K3 环境，只检查真实 UE 通信 | [实机 Quickstart](quickstart/README.md) | 需要已有部署 |

## 最短操作顺序

1. 选择平台，准备官方 sionna-rk 0abdce3 与指定 OAI 源码。XSAI_AIRAN 在这些教程中分发补丁、脚本和说明，不替代目标机上的 sionna-rk 路径。
2. 按本平台教程下载并校验补丁与工具；K3 使用 RV64 补丁，x86/ARM64 只使用 CPU-only 插件补丁。
3. 安装依赖、完成首次构建，再检查和应用统一计时，重新编译。
4. 先验证一轮同步和统计，再做理想/AWGN 各五轮；先检查提交、配置、绑核及时间窗口一致，再比较结果。
5. 只有需要完整协议接入或真实 UE 时才进入核心网教程；源码部署与 /opt Release 安装分开处理。

## 文件在哪里

- [K3 RV64 完整补丁](../patches/k3-rv64/20261029/README.md)：替代终端粘贴大型 diff。
- [共用计时工具与平台实验脚本](assets/20261029/README.md)：按日期分发，附 SHA256 和来源清单。
- 原始测量结果写入目标机教程指定的 results 目录，本项目此次未移动或清洗既有实验数据。

## 验证范围

教程整理保留了原实验参数与命令来源。发布前检查 Markdown 链接、Bash 语法、补丁应用、重复执行与失败停止；没有把这些静态检查写成目标硬件编译、射频或端到端业务验收。nearRT-RIC 仍是后续任务，本项目没有提供已验证的一键 RIC 部署。
