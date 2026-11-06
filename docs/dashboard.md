# 桌面仪表盘：实现、数据来源与边界

状态：**已内置**（csg v1.2.0 的 `csg dash`）。早期独立原型保留在 `legacy/csg-dash.ps1` 仅作对照。

## 1. 显示什么

每个活跃 run 一块，六行：

1. `● <runId>`
2. 状态（运行中 / 冷却中 Ns / 启动中）· 模型/推理档 · 已耗时
3. 第 N 轮 / 第 M 次 · 累计 attempt · **SMAC 次数**（>0 时琥珀色）
4. 截止剩余 · 工作目录名
5. `⏵` 当前工具调用（`exec` 的实际命令、`apply_patch` 的文件、`wait_agent`/`spawn_agent` 的目标）
6. `»` 最近一条模型进展文本；末行 token 用量与「最新事件多久以前」

run 结束后 15 分钟内底部保留一行 `○ <runId> <state> · attempts N · SMAC M · 多久前`。空闲时窗口缩成一行"当前没有活跃的 csg run"。

交互：无边框置顶、拖动移动、双击打开对应 run 目录、右键菜单（打开/复制 runId/刷新/退出）。刷新 2 秒一次。

## 2. 数据从哪来

| 用途 | 来源 | 说明 |
|---|---|---|
| run 列表、轮次、SMAC | `%LOCALAPPDATA%\csg\runs\<id>\status.json` | csg 自己维护，切换状态时写 |
| 实时进展 | `%USERPROFILE%\.codex\sessions\yyyy\MM\dd\rollout-*.jsonl` | Codex CLI 追加写，实测 3 秒约 8 KB |
| 结束摘要 | `status.json` 的 `endedAt`/`state` | 15 分钟窗口 |

两个"看起来能用其实不行"的来源，实现时必须避开：

- **`status.json` 在 attempt 执行期间不刷新**：只在 attempt 开始（写 pid）和结束各写一次，默认单次 attempt 超时 45 分钟，只看它界面会长时间冻住。
- **csg 把 codex 的 stdout 攒在内存里**：attempt 结束才写 `stdout.log`，跑的时候目录是空的。

所以实时进展只取 rollout：`response_item/message`（assistant 的 commentary）、`response_item/custom_tool_call`/`function_call`（工具调用）、`token_usage_record`（token）。用 `session_meta.thread_source=user` 排除子代理线程，用 `cwd` + 启动时间匹配主线程。

## 3. 能力边界

- `gpt-6-astra` 的 reasoning 是加密传输，rollout 里 `reasoning.summary` 为空数组，**看不到思维链原文**；显示的是模型边干边说的 commentary 文本 + 工具调用 + token/静默时长。若模型返回 `summary`，代码已优先显示它。
- rollout 是 Codex 内部格式（实测 0.166.0），升级可能变；解析失败静默跳过，退化为"等待 Codex 会话流…"，不影响 run 本身。
- 同一工作目录并发多个 run 时按 `cwd`+启动时间匹配可能串台；彻底解决需要 csg 把 session id 提前写进 `status.json`（未做）。

## 4. 进程与单实例

- 仪表盘是独立进程，与 csg 解耦：关窗口不影响正在跑的 run。
- 单实例用按数据目录派生的命名 Mutex；自身 pid 写在 `<数据目录>\dash.json`，`csg dash status` 据此判断。
- 只读打开 rollout（`FileShare.ReadWrite`），不阻塞 Codex 写入；不写任何 run 数据。
- 自动拉起开关：`--no-dash` / `csg config set autoDash false` / 环境变量 `CSG_NO_DASH=1`。

## 5. 验证记录

- 回归：`product\tests\run-tests.ps1` 6/6 通过（含 `status`/`stats` 输出）。
- 集成实测（假 codex，`CSG_FAKE_SMAC_COUNT=2`）：`csg run` 打印 `仪表盘: 已拉起 (pid 63708)`，窗口实时显示 `SMAC 3` 并高亮，run 结束后落到失败态。
- 真实任务：升级后在 volleyball 的 run（gpt-6.1-sol/high）上实时显示 `exec:` 命令、commentary、token 与静默时长，结束后底部保留结束摘要（见 `docs/img/dashboard-integrated.png`）。
- 多任务/冷却/SMAC 高亮用假数据验证（`docs/img/dashboard-multi-run.png`）。
