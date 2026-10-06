# GitHub 发布前检查

此清单用于**准备发布**，不代表执行其中的推送步骤。发布目标是整个 AIRAN 工程的可审查源码、模型、示例配置与文档，不包括个人实验机的运行状态。

**执行位置：K3 上独立的发布检出目录** `/home/ubuntu/airan-release`。`/home/ubuntu/sionna-rk` 是正在使用的实机工作树，不能在其中直接 `git add .` 上传；`ubuntu@ubuntu:~$` 也不是仓库目录。先执行：

```bash
cd /home/ubuntu/airan-release
git rev-parse --show-toplevel
```

输出应为 `/home/ubuntu/airan-release`。若不是，请停止并检查当前目录。Windows 上的 `.work-github-demapper-publish` 是同一发布候选的本地整理副本，不是实机运行目录。

## 1. 内容边界

- [ ] `README.md`、`docs/K3_PROJECT_GUIDE.md`、`docs/AI_PLUGIN_INTEGRATION.md`、`docs/EXPERIMENT_STATUS.md`、`docs/WORKSPACE_MAP.md` 与源码版本一致；未把旧快照写成当前在线二进制。
- [ ] `plugins/neural_receiver/k3_a100`、`plugins/neural_demapper/k3_a100` 含源码、构建与数值/烟雾测试，**不含** `build/` 或临时缓存。
- [x] 两份模型权重的来源与 SHA-256 已核对：接收机是我们在 Spark 上训练的 h24 模型；解调器是 NVIDIA Sionna-RK 上游检查点的格式转换，模型卡说明 Apache-2.0。保留上游署名和许可证；接收机训练日志未留存，不能宣称精确复训。
- [ ] `vendor/openairinterface5g`、Sionna-RK 与第三方代码的许可证、版权声明仍完整；未把第三方代码说成项目原创。
- [ ] `k3-porting-kit` 是单独的内核/CN5G 安装仓库，此处只提供链接；本仓库不假装包含可用的 SIM/订户数据。
- [ ] 原始视频、Office 文件、实验日志、抓包、数据库、主机密钥、环境文件、`.baseline/`、`.runtime/` 不在本次变更中。

## 2. 敏感信息审查

在同一个 K3 Bash 窗口、确认当前目录正确后运行。人工审查**文件名列表**，不要把命中值复制到 issue 或公开评论。`git grep` / `rg` 没有命中时退出码为 1，这是正常情况：

```bash
git status --short
git ls-files --others --exclude-standard
git grep -I -l -E 'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|AKIA[0-9A-Z]{16}' -- . || true
rg -l --hidden -i 'imsi|opc|password|secret|private.key|api[_-]?key' \
  config docs scripts plugins -g '!*.weights' -g '!*.onnx*' || true
```

关键词命中不必然是泄露：示例配置、警告文字和测试脚本也会出现这些词。必须检查每个命中文件是否含真实凭据、可识别订户/设备身份或不应公开的网络参数。真实值一旦进入 Git 历史，之后单纯删掉文件并不能清除历史；若发现泄露，先停止推送并轮换相关凭据。

本仓库继承的 `vendor/openairinterface5g` 内有上游示例 `.log` 和 `.sql`，它们已在旧提交中受 Git 跟踪；发布前仍应确认只是上游测试样例，而非本地真实订户数据。自动关键字扫描还可能命中补丁中嵌入的 PNG/base64 内容，不应把这种命中直接解释成密钥。

## 3. 体积与仓库卫生

```bash
git diff --check
git status --short
git ls-files --others --exclude-standard
```

检查新增文件是否意外包含 `.so`、`.o`、`.log`、`.pcap`、数据库、缓存、重复的大模型或压缩包。对每个将发布的文件记录来源，必要时使用 `sha256sum`。这个工作树已有上游/vendor 文件；不要用宽泛的 `git add .` 代替人工审查。

## 4. 可复现性检查

- [ ] 在 K3 上执行接收机 `bash build.sh`、`bash verify.sh`，记录 12/24 RB 数值结果；在线 gNB 活跃时**不采用**该次延迟数字作为正式基准。
- [ ] 在 K3 上执行解调器 `bash build.sh`、`bash verify.sh`，记录加载、回退和 16-QAM 结果。
- [ ] 只在可中断无线业务的实验窗口做完整 OAI/实机对照；保留原稳定服务的启动方式和日志。
- [ ] README 的所有相对链接、命令和版本说明经人工核对。对于缺失的 CN5G/SIM/UHD 依赖，明确说明需要另行准备。
- [ ] 对 3 Mbps、51/106 RB、重连和 XSAI 迁移等未通过项不使用“已完成”措辞。

## 5. 提交与上传

确认上述内容后，仍在同一 K3 Bash 窗口，只选定本轮文件：

```bash
git add .gitattributes .gitignore README.md \
  docs/K3_PROJECT_GUIDE.md docs/AI_PLUGIN_INTEGRATION.md \
  docs/EXPERIMENT_STATUS.md docs/WORKSPACE_MAP.md docs/GITHUB_RELEASE_CHECKLIST.md \
  plugins/neural_receiver/k3_a100 plugins/neural_receiver/models/k3_native_joint_h24.weights \
  plugins/neural_demapper/k3_a100 plugins/neural_demapper/models/demapper_a100.weights \
  patches/oai-neural-receiver-timing.patch
git diff --cached --check
git diff --cached --stat
```

仔细审阅 `git diff --cached` 后再提交、推送。**本次整理工作不会自动执行 `git add`、commit 或 push。** 若发布到新的公开仓库，先核对远端地址和可见性；若更新已有 `XSAI_AIRAN`，先检查远端是否有新的提交，避免覆盖别人的更改。
