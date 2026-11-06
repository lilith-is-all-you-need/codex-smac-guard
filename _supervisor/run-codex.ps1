#Requires -Version 7.0
<#
  Supervisor for codex exec runs.
  - Detects SMAC ("Selected model is at capacity") and retries.
  - 100 attempts per round (configurable), then cooldown (default 30 min), unlimited rounds.
  - Writes per-run status.json / events.jsonl / attempt logs, and appends a summary to _runs\stats.jsonl.
  - Honors a hard deadline.

  Usage:
    pwsh -File run-codex.ps1 -Label build-v1 -Workdir <dir> -PromptFile <file> -Model gpt-6-astra -Effort ultra
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Label,
  [Parameter(Mandatory)][string]$Workdir,
  [string]$Model = 'gpt-6.1-sol',
  [string]$Effort = 'high',
  [string]$PromptFile,
  [string]$Prompt,
  [string]$Sandbox = 'danger-full-access',
  [int]$AttemptsPerRound = 100,
  [int]$CooldownSeconds = 1800,
  [int]$MaxRounds = 0,
  [int]$AttemptTimeoutMinutes = 360,
  [string]$Deadline = '2026-11-04T21:00:00+08:00',
  [int]$TransientLimit = 5,
  [string[]]$AddDirs = @()
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $PSScriptRoot
$script:Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:RunDir = Join-Path (Join-Path $PSScriptRoot 'runs') ("{0}-{1}" -f $Stamp, ($Label -replace '[^\w\-\.]+','_'))
New-Item -ItemType Directory -Force -Path $script:RunDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $PSScriptRoot 'runs') | Out-Null

$script:StatusPath = Join-Path $script:RunDir 'status.json'
$script:EventsPath = Join-Path $script:RunDir 'events.jsonl'
$script:LogPath    = Join-Path $script:RunDir 'supervisor.log'
$script:LastMsgPath = Join-Path $script:RunDir 'last-message.md'
$script:StatsPath  = Join-Path (Join-Path $PSScriptRoot 'runs') 'stats.jsonl'
$script:DeadlineAt = [datetime]::Parse($Deadline, [cultureinfo]::InvariantCulture)
$script:StartedAt  = Get-Date

function Now { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }

function Log([string]$msg) {
  $line = '{0} {1}' -f (Now), $msg
  Add-Content -LiteralPath $script:LogPath -Value $line -Encoding utf8
  Write-Host $line
}

$script:State = @{
  label = $Label; model = $Model; effort = $Effort; workdir = $Workdir
  phase = 'starting'; round = 0; attempt = 0; attemptsPerRound = $AttemptsPerRound
  cooldownRemainingSec = 0; lastError = ''; smacCount = 0; attemptsTotal = 0
  started = $script:StartedAt.ToString('o'); updated = $script:StartedAt.ToString('o')
  exitCode = $null; logDir = $script:RunDir; pid = $null
}

