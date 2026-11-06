# CSG（Codex SMAC Guard）

CSG 是一个 Windows/PowerShell 7 launcher，为 `codex exec` 增加 SMAC（Selected model is at capacity）自动重试、中途续跑、状态和统计。当前版本 **v1.1.1**。

## 安装

在本目录执行：

```powershell
pwsh -File .\csg.ps1 install
```

安装会把 `csg.cmd` / `csg.ps1` 复制到 `%USERPROFILE%\bin` 并把它加入用户 PATH；不修改 `~/.codex/config.toml`。卸载：

```powershell
csg uninstall
```

## 最常用的三个命令

```powershell
# 直接运行任务（默认 gpt-6-astra + ultra）
csg run "修复当前项目中的测试并运行它们"

# 从 Markdown 文件读取 prompt，并指定工作目录/模型
csg run --file .\task.md --cd C:\work\demo --model gpt-6.1-sol --effort low

# 查看正在运行的任务、最近一次结果和统计
csg status
csg stats
```

`csg run` 每次都创建独立 run 目录，prompt 从 stdin 传给 `codex exec`。默认每轮最多 100 次；检测到容量错误后使用带抖动的指数退避。每轮耗尽后默认冷却 30 分钟，再开始下一轮，直到成功。可用 `--attempts-per-round`、`--cooldown`、`--max-rounds`、`--deadline` 调整。

v1.1 新增：

- `--resume-on-smac`：如果 SMAC 发生在回合中途（已产生工具调用），下一次重试用 `codex exec resume <session>` 接着跑，而不是从头重来；resume 失败会自动回退到完整 prompt。默认关闭，可在配置里设 `resumeOnSmac=true`。
- `--attempt-timeout-minutes N`：单次 attempt 超过 N 分钟即杀掉子进程树，按失败计数（连续 2 次超时停止）。默认 0 = 不限制。

v1.1.1 修复并发场景：每个 run 记录 `ownerPid`，避免多窗口同时运行时把另一个正在两次 attempt 之间的活跃 run 误判为 stale；统计按 runId 去重且成功优先，不会出现“成功了但统计仍是失败”。

## 中断与恢复

按 Ctrl+C 会写入 `status.json` 和事件日志并以 130 退出。使用 `csg run --resume <run-id>` 复用原 prompt、目录和模型继续执行。`status` 会显示轮次、尝试次数、冷却倒计时和最后错误。

进程被强杀（任务管理器/关机）时状态会停留在 `running`；`csg status` 会标 `stale`，执行 `csg repair` 可把它们改成 `interrupted` 并补一条统计（`csg run` 启动时也会自动修复）。

## 配置与数据目录

运行数据（`runs/`、`stats.jsonl`、`csg.config.json`）默认在 `%LOCALAPPDATA%\csg`，可用环境变量 `CSG_DATA_DIR` 覆盖；安装时会把仓库里的 `csg.config.json` 复制过去（已存在则不覆盖）。可配置的默认值：

```json
{
  "model": "gpt-6-astra",
  "effort": "ultra",
  "attemptsPerRound": 100,
  "cooldownSeconds": 1800,
  "deadlineMinutes": 0,
  "retainRuns": 30,
  "attemptTimeoutMinutes": 0,
  "resumeOnSmac": false
}
```

也可通过 `csg config set model gpt-6.1-sol` 修改。配置写入数据目录的 `csg.config.json`，不会碰 Codex 全局配置。

## 离线测试

测试不依赖网络：

```powershell
pwsh -File .\tests\run-tests.ps1                 # 基础 6/6
pwsh -File .\tests\adversarial\run-adversarial.ps1  # 对抗 16/16
pwsh -File .\tests\run-upgrade-tests.ps1         # v1.1/v1.1.1 回归 5/5
```

`--codex-cmd` 支持注入任意 `.ps1`/`.cmd` fake executable。测试证据写入 `product\evidence\`。

## 常见问题

- **找不到 codex**：运行 `csg doctor`；必要时用 `--codex-cmd C:\path\codex.exe`。
- **为什么等待很久**：SMAC 会在每次失败后退避；一轮耗尽后默认等待 30 分钟，可在命令行或配置中缩短。
- **如何查看完整输出**：进入 `runs\<run-id>\attempt-xxx-yyy\stdout.log`、`stderr.log` 或根目录 `last-message.md`。
- **非容量错误**：默认立即停止并返回 2，`status` 保存尾部错误；需要持续重试时显式使用 `--retry-non-capacity`。
- **run 一直显示 running**：进程被强杀时 `status.json` 不会更新；`csg status` 会标 `stale`，运行 `csg repair` 修复（`csg run` 启动时也会自动修复）。
- **日志太大**：单个 stdout/stderr 超过 5 MiB 时保留前段并写入截断标记；默认只保留最近 30 个 run。

## 桌面仪表盘（v1.2.0 起内置）

`csg run` 会自动拉起一个无边框置顶小窗，显示活跃 run 的 runId、状态、模型/耗时、轮次与 attempt、**SMAC 次数**、截止时间、**当前执行的命令**、**最近一条进展文本**、token 用量与「距上次进展多久」；run 结束后 15 分钟内还会留一行结束摘要。

```powershell
csg dash          # 手动拉起（run 已自动拉起；失败时补）
csg dash status   # 「运行中 · pid … · 显示 N 个活跃 run」/「未启动」
csg dash once     # 终端打印一份实时快照（不开窗口，脚本里好用）
csg dash stop     # 关闭窗口
```

数据只读自 `runs\<id>\status.json` 与 Codex 的 `%USERPROFILE%\.codex\sessions\**\rollout-*.jsonl`（主线程 `thread_source=user`、按 `cwd` + 启动时间匹配），仪表盘不写 run 数据，只在数据目录写 `dash.json` 记录自身 pid，单实例靠命名 Mutex。关闭自动拉起：`--no-dash`、`csg config set autoDash false` 或环境变量 `CSG_NO_DASH=1`（测试脚本已默认设置）。

## 退出码

0 成功；2 非容量错误/重试耗尽/连续超时；3 截止时间；124 单次超时（内部计数）；130 Ctrl+C 中断；参数/配置错误为 2。

