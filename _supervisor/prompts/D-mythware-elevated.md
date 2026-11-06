# 任务：在管理员令牌下重跑 [Lilith]Mythware 离线回归与扩展冒烟

工作目录（工程根）：`C:\Users\LLS\Desktop\[Lilith]Mythware`
你由 `csg`（SMAC Guard）拉起，遇容量错误会自动重试，无需处理。

## 背景（来自上一轮证据 `out\evidence\csg-chain\20261104-082247\`）

- Release Win32+x64 构建 PASS；运行包校验 PASS（15/15）。
- 非提升进程下：离线回归 23 PASS 后，`patch/power_ipc_test` FAIL（管道 SDDL 仅允许 SYSTEM/Administrators，当前 Medium IL）；脚本首错停止，x64 未开始。
- `python tests/feature_extension_smoke.py` FAIL：`WinError 740`，CLI 项目 `UACExecutionLevel=RequireAdministrator`。
- 本机 UAC 为 **静默提升**（`ConsentPromptBehaviorAdmin=0`，用户在 Administrators 组）。已验证：从当前 Medium IL 进程用 `Start-Process -Verb RunAs` 可静默获得 High IL 管理员令牌，无需用户点击。

## 目标

用管理员令牌把上述两步跑完，给出完整、可复核的结论；**不要为了变绿而跳过/弱化测试断言**。

## 步骤

1. 新建证据目录 `out\evidence\csg-chain\<yyyyMMdd-HHmmss>-elevated\`。
2. 在其中写 `elevated-run.ps1`（UTF-8），依次执行并记录：
   - `whoami /groups`（证明 High Mandatory Level）
   - `./tools/test.ps1`（默认离线套件，Win32+x64；输出 tee 到 `elevated-test.log`，记录开始/结束与退出码）
   - `python tests/feature_extension_smoke.py`（输出到 `elevated-smoke.log`）
   - 汇总为 `elevated-result.json`（每步 name/exitCode/duration/pass）
   注意：脚本内 `Set-Location -LiteralPath 'C:\Users\LLS\Desktop\[Lilith]Mythware'`（路径含方括号），并用 `2>&1 | Tee-Object` 保留完整输出。
3. 运行提升：
   `Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"<脚本绝对路径>" -Wait -PassThru`
   检查退出码与 `elevated-result.json`。
4. 读取日志，统计 PASS/FAIL；确认 `power_ipc_test` 与 x64 全部项目是否通过、smoke 是否产生真实结果。
5. 如提升后仍有失败：判断是真实缺陷还是环境（驱动/服务/目标机缺失）。真实缺陷做**最小修复**并只复跑失败项；环境缺失写清缺失项。不得修改测试期望来掩盖失败。
6. 写 `report.md`：提升证明（High IL 输出摘录）、两条命令的开始/结束/退出码、PASS/FAIL 统计、smoke 结论、失败明细、修复清单（若有）。**不要删除或覆盖上一轮证据目录。**
7. 在 `out\evidence\csg-chain\LATEST.md` 写一行指向本轮目录。

## 约束

- 只改 `C:\Users\LLS\Desktop\[Lilith]Mythware` 内文件；不动 `~/.codex`、`codex_harness`。
- 不接触 `.78/.79` 实机、注册表、服务、网络策略；不 git commit。
- 不伪造；失败如实记录。
- 预计 40~80 分钟；优先完成「test.ps1 全量 + smoke」两件事。

## 最后消息（≤20 行）

提升是否成功（High IL 证据）、离线回归总数/通过/失败、x64 是否跑完、smoke 结果、修复数、剩余阻塞、证据路径。
