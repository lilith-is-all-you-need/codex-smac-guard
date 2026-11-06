# csg 新手指南（Codex SMAC Guard）

> 适用：Windows + PowerShell 7。解决 Codex 报 `ERROR: Selected model is at capacity. Please try a different model.`（简称 SMAC）时，任务直接死掉、要人守着点重试的问题。

## 1. 先确认装好了

打开一个新的 PowerShell 窗口：

```powershell
csg doctor
```

正常会看到：

```
CSG 版本: 1.1.1（数据目录: C:\Users\<你>\AppData\Local\csg）
Codex 路径: ...\codex.cmd
版本: codex-cli 0.166.0
默认模型: gpt-6-astra，推理档: ultra
登录配置: 已找到 ~/.codex/config.toml
```

> 如果提示找不到 `csg`：在 `product` 目录执行 `pwsh -File .\csg.ps1 install`，然后**新开**一个终端。

## 2. 第一个任务

```powershell
cd C:\你的项目
csg run "读 README，跑一遍测试，把失败原因写进 report.md"
```

你会看到：

```
CSG · Codex SMAC Guard v1.1.1
模型: gpt-6-astra · 工作目录: C:\你的项目 · 每轮: 100 · 冷却: 1800s · 截止: 无 · 单次超时: 关 · SMAC续跑: 关
[23:12:01] 第 1 轮 · 第 2/100 次 · 上次: SMAC · 累计 SMAC 1 · 已用 2m10s · Ctrl+C 停止
结束：succeeded，尝试 4 次，SMAC 3 次，退出码 0
```

只要看到 `结束：succeeded` 就是成功。任务输出在 run 目录里（见第 6 节）。

## 3. 常用写法

```powershell
# 指定工作目录与模型
csg run --cd C:\work\demo --model gpt-6.1-sol --effort high "修一下构建"

# 任务书很长，放文件里
csg run --file .\task.md --cd C:\work\demo

# 限制总时长（到点自动退出，退出码 3）
csg run "跑回归" --deadline "2026-11-05T08:00:00"

# 单次 attempt 最长 45 分钟，超时杀掉重试
csg run "跑回归" --attempt-timeout-minutes 45

# SMAC 发生在中途时，下一次用 resume 接着跑（默认关）
csg run "长任务" --resume-on-smac
```

默认值：每轮 100 次、轮间冷却 30 分钟、无限轮、模型 `gpt-6-astra` + `ultra`。

## 4. 看状态与统计

另开一个窗口（或任务跑着时）：

```powershell
csg status
csg stats
```

`status` 会告诉你：现在第几轮/第几次、冷却还剩多少秒、累计 SMAC、最后错误；已结束的 run 也会列出来。

`stats` 是累计账本（历史快照，数字会随后续运行变化）：

```
总 run: 6 · 总尝试: 26 · SMAC: 21 · 成功率: 33.3% · 未成功: 4（其中中断/超时 4）
```

> 成功率低不一定是工具坏了：被手动杀掉的 run 也算“未成功”。

## 5. 中途想停 / 断了想续

- **Ctrl+C**：立即杀掉当前 attempt 的进程树，以退出码 130 结束并把状态落盘。
- 强杀（任务管理器/关机）会留下 `running` 状态；`csg status` 会标 `stale`，执行：

```powershell
csg repair
```

- 续跑一个被中断的 run：

```powershell
csg run --resume 20261104-233649-63c20b
```

## 6. 文件都在哪

数据目录默认 `%LOCALAPPDATA%\csg`：

```
runs\<run-id>\
  prompt.md           # 本次任务原文
  status.json         # 实时状态
  events.jsonl        # SMAC/冷却/超时/完成事件
  attempt-001-001\
    stdout.log        # Codex 完整输出
    stderr.log
    last-message.md   # Codex 最后一条消息
stats.jsonl           # 所有 run 的汇总
csg.config.json       # 默认配置
```

要改默认值：`csg config set model gpt-6.1-sol`，或直接编辑 `csg.config.json`。

## 7. 新手最容易踩的坑

| 现象 | 原因 | 处理 |
|---|---|---|
| `csg` 不是命令 | 装完没开新终端 | 新开 PowerShell；或 `%USERPROFILE%\bin\csg.cmd` |
| 一直显示 `running` | 进程被强杀，状态没来得及写 | `csg repair` |
| 任务中途 SMAC 后从头跑 | 默认不续跑 | 加 `--resume-on-smac`（会话已有工具调用时生效） |
| 在 Codex 桌面/TUI 里直接开的会话不生效 | csg 只管 `codex exec` | 用 `csg run` 起任务；TUI 透明代理尚未实现 |
| 冷却 30 分钟太久 | 默认策略 | `--cooldown-seconds 300` 临时缩短 |
| 日志太多 | 默认保留 30 个 run | 改 `retainRuns`，或手动删 `runs\` |

## 8. 本次 VM 调查的实际用法（示例）

```powershell
# 在 [Lilith]Mythware 项目里，让 Astra 去 .79 上查 Patch 失败
csg run --file "C:\...\prompts\F-vm79-fix.md" `
        --cd "C:\Users\LLS\Desktop\[Lilith]Mythware" `
        --model gpt-6-astra --effort ultra `
        --resume-on-smac --attempt-timeout-minutes 90 `
        --deadline "2026-11-05T08:00:00"
```

跑的时候另开窗口 `csg status` 看轮次/冷却；结束后看 `csg stats` 和 run 目录里的 `last-message.md`。

> 记住一句话：**csg 不改变 Codex 的能力，它只负责在你不在的时候替你按住“重试”。任务本身仍然要可重入、要有明确的成功标准。**

