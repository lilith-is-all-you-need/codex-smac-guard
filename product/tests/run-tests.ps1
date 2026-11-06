#Requires -Version 7.0
[CmdletBinding()]
param(
  [switch]$KeepState,
  [string]$EvidenceDir
)

$ErrorActionPreference = 'Stop'
# 测试运行时不要拉起桌面仪表盘
$env:CSG_NO_DASH = '1'
$ProductRoot = Split-Path -Parent $PSScriptRoot
$Fake = Join-Path $PSScriptRoot 'fake-codex.ps1'
$Launcher = Join-Path $ProductRoot 'csg.ps1'
if (-not (Test-Path -LiteralPath $Launcher)) {
  throw "找不到 product/csg.ps1（核心 launcher 尚未生成）"
}
$Evidence = if ($EvidenceDir) { $EvidenceDir } else { Join-Path $ProductRoot 'evidence' }
New-Item -ItemType Directory -Force -Path $Evidence | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$StateRoot = Join-Path $Evidence ("test-state-" + $Stamp)
New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
$env:CSG_HOME = $StateRoot
$env:CSG_DATA_DIR = $StateRoot

function Invoke-Csg {
  param(
    [Parameter(Mandatory)][string[]]$CliArgs,
    [hashtable]$Env = @{},
    [int]$TimeoutSeconds = 120
  )
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = (Get-Command pwsh).Source
  $psi.WorkingDirectory = $ProductRoot
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  foreach ($a in @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Launcher) + $CliArgs) {
    [void]$psi.ArgumentList.Add([string]$a)
  }
  $psi.Environment['CSG_HOME'] = $StateRoot
  $psi.Environment['CSG_DATA_DIR'] = $StateRoot
  foreach ($k in $Env.Keys) { $psi.Environment[[string]$k] = [string]$Env[$k] }
  $p = [Diagnostics.Process]::new(); $p.StartInfo = $psi
  $null = $p.Start()
  $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
    try { $p.Kill($true) } catch {}
    return [pscustomobject]@{ ExitCode = 124; StdOut = $outTask.Result; StdErr = $errTask.Result; TimedOut = $true }
  }
  return [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $outTask.Result; StdErr = $errTask.Result; TimedOut = $false }
}

function New-FakeEnv {
  param([string]$Mode, [int]$SmacCount = 0, [string]$Name, [string]$ExpectedHash)
  $state = Join-Path $StateRoot ("fake-" + $Name + '.count')
  Remove-Item -LiteralPath $state -Force -ErrorAction SilentlyContinue
  $h = @{
    CSG_FAKE_MODE = $Mode; CSG_FAKE_SMAC_COUNT = $SmacCount
    CSG_FAKE_STATE = $state; CSG_FAKE_DELAY_MS = 0
  }
  if ($ExpectedHash) { $h.CSG_FAKE_EXPECT_HASH = $ExpectedHash }
  return $h
}

function Add-Evidence([string]$name, $result) {
  $safe = $name -replace '[^A-Za-z0-9_-]', '_'
  $txt = @("exit=$($result.ExitCode) timedOut=$($result.TimedOut)", '--- stdout ---', $result.StdOut, '--- stderr ---', $result.StdErr) -join "`r`n"
  Set-Content -LiteralPath (Join-Path $Evidence ("$safe.txt")) -Value $txt -Encoding utf8
}

function Get-StatsLines {
  $candidates = @(
    (Join-Path $StateRoot 'stats.jsonl'),
    (Join-Path $StateRoot 'runs\stats.jsonl'),
    (Join-Path $ProductRoot 'runs\stats.jsonl'),
    (Join-Path $ProductRoot '.csg\stats.jsonl')
  )
  foreach ($p in $candidates) {
    if (Test-Path -LiteralPath $p) {
      foreach ($line in (Get-Content -LiteralPath $p -ErrorAction SilentlyContinue)) {
        if ($line.Trim()) { try { $line | ConvertFrom-Json } catch {} }
      }
      return
    }
  }
}

$results = [System.Collections.Generic.List[object]]::new()
function Assert-Test([string]$Name, [bool]$Pass, [string]$Detail) {
  $row = [ordered]@{ name = $Name; pass = $Pass; detail = $Detail }
  $results.Add([pscustomobject]$row)
  $mark = if ($Pass) { 'PASS' } else { 'FAIL' }
  $color = if ($Pass) { 'Green' } else { 'Red' }
  Write-Host ("[{0}] {1} - {2}" -f $mark, $Name, $Detail) -ForegroundColor $color
}

# 1) Three SMAC responses then success.
$e = New-FakeEnv -Mode 'smac-then-success' -SmacCount 3 -Name 't1'
$r1 = Invoke-Csg @('run','SMAC test 你好', '--codex-cmd',$Fake,'--attempts-per-round','100','--cooldown-seconds','0','--backoff-base-seconds','0','--max-rounds','1') -Env $e
Add-Evidence '01-smac-then-success' $r1
$count1 = 0; $smac1 = 0
$lines = @(Get-StatsLines); if ($lines) { $x = $lines[-1]; $count1 = [int]($x.attempts ?? $x.totalAttempts ?? 0); $smac1 = [int]($x.smacCount ?? $x.smac ?? 0) }
Assert-Test '3 次 SMAC 后成功' ($r1.ExitCode -eq 0 -and $count1 -eq 4 -and $smac1 -eq 3) ("exit=$($r1.ExitCode), attempts=$count1, smac=$smac1")

