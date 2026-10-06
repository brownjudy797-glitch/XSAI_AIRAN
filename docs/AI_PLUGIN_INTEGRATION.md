# K3 AI 插件接入与观察指南

本文面向**已有可用 gNB + CN5G + UE 的 K3**。构建 `.so` 与启用在线 gNB 是两个不同操作。改变运行中的 gNB 服务可能中断 UE/PDU 会话，只应在可中断业务、已保存原服务配置且能回滚的实验窗口进行；不要在别人的在线实验中直接照抄启动命令。

## 1. 两个插件的处理边界

```text
接收符号 + 导频 ── 神经接收机 ── LLR ── OAI LDPC 译码
        │
        └─ 传统：信道估计/均衡 → LLR

传统均衡后的符号 ── 神经解调器 ── LLR ── OAI LDPC 译码
```

神经接收机覆盖的处理范围比神经解调器大。两个插件分别使用 `receiver`、`demapper` loader ABI，不能把两者都称为“神经解码器”。当前短时实机演示只启用**接收机**，不是同时启用两个模型。

## 2. 构建并固定产物

在 K3 项目目录（默认 `/home/ubuntu/sionna-rk`）：

```bash
cd plugins/neural_receiver/k3_a100
bash build.sh
bash verify.sh
sha256sum build/libreceiver_a100_native_h24_b4_b256_hcache_power.so \
  ../models/k3_native_joint_h24.weights
```

解调器独立验证：

```bash
cd /home/ubuntu/sionna-rk/plugins/neural_demapper/k3_a100
bash build.sh
bash verify.sh
sha256sum build/libdemapper_a100_rvv.so ../models/demapper_a100.weights
```

前提是 K3 的 GCC/G++ 16、目标内核的 A100 HMP 接口、兼容 OAI 的头文件/生成目录与 `sudo -n` 均可用。数值/烟雾测试不负责替换正在运行的服务。

## 3. 接收机如何交给 OAI 加载

在兼容的 `nr-softmodem` 启动配置中，接收机需要以下设置；**这是参数片段，不是可直接复制运行的完整 gNB 命令**：

```text
环境变量：
XSAI_RECEIVER_NATIVE_WEIGHTS=/home/ubuntu/sionna-rk/plugins/neural_receiver/models/k3_native_joint_h24.weights
XSAI_RECEIVER_LLR_GAIN=4
XSAI_RECEIVER_H_INTERP=1

nr-softmodem 参数：
--loader.receiver.shlibpath /home/ubuntu/sionna-rk/plugins/neural_receiver/k3_a100/build
--loader.receiver.shlibversion _a100_native_h24_b4_b256_hcache_power
```

OAI loader 用 `libreceiver` + 上述版本后缀定位 `.so`。启动前检查文件存在、架构为 RISC-V、导出 `receiver_init`、`receiver_compute_llr` 等符号；检查模型散列和 OAI ABI。现有线上 K3 在整理时仍加载旧 `.work-neural-receiver-a100/build` 路径，虽然新旧 `.so` 散列相同，**本仓库没有自动切换该服务**。

该模型当前处理不超过 24 RB 的单层 16-QAM PUSCH 和特定 DMRS 形状；不满足条件走 OAI 原路径。实验配置曾将 `ul_max_mcs` 限于调制阶数 Qm4 对应范围，避免高阶调制全部回退后仍误称为“AI 处理”。B210 频带能力与插件 RB 能力不是同一概念。

解调器若在独立实验中启用，对应参数是 `--loader.demapper.shlibpath`、`--loader.demapper.shlibversion _a100_rvv`，并设置 `XSAI_DEMAPPER_WEIGHTS` 指向其权重文件。不要未经联合测试就同时启用接收机与解调器。

## 4. 如何证明 AI 真正在 A100 上执行

启动后按由弱到强的顺序核对：

1. 把下面的服务名替换成现场 gNB 服务名，确认**实际**加载路径和版本后缀，不只看配置文件草稿：

   ```bash
   service_name='你的-gNB.service'
   systemctl show "$service_name" -p ExecStart
   pid=$(systemctl show "$service_name" -p MainPID --value)
   ps -L -p "$pid" -o tid,psr,comm,stat,pcpu
   ```

2. 仅检查当前启动实例的日志，确认 `K3_NATIVE_JOINT_RECEIVER ready=1 ai_cpu=8`；若缺失，优先检查插件是否加载、HMP 切换与模型文件。
3. UE 产生上行流量时，当前实例日志中的 `K3_NATIVE_JOINT_RECEIVER call=` 计数持续增长，并显示相应 RB。只有初始化信息而无调用不能证明实际推理。
4. `psr=8` 只表明拍摄瞬间线程在 CPU8，还需结合调用日志证明执行。常规 L1 工作线程可在 X100（CPU0–7），A100 工作者在 CPU8。
5. 最后确认 UE 注册、PDU 会话和用户面没有因切换而失效。一个成功的 Ping 不等于吞吐或稳定性通过。

`top`、`ps` 的采样会带来轻微开销；正式热点耗时实验不要同时运行高频监控。异构调度展示可放在普通端到端连接实验，性能对比另在安静窗口做。

## 5. 计时和回退

插件内部分 `input`、`a100_inference`、`llr_output`、`total`。固定同一 RB/MCS、包长、持续时间，按每 PUSCH 总时间比较传统与 AI。`inference_us` 不是 gNB 接收全链路耗时；抽样日志也不是 P95/P99。

切换前保存旧服务定义、二进制和模型散列，确认核心网进程唯一；测试失败先回到原稳定服务，再让 UE 重新建立会话。不要通过删除整个工作树、无差别杀进程或反复拨号来“恢复”。任何会停止所有 `xsai-*` 服务的离线门禁脚本，必须先阅读其停止/恢复逻辑，并在允许中断业务的窗口运行。
