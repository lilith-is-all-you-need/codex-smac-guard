# 交付说明：Codex SMAC Guard（csg）

> 目标：Codex 报 `ERROR: Selected model is at capacity. Please try a different model.`（SMAC）时，不再卡死人工重试；单轮 100 次、轮间 30 分钟、直到成功，并且好用、可查、可留档。

## 1. 30 秒上手

已安装到 PATH（新终端直接可用）：

```powershell
csg run "把当前项目的测试跑绿并修复失败项"
csg run --file .\task.md --cd C:\work\demo --model gpt-6.1-sol --effort low
csg status        # 当前跑第几轮/第几次、冷却倒计时、最后错误
csg stats         # 累计尝试、SMAC 次数、成功率、按模型/按天
csg doctor        # codex 路径/版本/登录/默认模型
```

默认模型 `gpt-6-astra` + `ultra`；默认每轮 100 次、冷却 1800 秒、无限轮。数据在 `%LOCALAPPDATA%\csg`（`runs\`、`stats.jsonl`、`csg.config.json`），可用 `CSG_DATA_DIR` 覆盖。

安装/卸载：`pwsh -File product\csg.ps1 install|uninstall`（幂等，可恢复 PATH）。

## 2. 三条要求如何满足

| 要求 | 实现 |
|---|---|
| 每次任务随时拉起 | `csg run "任务"` 一条命令；`--file`、`--cd`、`--model`、`--effort`；Ctrl+C 中断后 `csg run --resume <run-id>` 续跑；`csg install` 后任意目录可用 |
| SMAC 自动重试 100 次/轮、轮间 30 分钟、直到成功 | 每次 attempt 独立进程 + 完整日志；识别真实 `ERROR: ... at capacity` 行（且 exit≠0）；轮内抖动退避（1→120s），轮耗尽后冷却 1800s，无限轮；`--max-rounds`/`--deadline` 可限 |
| 对用户友好 | 中文 banner/进度行、`status`/`stats`、每个 run 的 stdout/stderr/last-message、失败原因落 status、日志截断与保留 30 个 run、退出码约定（0/2/3/130）、`doctor` 自检 |

关键设计点：**只有 exit code ≠ 0 且匹配完整 ERROR 行时才认定 SMAC**。任务内容本身引用 SMAC 文案不会被误重试（这是审查中发现的真实高危缺陷，已修）。

## 3. 验证证据（可复现）

- 离线测试 `product\tests\run-tests.ps1`：**6/6 PASS**（3 次 SMAC 后成功、跨轮成功、非容量停止、过期 deadline、中文/引号/换行 prompt 哈希、status/stats）。
- 对抗测试 `product\tests\adversarial\run-adversarial.ps1`：**16/16 PASS**（默认参数、100 次轮边界、特殊路径、并发 stats、坏行、冷却中 deadline、安装回滚、误判回归、大小写/CRLF/无关 capacity）。
- 真实冒烟：`csg run "Reply with exactly: CSG-FINAL-OK"` 成功（1 次尝试，SMAC 0）。
- 误判回归（监督者复现）：exit 0 且输出含 SMAC 句子 → 1 次尝试 / SMAC 0（修复前会被重试）。
- 安装/卸载实测：PATH 恢复、重复安装不重复追加。
- 真实 SMAC：在 Mythware 实战中观测到 **21 次** SMAC（一次 run 连续 11 次，另一次 6 次、4 次），csg 全部自动重试、按退避等待、状态不丢。

## 4. 桌面 `[Lilith]Mythware` 全链路结果

由 `csg` 以 `gpt-6-astra` + `ultra` 拉起（run `20261104-082112-3bc341`），产出 `out\evidence\csg-chain\20261104-082247\`：

| 环节 | 结果 |
|---|---|
| Release 构建（Win32+x64 运行包） | **PASS**（退出码 0；VS2026 solution parser/integration/feature catalog 均 PASS） |
| 离线回归 `tools\test.ps1` | 非提升：23 PASS 后 `power_ipc_test` 因管道 ACL 仅允许 SYSTEM/Administrators 而 FAIL；**提升后全绿**：退出码 0，113.4s，**54 PASS / 0 FAIL**（51 个测试用例：26 Win32 + 25 x64，另有 3 项工程校验） |
| 扩展冒烟 `feature_extension_smoke.py` | 非提升：`WinError 740`（CLI 的 UAC 级别为 RequireAdministrator）；**提升后 PASS**（14.9s） |
| 运行包校验 `Test-FieldEnvironment.ps1` | **PASS**，15/15 文件 SHA256/大小/PE 位数一致 |
| 代码修改 | 0（失败均为权限边界，不是代码缺陷；未弱化任何断言） |

提升证据：`out\evidence\csg-chain\final-elevated\elevated-result.json`（`elevated=true`、`highIntegrity=true`、`overallPass=true`）。只读汇总见 `FINAL-SUMMARY.md`。

> 机器 UAC 为静默提升（`ConsentPromptBehaviorAdmin=0`，用户在 Administrators 组），因此上述两步可在无人工点击的情况下完成；非提升窗口下的失败已定位为权限边界并如实保留。

## 5. 监督、留档与统计

- 监督器 `_supervisor\run-codex.ps1`：每次 agent 运行都有 `status.json`、`events.jsonl`、`attempt-*` 原始日志，汇总 `stats.jsonl`；默认 100 次/轮、1800s 冷却、硬截止。
- 代理与耗时：Astra Ultra 构建 28.5 min（198,686 tokens，6/6 + 冒烟）；Sol 审查 36 min（16/16，修 6 类问题）。
- 事故与修复：07:33 监督器把 Agent A 的正常完成（exit 0，文档中引用了 SMAC 句子）误判为 SMAC 并重启；已修正判定逻辑，并把同类用例加入审查，进而修掉 csg 自身的同一缺陷。（详见 `_supervisor\SUPERVISION.md`）
- 其他修复：`--deadline` 时区偏移（14:30 曾显示为 22:30）、统计数据目录（从 `%USERPROFILE%\bin` 移到 `%LOCALAPPDATA%\csg`）、时长格式（`15m472s`）、提升脚本路径方括号问题。

## 6. 已知限制

- 交付形态是 **launcher（csg）**，不是透明代理：TUI/桌面 App 内直接开的会话不会被自动兜底；透明代理仅完成可行性调研（`product\docs\transparent-mode-feasibility.md`）。
- SMAC 发生在一轮中途时，重试会以新会话重跑 prompt；已产生的文件副作用不会回滚，需任务本身可重入。
- Ctrl+C 只做了静态审查（`CancelKeyPress` + 进程树 Kill + 130 + 落盘），未在伪终端实测。
- 本次 Mythware 验证仅限本机；未触碰 `.78/.79` 实机，也不代表真实课堂业务效果。
- 容量是服务端状态：观测窗口内 Astra 连续 11 次 SMAC，说明重试与 30 分钟冷却确有必要。

## 7. 时间线

- 07:00 开始；07:04–07:33 Astra 构建；07:39–08:15 Sol 审查；08:21 起 Mythware 实战；09:15 提升后全链路全绿；09:45 收尾。
- 距 14 小时硬截止（21:00）尚余约 11 小时，提前完成。

## 8. v1.1 升级（2026-11-04 晚）

| 升级 | 说明 | 验证 |
|---|---|---|
| `--resume-on-smac` | SMAC 发生在回合中途（已产生工具调用）时，下次重试用 `codex exec resume <session>` 续跑；resume 失败自动回退完整 prompt | 升级测试 O：2 次尝试、第 2 次命令含 `resume` + 会话 id、续跑 prompt 含“继续” |
| `--attempt-timeout-minutes N` | 单次 attempt 超时杀进程树，连续 2 次超时停止；默认 0（不限制） | 升级测试 P：2 次超时事件、7 秒内退出 2 |
| `csg repair` + 自动修复 | 强杀导致的 `running` 残留改为 `interrupted` 并补统计；用 “pid + 进程启动时间” 识别 PID 复用 | 升级测试 Q/R；真实修复 4 个历史 run |
| 统计修正 | 中断 run 也计入统计；按 runId 去重；`stats` 显示“未成功/其中中断超时” | 当前 6 run / 26 尝试 / 21 SMAC / 成功率 33.3% |
| 其他 | 错误信息截断、stale 标记、帮助文本、`doctor` 显示版本与数据目录 | 全部套件复跑 6/6 + 16/16 + 5/5 |

真实冒烟：`csg run "Reply with exactly: CSG-V11-OK" --resume-on-smac --attempt-timeout-minutes 10` → 成功，1 次尝试、SMAC 0。

## 9. 谁设计并构建了 csg

| 部分 | 负责人 |
|---|---|
| 需求、编排、监督、验收、留档 | 我（DeepSeek Harness agent） |
| **v1 主体设计与实现** | **Agent A：`gpt-6-astra` + `ultra`**（28.5 分钟，198,686 tokens；产出 `csg.ps1`、fake-codex、基础测试、README/设计文档，6/6 + 真实冒烟） |
| **独立对抗审查与 6 类修复** | **Agent B：`gpt-6.1-sol` + `high`**（36 分钟；16/16；修 SMAC 误判、并发 stats、脱敏、错误退出码、安装回滚、损坏状态容错） |
| v1.1 升级（resume、超时、repair、PID 复用、统计去重、时区/数据目录/时长格式、提升验证套件） | 我 |
| 测试基础设施 | 基础测试 A；对抗测试 B；升级回归测试我 |

关键缺陷归属：SMAC 误判是我在监督时先踩到并给出复现用例，B 定位并修复；`--deadline` 时区、数据目录落进 `bin`、时长格式 `15m472s`、stale/PID 复用是我发现并修复的。

## 10. v1.1.1 修复（并发场景）

- **stale 误杀**：多窗口同时用 csg 时，另一个 `csg run` 启动时的自动修复会把“正在两次 attempt 之间”的活跃 run 误判为 stale（我自己的 VM 调查 run 就中过）。修复：run 记录 `ownerPid`，修复逻辑优先看 owner 进程是否存活；新增回归测试 S。
- **统计去重**：同一 run 先被写成 interrupted、后来成功时，stats 现在按 runId 取最后一次（成功优先），不再出现“成功了但统计仍是失败”。
- 版本号 1.1.1；`run-tests` 6/6、`adversarial` 16/16、`upgrade` 5/5。

新手指南：[docs/csg-beginner-guide.md](docs/csg-beginner-guide.md) · 本次实战演示：[docs/csg-demo-walkthrough.md](docs/csg-demo-walkthrough.md)

## 11. 实战：.79 虚拟机 Patch 修复（2026-11-05 凌晨）

- 问题：`private_layout` 只认两组固定 SHA256，.79 的 StudentMain/LibComLayer 不匹配 → 缺 `LP_CAP_PRIVATE_PROTOCOL` → Patch 被拒，UI 显示 1114。
- **Astra（gpt-6-astra/ultra）**：run `20261104-235534-d0c0f5`，7 次尝试 / 6 次 SMAC（全部自动 resume），43 分钟成功。新增“证据型 API fallback 准入”（32 位、Com/Base/TD、caps 0x7、契约 0x7、导出候选置信度/差距/可执行区域），无新 SHA/RVA/PID 硬编码；VM 实测 `state=1 route=2`、事件“Patch 已就绪”。
- **Sol（gpt-6.1-sol/high）**：run `20261105-004301-d37e44`，5 次尝试 / 4 次 SMAC，43 分钟。独立重跑构建/单测/VM 两轮 unpatch→patch；发现并修复 3 个问题（旧私有 SHA 路线被新门槛误拒、DLL 已驻留时 PatchHost 重复 Patch 无效、DLL .def 未接入），并新增 A–G 对抗测试。
- 审计结论：未新增硬编码放行；`attempt_allowed` 恒 0；fallback 只 hook 公共 Windows API，不调用推断 RVA。剩余风险：证据来源未绑定（重复 report 可通过纯函数）、fallback hook 副作用较广、风险开关可降阈值。
- 期间 csg 自身修复：并发窗口下 repair 误杀活跃 run（`ownerPid` 保护，v1.1.1）；统计按 runId 去重、成功优先。
- 证据：`out/evidence/vm-79/20261105-003302/report.md`、`out/evidence/vm-79/sol-review/REVIEW.md`、`out/evidence/vm-79/PROGRESS.md`。
- 新手材料：[docs/csg-beginner-guide.md](docs/csg-beginner-guide.md)、[docs/csg-demo-walkthrough.md](docs/csg-demo-walkthrough.md)。

## 12. DSH skill 集成与文档一致性修复（2026-11-05 晚）

- **用户级 skill**：`%USERPROFILE%\.dsh\skills\csg\SKILL.md`，目录热加载、所有会话可见；用户可用 `/csg` 直接调用，模型在 Codex CLI/SMAC 场景会自动加载。
- **skill 约束**：Codex CLI 长任务统一走 `csg run`、后台 job 运行、结束时汇报 run id / attempts / SMAC / 退出码；不裸跑 `codex exec`。
- **验证**：`csg doctor` 正常；三套离线测试复跑 6/6 + 16/16 + 5/5；真实冒烟 `CSG-SKILL-OK`（run `20261105-233020-0a8833`，1 次尝试 / SMAC 0 / exit 0）。
- **文档修复**：`design.md` 的状态机、SMAC 判定、退出码、数据目录改为与实现一致；`4/4` 统一为 `5/5`；新手指南版本号与 Ctrl+C 行为更正；`smac-notes.md` 补充 exit≠0/续跑/非容量重试说明。
