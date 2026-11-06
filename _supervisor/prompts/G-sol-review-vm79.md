# 任务：独立审查并对抗测试 .79 Patch 兼容性修复（不要相信 Astra 的结论）

工作目录：`C:\Users\LLS\Desktop\[Lilith]Mythware`
目标机：`192.168.1.79`（Windows 10 IoT LTSC，用户 `lls`，SSH 免密，High IL）。

## 背景

Astra 刚改完并声称在 VM 上修好了 Patch：

- 根因：`MythwarePatch()` 原先把 `LP_CAP_PRIVATE_PROTOCOL` 作为硬准入；该位只由两组固定 SHA256 命中时设置，.79 的 StudentMain/LibComLayer 不匹配 → capabilities=0x7 → 拒绝 → 1114。
- 改动：新增证据型 API fallback 准入（`lp_admit_api_fallback`），要求 32 位、Com/Base/TD、caps 0x7、导出契约 0x7、Com/Base 两个导出候选的置信度/差距/可执行区域达标；`compat_probe.c` 记录 `LP_CAP_EVIDENCE_ADMITTED(0x40)`；`hook.c` 改为要求 API fallback + 证据准入；保留私有布局的旧 SHA 路线。
- Astra 证据：`out\evidence\vm-79\20261105-003302\report.md`；VM 上 `LilithPatchHost.exe 6980` 后 `patch-status` 为 `error=0 state=1 route=2`，事件“Patch 已就绪”。

## 你的任务

**独立设计测试**，目标是证明这套准入“既不过松、也不过紧”，并找出 Astra 没测到的边界。

### 1. 代码审查（不要只看报告）

重点文件：`src\patch-dll\compat_inference.c/.h`、`compat_probe.c/.h`、`hook.c`，测试 `tests\patch\compat_inference_test.c`。

必须回答：

- 是否新增了任何 **硬编码 SHA256 / RVA / 字节序列 / PID / 路径** 来放行？逐行确认。
- `LP_CAP_EVIDENCE_ADMITTED` 是否只可能由运行时证据计算得出？外部能否伪造（profile 文件、环境变量、启动参数）？
- 已知私有布局（旧 SHA 命中）是否被这次改动**误伤**（原来能过、现在过不了）？
- `risk_override_requested()`（`LILITH_ALLOW_INFERRED_ABI`）降低阈值后，是否仍不允许调用推断地址？阈值 30/10 是否过低？
- `hook.c` 的 API fallback 路线实际 hook 了哪些 API？是否可能影响课堂/端口让渡/电源路径？失败回滚是否完整？
- profile JSON 新增字段是否破坏现有消费者（GUI/CLI/工具）？

### 2. 自己写对抗测试（放 `tests\patch\sol_admission_test.c` 或扩展现有测试）

至少覆盖：

- A. facts 合法 + 两个 report 合法 → 允许（基线）。
- B. 64 位、缺 Com/Base/TD、caps 非 0x7、contract 非 0x7、role=false → 全拒绝。
- C. 一个 report confidence 低于阈值、margin 低于阈值、候选为 UNKNOWN/x64、缺可执行区域证据 → 拒绝。
- D. 两个 report 完全相同（复用同一份）→ 是否仍允许？这是证据独立性要求，若允许请指出风险。
- E. 阈值边界（39/40、19/20、30/10 risk 模式）逐个断言。
- F. 空指针、report_count<2、candidate_count=0、selected 越界 → 不崩溃、拒绝。
- G. `lp_inference_can_attempt` 仍恒 0；`lp_infer_code_shape` 的 `attempt_allowed` 不得变为 1。

用真实的 `ca_analyze_function` 样本（如果测试工程已有 fixture）或构造最小 x86 函数字节；不要只构造“理想结构体”自证。

### 3. VM 端到端（必须）

用 `_supervisor\vm\vm-exec.ps1` / `vm-copy.ps1`（宿主路径：

`C:\Users\LLS\Pictures\lilith's card design\科技\codex_harness\_supervisor\vm\`）：

- 复核当前 `[Lilith]Mythware.exe --patch-status`（应为 state=1 route=2，事件“Patch 已就绪”）。
- 尝试 **unpatch → 再 patch**（`LilithPatchHost.exe <pid>`），确认可重复、无残留、rollback 不误触发；记录前后事件。
- 检查 StudentMain 仍存活、GUI 可用；读取 `Release\logs\session-*.log`（UTF-8）。
- 若你想验证“拒绝路径”，不要破坏现有 StudentMain：可在测试进程里用 fake module/facts 做单元测试，或复制一份 runtime-profile JSON 做 profile 解析测试（说明它不影响准入即可）。

### 4. 构建与回归

- `tools\build.ps1 -Configuration Release`（Win32/x64）或至少受影响工程；
- `tests\patch\compat_inference_test.exe`、你的新测试；
- 项目自带离线回归里与 patch/compat 相关的套件（`tools\test.ps1` 可选跑 Patch 相关项，别跑全量拖太久）。
- 若发现真缺陷：**直接修**，保持最小改动，补回归测试，重跑。

### 5. 产出

- `out\evidence\vm-79\sol-review\REVIEW.md`：逐项结论（PASS/FAIL/风险）、发现的问题、修复、未解决项、VM 原始输出。
- `out\evidence\vm-79\sol-review\` 下测试源码/二进制/日志。
- 更新 `out\evidence\vm-79\PROGRESS.md` 追加你的段落（不要改 Astra 的记录）。

## 约束

- 只改 `[Lilith]Mythware` 内文件；不动 `codex_harness` 产品与 `~/.codex`。
- 不引入新依赖；不 git commit。
- 不伪造通过；失败/不确定要写清楚。
- 时间盒 90 分钟；先保证 A–G 单测与 VM 复测，再谈扩展。

## 最后消息（≤25 行）

结论（能否复现 Astra 的结果）、发现的问题数/修复数、最关键的 3 条风险、VM 最终 `patch-status` 原文、证据路径。
