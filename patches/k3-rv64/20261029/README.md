<!-- SPDX-License-Identifier: Apache-2.0 -->
# K3 RV64 CPU-only 移植补丁 — 20261029

该目录用于分发附加补丁；应用目标为 **NVlabs/sionna-rk 的 0abdce3**，不是 XSAI_AIRAN 当前源码根目录。

- [完整部署教程](../../../tutorials/k3-rv64/README.md)
- [补丁](sionna-rk-k3-rv64.patch)
- [SHA256SUMS](SHA256SUMS)

SHA256：`b35232cc7ec640be1b7a899fcfb9fd5887f86748376095da06b2883886d55738`。

补丁包含 RV64/CPU-only 构建适配、非 CUDA 默认配置及 RFsim 工具，共涉及 26 个文件。保留上游原有版权与许可；来源为用户提供的 K3 移植补丁，基于 NVlabs/sionna-rk 及其 OAI 补丁作适配，许可按仓库根目录 LICENSE 及上游组件原许可执行。

验证：在 0abdce3 的受影响原文件上完成 git apply --check、应用及反向检查；对初次应用、重复检查和已知 Makefile 空白/头部修改分别检查。仅验证补丁适用性和应用完整性，不表示新设备已完成编译、5G Core、RIC 或端到端业务验收。

教程将 SHA256 固定在命令中。后续若修改补丁，请新增版本目录并同步校验值，不原地更换本版本内容。不要自动清理补丁里的尾部空白，部分内容本身是嵌套 diff。
