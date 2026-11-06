# SMAC 现象与处理记录

SMAC 的典型文本是 `ERROR: Selected model is at capacity. Please try a different model.`，通常在请求开始后几秒到几十秒返回，Codex 以非零退出码结束，消息可能出现在 stdout 或 stderr。CSG 合并两路输出与最终消息后，仅在 exit code ≠ 0 且命中完整 `ERROR: ... at capacity. Please try a different model.` 行时判定为 SMAC，既避免因流向差异漏检，也避免把任务正文里的引用误判。

容量错误表示模型当时无法接收请求；若尚未产生工具动作，重试同一 prompt 通常安全。已产生副作用时需任务可重入，或开启 `--resume-on-smac` 用 `codex exec resume` 续跑。CSG 仍把每次 attempt 完整记录，便于审计。

退避使用指数上限与少量抖动：早期失败间隔几秒，逐渐增加到 120 秒，避免 100 次请求瞬间打满。每轮 100 次后等待 30 分钟，降低持续撞击服务的概率。轮次数默认无限，deadline/Ctrl+C 提供硬停止。相比固定轮询，退避在容量恢复时间未知时更节省请求；相比只换模型，保留用户选择并避免悄悄改变推理行为。

非容量错误默认立即停止并返回 2，错误尾部写入 status；确有需要时可用 `--retry-non-capacity` 强制重试，这类重试单独计数，不与 SMAC 混淆。日志检测只依赖文本，因此服务端改变措辞时可能产生漏检；可通过 `--codex-cmd` fake 测试并在后续版本扩展正则。

证据来自离线 fake-codex 场景和真实 `codex exec` 冒烟。真实服务状态会变化，SMAC 计数不代表模型质量指标。
