#Requires -Version 7.0
<#
.SYNOPSIS
  csg-dash — 只读桌面仪表盘：显示正在运行的 csg run、SMAC 次数、最新进展。

.DESCRIPTION
  设计原则（非侵入式）：
    1. 不修改 csg.ps1，不写 csg 数据目录里的任何文件，只读；
    2. 数据全部来自既有产物：
         %LOCALAPPDATA%\csg\runs\<run>\status.json   —— run/轮次/attempt/SMAC/截止
         <CODEX_HOME>\sessions\yyyy\MM\dd\rollout-*.jsonl —— Codex 会话实时事件流（最新进展）
    3. 进程存活用 status.pid / ownerPid 判定，与 `csg status` 口径一致。

.PARAMETER RefreshSeconds
  刷新间隔（秒），默认 2。

.PARAMETER MaxRuns
  最多显示几个活跃 run，默认 4。

.PARAMETER NoTopMost
  不置顶。

.PARAMETER Once
  只打印一次文本快照（无 GUI），用于终端/脚本自检。

.EXAMPLE
  pwsh -sta -File .\csg-dash.ps1
.EXAMPLE
  pwsh -File .\csg-dash.ps1 -Once
#>
param(
  [int]$RefreshSeconds = 2,
  [int]$MaxRuns = 4,
  [switch]$NoTopMost,
  [switch]$Once
)

$ErrorActionPreference = 'Continue'
$script:DataRoot  = if ($env:CSG_DATA_DIR) { $env:CSG_DATA_DIR } else { Join-Path $env:LOCALAPPDATA 'csg' }
$script:RunsRoot  = Join-Path $script:DataRoot 'runs'
$script:CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$script:Trace = @{}          # runId -> @{ path; offset; items; tokens; lastProgressAt }
$script:RolloutIndex = @{}   # path -> session_meta 摘要

# ---------------------------------------------------------------- 数据层

function ConvertTo-LocalTime($v) {
  # ConvertFrom-Json 会把 ISO 字符串转成 DateTime(Kind=Utc/Local)，因此不能再用 [DateTime]::Parse([string]$v)
  if ($null -eq $v) { return $null }
  if ($v -is [DateTimeOffset]) { return $v.LocalDateTime }
  if ($v -is [DateTime]) {
    switch ([string]$v.Kind) {
      'Utc' { return $v.ToLocalTime() }
      'Local' { return $v }
      default { return [DateTime]::SpecifyKind($v, 'Local') }
    }
  }
  try { return ([DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture)).LocalDateTime } catch { return $null }
}

function Read-JsonFileQuiet([string]$Path) {
  try {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
    if (-not $raw.Trim()) { return $null }
    return $raw | ConvertFrom-Json -ErrorAction Stop
  } catch { return $null }
}

function Test-ProcessAlive($Id) {
  if (-not $Id) { return $false }
  try { return [bool](Get-Process -Id ([int]$Id) -ErrorAction Stop) } catch { return $false }
}

function Test-RunAlive($run) {
  if (Test-ProcessAlive $run.pid)      { return $true }
  if (Test-ProcessAlive $run.ownerPid) { return $true }
  return $false
}

function Get-CsgRuns {
  $out = @()
  if (-not (Test-Path -LiteralPath $script:RunsRoot)) { return $out }
  foreach ($d in (Get-ChildItem -LiteralPath $script:RunsRoot -Directory -ErrorAction SilentlyContinue)) {
    $s = Read-JsonFileQuiet (Join-Path $d.FullName 'status.json')
    if (-not $s) { continue }
    $state = [string]$s.state
    if ($state -notin @('running', 'cooling', 'starting')) { continue }
    $fresh = $false
    if ($s.updatedAt) { try { $fresh = (((Get-Date) - (ConvertTo-LocalTime $s.updatedAt)).TotalMinutes -lt 5) } catch { $fresh = $false } }
    $alive = Test-RunAlive $s
    if ($state -eq 'running' -and -not $alive) { continue }   # 强杀留下的 stale，交给 csg repair
    if ($state -ne 'running' -and -not $fresh) { continue }
    $s | Add-Member -NotePropertyName dir -NotePropertyValue $d.FullName -Force
    $out += $s
  }
  return @($out | Sort-Object { [string]$_.startedAt })
}

