#Requires -Version 7.0
# 升级回归：resume-on-smac / 单次超时 / stale run 修复
$ErrorActionPreference = 'Stop'
# 测试运行时不要拉起桌面仪表盘
$env:CSG_NO_DASH = '1'
$ProductRoot = Split-Path -Parent $PSScriptRoot
$Launcher = Join-Path $ProductRoot 'csg.ps1'
$Fake = Join-Path $PSScriptRoot 'fake-codex.ps1'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Evidence = Join-Path $PSScriptRoot "evidence\upgrade-$Stamp"
New-Item -ItemType Directory -Force -Path $Evidence | Out-Null
$State = Join-Path $Evidence 'state'
New-Item -ItemType Directory -Force -Path $State | Out-Null
$results = @()

function Invoke-Csg([string[]]$Arguments, [int]$TimeoutSec = 120) {
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = (Get-Command pwsh).Source
  foreach ($a in @('-NoProfile', '-File', $Launcher) + $Arguments) { $psi.ArgumentList.Add([string]$a) }
  $psi.WorkingDirectory = $ProductRoot
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.RedirectStandardInput = $true
  $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
  $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
  $p = [Diagnostics.Process]::new(); $p.StartInfo = $psi
  $null = $p.Start(); $p.StandardInput.Close()
  $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill($true) } catch {}; $p.WaitForExit(5000) | Out-Null }
  return [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $outTask.GetAwaiter().GetResult(); Err = $errTask.GetAwaiter().GetResult() }
}

function Latest-RunDir([string]$DataDir) {
  Get-ChildItem -LiteralPath (Join-Path $DataDir 'runs') -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Last-Stat([string]$DataDir) {
  $f = Join-Path $DataDir 'stats.jsonl'
  if (-not (Test-Path -LiteralPath $f)) { return $null }
  $lines = @(Get-Content -LiteralPath $f | Where-Object { $_.Trim() })
  if (-not $lines) { return $null }
  return ($lines[-1] | ConvertFrom-Json)
}

function Add-Result([string]$Name, [bool]$Pass, [string]$Detail) {
  $script:results += [pscustomobject]@{ name = $Name; pass = $Pass; detail = $Detail }
  Write-Host ("[{0}] {1} - {2}" -f $(if ($Pass) { 'PASS' } else { 'FAIL' }), $Name, $Detail)
}

# ---------- O: mid-run SMAC -> resume ----------
try {
  $dir = Join-Path $State 'resume'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $argsFile = Join-Path $dir 'args.log'; $promptDump = Join-Path $dir 'prompt.txt'
  $env:CSG_DATA_DIR = $dir
  $env:CSG_FAKE_MODE = 'midrun-smac'
  $env:CSG_FAKE_STATE = Join-Path $dir 'count.txt'
  $env:CSG_FAKE_ARGS = $argsFile
  $env:CSG_FAKE_DUMP_PROMPT = $promptDump
  $r = Invoke-Csg @('run', 'do half the work', '--codex-cmd', $Fake, '--resume-on-smac', '--attempts-per-round', '3', '--cooldown-seconds', '0', '--backoff-base-seconds', '0')
  $stat = Last-Stat $dir
  $argLines = if (Test-Path -LiteralPath $argsFile) { @(Get-Content -LiteralPath $argsFile) } else { @() }
  $second = if ($argLines.Count -ge 2) { $argLines[1] } else { '' }
  $prompt = if (Test-Path -LiteralPath $promptDump) { Get-Content -LiteralPath $promptDump -Raw } else { '' }
  $ok = ($r.ExitCode -eq 0) -and ($stat.totalAttempts -eq 2) -and ($second -match 'resume') -and ($second -match '11111111-2222-3333-4444-555555555555') -and ($prompt -match '继续')
  Add-Result 'O mid-run SMAC 续跑' $ok ("exit=$($r.ExitCode) attempts=$($stat.totalAttempts) resumed=$([bool]($second -match 'resume')) promptHasContinue=$([bool]($prompt -match '继续'))")
} catch { Add-Result 'O mid-run SMAC 续跑' $false $_.Exception.Message }

# ---------- P: 单次 attempt 超时 ----------
try {
  $dir = Join-Path $State 'timeout'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $env:CSG_DATA_DIR = $dir
  $env:CSG_FAKE_MODE = 'timeout'
  $env:CSG_FAKE_STATE = Join-Path $dir 'count.txt'
  Remove-Item Env:CSG_FAKE_ARGS -ErrorAction SilentlyContinue
  Remove-Item Env:CSG_FAKE_DUMP_PROMPT -ErrorAction SilentlyContinue
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $r = Invoke-Csg @('run', 'will hang', '--codex-cmd', $Fake, '--attempt-timeout-minutes', '0.05', '--attempts-per-round', '2', '--cooldown-seconds', '0', '--backoff-base-seconds', '0')
  $sw.Stop()
  $stat = Last-Stat $dir
  $runDir = Latest-RunDir $dir
  $events = if ($runDir) { Get-Content -LiteralPath (Join-Path $runDir.FullName 'events.jsonl') -ErrorAction SilentlyContinue } else { @() }
  $timeouts = @($events | Where-Object { $_ -match '"attempt-timeout"' }).Count
  $ok = ($r.ExitCode -eq 2) -and ($stat.totalAttempts -eq 2) -and ($timeouts -eq 2) -and ($sw.Elapsed.TotalSeconds -lt 60)
  Add-Result 'P 单次超时' $ok ("exit=$($r.ExitCode) attempts=$($stat.totalAttempts) timeoutEvents=$timeouts sec=$([int]$sw.Elapsed.TotalSeconds)")
} catch { Add-Result 'P 单次超时' $false $_.Exception.Message }

# ---------- Q: stale run 修复 ----------
try {
  $dir = Join-Path $State 'repair'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $rd = Join-Path $dir 'runs\20260101-000000-dead'; New-Item -ItemType Directory -Force -Path $rd | Out-Null
  $status = [ordered]@{ runId = '20260101-000000-dead'; dir = $rd; model = 'gpt-6-astra'; effort = 'ultra'; workDir = $ProductRoot;
    attemptsPerRound = 100; cooldownSeconds = 1800; state = 'running'; round = 1; attemptInRound = 2; totalAttempts = 3; smacCount = 1;
    pid = 999999; startedAt = (Get-Date).AddMinutes(-10).ToString('o'); updatedAt = (Get-Date).AddMinutes(-9).ToString('o') }
  $status | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $rd 'status.json') -Encoding utf8
  $env:CSG_DATA_DIR = $dir
  $r = Invoke-Csg @('repair')
  $after = Get-Content -LiteralPath (Join-Path $rd 'status.json') -Raw | ConvertFrom-Json
  $stat = Last-Stat $dir
  $ok = ($r.ExitCode -eq 0) -and ($after.state -eq 'interrupted') -and ($after.exitCode -eq 130) -and ($stat -and $stat.runId -eq '20260101-000000-dead' -and -not $stat.success)
  Add-Result 'Q stale run 修复' $ok ("exit=$($r.ExitCode) state=$($after.state) exitCode=$($after.exitCode) statRun=$($stat.runId)")
} catch { Add-Result 'Q stale run 修复' $false $_.Exception.Message }

