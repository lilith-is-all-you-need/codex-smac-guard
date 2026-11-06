# 实战演示：用 csg 让两个模型接力修 .79 Patch（面向新手）

> 这是本次真实发生的过程，可直接照抄命令。

## 场景

`[Lilith]Mythware` 的 Release 拷到 VM `192.168.1.79` 后，启动 Patch 报：

```
[DLL] 兼容准入未通过，未安装正式 Patch
[Patch] stage=patch-command pid=7996 error=1114 (DLL_INIT_FAILED)
```

目标：让 Astra 去查/修，让 Sol 独立复核；我只看状态和证据。

## 第 1 步：确认工具可用

```powershell
csg doctor
```

看到 `CSG 版本: 1.1.1`、`默认模型: gpt-6-astra` 即可。

## 第 2 步：把任务书交给 Astra（一条命令）

```powershell
csg run --file "C:\...\prompts\F-vm79-fix.md" `
        --cd "C:\Users\LLS\Desktop\[Lilith]Mythware" `
        --model gpt-6-astra --effort ultra `
        --resume-on-smac --attempt-timeout-minutes 90 `
        --deadline "2026-11-05T08:00:00"
```

参数含义：

| 参数 | 为什么这么设 |
|---|---|
| `--file` | 任务书很长，放 md 文件里 |
| `--cd` | 让 Codex 直接以项目为工作目录 |
| `--model/--effort` | Astra + ultra |
| `--resume-on-smac` | 中途被容量打断时接着原会话跑，不从头来 |
| `--attempt-timeout-minutes 90` | 单次 attempt 最多 90 分钟，防止挂死 |
| `--deadline` | 总截止，到点自动退出 |

## 第 3 步：不用盯着，偶尔看状态

```powershell
csg status
```

真实过程（run `20261104-235534-d0c0f5`）：

```
[00:01] 第 1 轮 · 第 1/100 次 · 上次: SMAC · 累计 SMAC 1
[00:05] 第 1 轮 · 第 2/100 次 · 上次: SMAC · 累计 SMAC 2
[00:10] 第 1 轮 · 第 3/100 次 · 上次: SMAC · 累计 SMAC 3
[00:14] ... 累计 SMAC 4
[00:19] ... 累计 SMAC 5
...
结束：succeeded，尝试 7 次，SMAC 6 次，退出码 0
```

期间 `events.jsonl` 里每次 SMAC 后都有 `resume-armed`，下一次 attempt 自动变成：

```
codex exec resume 01a1a745-... -
  prompt: 继续执行未完成的任务。先检查工作区当前状态……
```

所以 Astra 的上下文没有丢，文件改动也都在（`compat_probe.c`、`compat_inference.c`、`hook.c` 等）。

## 第 4 步：看结果

```powershell
csg stats
```

```
总 run: 10 · 总尝试: 36 · SMAC: 27 · 成功率: 50.0%
```

> 成功率不是重点；重点是这个 run 最终 `succeeded`，且 6 次 SMAC 没有让人工介入。

证据在：

```
%LOCALAPPDATA%\csg\runs\20261104-235534-d0c0f5\
  last-message.md        # Astra 的最终结论
  events.jsonl           # SMAC / resume / finished
  attempt-001-00x\       # 每次尝试的完整输出
```

VM 侧最终：

```
pid=6980 error=0 state=1 route=2
event: 版本或协议适配不可用，使用 API 拦截路线
event: Patch 已就绪
```

## 第 5 步：换 Sol 独立复核

```powershell
csg run --file "C:\...\prompts\G-sol-review-vm79.md" `
        --cd "C:\Users\LLS\Desktop\[Lilith]Mythware" `
        --model gpt-6.1-sol --effort high `
        --resume-on-smac --deadline "2026-11-05T08:00:00"
```

两个模型不共享上下文：Astra 改完，Sol 只看代码、报告和 VM 现场，自己重新设计测试、复跑、找漏洞。这样才叫“审查”，不是“复述”。

## 第 6 步：日常怎么用

- 短任务：`csg run "任务"`，结束看 `succeeded`。
- 长任务：加 `--deadline` + `--attempt-timeout-minutes` + `--resume-on-smac`。
- 中断了：`csg status` 看 `stale` 就 `csg repair`；要续跑用 `csg run --resume <run-id>`。
- 不要在 Codex 桌面/TUI 里直接开的会话上期待 csg 生效——它只管 `codex exec`。

## 一句话总结

**csg 的价值不是“让模型变强”，而是“在容量故障的几十分钟里，替你保持任务不死、上下文不断、证据不丢”。**
