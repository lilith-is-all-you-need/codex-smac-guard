# 任务：修复 [Lilith]Mythware 在 .79 虚拟机上的 Patch 初始化失败，并扩展兼容性（禁止硬编码 patch）

工作目录（宿主源码）：`C:\Users\LLS\Desktop\[Lilith]Mythware`
目标机：`192.168.1.79`（Windows 10 IoT LTSC，用户 `lls`，已配置 SSH 免密，登录后是 **High IL 管理员**）。

## 现象（用户实测）

`C:\Users\lls\Desktop\Release` 拷到 VM 后启动 Patch，失败：

```
[DLL] 兼容探测：学生角色=已确认，进程=StudentMain.exe，位数=32，Com=yes Base=yes TD=yes，能力=0x00000007，导出契约=0x7，历史风险开关=off，私有布局=not-matched；评分不授予调用权限
[DLL] 兼容准入未通过，未安装正式 Patch；请使用兼容探测工具取得证据。
[DLL] Patch 初始化失败，请在 UI 查看状态
[Patch] stage=patch-command pid=7996 error=1114 (DLL_INIT_FAILED) status=2 route=3 ports=0
[Patch] stage=rollback-start ... / stage=prepare ...
```

## 已确认的关键事实（省你时间，但请自己复核）

- StudentMain：`C:\Program Files (x86)\Mythware\极域课堂管理系统软件v6.0\StudentMain.exe`，pid 7996，32 位，High IL。
- 运行时 profile：`C:\Users\lls\Desktop\Release\diagnostics\runtime-profile-7996-*.json`
  - `capabilities=0x7`，`export_contracts.mask=0x7`，`private_layout=false`，`confidence=candidate-only`。
  - StudentMain SHA256=`68b859825cfe7ae3b8e847d50f29af06ed0912f194307cf5b7dfb76ae1c69eee`；LibComLayer=`d8696ea4...`。
- 源码链路：
  - `src/patch-dll/compat_probe.c:281`：`private_layout` 只由两段**硬编码 SHA256**（`5e77f1b7...` / `f85e5d24...`）决定；不匹配 → `caps` 没有 `LP_CAP_PRIVATE_PROTOCOL(0x10)`。
  - `src/patch-dll/hook.c:662`：准入要求 `LP_CAP_API_FALLBACK` 且 `LP_CAP_PRIVATE_PROTOCOL`；缺一个就 `LP_ROUTE_OFF`，`LP_PATCH` 返回错误。
  - `src/patch-dll/compat_inference.c:37-45`：`attempt_allowed=0`、`lp_inference_can_attempt()` 恒 0。
  - `src/shared/patch_client.c:270-281`：`patch_status != 1` 会被报成 `ERROR_DLL_INIT_FAILED(1114)`，于是 UI 看到 1114。
- Patch 入口可命令行复现：`LilithPatchHost.exe <pid>`（`src/patch-host/patch_host.c`），无需点 GUI。
- 日志：`C:\Users\lls\Desktop\Release\logs\session-*.log`（UTF-8；PowerShell 5.1 读取要 `-Encoding UTF8`）。

## 目标

1. **让 Patch 在 .79 这台 VM 上真正就绪**（`Patch 已就绪` / `patch_status=1`），并给出可复现证据。
2. **扩展兼容性**：让同一类 32 位 StudentMain（v6 系列，Com/Base/TD 存在、导出契约 0x7、ABI 推断有候选）能通过**基于证据的准入**，而不是只认两段硬编码哈希。
   - 明确禁止：写死新的 SHA256 白名单、写死 RVA/字节序列、写死某个 PID/路径来“碰巧通过”。
   - 允许：用运行时证据（模块存在性、导出解析、ABI 推断置信度/差距、能力位、显式风险确认）做分级准入；保留对未知版本的安全拒绝。
3. **自己设计测试**（用户明确要求）：
   - 单元测试：新增/修改的准入判定、profile 分类、拒绝路径；
   - 反例测试：缺模块、64 位、无导出、低置信度、伪造 profile 不得误放行；
   - VM 端到端：`LilithPatchHost.exe` → 期望 `patch_status=1`、route 正确、无 rollback。
4. 产物：
   - 代码改动 + 构建（Release Win32/x64）；
   - `out\evidence\vm-79\<timestamp>\report.md`（根因、改动、测试、VM 证据、风险）；
   - `out\evidence\vm-79\PROGRESS.md`（每完成一个里程碑就更新，便于监督者查看）。

## VM 访问方式（宿主上执行）

- 远程执行：`pwsh -File "C:\Users\LLS\Pictures\lilith's card design\科技\codex_harness\_supervisor\vm\vm-exec.ps1" -Script '<PowerShell 脚本>'`
- 传文件：`...vm-copy.ps1 -Local <宿主文件> -Remote 'C:/Users/lls/Desktop/Release/xxx'`；下载加 `-Download`。
- 已配置 ed25519 免密；VM 上默认 shell 是 cmd，但 vm-exec 用 EncodedCommand 跑 PowerShell。
- 读中文日志记得 `-Encoding UTF8`；远程输出用 `[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)` 开头。

## 部署与验证建议

- 先在宿主构建（VS2026，`build.ps1` 或 `tools\build.ps1`），只把**必要文件**（DLL/exe）备份后覆盖到 VM `Release`；不要动 Mythware 安装目录。
- Patch 前先 `LilithPatchHost.exe` 查询/恢复；若 DLL 已注入旧版，研究是否需要重启 StudentMain 或走 unpatch；**不要杀/改 Mythware 安装**，除非确认可恢复。
- 验证命令示例：`LilithPatchHost.exe 7996`，随后读取 `Release\logs\session-*.log` 与 `diagnostics\*.json`。
- 每轮改动都要有“改前/改后”日志证据；失败也要记录。

## 约束

- 只改 `[Lilith]Mythware` 源码/工具/证据；不改 `~/.codex`、`codex_harness` 产品代码。
- 不引入新依赖；不提交 git。
- 安全第一：不认识的行为不要放开；风险开关必须显式、可审计。
- 时间盒：3 小时内给出第一版（含 VM 验证）；若 1.5 小时仍无法让 patch_status=1，先在 PROGRESS.md 写清卡点，再决定是否换路线。

## 最后消息（≤25 行）

根因一句话、改了什么、测试结果、VM 上 `LilithPatchHost` 的最终输出（status/route/error）、剩余风险、证据路径。
