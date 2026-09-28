# K3 A100 神经网络解调器：当前问题清单

记录日期：2026-09-28

## 当前结论

当前实现已经能通过 SpaceMIT ONNX Runtime Execution Provider（EP）在 K3
的 A100 核簇上运行 Spark 的原始神经网络解调模型，也已经完成固定形状缓存、
两路 ULSCH 合并和独立微基准验证。现在的首要问题不是“有没有调用到 A100”，
而是小模型的有效计算量太少，单次调用主要消耗在 ONNX Runtime/EP 边界和
调度开销中。

## 问题与优先级

| 优先级 | 问题 | 已有证据 | 下一步 |
|---:|---|---|---|
| P0 | 缺少真正的 OAI 多 ULSCH slot 级协调器 | Stage 15 只克隆同一 RF 输入；它验证了所有权和调用链，但不代表真实两 UE | 准备各 ULSCH 的不同 IQ/magnitude，再统一 infer/scatter；失败立即回退单路 |
| P0 | 单批 3312 RE 的固定开销偏大 | EP profile 中神经节点约 40.24 us，而非节点/运行时开销约 118.8 us；profile 仅用于归因 | 优先通过多 ULSCH 合并摊销边界成本；向厂商确认是否有稳定的持久执行器或 fused MLP API |
| P1 | Spark MLP 与 A100 8 宽矩阵 tile 不完全匹配 | 模型为 2→32→32→4；首层 K=2，末层 N=4；等价 padding 和 Conv 改写均更慢 | 保持冻结模型，不为填 tile 擅自改网络；除非重新训练并做 BLER 门禁 |
| P1 | 多个固定 Session 之间仍有切换成本 | shared pool 已改善混合形状 6.6%–8.3%，但混合形状仍慢于单一 hot shape | 保留 3312/6624/9936/13248 缓存和 global intra-thread pool；继续测实际 shape 分布 |
| P1 | 3 ULSCH/9936 RE 波动较大 | 统一缓存相对专用插件慢 1.4%，重复结果波动高于其他形状 | 增加长时间重复和频率/调度 trace，不据单次均值判断 |
| P1 | 长尾受 OS 调度干扰 | 3312 混合形状曾出现一次 17.5 ms outlier，P99 仍约 199 us | 保留异常值；端到端阶段检查 IRQ、迁核、频率和实时调度，不用均值掩盖尾部 |
| P2 | 厂商公开接口能力有限 | 已安装 2.0.3 公开头文件只暴露 `SessionOptionsSpaceMITEnvInit()`；未找到持久 executor、异步提交或直接 fused MLP ABI | 只使用公开 API；内部符号不能当稳定接口 |
| P2 | TCM/DMA 私有选项存在稳定性风险 | 早期 DMA/block-layout 试验发生挂起和 TCM 占用，后用厂商工具恢复；当前 8/8 block 空闲 | 不在常规实验启用未公开选项；每次实验前后检查 TCM |
| P2 | 质量标度与 Spark 不完全相同 | Spark 原始输出通常按 256 缩放；当前 K3 解码链需 scale=8，scale=256 会破坏当前解码 | 所有比较注明 scale；端到端以 BLER、false positive 和固定输入数值门禁为准 |

## 不能混淆的四件事

1. `taskset -c 0` 固定的是测试程序/OAI 主线程所在的 X100，不表示模型跑在
   X100。SpaceMIT EP 的工作线程由 provider affinity 固定到 CPU8–15，即 A100。
2. 旧的 `run_on_k3_a100` 是把整个标量/RVV 进程切成 AI 线程，适用于早期
   RVV 实验；现在的 ONNX Runtime EP 路径不需要用它包住整个 OAI 进程。
3. 纯插件的 143–180 us 只覆盖预处理、一次 `Session::Run` 和量化，不包含
   FFT、信道估计、资源提取和 LDPC。
4. Stage 15 的约 1.55 ms 是两个解码上下文的完整 RX 仿真时间，不是神经网络
   单次耗时，也不是已经验证的真实双 UE 空口性能。

## 当前优化主线

在厂商没有公开更低开销执行接口的前提下，保留冻结 Spark 模型和公开 EP，
通过“多 ULSCH 合并 + 固定 shape Session 缓存 + shared worker pool”摊销调用
成本。下一阶段应进入真实不同输入的 slot coordinator；完整端到端优化另行进行。
