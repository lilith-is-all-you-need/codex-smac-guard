# CSG 构建报告

## 已完成

- 独立 PowerShell 7 launcher 与 `csg.cmd` shim，运行时不依赖 `_supervisor`。
- `run`/`resume`/`status`/`stats`/`doctor`/`config`/`install`/`uninstall` 命令。
- SMAC 正则检测、每轮重试（默认 100）、指数抖动退避、跨轮冷却（默认 30 分钟）、deadline、Ctrl+C 状态落盘。
- 每次 run 的 UTF-8 prompt、stdout/stderr（单 attempt 5 MiB 上限并写截断标记）、last-message、events、status；全局 `stats.jsonl` 支持按模型/按日、平均首次成功。
- `install-state.json` 保存安装前用户 PATH，`uninstall` 可恢复；不修改 `~/.codex/config.toml`。
- fake-codex 与一键离线测试脚本，证据写入 `product/evidence/`。
- 中文 README、设计、SMAC 记录、透明模式可行性说明。

## 自测

- `pwsh -NoProfile -File product/tests/run-tests.ps1`：**6/6 PASS**。
- 覆盖 3 次 SMAC 后成功（4 次尝试/3 次 SMAC）、跨轮成功（8 次尝试/3 轮）、非容量错误退出 2、过期 deadline 退出 3、中文/引号/换行 UTF-8 hash、status/stats 计数。
- 证据：`product/evidence/test-summary.md`、`test-summary.json`、`01-*.txt` 至 `06-*.txt`。
- 真实冒烟：`csg run "Reply with exactly: CSG-OK" --model gpt-6.1-sol --effort low` 成功，退出码 0、1 次尝试、SMAC 0；详见 `product/evidence/smoke.txt`。

## 已知限制

- 透明 HTTP 代理尚未实现，详见 `docs/transparent-mode-feasibility.md`；当前入口是 `codex exec` launcher。
- SMAC 依赖组合 stdout/stderr 文本匹配；服务端改写措辞需更新正则。
- 长时间冷却期间机器休眠会延后下一轮；恢复命令可继续。
- 单 attempt 超时默认关闭；v1.1 起可用 `--attempt-timeout-minutes` 限制，`--deadline` / Ctrl+C 仍可整体停止。
- stdout/stderr 在 attempt 完成后统一落盘，终端进度仍按尝试实时更新。
- 无法保证 Codex 子进程已产生副作用时重复请求的幂等性。

## 独立对抗审查（2026-11-04）

- 独立复测原作者测试：`pwsh -NoProfile -File product/tests/run-tests.ps1`，6/6 PASS。
- 新增 `tests/adversarial/run-adversarial.ps1` 与 fake 模式，覆盖 A-N；最终 16/16 PASS，证据：`tests/adversarial/evidence/final-20261104-5/summary.md`。
- 修复 SMAC 误判高危缺陷：仅在 exit code 非 0 且匹配完整 ERROR 行时判定 SMAC；成功输出引用该句子不再重试。
- 加固并发 `stats.jsonl` 追加、日志/状态脱敏、`--cd` 清晰错误、安装临时文件回滚、损坏状态时间戳容错；新增冷却开始事件便于审计。
- Ctrl+C 仍为静态审查，未在当前环境注入真实 CTRL_C_EVENT；透明代理、休眠和请求副作用幂等性仍为已知限制。详细结论见 `REVIEW.md`。




## v1.1 升级（2026-11-04 晚，监督者）

- `--resume-on-smac`：中途 SMAC 用 `codex exec resume <session>` 续跑，失败自动回退完整 prompt。
- `--attempt-timeout-minutes N`：单次 attempt 超时杀进程树，连续 2 次超时停止。
- `csg repair`：强杀残留 `running` → `interrupted`，用“pid + 进程启动时间”识别 PID 复用；`run` 启动时自动修复。
- 统计：中断 run 也落 `stats.jsonl`，按 runId 去重，`stats` 显示未成功/其中中断超时。
- 其他修复：`--deadline` 时区、数据目录 `%LOCALAPPDATA%\csg`、时长格式。
- 复测：基础 6/6、对抗 16/16、升级回归 5/5；真实冒烟 `CSG-V11-OK` 成功。
- v1.1.1：并发运行时用 `ownerPid` 保护活跃 run 不被 repair 误杀；统计按 runId 去重、成功优先；升级回归 5/5。
