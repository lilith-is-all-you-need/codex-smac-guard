# 任务：构建 Codex「SMAC 自动重试」交付物（代号 csg = Codex SMAC Guard）

你是一个在 Windows 上工作的资深工程师。用户长期用 Codex 跑项目任务，但经常遇到：

```
ERROR: Selected model is at capacity. Please try a different model.
```

（下称 SMAC；codex 以 exit code 1 退出，错误打印在 stdout/stderr，且通常发生在回合开始后几秒到几十秒内。）

用户要求你**独立设计并实现**一个插件/组件/launcher，满足：

1. **随时可拉起**：用户每次想做任务时，都能用同一条简单命令把「带 SMAC 保护的 Codex 任务」拉起来；不要求用户改代码或记复杂参数。
2. **SMAC 自动重试**：识别到 SMAC 后自动重新请求同一任务；**单轮最多重试 100 次**；一轮 100 次全部仍是 SMAC 后，**等待 30 分钟**，再开始下一轮，如此循环**直到成功**（不设轮数上限；可配置）。
3. **对用户操作友好**：中文提示、实时进度、可查看状态/统计、可中断、可恢复、失败原因清楚、默认参数合理、一条命令安装。

## 环境事实（已核实）

- 工作区（只在这里写文件）：`C:\Users\LLS\Pictures\lilith's card design\科技\codex_harness`
- 你的交付物放在 `product\` 子目录；文档 `product\docs\`；测试证据 `product\evidence\`。
- Codex CLI 版本 `0.166.0`，可执行文件：`C:\Users\LLS\AppData\Local\OpenAI\Codex\bin\b6c7fc9497179c98\codex.exe`（另有 `%APPDATA%\npm\codex.cmd` 包装）。
- `codex exec` 用法要点：`exec --skip-git-repo-check -s danger-full-access -C <dir> -m <model> -c model_reasoning_effort="<low|medium|high|xhigh|max|ultra>" --color never -o <last-message.md> -`（`-` 表示从 stdin 读 prompt）。
- 可用模型包含 `gpt-6-astra`（支持 `ultra` 推理档，会自动任务委派）、`gpt-6.1-sol`、`gpt-6-sol` 等。默认模型建议 `gpt-6-astra` + `ultra`，可配置。
- 运行时：Windows + PowerShell 7（`pwsh`）。不要引入需要联网安装的依赖；不要依赖 Node/Python 包。
- 用户 `~/.codex/config.toml` 中存在其他配置，**未经备份不得修改**；任何全局修改必须可一键还原（提供 `csg uninstall`/`--restore`）。
- 机器上已有一个我（监督者）写的私有 `_supervisor\run-codex.ps1`；你可以阅读借鉴思路，但**产品必须独立、自包含**，不得在运行时依赖 `_supervisor`。

## 必须交付的功能

### A. 核心 launcher
- `csg run "<任务文本>"`（也支持 `--file task.md`、`--cd <dir>`、`--model`、`--effort`）；
- 内部调用 `codex exec`，把任务 prompt 从 stdin 传入，工作目录正确；
- 实时把 Codex 输出落盘（本次 run 目录：stdout/stderr/最后消息/事件日志），终端显示精简进度而不是刷屏；
- SMAC 检测：组合 stdout+stderr 文本正则（大小写不敏感），至少覆盖 `selected model is at capacity`；
- 重试策略：单轮 100 次（默认，可配置），SMAC 后短暂退避（建议指数/抖动，几秒到 2 分钟，避免 100 次瞬间打满）；
- 一轮耗尽 → 冷却 30 分钟（默认，可配置）→ 下一轮；**无限轮**直到成功（可配 `--max-rounds`）；
- 终止条件：成功（exit 0 且无 SMAC）、非容量错误（明确报告后停止，可选 `--retry-non-capacity`）、`--deadline` 到期、Ctrl+C；
- 中断/断点：Ctrl+C 后状态落盘；`csg run --resume <run-id>` 可继续未完成任务（可复用 run 配置与 prompt）；
- 退出码约定清晰（0 成功；2 非容量错误；3 截止；130 中断）。

### B. 用户友好
- 启动 banner：模型、工作目录、每轮次数、冷却时长、截止时间；
- 进度行示例：`[14:03:22] 第 2 轮 · 第 17/100 次 · 上次: SMAC · 累计 SMAC 35 · 已用 1h02m · Ctrl+C 停止`；
- `csg status`：显示当前活跃 run 的轮次/次数/冷却倒计时/最后错误，以及最近完成的 run；
- `csg stats`：聚合统计（总尝试、SMAC 次数、成功率、按模型/按天、平均首次成功耗时），数据来自 `stats.jsonl`；
- `csg doctor`：检查 codex 路径/版本/登录状态/默认模型，输出人话结论；
- `csg install`：把 `csg.cmd`/shim 安装到用户 PATH（如 `%USERPROFILE%\bin`），并在桌面创建快捷方式（可选）；`csg uninstall` 可移除；
- 配置：`csg.config.json`（默认模型/推理档/每轮次数/冷却/截止/日志保留），`csg config set` 或直接编辑均可；
- 日志保留策略：默认保留最近 30 个 run，自动清理，避免磁盘膨胀；单个 attempt 日志超大时截断策略明确。

### C. 可验证性（重点）
- 必须支持 `--codex-cmd <可执行或 .ps1/.cmd>` 注入，用于离线测试；
- 附带 `product\tests\fake-codex.ps1`：可模拟「前 N 次 SMAC 然后成功」「一直 SMAC」「非容量错误」「超时」等场景（参数化）；
- 附带 `product\tests\run-tests.ps1`：一键跑完以下断言，输出 PASS/FAIL 与证据文件：
  1. 3 次 SMAC 后成功：总尝试 4、SMAC 3、退出 0；
  2. 一轮耗尽：把每轮次数调小（如 3）+ 冷却 1s，模拟 7 次 SMAC 后成功：应跨 2 轮、总尝试 8 左右、退出 0；
  3. 非容量错误（如 "authentication failed"）：立即停止、退出 2、错误信息进 status；
  4. 截止时间：`--deadline` 设为过去 → 立即退出 3；
  5. prompt 含中文/引号/换行：fake codex 能完整收到 stdin（用 hash 校验）；
  6. `status`/`stats` 在 run 完成后输出正确计数；
- 真实冒烟：`csg run "Reply with exactly: CSG-OK" --model gpt-6.1-sol --effort low` 成功（允许一次真实调用，不要滥用额度）。

### D. 文档
- `product\README.md`（中文，面向普通用户：安装、3 个常用命令、如何看状态、常见问题）；
- `product\docs\design.md`（架构、状态机、重试策略、数据格式、退出码）；
- `product\docs\smac-notes.md`（SMAC 现象、检测证据、与轮询/退避的取舍）；
- `product\docs\transparent-mode-feasibility.md`（**调研项**：能否用本地 HTTP 代理 + `model_providers` 配置，让 TUI/桌面 App 也透明重试；给出结论、证据、风险与后续路线。最多花 45 分钟，不要为此冒险改用户全局配置）；
- `product\BUILD-REPORT.md`：你做了什么、如何自测、证据路径、已知限制、后续建议（≤120 行）。

## 约束

- 只写 `codex_harness\` 内的文件；**不要修改** `C:\Users\LLS\Desktop\[Lilith]Mythware` 或 `~/.codex/config.toml`（只读检查可以）。
- 不要启动其它 codex 会话/agent；不要用 codex 递归调用自己。
- 不要提交 git（该目录不是仓库）。
- PowerShell 脚本必须兼容 PowerShell 7，路径含空格/中文/方括号要处理好（`-LiteralPath`，不要用未加引号的通配路径）。
- 你的产出会被另一个 agent 做对抗性审查，请把边界情况做实（空 prompt、超长 prompt、run 目录已存在、并发两个 run、stats 文件损坏、冷却期间被中断、日志写失败）。
- 预计 2.5 小时内完成；每完成一个里程碑就更新 `product\BUILD-REPORT.md`，不要只在最后才写文件。

## 验收标准（自查后再交付）

- `product\tests\run-tests.ps1` 全绿，证据落盘；
- 真实冒烟成功；
- 新开一个 shell 能用 `csg run/status/stats/doctor`；
- 用户不改任何代码、只记 `csg run "..."` 就能用；
- 统计能回答「这个月 SMAC 了多少次、平均第几次成功」。

完成后在最后一条消息里给出：交付路径、测试摘要、真实冒烟结果、遗留问题（≤30 行）。
