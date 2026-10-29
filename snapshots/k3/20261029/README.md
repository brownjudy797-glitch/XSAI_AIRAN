<!-- SPDX-License-Identifier: Apache-2.0 -->
# K3 现场核查记录 — 2026-10-29

[现场状态说明](../../../docs/K3_CURRENT_STATUS.md) · [机器可读清单](manifest.json)

本目录是一次远程只读核查的公开摘要，不包含设备配置、原始日志或二进制。发布操作没有启动、停止、重编译或替换 K3 服务。

## 两份 OAI 补丁的区别

- `oai-published-to-observed.patch`：以本仓库当时的 vendor 源码快照为输入，仅补充现场 nr-gnb.c、defs_gNB.h 的计时/统计差异；适用于保留发布基线、单独研究现场改动。
- `oai-vs-head.patch`：现场 OAI 工作区相对 c6698f7dda869e0ab92e232da08d1a91385eb044 的完整未提交差异，覆盖九个源码文件；它不是用于教程的官方 207aac9 OAI 基线，也不是在前一份补丁后叠加应用的补丁。

只在独立工作目录检查补丁，不在现场运行目录直接应用。对仓库 vendor 的适用性检查为：

```bash
git apply --check --directory=vendor/openairinterface5g snapshots/k3/20261029/oai-published-to-observed.patch
```

清单保存现场二进制和源码散列以便核对，但不能据此证明现有二进制由当前工作区的全部改动重新构建。公开新增源码只补许可注释；DFT Python 启动器另外增加可选工程/构建目录参数，清单分别记录现场和发布散列。
