# A 版 DFT/IDFT 实现抽离

2026-09-24：将 A 版 `openair1/PHY/TOOLS/oai_dfts_rvv.h` 的 1,266 行实现原样复制到 `plugins/rvv_phy/include/oai_dfts_rvv.h`，通过 `adapters/oai/include/xsai_dfts_adapter.h` 接入。保留来源及原函数名，不在本轮重写算法或承诺性能收益。来源哈希见 `adapters/oai/DFTS_PROVENANCE.json`，许可证沿用来源 OAI 的相关条款。

调用关系：`oai_dfts.c` → 原头文件位置的兼容入口 → `xsai_dfts_adapter.h` → 插件中的现有 RVV 内核。

原 vendor A 快照保留完整头文件。`patches/k3-A-dfts-extraction.patch` 把新开发目录中的原头文件替换为两行兼容入口；该补丁仅适用于已保存的 A 版本，不要将历史上游总补丁重复应用到 A 版。

```sh
bash scripts/prepare-oai-worktree.sh /absolute/new/oai-A-adapted --dfts-adapter
bash scripts/check-dfts-migration.sh
```

实机 sionna-rk 没有 vendor 副本时可运行：

```sh
OAI_BASELINE=/home/ubuntu/sionna-rk/ext/openairinterface5g bash scripts/check-dfts-migration.sh
```

验证结果：迁出的整个头文件与 A 基线逐字节一致；独立编译迁移前/后两个测试实现，16,016 组正反向蝶形用例（长度 0/1/7/8/9/16/31/64、极值和随机输入）输出逐字节一致；隔离 A 目录的补丁检查及完整 `oai_dfts.c` 编译语法检查通过。没有完成完整 gNB 链接或全部 DFT 尺寸的系统回归，也未替换运行二进制。

A 本身已有不同于外层历史总补丁的 RVV 实现。此次抽离的是 A 的实现，不是上一阶段 `xsai_complex_adapter.h` 所包装的复数乘法。两个接口分开命名；本次 DFT 适配保留 A 的 `__riscv_vector` 选择条件，并不受 `XSAI_ENABLE_RVV` 的独立复数乘法测试开关控制。后续统一选择策略时需另作数值回归。
