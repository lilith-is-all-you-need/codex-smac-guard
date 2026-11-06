# CSG SMAC Guard 对抗性审查

审查日期：2026-11-04

审查范围：独立通读 `csg.ps1`、`csg.config.json`、`csg.cmd`、`tests/run-tests.ps1`、`tests/fake-codex.ps1`、README 与 docs；运行原作者测试；新增并运行 `tests/adversarial/run-adversarial.ps1`。未启动其它 Codex 会话，未访问网络，未执行真实 Codex 调用。

## 结论

| 项目 | 结论 | 证据/说明 |
|---|---|---|
| A 默认每轮 100 次、冷却 1800 秒；小参数验证轮次边界 | PASS | 配置断言；5 次等价轮耗尽后才进入一次冷却阶段 |
| B 跨轮成功 | PASS | 5 次 SMAC 后第 6 次成功，尝试 6、轮次 2、冷却阶段 1 |
| C 空格/中文/方括号路径 | PASS | run、`--cd`、日志和清理链路通过 |
| D 特殊 prompt stdin 字节 | PASS | 双/单引号、换行、emoji、`$`、反引号、`%`、`!` 的 SHA256 一致 |
| E 并发 run | PASS | 两个进程同时运行，stats 行均可解析、run 状态独立 |
| F 损坏 stats/status 行 | PASS | 坏行与半行被跳过，`stats`/`status` 仍退出 0 |
| G 冷却中 deadline | PASS | 到期退出码 3，未继续请求 |
| H 非容量 exit 1 | PASS | 立即退出码 2，status 保存 authentication failed，SMAC=0 |
| I Ctrl+C | PASS（静态） | `CancelKeyPress`、递归 Kill、130 和落盘逻辑存在；未使用伪终端发送实测信号 |
| J install/uninstall | PASS | 隔离 USERPROFILE 下幂等安装/卸载，用户 PATH 单一追加并恢复；安装失败路径有回滚逻辑 |
| K 无历史、run 删除、半写 status | PASS | `status` 均不崩 |
| L 安全与 `--cd` 错误 | PASS | token-like 输出脱敏；不存在目录返回清晰错误且不创建目标目录 |
| M 成功输出引用 SMAC 句子 | PASS | exit 0 时只尝试 1 次、SMAC=0，绝不重试 |
| N 检测强度 | PASS | 大小写、空白、CRLF 变体可识别；`disk at capacity` 不误判 |

## 发现与修复

1. **高危误判（已修复）**：原实现对整段 stdout/stderr/最终消息做宽松 `at capacity` 匹配，且不检查退出码；成功 transcript 引用 SMAC 句子会被当成容量错误。现改为仅在 exit code 非 0 时，匹配完整的 `ERROR: Selected model is at capacity. Please try a different model.` 行，大小写和空白可变，并纳入最终消息检查。
2. **并发统计完整性风险（已修复）**：原 `Add-Content` 没有显式跨进程串行化。现以独占文件句柄重试追加 JSONL，避免两个 run 互相覆盖或产生半行。
3. **日志泄密风险（已修复）**：stdout/stderr、last-message、status 错误和 stats reason 现在对 Bearer、`sk-`、token/secret/password/api-key 形式做脱敏。
4. **参数错误退出码不稳定（已修复）**：全局 Stop 后 `Write-Error` 可能再次终止，导致 `--cd` 等参数错误返回 1。现直接写 stderr 并稳定返回 2，同时保留中文具体错误。
5. **安装失败回滚（已加固）**：安装使用临时文件和备份，复制或 PATH 更新失败时恢复目标文件、PATH 和临时状态；重复安装不重复追加 PATH。
6. **状态健壮性（已加固）**：`status` 对损坏/无效时间戳记录按不可用记录跳过。

## 未解决项与理由

- Ctrl+C 仅做静态审查，当前环境没有可靠的 Windows 伪终端/CTRL_C_EVENT 注入方式；代码路径已验证包含递归子进程清理、状态落盘和退出码 130。
- 未运行真实 Codex；遵守本次任务的额度边界。fake-codex 覆盖了 SMAC、非容量、超时、stdin 哈希、误判和检测变体。
- 冷却期间机器休眠、Codex 请求副作用的幂等性、透明 HTTP 代理仍是原设计限制，未在本次审查中改变。

## 复测证据

- 原作者测试：`product/evidence/test-summary.md`（6/6 PASS）。
- 对抗测试：`product/tests/adversarial/evidence/final-20261104-5/summary.md`（16/16 PASS）。
## 监督者复核补充（2026-11-04 09:50）

在审查之后，监督者又修了 4 处（均有复测）：

1. `--deadline` 时区偏移：`2026-11-04T14:30:00` 被解析成 22:30；改为 `DateTimeOffset.Parse(..., InvariantCulture).LocalDateTime` 后正确显示 14:30。
2. 数据目录：安装到 `%USERPROFILE%\bin` 后 runs/stats 曾落在 bin；现默认 `%LOCALAPPDATA%\csg`（`CSG_DATA_DIR` 可覆盖），安装时播种 `csg.config.json`。
3. 时长格式：`.NET` 把 `"02"` 当自定义数字格式，`947s` 显示成 `15m472s`；改为 `"00"` + `Floor`，现为 `15m47s`。
4. 对抗测试 J 的隔离性：真实安装留下 `install-state.json` 时 `restored=False`；测试开始前清理该状态后恢复 16/16。

以上改动后：`run-tests.ps1` 6/6、`run-adversarial.ps1` 16/16（16/16 为改数据目录后复跑结果）。



