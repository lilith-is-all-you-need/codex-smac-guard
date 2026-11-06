# 透明模式可行性调研

## 目标

评估是否能通过本地 HTTP 代理和 `model_providers` 配置，让 Codex TUI/桌面 App 在不改命令的情况下透明重试 SMAC。

## 结论

可做概念验证，但不作为本交付默认路径。代理需要拦截 Codex 到模型 API 的请求，在检测到容量响应时延迟并重放请求；TUI/桌面 App 只看到最终响应。当前 CSG 选择显式 launcher，因为它不需要修改全局配置，能记录每次尝试并可靠处理中断/恢复。

## 证据与限制

官方 app-server 文档展示了 `model_providers.<id>.base_url`、`wire_api`、鉴权环境变量等 provider 配置字段，因此把 base URL 指向本地转发器在协议层是可行的（字段仍可能随 CLI 版本变化）：<https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server>。官方插件文档也说明桌面 App 与 CLI 都会读取受信任项目的插件配置，但用户级设置会写入 `~/.codex/config.toml`：<https://developers.openai.com/plugins/build/plugins>。

代理必须正确转发 SSE、鉴权头、压缩、超时和取消信号；重复 POST 可能在服务端已创建任务后产生副作用。容量错误也可能以 HTTP 429/503、JSON 错误码或流中事件出现，单靠状态码不够。

未修改用户 `~/.codex/config.toml`，未安装代理，也未在桌面 App 上做侵入式实验。该调研基于本机 CLI 0.166.0 的公开配置能力与协议约束，不能证明桌面 App 一定读取同一配置。

## 后续路线

1. 在隔离临时账号/配置目录启动一个只转发的本地代理，记录真实请求形态。
2. 对 429/503 和流内 capacity 事件做重放测试，验证幂等和取消。
3. 通过单独 `CODEX_HOME`/临时 config 做 TUI 冒烟，确认不会污染全局配置。
4. 若稳定，再增加 `csg proxy` 子命令；默认仍保持显式 launcher。

风险：代理凭据暴露、重复执行副作用、协议升级导致失效、桌面 App 忽略自定义 provider。任何启用都应提供一键恢复并先备份配置。