function SaveStatus {
  $script:State.updated = (Get-Date).ToString('o')
  ($script:State | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $script:StatusPath -Encoding utf8
}

function Emit([string]$event, [hashtable]$data = @{}) {
  $d = [ordered]@{ ts = (Get-Date).ToString('o'); event = $event; label = $Label; model = $Model; effort = $Effort }
  foreach ($k in $data.Keys) { $d[$k] = $data[$k] }
  ($d | ConvertTo-Json -Compress -Depth 6) | Add-Content -LiteralPath $script:EventsPath -Encoding utf8
}

function Get-CodexExe {
  if ($env:CODEX_EXE -and (Test-Path -LiteralPath $env:CODEX_EXE)) { return $env:CODEX_EXE }
  $candidates = @(
    'C:\Users\LLS\AppData\Local\OpenAI\Codex\bin\b6c7fc9497179c98\codex.exe',
    "$env:APPDATA\npm\codex.cmd"
  )
  foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
  $cmd = Get-Command codex -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw 'codex executable not found'
}

function Quote([string]$s) {
  if ($null -eq $s -or $s -eq '') { return '""' }
  if ($s -notmatch '[\s"]') { return $s }
  return '"' + ($s -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

$promptText = if ($Prompt) { $Prompt } elseif ($PromptFile) { Get-Content -LiteralPath $PromptFile -Raw -Encoding utf8 } else { throw 'Prompt or PromptFile required' }
$codexExe = Get-CodexExe
$script:State.codexExe = $codexExe

function Get-TailText([string]$path, [int]$bytes = 65536) {
  if (-not (Test-Path -LiteralPath $path)) { return '' }
  $fi = Get-Item -LiteralPath $path
  if ($fi.Length -le $bytes) { return Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue }
  $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
  try {
    $fs.Seek(-$bytes, 'End') | Out-Null
    $sr = [System.IO.StreamReader]::new($fs)
    return $sr.ReadToEnd()
  } finally { $fs.Dispose() }
}

$capacityRegex = '(?i)(selected model is at capacity|model is at capacity|at capacity)'
$transientRegex = '(?i)(stream disconnected|connection reset|timed out|timeout|temporarily unavailable|overloaded|econnreset|socket hang up|502|503|504|429)'

function Invoke-Attempt {
  param([int]$Round, [int]$Attempt)
  $attemptDir = Join-Path $script:RunDir ('attempt-{0:D3}-{1:D3}' -f $Round, $Attempt)
  New-Item -ItemType Directory -Force -Path $attemptDir | Out-Null
  $outFile = Join-Path $attemptDir 'stdout.log'
  $errFile = Join-Path $attemptDir 'stderr.log'
  $lastMsg = Join-Path $attemptDir 'last-message.md'

  $argv = @('exec', '--skip-git-repo-check', '-s', $Sandbox, '-C', $Workdir, '-m', $Model,
            '-c', ('model_reasoning_effort="' + $Effort + '"'), '--color', 'never',
            '-o', $lastMsg)
  foreach ($d in $AddDirs) { $argv += @('--add-dir', $d) }
  $argv += '-'
  $argLine = ($argv | ForEach-Object { Quote $_ }) -join ' '

  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $codexExe
  $psi.Arguments = $argLine
  $psi.WorkingDirectory = $Workdir
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  $psi.CreateNoWindow = $true

  $p = [System.Diagnostics.Process]::new()
  $p.StartInfo = $psi
  $null = $p.Start()
  $script:State.pid = $p.Id
  $script:State.phase = 'running'
  $script:State.attempt = $Attempt
  SaveStatus

  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  $promptBytes = [System.Text.Encoding]::UTF8.GetBytes($promptText)
  $p.StandardInput.BaseStream.Write($promptBytes, 0, $promptBytes.Length)
  $p.StandardInput.BaseStream.Flush()
  $p.StandardInput.Close()

  $timeoutMs = [int]([math]::Min([double]$AttemptTimeoutMinutes * 60000, 2147000000))
  $exited = $p.WaitForExit($timeoutMs)
  if (-not $exited) {
    Log "attempt timeout ($AttemptTimeoutMinutes min), killing pid $($p.Id)"
    & taskkill /T /F /PID $p.Id 2>&1 | Out-Null
    $p.WaitForExit(30000) | Out-Null
  }

  $out = ''
  $err = ''
  try { $out = $outTask.GetAwaiter().GetResult() } catch { $out = '' }
  try { $err = $errTask.GetAwaiter().GetResult() } catch { $err = '' }
  Set-Content -LiteralPath $outFile -Value $out -Encoding utf8
  Set-Content -LiteralPath $errFile -Value $err -Encoding utf8

  $exitCode = if ($p.HasExited) { $p.ExitCode } else { -1 }
  $text = ($out + "`n" + $err)
  if ($exitCode -eq 0) { $kind = 'ok' }
  elseif ($text -match '(?im)^\s*ERROR:\s*Selected model is at capacity') { $kind = 'capacity' }
  elseif ($text -match '(?i)selected model is at capacity') { $kind = 'capacity' }
  elseif ($text -match $transientRegex) { $kind = 'transient' }
  else { $kind = 'error' }

  return [pscustomobject]@{
    ExitCode = $exitCode; Kind = $kind; OutFile = $outFile; ErrFile = $errFile
    LastMsg = if (Test-Path -LiteralPath $lastMsg) { $lastMsg } else { $null }
    Tail = (($text.Trim() -split "`n") | Select-Object -Last 6) -join "`n"
  }
}

function Wait-WithCountdown([int]$seconds, [string]$why) {
  $end = (Get-Date).AddSeconds($seconds)
  $script:State.phase = 'cooldown'
  while ((Get-Date) -lt $end) {
    if ((Get-Date) -ge $script:DeadlineAt) { return $false }
    $remain = [int]($end - (Get-Date)).TotalSeconds
    $script:State.cooldownRemainingSec = [math]::Max(0, $remain)
    SaveStatus
    $step = [math]::Min(30, [math]::Max(1, $remain))
    Log ("{0}（剩余 {1} 分 {2} 秒）" -f $why, [math]::Floor($remain / 60), ($remain % 60))
    Start-Sleep -Seconds $step
  }
  $script:State.cooldownRemainingSec = 0
  return $true
}

# ---------------- main loop ----------------
Log "run dir: $script:RunDir"
Log "codex: $codexExe | model: $Model | effort: $Effort | workdir: $Workdir"
Log "attempts/round: $AttemptsPerRound | cooldown: $CooldownSeconds s | deadline: $($script:DeadlineAt.ToString('yyyy-MM-dd HH:mm:ss'))"
Emit 'run_start' @{ attemptPerRound = $AttemptsPerRound; cooldownSeconds = $CooldownSeconds; deadline = $script:DeadlineAt.ToString('o'); workdir = $Workdir }

$round = 0
$total = 0
$smac = 0
$transientStreak = 0
$outcome = 'failed'
$finalExit = 1

while ($true) {
  if ((Get-Date) -ge $script:DeadlineAt) { $outcome = 'deadline'; $finalExit = 3; Log 'deadline reached before round start'; break }
  $round++
  $script:State.round = $round
  Log "===== 第 $round 轮开始（每轮 $AttemptsPerRound 次） ====="
  Emit 'round_start' @{ round = $round }
  $roundFailed = $true

  for ($i = 1; $i -le $AttemptsPerRound; $i++) {
    if ((Get-Date) -ge $script:DeadlineAt) { $outcome = 'deadline'; $finalExit = 3; Log 'deadline reached'; break }
    $total++
    $script:State.attemptsTotal = $total
    Log "开始：第 $round 轮第 $i/$AttemptsPerRound 次（总计第 $total 次）"
    $r = Invoke-Attempt -Round $round -Attempt $i
    Emit 'attempt_end' @{ round = $round; attemptInRound = $i; total = $total; exitCode = $r.ExitCode; kind = $r.Kind; tail = $r.Tail }

    if ($r.Kind -eq 'ok') {
      $outcome = 'success'; $finalExit = 0
      Log "成功：第 $round 轮第 $i 次（总第 $total 次）"
      if ($r.LastMsg) { Copy-Item -LiteralPath $r.LastMsg -Destination $script:LastMsgPath -Force }
      $roundFailed = $false
      break
    }
    elseif ($r.Kind -eq 'capacity') {
      $smac++
      $script:State.smacCount = $smac
      $script:State.lastError = 'Selected model is at capacity'
      $transientStreak = 0
      SaveStatus
      Log "SMAC：第 $round 轮第 $i/$AttemptsPerRound 次（总第 $total 次）"
      if ($i -lt $AttemptsPerRound) {
        $wait = [math]::Min(120, [math]::Max(3, [int](3 * [math]::Pow(1.35, [math]::Min($i, 20))) + (Get-Random -Maximum 4)))
        Log "等待 $wait 秒后重试同一请求..."
        if (-not (Wait-WithCountdown $wait 'SMAC 退避')) { $outcome = 'deadline'; $finalExit = 3; break }
        $script:State.phase = 'retrying'; SaveStatus
      }
    }
    elseif ($r.Kind -eq 'transient') {
      $transientStreak++
      $script:State.lastError = $r.Tail
      SaveStatus
      Log "瞬态错误（第 $transientStreak/$TransientLimit 次）：$($r.Tail)"
      if ($transientStreak -ge $TransientLimit) { $outcome = 'transient-exhausted'; $finalExit = 2; break }
      if (-not (Wait-WithCountdown 60 '瞬态错误退避')) { $outcome = 'deadline'; $finalExit = 3; break }
    }
    else {
      $script:State.lastError = $r.Tail
      SaveStatus
      Log "非容量错误（exit=$($r.ExitCode)），停止：$($r.Tail)"
      Emit 'fatal_error' @{ tail = $r.Tail }
      $outcome = 'error'; $finalExit = $r.ExitCode; if ($finalExit -eq 0) { $finalExit = 2 }
      break
    }
  }

  if ($outcome -in @('success','deadline','transient-exhausted','error')) { break }

  if ($roundFailed) {
    Emit 'round_failed' @{ round = $round; total = $total }
    if ($MaxRounds -gt 0 -and $round -ge $MaxRounds) { $outcome = 'max-rounds'; $finalExit = 4; Log "达到 MaxRounds=$MaxRounds，退出"; break }
    Log "第 $round 轮 $AttemptsPerRound 次全部失败，冷却 $([math]::Round($CooldownSeconds/60,1)) 分钟..."
    $ok = Wait-WithCountdown $CooldownSeconds '冷却'
    if (-not $ok) { $outcome = 'deadline'; $finalExit = 3; break }
    Log '冷却结束。'
  }
}

$script:State.phase = 'done'
$script:State.exitCode = $finalExit
$script:State.outcome = $outcome
$script:State.ended = (Get-Date).ToString('o')
$script:State.durationSec = [int]((Get-Date) - $script:StartedAt).TotalSeconds
SaveStatus
Emit 'run_end' @{ outcome = $outcome; exitCode = $finalExit; rounds = $round; attempts = $total; smacCount = $smac; durationSec = $script:State.durationSec }
$summary = [ordered]@{
  ts = (Get-Date).ToString('o'); label = $Label; model = $Model; effort = $Effort; workdir = $Workdir
  outcome = $outcome; exitCode = $finalExit; rounds = $round; attempts = $total; smacCount = $smac
  durationSec = $script:State.durationSec; logDir = $script:RunDir
}
($summary | ConvertTo-Json -Compress) | Add-Content -LiteralPath $script:StatsPath -Encoding utf8
Log "结束：outcome=$outcome exit=$finalExit rounds=$round attempts=$total smac=$smac duration=$($script:State.durationSec)s"
exit $finalExit