function Get-RolloutHeader([string]$Path) {
  $mtime = (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).LastWriteTimeUtc
  $c = $script:RolloutIndex[$Path]
  if ($c -and $c.mtime -eq $mtime -and $c.ok) { return $c }
  $info = [pscustomobject]@{ path = $Path; cwd = $null; threadSource = $null; parent = $null; sessionId = $null; ts = $null; mtime = $mtime; ok = $false }
  try {
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
      $buf = New-Object byte[] 65536
      $n = $fs.Read($buf, 0, $buf.Length)
      $line = [Text.Encoding]::UTF8.GetString($buf, 0, $n) -split "`n" | Select-Object -First 1
      $o = $line | ConvertFrom-Json -ErrorAction Stop
      if ($o.type -eq 'session_meta') {
        $info.cwd = [string]$o.payload.cwd
        $info.threadSource = [string]$o.payload.thread_source
        $info.parent = [string]$o.payload.parent_thread_id
        $info.sessionId = [string]$o.payload.session_id
        $info.ts = ConvertTo-LocalTime $o.payload.timestamp
        $info.ok = $true
      }
    } finally { $fs.Close() }
  } catch { }
  $script:RolloutIndex[$Path] = $info
  return $info
}

function Get-RecentRollouts {
  $dirs = @()
  foreach ($delta in 0, -1) {
    $d = (Get-Date).AddDays($delta)
    $p = Join-Path $script:CodexHome ('sessions\{0}\{1}\{2}' -f $d.ToString('yyyy'), $d.ToString('MM'), $d.ToString('dd'))
    if (Test-Path -LiteralPath $p) { $dirs += $p }
  }
  $files = @()
  foreach ($d in $dirs) { $files += Get-ChildItem -LiteralPath $d -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue }
  return $files
}

function Find-RunRollout($run) {
  if (-not $run.startedAt) { return $null }
  $start = (ConvertTo-LocalTime $run.startedAt).AddMinutes(-3)
  $best = $null
  foreach ($f in (Get-RecentRollouts)) {
    $h = Get-RolloutHeader $f.FullName
    if (-not $h.ok) { continue }
    if ($h.threadSource -ne 'user') { continue }            # 排除子代理线程
    if ($h.cwd -ne [string]$run.workDir) { continue }
    if ($h.ts -lt $start) { continue }
    if (-not $best -or $h.ts -gt $best.ts) { $best = $h }
  }
  return $best
}

function Format-Ago([double]$seconds) {
  if ($seconds -lt 0) { return '0s' }
  if ($seconds -lt 60) { return ('{0:0}s' -f $seconds) }
  if ($seconds -lt 3600) { return ('{0:0}m{1:00}s' -f [Math]::Floor($seconds / 60), ([int]$seconds % 60)) }
  return ('{0}h{1:00}m' -f [Math]::Floor($seconds / 3600), [Math]::Floor(($seconds % 3600) / 60))
}

