# K3 固定项目版本：K3-A-20260922

本文件是当前 K3 实机项目的版本入口。旧 RFsim、B210 指导中的构建目录和切换命令仅作历史参考，不用于覆盖当前部署。

## 固定范围与状态

- 项目：`/home/ubuntu/sionna-rk`，项目 HEAD `0abdce3ff7f5840d64b783632eb419ea6bf54ae5`，保留现有工作区改动，未自动提交或重置。
- 唯一在用 OAI：A 版（同门大改版，加本次计时补丁），`ext/openairinterface5g`。
- OAI HEAD：`c6698f7dda869e0ab92e232da08d1a91385eb044`，另有 9 个已跟踪文件的未提交改动。完整工作树源码快照和补丁已保存，不能只用 HEAD 重现。
- 唯一选定构建：`ext/openairinterface5g/cmake_targets/phy-fixed-build-20260922`。不要使用遗留 `ran_build/build`，不要重新运行 A/B 对调或旧版本准备脚本。
- gNB SHA256：`ddb267e5fbbd030f7b28f9560e6673db2816c2ce3a1db932f4d5109581d09f7f`。
- B 版已从 `ext` 移至 K3 回收站，未永久销毁。不恢复到实验路径，不清空回收站中的源码修改。
- **这是版本固定，不是通信验收通过。UE 连接尚有未解决问题；上午 A 版成功实验数据单独保留，不能用来代表当前已恢复连接。**

## 唯一推荐的操作入口（K3 Bash）

```bash
cd /home/ubuntu/sionna-rk
python3 scripts/k3-fixed-baseline.py --check
bash scripts/run-k3-b200.sh start
bash scripts/run-k3-b200.sh status
# 仅在确实需要停止时执行：会停止 gNB 和核心网
bash scripts/run-k3-b200.sh stop
```

默认 `start` 已加基线校验，在启动核心网、写运行配置和启动 gNB 之前执行。校验失败会拒绝该入口启动并列出变化文件；不会停止已运行的进程。`status/stop` 不受校验阻挡。不要绕过入口直接执行二进制或使用 `.runtime` 内历史诊断启动器。

校验覆盖 4064 个已固定文件，包括 OAI 已跟踪源码、选定构建的程序/动态库、实际加载的系统和核心网库、核心网程序、关键配置及启动脚本；同时核对项目/OAI HEAD，并检查 B 版目录未重新出现。它不是全磁盘防篡改或实时监控，不会阻止手动编辑、其他入口启动或新增未跟踪文件。

## 保存位置与恢复材料

K3：`/home/ubuntu/sionna-rk/.baseline/k3-a-20260922`。

- `manifest.json`：基线版本与 SHA256 清单。
- `oai-tracked-working-tree.tar.gz`：OAI 已跟踪文件当前内容（含未提交改动）；不含未初始化子模块和完整 Git 历史。
- `oai-unstaged.patch`、`oai-staged.patch`：OAI 改动。
- `project-unstaged.patch`、`project-staged.patch`：父项目已跟踪改动，不是父项目完整备份。
- `deployment-files/`：关键启动脚本、配置、二进制和已加载依赖库快照。
- `run-k3-b200.before-guard.sh`：添加启动校验之前的启动脚本。
- `runtime-service.txt`：固定时实际服务参数。

快照目录为所有者专用权限。配置可能包含本地凭据，不公开上传；数据库/SIM 订阅数据未导出。本固定操作不替代整机或数据库备份。

## 当前运行参数

真实 UE + B210（31EC606），24 PRB，PLMN 26299，PCI 0，SSB ARFCN 640320；收发采样率 15.36 MSps；非 RFsim。

`usrp-tx-thread-config=1`、`min_rxtxtime=8`，连续发射选项未启用。两次临时诊断参数已撤回；UE 为自动选网。

gNB 允许 CPU 0–6；L1 RX=0，L1 TX=1，RU 及其继承亲和性的辅助线程=2，显式 PHY 工作线程=3/4/5/6；B210 USB IRQ=7。核心网允许 CPU 0–7，存在共核；CPU 2 辅助线程分散逻辑在最近启动时被跳过。实时预算 950000/1000000 微秒。这些是固定时的现状，不代表调度已优化。

## 后续改动规则

修复 UE 时先记录单变量诊断和结果，不覆盖此快照，不把诊断运行混入正式 PHY 数据。确需改变默认源码、构建、配置或调度后，建立新的有日期/编号基线，注明差异并重新验证接入和固定负载；不要删除校验来掩盖变化，也不要重新运行 `--freeze` 覆盖当前版本。