# 2) Round exhaustion then second round (7 SMAC, success on attempt 8).
$e = New-FakeEnv -Mode 'smac-then-success' -SmacCount 7 -Name 't2'
$r2 = Invoke-Csg @('run','round boundary test','--codex-cmd',$Fake,'--attempts-per-round','3','--cooldown-seconds','1','--backoff-base-seconds','0','--max-rounds','3') -Env $e -TimeoutSeconds 60
Add-Evidence '02-round-boundary' $r2
$count2 = 0; $rounds2 = 0
$lines = @(Get-StatsLines); if ($lines) { $x = $lines[-1]; $count2 = [int]($x.attempts ?? $x.totalAttempts ?? 0); $rounds2 = [int]($x.rounds ?? 0) }
Assert-Test '一轮耗尽后跨轮成功' ($r2.ExitCode -eq 0 -and $count2 -ge 8 -and $rounds2 -ge 2) ("exit=$($r2.ExitCode), attempts=$count2, rounds=$rounds2")

# 3) Non-capacity error stops immediately with exit 2 and is visible in status.
$e = New-FakeEnv -Mode 'non-capacity' -Name 't3'
$r3 = Invoke-Csg @('run','auth failure test','--codex-cmd',$Fake,'--attempts-per-round','3','--cooldown-seconds','0','--backoff-base-seconds','0') -Env $e
Add-Evidence '03-non-capacity' $r3
$status = Invoke-Csg @('status') -Env @{}
Add-Evidence '03-status' $status
$statusText = $status.StdOut + "`n" + $status.StdErr
Assert-Test '非容量错误立即停止' ($r3.ExitCode -eq 2 -and $statusText -match '(?i)authentication failed') ("exit=$($r3.ExitCode), statusContainsError=$($statusText -match '(?i)authentication failed')")

# 4) Deadline in the past exits 3 without invoking fake codex.
$e = New-FakeEnv -Mode 'smac-then-success' -SmacCount 0 -Name 't4'
$r4 = Invoke-Csg @('run','deadline test','--codex-cmd',$Fake,'--deadline','2000-01-01T00:00:00Z') -Env $e
Add-Evidence '04-deadline' $r4
Assert-Test '过期截止时间' ($r4.ExitCode -eq 3) ("exit=$($r4.ExitCode)")

# 5) Prompt with CJK, quotes, and newlines survives stdin intact.
$rocket = [char]::ConvertFromUtf32(0x1F680)
$prompt5 = "第一行：中文『引号』`r`n第二行 `"quoted`" / $rocket"
$sha = [Security.Cryptography.SHA256]::Create(); try { $hash5 = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($prompt5)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
$e = New-FakeEnv -Mode 'hash' -Name 't5' -ExpectedHash $hash5
$r5 = Invoke-Csg @('run',$prompt5,'--codex-cmd',$Fake,'--attempts-per-round','1','--cooldown-seconds','0','--backoff-base-seconds','0') -Env $e
Add-Evidence '05-prompt-hash' $r5
Assert-Test '中文引号换行 stdin 完整' ($r5.ExitCode -eq 0 -and ($r5.StdOut + $r5.StdErr) -notmatch 'PROMPT_HASH_MISMATCH') ("exit=$($r5.ExitCode)")

# 6) status/stats commands are callable and expose completed counters.
$r6s = Invoke-Csg @('status')
$r6t = Invoke-Csg @('stats')
Add-Evidence '06-status' $r6s; Add-Evidence '06-stats' $r6t
$statsText = $r6t.StdOut + "`n" + $r6t.StdErr
$statusText2 = $r6s.StdOut + "`n" + $r6s.StdErr
Assert-Test 'status/stats 输出计数' ($r6s.ExitCode -eq 0 -and $r6t.ExitCode -eq 0 -and $statsText -match '(?i)(attempt|SMAC|总尝试)' -and $statusText2 -match '(?i)(run|轮|attempt|完成)') ("statusExit=$($r6s.ExitCode), statsExit=$($r6t.ExitCode)")

$summary = [ordered]@{ generatedAt = (Get-Date).ToString('o'); stateRoot = $StateRoot; tests = @($results); passed = @($results | Where-Object pass).Count; failed = @($results | Where-Object { -not $_.pass }).Count }
$summaryPath = Join-Path $Evidence 'test-summary.json'
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
$md = @('# CSG 离线测试证据', '', "生成时间：$($summary.generatedAt)", "通过：$($summary.passed) / $($results.Count)", '')
foreach ($t in $results) { $md += "- [$([string]::new($(if ($t.pass) {'x'} else {' '})))] $($t.name)：$($t.detail)" }
Set-Content -LiteralPath (Join-Path $Evidence 'test-summary.md') -Value ($md -join "`r`n") -Encoding utf8
if (-not $KeepState) { Remove-Item -LiteralPath $StateRoot -Recurse -Force -ErrorAction SilentlyContinue }
if ($summary.failed -gt 0) { exit 1 } else { exit 0 }

