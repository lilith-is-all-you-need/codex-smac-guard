# CSG 设计说明

## 组件

`csg.ps1` 是单文件 PowerShell 7 launcher；`csg.cmd` 仅负责转发到脚本，保证新 shell 中可直接调用。每次运行写入数据目录 `%LOCALAPPDATA%\csg\runs\<run-id>\`（可用 `CSG_DATA_DIR` 覆盖），全局统计位于 `<数据目录>\stats.jsonl`。运行时通过 `System.Diagnostics.Process` 启动 `codex exec`，将 prompt 以 UTF-8 写入 stdin，并异步读取 stdout/stderr。

## 状态机

轮内循环为 `running`；一轮尝试耗尽后进入 `cooling`，冷却结束回到 `running`。终态：成功（exit 0）→ `succeeded`；非容量错误、轮数耗尽或连续超时 → `failed`；到截止时间 → `deadline`；Ctrl+C 或强杀后修复 → `interrupted`。每次状态变化先写 `status.json`，再追加 `events.jsonl`，因此中断或崩溃后仍可恢复。

## SMAC 检测

组合 stdout、stderr 与 `last-message.md`，使用大小写不敏感的多行正则，匹配完整的 `^\s*ERROR\s*:\s*Selected\s+model\s+is\s+at\s+capacity\.\s*Please\s+try\s+a\s+different\s+model\.\s*$` 行，且要求进程 exit code ≠ 0。任务正文引用这句话不会被误判；`disk at capacity` 等无关文本也不会命中。其他非零退出视为非容量错误（除非显式开启 `--retry-non-capacity`）。

## 重试与截止

默认每轮 100 次。每次失败后按 `min(backoffMax, backoffBase × 2^(n-1))` 退避，并附加 ≤25% 抖动（默认 base 1s、max 120s）。一轮耗尽后默认冷却 1800 秒，冷却倒计时写入 `status.json`；`--max-rounds 0` 表示无限轮。每次等待都检查 deadline 和 Ctrl+C；`--deadline` 可为 ISO 时间或相对分钟，到期返回 3。`--attempt-timeout-minutes` 控制单次 attempt 超时（默认 0 = 不限制）。

## 中途续跑

`--resume-on-smac` 开启时，若 SMAC attempt 已产生会话 id 且检测到工具动作，下次尝试改用 `codex exec resume <session>` 并发送“继续”prompt；resume 失败自动回退为完整 prompt。

## 文件格式

- `status.json`：runId、state、round、attemptInRound、totalAttempts、smacCount、cooldownRemainingSec、lastError、model、effort、workDir、startedAt/updatedAt、exitCode、ownerPid。
- `events.jsonl`：每行包含时间、事件类型及轮次/尝试信息。
- `attempt-<round>-<attempt>/stdout.log`、`stderr.log`、`last-message.md`：单次原始输出（已脱敏）。
- `stats.jsonl`：完成后追加摘要，包含 attempts、smac、durationSeconds、model、started、success、reason，供 `stats` 按 runId 去重聚合。

### 日志截断与保留

读取子进程输出后落盘；单个 stdout/stderr 超过 5 MiB 时保留前段并写入中文截断标记。清理任务按目录最后修改时间删除最旧 run，默认保留 30 个。

## 并发与恢复

每个 run 使用唯一时间戳加随机后缀目录，因此并发启动不会覆盖目录。`run` 启动时自动调用 repair：依据 `ownerPid`（优先）或“pid + 进程启动时间”判断活跃 run，避免多窗口并发时误杀；被强杀的 `running` 记录改为 `interrupted` 并补一条统计。`--resume` 读取原 run 的 `status.json` 与 `prompt.md`，沿用模型、工作目录、退避和轮次配置继续执行；若 run 已成功，恢复命令仍会按保存配置重新运行，使用前应确认意图。

## 退出码

0 成功；2 非容量错误、轮数耗尽、连续超时或 codex 启动失败；3 deadline；124 单次超时（内部计数）；130 Ctrl+C 中断；参数/配置错误为 2。

## 安全边界

CSG 不改写 `~/.codex/config.toml`，不保存凭据，不启动嵌套 Codex；日志与状态中的 Bearer、`sk-`、token/password 等形式会脱敏。`install`/`uninstall` 只操作用户 bin 与 shim，并用 `install-state.json` 保存/恢复用户 PATH。
