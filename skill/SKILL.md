---
name: csg
description: "Codex SMAC Guard：凡是通过 Codex CLI（codex exec）跑任务、遇到 Selected model is at capacity/SMAC、或要查询/续跑 csg 运行时，必须先加载本 skill。用 csg 包装任务，自动重试、续跑、留档。"
---

# CSG — Codex SMAC Guard

`csg` 是 `codex exec` 的自动重试 launcher：单轮默认 100 次、轮间冷却 30 分钟、默认无限轮，直到成功。本 skill 是运行 Codex CLI 任务的标准入口。

## 何时必须使用

- 用户要求在某个项目里跑 Codex 任务（尤其是长任务、无人值守、要跑几十分钟以上的）。
- 输出出现 `ERROR: Selected model is at capacity. Please try a different model.`（SMAC）。
- 用户要查看/续跑/修复 csg 运行（`csg status` / `stats` / `repair` / `--resume`）。
- 用户说“用 csg 跑”“codex 又 capacity 了”“看看之前的 run”。

用户直接说 `/csg` 时，同样从本 skill 的流程开始。

## 强制规则

1. **不要裸跑 `codex exec` 做长任务**；一律用 `csg run`。csg 负责重试、冷却、日志和统计。
2. 启动前先 `csg doctor` 确认 codex 路径/版本/登录。找不到 `csg` 时用仓库脚本：`pwsh -File "<codex_harness>\product\csg.ps1"`；需要安装时执行 `pwsh -File "<codex_harness>\product\csg.ps1" install`，然后新开终端。仓库默认在 `C:\Users\LLS\Pictures\lilith's card design\科技\codex_harness`。
3. 长任务必须作为后台 job 启动（DSH 的 `pwsh` + `run_in_background`），从输出拿到 run 信息；不要阻塞会话。
4. 运行中用 `csg status` 低频查看，不要 busy-loop 或反复探测进程。
5. **每次拉起必须确认桌面仪表盘**：`csg run` 会自动拉起桌面仪表盘（`csg dash`）。启动后立刻执行 `csg dash status`，输出必须是「仪表盘: 运行中」；不是就执行 `csg dash` 补拉起。补拉起仍失败时，必须在汇报里写明失败原因，并改用 `csg status` / `csg dash once` 作为查看通道。仪表盘是无人值守时唯一不打断会话就能看实时进展的通道，不要跳过这一步。
6. 结束时必须向用户汇报：run id、尝试次数、SMAC 次数、退出码、`last-message.md` 的结论摘要；失败要给出 `status.json` 里的 `lastError`；同时汇报仪表盘最终状态（运行中 / 已关闭 / 拉起失败）。
7. **改动必须同步 GitHub（本地工作副本即仓库）**：凡是改 csg 本体（`product/csg.ps1` 等）、仪表盘或本 skill，都要在本地仓库 `C:\Users\LLS\Pictures\lilith's card design\科技\codex_harness` 里 `git add/commit/push` 到 `https://github.com/lilith-is-all-you-need/codex-smac-guard`，并用 `git ls-remote` 确认远端已有该提交。推送前先跑 `pwsh -File product\tests\run-tests.ps1`（应为 6/6）。本 skill 与仓库里的 `skill/SKILL.md` 是同一份内容的两处副本，改完必须两边同时更新。
8. **语言**：写任务书、续跑指令和 agent 间沟通用**英文**；交付给用户的结果用**中文**（由本层转译），详见下面「语言约定」。

## 语言约定：过程全英文，交付全中文

- **任务书 / Prompt 一律英文**：`csg run "..."` 的文本、`--file task.md` 的内容、给 Codex 的追问与续跑指令、agent 之间（子代理、多会话、异常上报）的沟通，全部用英文。英文任务书在 Codex 侧更稳、歧义更少，也避免中英混排把指令吃掉。
- **不要为了英文去改 csg 本体**：csg 自己的进度行/报错/`status` 输出是中文，那是工具输出而不是"交流"，保留原样即可，不需要翻译也不需要改代码。
- **给用户的最终结果一律中文**：run 结束后由**本层（DSH 会话里的 agent）**把英文的 `last-message.md`、`lastError`、日志要点转译成中文再交付；不要把英文原文直接丢给用户。
- **对用户的中途进度也用中文**：英文只用于「喂给 Codex 的输入」和「agent 之间的沟通」；凡是直接写给用户的内容（进度、卡点、结论）一律中文。
- 转译时保留英文专有名词/命令/路径/代号原文（`csg run`、`SMAC`、`status.json` 之类），只翻叙述部分。
- 例外：任务本身就是要中文产出（中文文案、本地化、中文语音稿），或用户明确要求用中文写任务书。此时按用户要求执行，但必须在汇报里写明"本任务按用户要求用中文写任务书"。

## 基本用法

```powershell
csg run "Make the project test suite pass and fix the failing tests"
csg run --file .\task.md --cd C:\work\demo --model gpt-6.1-sol --effort high   # task.md 用英文
csg status
csg stats
csg doctor
csg dash status      # 启动后必须确认：仪表盘是否已拉起
csg dash             # 手动拉起（run 会自动拉起，失败时补）
csg dash once        # 终端里打一份实时快照，不开窗口
csg dash stop        # 关闭仪表盘
```

默认：模型 `gpt-6-astra`、推理档 `ultra`、每轮 100 次、冷却 1800 秒、无限轮。

### 桌面仪表盘（v1.2.0 起内置）