# ---------- R: PID 被复用时的 stale 识别 ----------
try {
  $dir = Join-Path $State 'pidreuse'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $rd = Join-Path $dir 'runs\20260101-000001-pidreuse'; New-Item -ItemType Directory -Force -Path $rd | Out-Null
  $status = [ordered]@{ runId = '20260101-000001-pidreuse'; dir = $rd; model = 'gpt-6-astra'; effort = 'ultra'; workDir = $ProductRoot;
    attemptsPerRound = 100; cooldownSeconds = 1800; state = 'running'; round = 1; attemptInRound = 1; totalAttempts = 1; smacCount = 0;
    pid = $PID; startedAt = (Get-Date).AddHours(-1).ToString('o'); updatedAt = (Get-Date).AddHours(-1).ToString('o') }
  $status | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $rd 'status.json') -Encoding utf8
  $env:CSG_DATA_DIR = $dir
  $r = Invoke-Csg @('repair')
  $after = Get-Content -LiteralPath (Join-Path $rd 'status.json') -Raw | ConvertFrom-Json
  $ok = ($r.ExitCode -eq 0) -and ($after.state -eq 'interrupted')
  Add-Result 'R PID复用 stale 识别' $ok ("exit=$($r.ExitCode) state=$($after.state)")
} catch { Add-Result 'R PID复用 stale 识别' $false $_.Exception.Message }

# ---------- S: 活跃 owner 的 run 不得被 repair 误杀 ----------
try {
  $dir = Join-Path $State 'owner'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $rd = Join-Path $dir 'runs\20260101-000002-owner'; New-Item -ItemType Directory -Force -Path $rd | Out-Null
  $status = [ordered]@{ runId = '20260101-000002-owner'; dir = $rd; model = 'gpt-6-astra'; effort = 'ultra'; workDir = $ProductRoot;
    attemptsPerRound = 100; cooldownSeconds = 1800; state = 'running'; round = 1; attemptInRound = 2; totalAttempts = 2; smacCount = 1;
    pid = $null; ownerPid = $PID; startedAt = (Get-Date).AddMinutes(-30).ToString('o'); updatedAt = (Get-Date).AddMinutes(-10).ToString('o') }
  $status | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $rd 'status.json') -Encoding utf8
  $env:CSG_DATA_DIR = $dir
  $r = Invoke-Csg @('repair')
  $after = Get-Content -LiteralPath (Join-Path $rd 'status.json') -Raw | ConvertFrom-Json
  $ok = ($r.ExitCode -eq 0) -and ($after.state -eq 'running')
  Add-Result 'S 活跃 owner 不被误杀' $ok ("exit=$($r.ExitCode) state=$($after.state)")
} catch { Add-Result 'S 活跃 owner 不被误杀' $false $_.Exception.Message }

# ---------- 收尾 ----------
$summary = [ordered]@{ generatedAt = (Get-Date).ToString('o'); passed = @($results | Where-Object pass).Count; total = $results.Count; tests = @($results) }
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Evidence 'summary.json') -Encoding utf8
$md = @('# CSG 升级回归测试', '', ("通过：{0} / {1}" -f $summary.passed, $summary.total), '')
foreach ($t in $results) { $md += ("- [{0}] {1}：{2}" -f $(if ($t.pass) { 'x' } else { ' ' }), $t.name, $t.detail) }
$md | Set-Content -LiteralPath (Join-Path $Evidence 'summary.md') -Encoding utf8
if ($summary.passed -ne $summary.total) { exit 1 } else { exit 0 }
