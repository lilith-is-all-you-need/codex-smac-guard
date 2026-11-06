# 任务：对抗性审查并加固 Codex「SMAC Guard」(csg) 交付物

你是独立审查者（不要相信原作者的自测结论）。工作区：`C:\Users\LLS\Pictures\lilith's card design\科技\codex_harness`。

产品在 `product\`：`csg.ps1`（主程序）、`csg.cmd`、`csg.config.json`、`tests\run-tests.ps1`、`tests\fake-codex.ps1`、`README.md`、`docs\*`。
背景：Codex 遇到 `ERROR: Selected model is at capacity. Please try a different model.`（SMAC，exit 1）时，用户要求：单轮自动重试 100 次；一轮耗尽后等 30 分钟再继续；直到成功；操作友好、可留档统计。

## 你的职责

1. **先独立通读** `product\csg.ps1` 与配置、测试脚本（不要只看 README 和 BUILD-REPORT）。
2. **跑原作者测试**：`pwsh -File product\tests\run-tests.ps1`，记录结果。
3. **写你自己的对抗测试**（放 `product\tests\adversarial\`，可复用 fake-codex），至少覆盖：
   - A. 默认参数确实是「每轮 100 次 / 冷却 1800 秒」；且一轮 100 次 SMAC 后才进入冷却（可用 `--attempts 5 --cooldown-seconds 2` 等价验证计数与轮次边界，说明等价性）。
   - B. 第 1 轮 100 次全 SMAC、第 101 次成功：验证跨轮、总尝试 101、轮次=2、冷却只发生 1 次（用小参数等价模拟，别真等 30 分钟）。
   - C. 路径含空格、中文、方括号（例如 `C:\...\tmp\[Lilith] test 中文\`）：run/cd/日志/cleanup 全链路正常。
   - D. prompt 含双引号、单引号、换行、emoji、`$`、反引号、`%`、`!`：fake codex 收到的 stdin 字节与原文 SHA256 一致。
   - E. 并发：两个 `csg run` 同时跑（fake），stats.jsonl 不损坏、互不覆盖、status 各自独立。
   - F. `stats.jsonl` 被人为插入坏行/半行：`stats`/`status` 不崩，能跳过坏行并提示。
   - G. 冷却中途到达 `--deadline`：按时退出码 3，状态落盘，不继续请求。
   - H. 非容量错误（exit 1，如 `authentication failed`）：立即停止、退出码 2、错误进 status，不误判为 SMAC。
   - I. Ctrl+C（可发送 CTRL_C_EVENT 或用伪终端；做不到就静态审查信号处理与子进程树清理，明确说明）。
   - J. `install`/`uninstall`：幂等、只改用户级 PATH、失败可回滚、不破坏已有 PATH；安装后新 shell 里 `csg` 可用。
   - K. `status` 在没有历史 run 时、run 目录被删时、status.json 半写入时都不崩。
   - L. 安全：日志与 stats 不写入 token/密钥；`--cd` 不存在时报错清晰；不静默创建目录。
   - M. **误判测试（最高优先级，已知高危）**：fake codex 正常退出 0，但它的输出/最终消息里**包含** `ERROR: Selected model is at capacity. Please try a different model.`（模拟 agent 在写 SMAC 文档、或任务内容本身就引用这句话）。csg 必须判为成功（1 次尝试、SMAC=0、exit 0），**绝不重试**。真实 SMAC（该行出现且 exit 1）才允许判为 SMAC。补一条回归测试并纳入 run-tests 或 adversarial。同时检查：`csg` 的 SMAC 判定是否只在 `exit code != 0` 时生效；只扫描「ERROR 行」而不是整篇 transcript。
   - N. 检测强度：SMAC 行大小写变体、前后有空格/CRLF、以及“at capacity”出现在无关句子（如 “disk at capacity”）时不得误判。
4. **修**：发现的缺陷直接修（保持单文件可运行、无新依赖、默认行为不变），修完重跑全部测试。不要重写架构，不要删除已有功能。
5. **写** `product\REVIEW.md`：审查范围、逐项结论（PASS/FAIL/风险）、修复清单（文件+行为）、未解决项与理由、复测证据路径。
6. 更新 `product\BUILD-REPORT.md` 的「审查」小节（追加，不改原作者内容）。

## 硬性边界

- 只改 `codex_harness\product\` 内文件；不要动 `_supervisor`、`C:\Users\LLS\Desktop\[Lilith]Mythware`、`~/.codex\config.toml`。
- 不启动其它 codex 会话；不访问网络。
- 真实 codex 调用最多 1 次（`csg run "Reply: CSG-RV-OK"`，gpt-6.1-sol low），避免烧额度。
- 保留原作者的中文 UX 风格；错误信息要具体。

## 交付

- 修复后的产品 + `REVIEW.md` + 测试证据（`product\evidence\adversarial\` 或 `product\tests\adversarial\evidence\`）。
- 最后一条消息 ≤30 行：发现的问题数、修复数、复测结果、剩余风险。
