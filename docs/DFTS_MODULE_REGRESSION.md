# 完整 DFT 动态库迁移回归（2026-09-24）

状态：动态库构建完成，完整数值验收未通过，未替换默认运行库。

使用实机 A 版保存的 `CMakeFiles/dfts.dir/flags.make` 和 `link.txt`，在独立目录编译、链接 `oai_dfts.c` 与 `oai_dfts_neon.c`。没有修改原构建目录的对象文件。对比三份动态库：已部署 A 库、相同工具链重编译的未迁移 A 库、迁移后的库。

迁移库 SHA256：`3010e2604000f29e0581b8318e8db9744f8a279e0d427682ad0b8ff16e1cc41f`。

## 覆盖范围与结果

覆盖接口表中的 68 种 DFT 和 21 种 IDFT 长度，每种包含两种缩放设置、零输入、脉冲、小幅随机和全幅随机四种输入。输入输出均对齐；批量 DFT 使用源码实际四路交织布局。每个库、每个长度在独立进程中运行，调用 `dfts_autoinit()` 后使用正式入口；只提供日志/跟踪宿主符号，不替代任何 DFT 运算。

- 87/89 个方向与长度组合：重编译原版和迁移版输出逐字节一致，共 696 组输入测试。
- DFT 2304：迁移前后比较不一致；相同的未迁移控制库重复执行也不一致。代码中的四路中间布局调用单路 `dft768`，存在未完整写入中间数组的嫌疑；需要单独修复并验证，不能归为迁移回归通过。
- DFT 98304：部署库、未迁移控制库和迁移库均 SIGSEGV。控制库 GDB 回溯定位到 `dft32768` → `transpose4_ooff_simd256` → `oai_rvv_deinterleave_2x8_i32` 的读取。尚未完成根因修复。
- 26 个方向与长度组合在至少一份库中出现零输入非零输出；输出一致不等于算法正确，这些异常仍需逐项排查。

结构化数据见 [dfts-module-result.json](validation/dfts-module-result.json)。因此本轮结论仅是已构建完整迁移模块、确认大多数路径保持既有行为；不能声明完整 DFT 正确性通过、性能提升或可替换生产库。没有启动端到端实验。

## 复现环境

仓库 `scripts/build-dfts-module.py` 与 `scripts/check-dfts-module.py` 保存本次 K3 专用复现流程，文件顶部固定了实机源码、原构建目录、隔离源码目录、发布工作目录的绝对路径。它们依赖既有 GCC 16 / A 编译缓存，不是全新主机上的独立构建工具；换环境需先对应调整路径。

```sh
python3 scripts/build-dfts-module.py
python3 scripts/build-dfts-module.py --control
python3 scripts/check-dfts-module.py
```

最后一个命令在存在输出差异、崩溃或零输入异常时返回非零。完整命令、日志、各尺寸原始二进制输出在 K3 发布目录的 `.build/dfts-module/`；未迁移控制库在 `.build/dfts-control/`。这些构建产物不提交 Git。
