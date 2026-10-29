<!-- SPDX-License-Identifier: Apache-2.0 -->
# 教程工具包 — 20261029

[教程入口](../../README.md) · [校验清单](SHA256SUMS) · [来源记录](manifest.json)

| 文件 | 用途 |
|---|---|
| add-oai-timer.sh | 三平台共用的 gNB 计时补丁工具，支持检查、备份和回滚 |
| run-k3-hotspot-experiment.sh | K3 RFsim 热点采集 |
| run-x86-hotspot-experiment.sh | x86 RFsim 热点采集 |
| run-arm64-hotspot-experiment.sh | ARM64 RFsim 热点采集 |
| cpu-only-plugins.patch | x86/ARM64 非 CUDA 插件入口桩函数，应用于官方 sionna-rk 0abdce3 |
| run-k3-b200.sh | 用户提供的历史源码部署布局 B210 启动器；Release 安装优先使用其自带版本 |
| k3-porting-dependency.patch | 修正安装仓库 install-online.sh 的 mysql-serve 包名，基线见 manifest |

脚本从用户提供的教程逐字提取，仅补充 SPDX 许可注释；脚本行为未合并成跨架构启动器。三份教程中的计时脚本内容一致，分发时共享同一文件。脚本注释里的计时数字属于历史 K3 记录，不能当成其他平台或本次发布的性能验证。

工具用于 Linux 目标机。本次只做 Bash 语法、补丁、模拟下载失败与重复应用检查，未在目标硬件运行完整实验。后续改变工具内容请建立新版本目录并同步教程校验值。