function Format-Elapsed([double]$s) {
  if ($s -lt 0) { return '0:00:00' }
  $ts = [TimeSpan]::FromSeconds($s)
  return ('{0}:{1:00}:{2:00}' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
}

function Get-ToolLabel($name, $payloadText) {
  $s = [string]$payloadText
  $label = [string]$name
  if (-not $s.Trim()) { return $label }
  if ($label -eq 'exec') {
    $m = [regex]::Match($s, 'cmd:\s*"((?:[^"\\]|\\.){1,160})"')
    if (-not $m.Success) { $m = [regex]::Match($s, "cmd:\s*'((?:[^'\\]|\\.){1,160})'") }
    if ($m.Success) { $label = 'exec: ' + $m.Groups[1].Value }
    else { $label = 'exec: ' + $s }
  } elseif ($label -in @('wait_agent', 'spawn_agent', 'send_message', 'close_agent')) {
    $m = [regex]::Match($s, '"(?:task_name|agent_id|id)":"([^"]{1,40})"')
    if ($m.Success) { $label = "${label}: " + $m.Groups[1].Value }
  } elseif ($label -match 'apply_patch') {
    $m = [regex]::Match($s, '\*\*\* (Add|Update|Delete) File: ([^\\\r\n"]{1,120})')
    if ($m.Success) { $label = 'apply_patch: ' + $m.Groups[2].Value }
  } elseif ($s) {
    $label = "${label}: $s"
  }
  $label = ($label -replace '\s+', ' ').Trim()
  if ($label.Length -gt 110) { $label = $label.Substring(0, 110) + '…' }
  return $label
}

function Update-RunTrace($run) {
  $id = [string]$run.runId
  $t = $script:Trace[$id]
  if (-not $t) {
    $t = @{ path = $null; offset = 0; items = (New-Object System.Collections.ArrayList); tokens = $null; lastProgressAt = $null }
    $script:Trace[$id] = $t
  }

  if (-not $t.path -or -not (Test-Path -LiteralPath $t.path)) {
    $h = Find-RunRollout $run
    if ($h) { $t.path = $h.path; $t.offset = 0; $t.items.Clear(); $t.tokens = $null } else { return $t }
  }

  $fs = $null
  try { $fs = [IO.File]::Open($t.path, 'Open', 'Read', 'ReadWrite') } catch { return $t }
  try {
    $len = $fs.Length
    if ($len -lt $t.offset) { $t.offset = 0; $t.items.Clear() }
    $firstRead = ($t.offset -eq 0 -and $t.items.Count -eq 0)
    if ($firstRead -and $len -gt 524288) { $t.offset = $len - 524288 }   # 首次只看尾部，避免从 0 逐块爬
    if ($len -le $t.offset) { return $t }
    $take = [Math]::Min(524288, $len - $t.offset)
    [void]$fs.Seek($t.offset, 'Begin')
    $buf = New-Object byte[] $take
    $read = 0
    while ($read -lt $take) {
      $n = $fs.Read($buf, $read, $take - $read)
      if ($n -le 0) { break }
      $read += $n
    }
    $chunk = [Text.Encoding]::UTF8.GetString($buf, 0, $read)
    $lastNl = $chunk.LastIndexOf("`n")
    if ($lastNl -lt 0) { return $t }
    $complete = $chunk.Substring(0, $lastNl)
    $t.offset += [Text.Encoding]::UTF8.GetByteCount($complete) + 1
    if ($firstRead) {
      $i = $complete.IndexOf("`n")            # 首行多半是被截断的半行，丢弃
      $complete = if ($i -ge 0) { $complete.Substring($i + 1) } else { '' }
    }

    foreach ($line in ($complete -split "`n")) {
      if ($line.Length -lt 8 -or $line.Length -gt 262144) { continue }
      if ($line.IndexOf('"response_item"') -lt 0 -and $line.IndexOf('"token_usage_record"') -lt 0) { continue }
      $o = $null
      try { $o = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
      if (-not $o) { continue }
      if ($o.type -eq 'token_usage_record') {
        if ($o.payload.usage) { $t.tokens = $o.payload.usage }
        continue
      }
      if ($o.type -ne 'response_item') { continue }
      $p = $o.payload
      $ts = ConvertTo-LocalTime $o.timestamp
      if (-not $ts) { $ts = Get-Date }
      switch ([string]$p.type) {
        'message' {
          if ([string]$p.role -ne 'assistant') { break }
          $txt = (@($p.content) | Where-Object { $_.type -eq 'output_text' } | ForEach-Object { [string]$_.text }) -join "`n"
          if (-not $txt.Trim()) { break }
          [void]$t.items.Add([pscustomobject]@{ kind = 'msg'; ts = $ts; text = $txt.Trim() })
          $t.lastProgressAt = $ts
        }
        'reasoning' {
          $sum = (@($p.summary) | ForEach-Object { [string]$_.text }) -join "`n"
          if (-not $sum.Trim()) { break }
          [void]$t.items.Add([pscustomobject]@{ kind = 'think'; ts = $ts; text = $sum.Trim() })
          $t.lastProgressAt = $ts
        }
        { $_ -in @('custom_tool_call', 'function_call', 'local_shell_call', 'web_search_call') } {
          $label = Get-ToolLabel $p.name ([string]$p.input + [string]$p.arguments)
          [void]$t.items.Add([pscustomobject]@{ kind = 'tool'; ts = $ts; text = $label })
          $t.lastProgressAt = $ts
        }
        default { }
      }
      if ($t.items.Count -gt 60) { $t.items.RemoveRange(0, $t.items.Count - 60) }
    }
  } catch {
  } finally { if ($fs) { $fs.Close() } }
  return $t
}

function Get-RunView($run) {
  $t = Update-RunTrace $run
  $now = Get-Date
  $start = ConvertTo-LocalTime $run.startedAt
  if (-not $start) { $start = $now }
  $elapsed = ($now - $start).TotalSeconds

  $msg = $null; $tool = $null; $think = $null
  if ($t.items.Count -gt 0) {
    for ($i = $t.items.Count - 1; $i -ge 0; $i--) {
      $it = $t.items[$i]
      if (-not $msg -and $it.kind -eq 'msg')     { $msg = $it }
      if (-not $tool -and $it.kind -eq 'tool')   { $tool = $it }
      if (-not $think -and $it.kind -eq 'think') { $think = $it }
      if ($msg -and $tool -and $think) { break }
      if (($t.items.Count - $i) -gt 40) { break }
    }
  }

  $tok = $null
  if ($t.tokens) {
    $inp = [double]$t.tokens.input_tokens; $outp = [double]$t.tokens.output_tokens
    $tok = ('{0:N0}k↑ {1:N0}↓' -f ($inp / 1000), $outp)
  }

  $deadlineLeft = $null
  $dl = ConvertTo-LocalTime $run.deadline
  if ($dl) { $deadlineLeft = ($dl - $now).TotalSeconds }

  return [pscustomobject]@{
    run          = $run
    elapsed      = $elapsed
    message      = $msg
    think        = $think
    tool         = $tool
    tokens       = $tok
    idleSeconds  = if ($t.lastProgressAt) { ($now - $t.lastProgressAt).TotalSeconds } else { $null }
    deadlineLeft = $deadlineLeft
    hasTrace     = [bool]$t.path
  }
}

# ---------------------------------------------------------------- 文本快照（-Once）

function Get-StateBadge($run) {
  switch ([string]$run.state) {
    'running'  { return @{ text = '运行中'; color = '#5fd75f' } }
    'cooling'  { return @{ text = ('冷却中 ' + [string]$run.cooldownRemainingSec + 's'); color = '#e0b040' } }
    'starting' { return @{ text = '启动中'; color = '#8ab4f8' } }
    default    { return @{ text = [string]$run.state; color = '#9aa0aa' } }
  }
}

function Show-Once {
  $runs = @(Get-CsgRuns | Select-Object -First $MaxRuns)
  Write-Host ('CSG 监视器  ·  ' + (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Cyan
  if ($runs.Count -eq 0) { Write-Host '当前没有活跃的 csg run'; return }
  foreach ($r in $runs) {
    $v = Get-RunView $r
    $badge = Get-StateBadge $r
    Write-Host ''
    Write-Host ('● ' + $r.runId) -ForegroundColor Cyan
    Write-Host ('  {0}  ·  {1}/{2}  ·  {3}' -f $badge.text, $r.model, $r.effort, (Format-Elapsed $v.elapsed)) -ForegroundColor Green
    Write-Host ('  第 {0} 轮/第 {1} 次 · 累计 {2} 次 · SMAC {3}' -f $r.round, $r.attemptInRound, $r.totalAttempts, $r.smacCount)
    if ($v.deadlineLeft -ne $null) { Write-Host ('  截止剩 ' + (Format-Ago $v.deadlineLeft) + ' · ' + (Split-Path -Leaf ([string]$r.workDir))) -ForegroundColor DarkGray }
    if ($v.tool)    { Write-Host ('  ⏵ ' + $v.tool.text) -ForegroundColor Gray }
    if ($v.message) { $m = ($v.message.text -replace '\s+', ' '); Write-Host ('  💬 ' + $m) -ForegroundColor DarkCyan }
    elseif (-not $v.hasTrace) { Write-Host '  （等待 Codex 会话流…）' -ForegroundColor DarkGray }
    $tail = @()
    if ($v.tokens) { $tail += $v.tokens }
    if ($v.idleSeconds -ne $null) { $tail += ('最新事件 ' + (Format-Ago $v.idleSeconds) + ' 前') }
    if ($tail.Count) { Write-Host ('  ' + ($tail -join ' · ')) -ForegroundColor DarkGray }
  }
}

if ($Once) { Show-Once; exit 0 }

# ---------------------------------------------------------------- GUI

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:PAD_X = 12
$script:PAD_Y = 10
$script:WIDTH = 440

$script:F = @{
  title = New-Object Drawing.Font('Microsoft YaHei UI', [single]9, [Drawing.FontStyle]::Bold)
  id    = New-Object Drawing.Font('Consolas', [single]10, [Drawing.FontStyle]::Bold)
  head  = New-Object Drawing.Font('Microsoft YaHei UI', [single]9, [Drawing.FontStyle]::Regular)
  meta  = New-Object Drawing.Font('Microsoft YaHei UI', [single]8, [Drawing.FontStyle]::Regular)
  mono  = New-Object Drawing.Font('Consolas', [single]8.5, [Drawing.FontStyle]::Regular)
  hint  = New-Object Drawing.Font('Microsoft YaHei UI', [single]7.5, [Drawing.FontStyle]::Regular)
}
$script:C = @{
  bg    = [Drawing.ColorTranslator]::FromHtml('#12141a')
  edge  = [Drawing.ColorTranslator]::FromHtml('#22262f')
  title = [Drawing.ColorTranslator]::FromHtml('#8ab4f8')
  id    = [Drawing.ColorTranslator]::FromHtml('#8ab4f8')
  green = [Drawing.ColorTranslator]::FromHtml('#5fd75f')
  amber = [Drawing.ColorTranslator]::FromHtml('#e0b040')
  blue  = [Drawing.ColorTranslator]::FromHtml('#8ab4f8')
  text  = [Drawing.ColorTranslator]::FromHtml('#d7dae2')
  msg   = [Drawing.ColorTranslator]::FromHtml('#b9c6ff')
  dim   = [Drawing.ColorTranslator]::FromHtml('#6b7280')
  faint = [Drawing.ColorTranslator]::FromHtml('#4b5563')
}

function Get-Elided([string]$text, $font, [int]$maxWidth) {
  if (-not $text) { return '' }
  if ([System.Windows.Forms.TextRenderer]::MeasureText($text, $font).Width -le $maxWidth) { return $text }
  $t = $text
  while ($t.Length -gt 4) {
    $t = $t.Substring(0, $t.Length - 2)
    if ([System.Windows.Forms.TextRenderer]::MeasureText($t + '…', $font).Width -le $maxWidth) { return $t + '…' }
  }
  return $t
}

function Add-PhysLine($list, $text, $font, $color, [int]$indent, $runId, [int]$extra = 0) {
  [void]$list.Add([pscustomobject]@{
      text = [string]$text; font = $font; color = $color; indent = $indent; runId = $runId; extra = $extra
    })
}

function New-TextLine($text, $font, $color, $indent, $runId, [switch]$wrap, [int]$maxLines = 2) {
  # 返回物理行数组（已按宽度折行）
  $out = New-Object System.Collections.ArrayList
  $avail = $script:WIDTH - ($script:PAD_X * 2) - $indent
  if (-not $wrap) { Add-PhysLine $out (Get-Elided $text $font $avail) $font $color $indent $runId; return , $out }
  $s = [string]$text
  $line = ''
  $count = 0
  foreach ($ch in $s.ToCharArray()) {
    $try = $line + $ch
    if ([System.Windows.Forms.TextRenderer]::MeasureText($try, $font).Width -gt $avail -and $line.Length -gt 0) {
      $count++
      if ($count -ge $maxLines) {
        Add-PhysLine $out (Get-Elided ($line + '…') $font $avail) $font $color $indent $runId
        return , $out
      }
      Add-PhysLine $out $line $font $color $indent $runId
      $line = [string]$ch
    } else { $line = $try }
  }
  if ($line) { Add-PhysLine $out $line $font $color $indent $runId }
  return , $out
}

function Build-Layout($views) {
  $lines = New-Object System.Collections.ArrayList
  $cnt = if ($views) { $views.Count } else { 0 }
  $cntText = if ($cnt -gt 0) { ' · ' + $cnt + ' 个任务' } else { ' · 空闲' }
  Add-PhysLine $lines ('CSG 监视器' + $cntText + ' · ' + (Get-Date -Format 'HH:mm:ss')) $script:F.title $script:C.title 0 $null
  if (-not $views -or $views.Count -eq 0) {
    Add-PhysLine $lines '' $script:F.meta $script:C.bg 0 $null 4
    Add-PhysLine $lines '当前没有活跃的 csg run' $script:F.head $script:C.dim 0 $null
    Add-PhysLine $lines 'csg run 启动后自动出现' $script:F.hint $script:C.faint 0 $null
    return , $lines
  }
  foreach ($v in $views) {
    $r = $v.run
    $badge = Get-StateBadge $r
    Add-PhysLine $lines '' $script:F.meta $script:C.bg 0 $null 6
    Add-PhysLine $lines ('● ' + [string]$r.runId) $script:F.id $script:C.id 0 ([string]$r.runId)
    $head = ('{0}   {1}/{2}   {3}' -f $badge.text, $r.model, $r.effort, (Format-Elapsed $v.elapsed))
    Add-PhysLine $lines $head $script:F.head (Convert-HexToColor $badge.color) 14 ([string]$r.runId)
    $meta = ('第 {0} 轮/第 {1} 次 · 累计 {2} 次 · SMAC {3}' -f $r.round, $r.attemptInRound, $r.totalAttempts, $r.smacCount)
    $metaColor = if ([int]$r.smacCount -gt 0) { $script:C.amber } else { $script:C.dim }
    Add-PhysLine $lines $meta $script:F.meta $metaColor 14 ([string]$r.runId)
    if ($v.deadlineLeft -ne $null) {
      $dl = if ($v.deadlineLeft -gt 0) { '截止剩 ' + (Format-Ago $v.deadlineLeft) } else { '已过截止' }
      Add-PhysLine $lines ($dl + ' · ' + (Split-Path -Leaf ([string]$r.workDir))) $script:F.meta $script:C.dim 14 ([string]$r.runId)
    } elseif ($r.workDir) {
      Add-PhysLine $lines (Split-Path -Leaf ([string]$r.workDir)) $script:F.meta $script:C.dim 14 ([string]$r.runId)
    }
    if ($v.tool) {
      foreach ($l in (New-TextLine ('⏵ ' + $v.tool.text) $script:F.mono $script:C.text 14 ([string]$r.runId) -wrap -maxLines 1)) { [void]$lines.Add($l) }
    }
    if ($v.message) {
      $m = ($v.message.text -replace '\s+', ' ')
      foreach ($l in (New-TextLine ('» ' + $m) $script:F.meta $script:C.msg 14 ([string]$r.runId) -wrap -maxLines 2)) { [void]$lines.Add($l) }
    } elseif ($v.think) {
      $m = ($v.think.text -replace '\s+', ' ')
      foreach ($l in (New-TextLine ('» ' + $m) $script:F.meta $script:C.msg 14 ([string]$r.runId) -wrap -maxLines 2)) { [void]$lines.Add($l) }
    } elseif (-not $v.hasTrace) {
      Add-PhysLine $lines '（等待 Codex 会话流…）' $script:F.meta $script:C.faint 14 ([string]$r.runId)
    }
    $tail = @()
    if ($v.tokens) { $tail += $v.tokens }
    if ($v.idleSeconds -ne $null) { $tail += ('最新事件 ' + (Format-Ago $v.idleSeconds) + ' 前') }
    if ($tail.Count) { Add-PhysLine $lines ($tail -join ' · ') $script:F.hint $script:C.dim 14 ([string]$r.runId) }
  }
  Add-PhysLine $lines '' $script:F.meta $script:C.bg 0 $null 6
  Add-PhysLine $lines '双击打开 run 目录 · 右键菜单 · 拖动移动' $script:F.hint $script:C.faint 2 $null
  return , $lines
}

function Convert-HexToColor([string]$hex) {
  if ($hex -match '^#[0-9a-fA-F]{6}$') { return [Drawing.ColorTranslator]::FromHtml($hex) }
  return $script:C.text
}

function Measure-LineHeight($font) {
  return [Math]::Max([int]$font.Height, 11) + 2
}

# --- 窗体 ---
$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'csg-dash'
$script:Form.FormBorderStyle = 'None'
$script:Form.StartPosition = 'Manual'
$script:Form.ShowInTaskbar = $false
$script:Form.BackColor = $script:C.bg
if (-not $NoTopMost) { $script:Form.TopMost = $true }
$script:Form.ClientSize = New-Object Drawing.Size($script:WIDTH, 160)

$script:Panel = New-Object System.Windows.Forms.Panel
$script:Panel.Dock = 'Fill'
$script:Panel.BackColor = $script:C.bg
$script:Form.Controls.Add($script:Panel)

# 高分屏适配：字体本身按 DPI 渲染，画布宽度与内边距同步放大
$null = $script:Form.Handle
$null = $script:Panel.Handle
$script:Scale = [Math]::Max(1.0, ($script:Panel.DeviceDpi / 96.0))
$script:WIDTH = [int](420 * $script:Scale)
$script:PAD_X = [int](12 * $script:Scale)
$script:PAD_Y = [int](10 * $script:Scale)
$script:Form.ClientSize = New-Object Drawing.Size($script:WIDTH, [int](150 * $script:Scale))

$script:Phys = New-Object System.Collections.ArrayList
$script:lineY = @()

$script:Panel.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.Clear($script:C.bg)
    $pen = New-Object Drawing.Pen($script:C.edge)
    $g.DrawRectangle($pen, 0, 0, $script:Panel.Width - 1, $script:Panel.Height - 1)
    $pen.Dispose()
    $y = $script:PAD_Y
    $script:lineY = @()
    $brushCache = @{}
    foreach ($l in $script:Phys) {
      $lh = Measure-LineHeight $l.font
      $script:lineY += [pscustomobject]@{ y0 = $y; y1 = $y + $lh + $l.extra; runId = $l.runId }
      if ($l.text) {
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
        $rect = New-Object Drawing.RectangleF(($script:PAD_X + $l.indent), $y, ($script:WIDTH - 24 - $l.indent), $lh)
        $key = $l.color.ToArgb()
        if (-not $brushCache.ContainsKey($key)) { $brushCache[$key] = New-Object Drawing.SolidBrush($l.color) }
        try { $g.DrawString($l.text, $l.font, $brushCache[$key], $rect, $fmt) } catch { }
        $fmt.Dispose()
      }
      $y += $lh + $l.extra
    }
  })

# 拖动
$script:drag = $false
$script:dragOffset = New-Object Drawing.Point(0, 0)
$script:Panel.Add_MouseDown({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $script:drag = $true; $script:dragOffset = $e.Location } })
$script:Panel.Add_MouseMove({
    param($s, $e)
    if ($script:drag) {
      $p = $script:Panel.PointToScreen($e.Location)
      $script:Form.Location = New-Object Drawing.Point(($p.X - $script:dragOffset.X), ($p.Y - $script:dragOffset.Y))
    }
  })
$script:Panel.Add_MouseUp({ param($s, $e) $script:drag = $false })

# 双击
$script:Panel.Add_DoubleClick({
    param($s, $e)
    try {
      $hit = $script:lineY | Where-Object { $e.Y -ge $_.y0 -and $e.Y -lt $_.y1 } | Select-Object -First 1
      $target = if ($hit -and $hit.runId) { $hit.runId } else { $script:firstRunId }
      if ($target) { Start-Process explorer.exe -ArgumentList ('"' + (Join-Path $script:RunsRoot $target) + '"') }
    } catch { }
  })

# 右键菜单
$script:Menu = New-Object System.Windows.Forms.ContextMenuStrip
$mi1 = New-Object System.Windows.Forms.ToolStripMenuItem('打开最新 run 目录')
$mi1.Add_Click({ if ($script:firstRunId) { Start-Process explorer.exe -ArgumentList ('"' + (Join-Path $script:RunsRoot $script:firstRunId) + '"') } })
[void]$script:Menu.Items.Add($mi1)
$mi2 = New-Object System.Windows.Forms.ToolStripMenuItem('复制最新 run id')
$mi2.Add_Click({ if ($script:firstRunId) { [System.Windows.Forms.Clipboard]::SetText($script:firstRunId) } })
[void]$script:Menu.Items.Add($mi2)
$mi3 = New-Object System.Windows.Forms.ToolStripMenuItem('立即刷新')
$mi3.Add_Click({ & $script:Update })
[void]$script:Menu.Items.Add($mi3)
[void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$mi4 = New-Object System.Windows.Forms.ToolStripMenuItem('退出')
$mi4.Add_Click({ $script:Form.Close() })
[void]$script:Menu.Items.Add($mi4)
$script:Panel.ContextMenuStrip = $script:Menu

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$script:Form.Location = New-Object Drawing.Point(($screen.Right - $script:WIDTH - 16), ($screen.Top + 16))

$script:Update = {
  try {
    $runs = @(Get-CsgRuns | Select-Object -First $MaxRuns)
    $script:firstRunId = if ($runs.Count -gt 0) { [string]$runs[0].runId } else { $null }
    $views = @($runs | ForEach-Object { Get-RunView $_ })
    $script:Phys = Build-Layout $views
    $h = $script:PAD_Y * 2
    foreach ($l in $script:Phys) { $h += (Measure-LineHeight $l.font) + $l.extra }
    $h = [Math]::Max(96, [Math]::Min(($screen.Height - 60), ($h + 4)))
    if ([Math]::Abs($script:Form.ClientSize.Height - $h) -gt 2) { $script:Form.ClientSize = New-Object Drawing.Size($script:WIDTH, $h) }
    $script:Panel.Invalidate()
  } catch { }
}

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = [Math]::Max(500, $RefreshSeconds * 1000)
$script:Timer.Add_Tick({ & $script:Update })

$script:Form.Add_Shown({
    & $script:Update
    $script:Timer.Start()
  })
$script:Form.Add_FormClosing({ $script:Timer.Stop() })

[void]$script:Form.ShowDialog()
