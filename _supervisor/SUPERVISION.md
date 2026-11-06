# 监督记录（2026-11-04）

## 角色分工

| 角色 | 模型/推理 | 时间 | 结果 |
|---|---|---|---|
| 监督者（DSH） | DeepSeek Harness | 07:00– | 编排、留档、统计、修监督工具、验证交付 |
| Agent A 构建 | `gpt-6-astra` / `ultra` | 07:04–07:33 | 交付 CSG v1：6/6 离线测试 + 真实冒烟；自报 198,686 tokens |
| Agent B 审查 | `gpt-6.1-sol` / `high` | 07:39–08:15 | 对抗审查 16/16，修复 6 类缺陷（含高危 SMAC 误判） |
| csg 实战 #1 | `gpt-6-astra` / `ultra` | 08:21–08:35 | Mythware 本机链路（非提升）：构建/包校验 PASS，回归 23 PASS 后遇权限边界 |
| csg 实战 #2 | `gpt-6-astra` / `ultra` | 08:39–09:12 | 提升方案尝试；连遇 6 次真实 SMAC 自动重试；其自写提升脚本有路径缺陷，监督者手动停止 |
| 监督者提升验证 | 本地脚本（High IL） | 09:13–09:15 | `test.ps1` Win32+x64 全绿（113.4s，54 PASS/0 FAIL）、`feature_extension_smoke.py` PASS（14.9s） |
| csg 实战 #3 | `gpt-6-astra` / `ultra` | 09:19– | 只读汇总 Mythware 证据；持续 SMAC，由 csg 自动重试 |

## 监督工具与留档

- `_supervisor/run-codex.ps1`：包住 `codex exec` 的监督器。默认每轮 100 次、轮间 1800s、无限轮、硬截止；每次 attempt 有独立 stdout/stderr/last-message 日志；`runs/<id>/status.json` 实时状态、`events.jsonl` 事件流、`runs/stats.jsonl` 汇总。
- `_supervisor/prompts/`：三份任务书（Astra 构建 / Sol 审查 / Mythware 链路 + 提升 + 汇总）。
- 运行数据：`_supervisor/runs/`；交付物自身统计：`%LOCALAPPDATA%\csg\stats.jsonl`。

## 关键事件：SMAC 误判（已修复）

07:33，Agent A 的 attempt 以 **exit 0 正常完成**，但其最终消息里引用了 `ERROR: Selected model is at capacity...` 作为文档内容；监督器把整段 transcript 当证据，误判为 SMAC 并重启了一次（第二次被手动终止，节省 ~20 万 tokens）。

- 监督器修复：**exit 0 一律 success**；仅当 exit≠0 且匹配 `^\s*ERROR:\s*Selected model is at capacity` 才判 SMAC。
- 把同类用例加入 Agent B 的审查任务（M 项）。B 发现 **csg 原实现有同样缺陷**（对整段输出做宽松 `at capacity` 匹配、且不检查退出码），已修复为「exit≠0 + 完整 ERROR 行」，并加了 `disk at capacity` 等反例。
- 回归证据：成功输出引用 SMAC 句子时，`csg` 仅 1 次尝试、SMAC=0；真实错误行仍正确重试。

## 真实 SMAC 统计（截至 09:50）

- 实战 #2（`083913`）：6 次 attempt / 6 次 SMAC，csg 全部自动重试；因提升脚本缺陷由监督者停止。
- 实战 #3（`091952`）：连续 11 次 SMAC（09:19–09:40），csg 按退避策略持续重试，未误判、未退出、未丢状态。
- 实战 #4（`094153`，gpt-6.1-sol）：4 次 SMAC 后由监督者停止（容量故障窗口，汇总改由监督者整理）。
- 合计在真实 Codex 请求上观测到 SMAC **21 次**，全部由工具链自动处理（无人工点重试）。

## 交付物验证摘要

- 离线测试 6/6；对抗测试 16/16（含并发、坏 stats、路径特殊字符、prompt 哈希、死线、安装回滚、误判回归）。
- 真实冒烟：`csg run "Reply with exactly: CSG-OK"` 成功；`CSG-FINAL-OK` 亦成功。
- 误判回归：exit 0 + 含 SMAC 文案 → 1 attempt / SMAC 0。
- 安装：`csg install/uninstall` 幂等，PATH 恢复；数据目录 `%LOCALAPPDATA%\csg`。
- 死线解析：`--deadline 2026-11-04T14:30:00` 正确显示本地 14:30（修复了 UTC 偏移 bug）。

## v1.1 升级（23:00–23:55，监督者直接完成）

- 新增 `--resume-on-smac`（中途 SMAC 续跑）、`--attempt-timeout-minutes`、`csg repair`、统计去重与中断统计。
- 修复 PID 复用导致的 stale 误判（旧 run 的 pid 被别的进程占用）；真实修复 4 个历史 run。
- 复测：基础 6/6、对抗 16/16、升级回归 5/5；真实冒烟 `CSG-V11-OK`。
