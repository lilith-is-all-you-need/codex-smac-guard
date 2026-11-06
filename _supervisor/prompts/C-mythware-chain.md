# 任务：[Lilith]Mythware 本机全链路验证（通过 CSG harness 运行）

工作目录（也是工程根）：`C:\Users\LLS\Desktop\[Lilith]Mythware`
你现在是由 `csg`（Codex SMAC Guard）拉起的受监督任务；遇到 `Selected model is at capacity` 会自动重试，你不需要处理。

## 背景

- 该工程 M0 本机闭环已完成，当前在等待 M1-A `.79` 真机只读窗口（本机不可达，**不要尝试**）。
- 本次目标不是推进里程碑，而是验证**本机工程链路仍然完整**：Release 构建 → 离线回归 → 扩展冒烟 → 运行包校验。
- 这是真实工程：先读文档和脚本，再执行；只做必要修复，全部留证据。

## 必做步骤（按顺序，失败也要记录）

1. 阅读：`README.md`、`tools\build.ps1`、`tools\test.ps1`、`docs\field-testing.md`（按需）、`docs\compatibility-milestones-20261031.md`（只看与本机构建/测试有关部分）。
2. 运行 `./build.ps1`（Release，Win32+x64 运行包）。记录耗时、退出码、末尾输出。
3. 运行 `./tools/test.ps1`（默认离线套件；若脚本支持且时间允许，追加 `-BuildAllTests`）。记录每个 PASS/FAIL 统计。
4. 运行 `python tests/feature_extension_smoke.py`。
5. 运行 `tools\Test-FieldEnvironment.ps1 -PackagePath out\packages\Release\x64`，记录清单/哈希/PE 位数校验结果。
6. 若 2-5 任意一步失败：定位根因；只做**最小必要修复**（构建脚本、工程文件、测试夹具）；重跑失败的那一步，直到通过或确认是环境缺失（如缺 SDK/驱动/外部目标机）——环境缺失要给出精确缺失项，不许伪装通过。

## 证据与报告

在 `out\evidence\csg-chain\<yyyyMMdd-HHmmss>\` 下产出：

- `report.md`：每步命令、开始/结束时间、退出码、关键输出摘要、修复清单（文件 + 原因 + 前后行为）、最终结论表。
- `result.json`：`{ steps: [{name, status: pass|fail|skip, exitCode, durationSeconds, note}], fixes: [...], blockers: [...] }`。
- 修复涉及的文件 diff 摘要（不要复制整文件）。

## 约束

- 只改 `C:\Users\LLS\Desktop\[Lilith]Mythware` 内的文件；不要动 `~/.codex`、`codex_harness`、用户其他目录。
- 不改注册表/服务/网络策略；不操作 .78/.79 实机；不 git commit。
- 不伪造、不弱化测试断言；测试失败必须如实记录。
- 单个阻塞超过 30 分钟：记录根因与已尝试手段，跳到下一步可执行项，最后汇总。
- 预计 2~2.5 小时；优先保证「构建 + 离线回归 + 冒烟 + 包校验」四件事有明确结论。

## 最后消息（≤25 行）

给出：构建结果、离线回归统计、冒烟结果、包校验结果、修复数、剩余阻塞、证据路径。
