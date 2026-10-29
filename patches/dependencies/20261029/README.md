<!-- SPDX-License-Identifier: Apache-2.0 -->
# K3 SIMDe 依赖修改

`simde-c7f26-k3.patch` 是 2026-10-29 从 K3 已使用的 SIMDe 工作树提取的六个头文件差异，基于 SIMD Everywhere `c7f26b73ba8e874b95c2cec2b497826ad2188f68`。它补充 RVV/GCC16 适配和运算路径；原环境把这些修改放在 `/usr/include/simde`，只安装系统 SIMDe 包无法重现。

SHA256：`3e0c495c7b69d575e4f601ec3bdcec89f917b3b5848a86db77d3417ab06582b3`。

新流程使用 `scripts/repro-deps.sh tools WORKSPACE` 下载固定版本、校验补丁并应用到工作区私有目录，保留系统头文件。重复应用用反向检查识别；检查失败就停止。

上游：[SIMD Everywhere](https://github.com/simd-everywhere/simde-no-tests)。保留 SIMDe 的 MIT 许可和文件版权声明；补丁不改变上游许可。完整依赖版本见 `config/repro/20261029.json`。本补丁用于本项目复现，不宣称已完成 SIMDe 全套指令一致性测试。