`csg run` 会自动拉起一个无边框置顶小窗，显示：run id、状态（运行中/冷却中）、模型与耗时、轮次与累计 attempt、**SMAC 次数**、截止时间、**当前执行的命令**、**最近一条进展文本**、token 用量与「距上次进展多久」；run 结束 15 分钟内还会留一行结束摘要。数据只读自 `runs\<id>\status.json` 与 Codex 的 `~/.codex/sessions/**/rollout-*.jsonl`，不写运行数据。

- 关闭自动拉起：`--no-dash` 或 `csg config set autoDash false`，或环境变量 `CSG_NO_DASH=1`。
- 取不到实时进展（窗口显示「等待 Codex 会话流…」）：多半是 rollout 里没有主线程记录，`csg dash once` 同样看得到，不影响 run 本身。
- 仪表盘与 csg 解耦：关掉窗口不影响正在跑的 run。

### 长任务推荐参数

```powershell
csg run --file .\task.md --cd C:\work\demo `
  --model gpt-6-astra --effort ultra `
  --resume-on-smac --attempt-timeout-minutes 90 `
  --deadline "2026-11-05T08:00:00"
```

| 参数 | 作用 |
|---|---|
| `--file` | 从 md 读 prompt（长任务书） |
| `--cd` | Codex 工作目录 |
| `--model` / `--effort` | 模型与推理档 |
| `--resume-on-smac` | SMAC 发生在回合中途时续跑原会话 |
| `--attempt-timeout-minutes N` | 单次 attempt 超时，连续 2 次超时停止 |
| `--deadline ISO或分钟` | 总截止，到期退出码 3 |
| `--max-rounds N` | 限制轮数（默认无限） |
| `--attempts-per-round N` | 每轮次数（默认 100） |
| `--cooldown-seconds N` | 轮间冷却（默认 1800） |
| `--codex-cmd path` | 指定 codex 可执行文件 |
| `--retry-non-capacity` | 非容量错误也重试（默认关闭） |

## 结果与文件

数据目录 `%LOCALAPPDATA%\csg`（`CSG_DATA_DIR` 可覆盖）：

```
runs\<run-id>\status.json      # 状态/轮次/冷却/最后的错误
runs\<run-id>\events.jsonl     # smac / cooldown-start / resume-armed / finished
runs\<run-id>\last-message.md  # Codex 最终消息（给用户看的结论）
runs\<run-id>\attempt-*\       # 每次尝试的 stdout/stderr
stats.jsonl                    # 跨 run 统计
```

## 中断与恢复

- Ctrl+C：立即杀当前 attempt 进程树，退出码 130，状态落盘。
- 强杀留下 `running`：`csg status` 显示 stale，执行 `csg repair`。
- 续跑：`csg run --resume <run-id>`（复用原 prompt/目录/模型）。
- 退出码：0 成功；2 非容量错误/轮数耗尽/连续超时；3 deadline；124 单次超时（内部）；130 中断。

## 仓库与同步（本地 ↔ GitHub）

- 本地工作副本：`C:\Users\LLS\Pictures\lilith's card design\科技\codex_harness`（已 `git init`，远端 `origin`）。
- GitHub：`https://github.com/lilith-is-all-you-need/codex-smac-guard`（公开 public）。
- 仓库结构：`product/`（csg 本体 + 测试）、`skill/SKILL.md`（本文件的副本）、`docs/`（设计、仪表盘说明、截图）、`legacy/`（历史原型）、`_supervisor/`（历史监督脚本）。
- 本 skill 安装位置：`%USERPROFILE%\.dsh\skills\csg\SKILL.md`（DSH 热加载的就是这一份）。
- **同步动作**（每次改动后必做）：
  ```powershell
  cd "C:\Users\LLS\Pictures\lilith's card design\科技\codex_harness"
  pwsh -File product\tests\run-tests.ps1     # 6/6 再提交
  Copy-Item "$env:USERPROFILE\.dsh\skills\csg\SKILL.md" .\skill\SKILL.md -Force
  git add -A; git commit -m "csg: <改了什么>"; git push
  git ls-remote origin                       # 确认远端有该提交
  ```
- 只改本地 skill 不推仓库、或只改仓库副本不更新 `~\.dsh\skills\csg\SKILL.md`，都算漏同步。
- 本机 git 配了 `http.proxy=http://127.0.0.1:7897`；代理没开时 `git push` 会报 `Failed to connect ... via 127.0.0.1`，此时直连可用，改跑 `git -c http.proxy= -c https.proxy= push`。

## 安全与边界

- csg 以完全访问权限运行 codex（`-s danger-full-access`），只在用户明确要跑该项目任务时使用；不要用它执行来历不明的 prompt。
- 默认每次重试都从头跑 prompt；有文件副作用的任务应可重入，或开启 `--resume-on-smac`。
- csg 只包装 `codex exec`；Codex TUI/桌面 App 里直接开的会话不受保护。
- 不要用 csg 去包装 DSH 子代理或 DSH 自身；它只针对本机 codex CLI。

## 自检清单

- [ ] `csg doctor` 通过
- [ ] 任务书/工作目录明确，成功标准可判定（任务书为英文，除非用户另有要求）
- [ ] 长任务已用后台 job + `--deadline`/`--attempt-timeout-minutes`
- [ ] **`csg dash status` 显示「运行中」**（没拉起就 `csg dash`；仍失败要写明原因）
- [ ] 结束时已读 `last-message.md` 并汇报 attempts/SMAC/退出码与仪表盘状态（英文原文已转成中文交付）
