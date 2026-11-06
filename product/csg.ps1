[CmdletBinding()]
param(
  [Parameter(Position=0)] [string]$Command,
  [Parameter(ValueFromRemainingArguments=$true)] [string[]]$Remaining
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:DataBase = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $env:USERPROFILE }
$script:DataRoot = if ($env:CSG_DATA_DIR) { $env:CSG_DATA_DIR } else { Join-Path $script:DataBase 'csg' }
$script:ConfigPath = if ($env:CSG_CONFIG) { $env:CSG_CONFIG } elseif (Test-Path -LiteralPath (Join-Path $script:Root 'csg.config.json')) { Join-Path $script:Root 'csg.config.json' } else { Join-Path $script:DataRoot 'csg.config.json' }
$script:RunsRoot = Join-Path $script:DataRoot 'runs'
$script:StatsPath = Join-Path $script:DataRoot 'stats.jsonl'
$script:StopRequested = $false
$script:Version = '1.2.0'
$script:ScriptPath = $MyInvocation.MyCommand.Path
$script:DashCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$script:DashTrace = @{}
$script:DashRolloutIndex = @{}

function Write-JsonFile([string]$Path, $Object) {
  try {
    $dir = Split-Path -Parent $Path
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = "$Path.tmp.$PID"
    $Object | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
  } catch { Write-Warning "写入文件失败 $Path : $($_.Exception.Message)" }
}
function Read-JsonFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}
function Get-Config {
  $d = [ordered]@{ model='gpt-6-astra'; effort='ultra'; attemptsPerRound=100; cooldownSeconds=1800; deadlineMinutes=0; retainRuns=30; backoffBaseSeconds=1; backoffMaxSeconds=120; retryNonCapacity=$false; attemptTimeoutMinutes=0; resumeOnSmac=$false; autoDash=$true }
  $x = Read-JsonFile $script:ConfigPath
  if ($x) { foreach ($p in $x.PSObject.Properties) { $d[$p.Name] = $p.Value } }
  return [pscustomobject]$d
}
function Save-Config($cfg) { Write-JsonFile $script:ConfigPath $cfg }
function Get-Opt([string[]]$argv,[string]$Name,$Default=$null) {
  for ($i=0;$i -lt $argv.Count;$i++) { if ($argv[$i] -eq $Name) { if ($i+1 -lt $argv.Count) { return $argv[$i+1] }; return $true } }
  return $Default
}
function Has-Opt([string[]]$argv,[string]$Name) { return $argv -contains $Name }
function Get-PromptFromArgs([string[]]$argv) {
  $takes=@('--file','--cd','--model','--effort','--codex-cmd','--attempts-per-round','--round-attempts','--cooldown-seconds','--cooldown','--deadline','--max-rounds','--backoff-base-seconds','--backoff-max-seconds','--attempt-timeout-minutes')
  $out=@(); for($i=0;$i -lt $argv.Count;$i++){ $a=$argv[$i]; if($a -eq '--'){ if($i+1 -lt $argv.Count){$out += $argv[($i+1)..($argv.Count-1)]}; break }; if($a -in $takes){$i++;continue}; if($a -in @('--retry-non-capacity','--resume','--resume-on-smac')){continue}; $out+=$a }
  if($out.Count -gt 0){ return ($out -join ' ') }; return ''}
function Parse-Deadline($value) {
  if (-not $value) { return $null }
  try {
    if ($value -match '^\d+$') { return [DateTime]::Now.AddMinutes([double]$value) }
    return [DateTimeOffset]::Parse($value, [cultureinfo]::InvariantCulture).LocalDateTime
  } catch { throw "无法解析截止时间: $value（可用分钟数或 ISO 时间）" }
}
function New-RunId { return (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([Guid]::NewGuid().ToString('N').Substring(0,6)) }
function Append-Event([string]$Path,$Type,$Data) {
  try { [ordered]@{ts=(Get-Date).ToString('o'); type=$Type; data=$Data} | ConvertTo-Json -Compress -Depth 10 | Add-Content -LiteralPath $Path -Encoding UTF8 } catch { }
}
function Write-CappedText([string]$Path,[string]$Text,[int]$MaxChars=5242880) {
  try { if($null -eq $Text){$Text=''}; if($Text.Length -gt $MaxChars){$Text=$Text.Substring(0,$MaxChars)+"`n...[日志已截断，原始输出超过 5 MiB]"}; [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false)) } catch { }
}
function Limit-LogFile([string]$Path,[int]$MaxBytes=5242880) {
  # CopyToAsync below keeps logs live on disk.  Once the process exits, cap the
  # file by bytes without loading an unbounded transcript into PowerShell.
  try {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ([int64]$fi.Length -le [int64]$MaxBytes) { return $false }
    $marker = "`n...[日志已截断，原始输出超过 5 MiB]`n"
    $markerBytes = [Text.UTF8Encoding]::new($false).GetBytes($marker)
    $keep = [Math]::Max(1, $MaxBytes - $markerBytes.Length)
    $buf = New-Object byte[] $keep
    $fs = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try {
      $read = 0
      while ($read -lt $keep) {
        $n = $fs.Read($buf,$read,$keep-$read)
        if ($n -le 0) { break }
        $read += $n
      }
    } finally { $fs.Dispose() }
    # Do not leave a partial UTF-8 code point at the truncation boundary.
    $cut = $read
    while ($cut -gt 0 -and (($buf[$cut-1] -band 0xC0) -eq 0x80)) { $cut-- }
    if ($cut -gt 0) {
      $lead = $buf[$cut-1]
      if (($lead -band 0xE0) -eq 0xC0 -or ($lead -band 0xF0) -eq 0xE0 -or ($lead -band 0xF8) -eq 0xF0) { $cut-- }
    }
    $tmp = "$Path.tmp.$PID"
    $ofs = [IO.File]::Open($tmp,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { if ($cut -gt 0) { $ofs.Write($buf,0,$cut) }; $ofs.Write($markerBytes,0,$markerBytes.Length) } finally { $ofs.Dispose() }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    return $true
  } catch { return $false }
}
function Read-LogText([string]$Path) {
  try { return [IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$false)) } catch { return '' }
}
function Test-SmacText([string]$Text) {
  if ([string]::IsNullOrEmpty($Text)) { return $false }
  # Only a complete ERROR line is a SMAC signal.  This deliberately excludes
  # prose such as "disk at capacity" and quoted SMAC text in a successful task.
  return [bool]($Text -match '(?im)^\s*ERROR\s*:\s*Selected\s+model\s+is\s+at\s+capacity\.\s*Please\s+try\s+a\s+different\s+model\.\s*$')
}
function Redact-Sensitive([string]$Text) {
  if ($null -eq $Text) { return '' }
  $x = $Text
  $x = $x -replace '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+', 'Bearer [REDACTED]'
  $x = $x -replace '(?i)\b(sk-[A-Za-z0-9_-]{8,})\b', '[REDACTED]'
  $x = $x -replace '(?i)\b(api[_-]?key|token|secret|password)\s*[:=]\s*["'']?[^\s"'';]+', '$1=[REDACTED]'
  return $x
}
function Append-JsonLine([string]$Path,[string]$Line) {
  $dir = Split-Path -Parent $Path
  if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Line + "`n")
  for ($try = 0; $try -lt 40; $try++) {
    $fs = $null
    try {
      $fs = [IO.File]::Open($Path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::Write,[IO.FileShare]::Read)
      $fs.Seek(0,[IO.SeekOrigin]::End) | Out-Null
      $fs.Write($bytes,0,$bytes.Length)
      $fs.Flush($true)
      return $true
    } catch {
      Start-Sleep -Milliseconds 25
    } finally {
      if ($fs) { $fs.Dispose() }
    }
  }
  return $false
}
function Add-StatsRow($row) {
  try {
    $id = [string]$row.runId
    $existing = $null
    if ($id -and (Test-Path -LiteralPath $script:StatsPath)) {
      foreach ($l in (Get-Content -LiteralPath $script:StatsPath -Encoding UTF8)) {
        try { $o = ($l | ConvertFrom-Json); if ([string]$o.runId -eq $id) { $existing = $o } } catch { }
      }
    }
    if ($existing -and -not ($row.success -and -not $existing.success)) { return $false }
  } catch { }
  try { [void](Append-JsonLine $script:StatsPath ($row | ConvertTo-Json -Compress)); return $true } catch { return $false }
}
function Save-Status($run) { $run.updatedAt=(Get-Date).ToString('o'); Write-JsonFile (Join-Path $run.dir 'status.json') $run }
function Format-Duration([double]$seconds) {
  if ($seconds -lt 0) { $seconds=0 }; $ts=[TimeSpan]::FromSeconds($seconds)
  if ($ts.TotalHours -ge 1) { return ('{0}h{1:00}m' -f [math]::Floor($ts.TotalHours),$ts.Minutes) }
  if ($ts.TotalMinutes -ge 1) { return ('{0}m{1:00}s' -f [math]::Floor($ts.TotalMinutes),$ts.Seconds) }
  return ('{0}s' -f [int]$ts.TotalSeconds)
}
function Resolve-Codex([string]$cmd) {
  if ($cmd) {
    if ([IO.Path]::IsPathRooted($cmd)) { return $cmd }
    try { $rp=Resolve-Path -LiteralPath $cmd -ErrorAction Stop; return $rp.Path } catch { return $cmd }
  }
  foreach ($n in @('codex.exe','codex.cmd','codex')) {
    try { $c=Get-Command $n -ErrorAction SilentlyContinue; if ($c) { return $c.Source } } catch { }
  }
  $known=Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\b6c7fc9497179c98\codex.exe'
  if (Test-Path -LiteralPath $known) { return $known }
  return 'codex'
}
function Resolve-WorkDirectory([string]$Path) {
  try {
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if (-not $item.PSIsContainer) { throw "路径不是目录" }
    return $item.FullName
  } catch {
    throw "工作目录不存在或不可用: $Path（请检查 --cd 路径）"
  }
}
function Invoke-CodexAttempt($run,[int]$round,[int]$attempt,[string]$codexCmd,[string]$ResumeSession) {
  $adir=Join-Path $run.dir ('attempt-{0:000}-{1:000}' -f $round,$attempt)
  New-Item -ItemType Directory -Force -Path $adir | Out-Null
  $stdoutPath=Join-Path $adir 'stdout.log'; $stderrPath=Join-Path $adir 'stderr.log'; $lastPath=Join-Path $adir 'last-message.md'
  $psi=[Diagnostics.ProcessStartInfo]::new(); $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; $psi.RedirectStandardInput=$true; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.StandardInputEncoding=[Text.UTF8Encoding]::new($false); $psi.StandardOutputEncoding=[Text.UTF8Encoding]::new($false); $psi.StandardErrorEncoding=[Text.UTF8Encoding]::new($false); $psi.WorkingDirectory=$run.workDir
  try { $psi.StandardInputEncoding=[Text.UTF8Encoding]::new($false); $psi.StandardOutputEncoding=[Text.UTF8Encoding]::new($false); $psi.StandardErrorEncoding=[Text.UTF8Encoding]::new($false) } catch { }
  $ext=[IO.Path]::GetExtension($codexCmd).ToLowerInvariant()
  if ($ext -eq '.ps1') { $psi.FileName='pwsh'; [void]$psi.ArgumentList.Add('-NoProfile'); [void]$psi.ArgumentList.Add('-ExecutionPolicy'); [void]$psi.ArgumentList.Add('Bypass'); [void]$psi.ArgumentList.Add('-File'); [void]$psi.ArgumentList.Add($codexCmd) }
  elseif ($ext -eq '.cmd' -or $ext -eq '.bat') { $psi.FileName=$env:ComSpec; [void]$psi.ArgumentList.Add('/d'); [void]$psi.ArgumentList.Add('/c'); [void]$psi.ArgumentList.Add($codexCmd) }
  else { $psi.FileName=$codexCmd }
  $resumeMode = -not [string]::IsNullOrWhiteSpace($ResumeSession)
  if ($resumeMode) {
    $argList = @('exec','resume',$ResumeSession,'--dangerously-bypass-approvals-and-sandbox','--skip-git-repo-check','-m',$run.model,'-c',('model_reasoning_effort="{0}"' -f $run.effort),'-o',$lastPath,'-')
  } else {
    $argList = @('exec','--skip-git-repo-check','-s','danger-full-access','-C',$run.workDir,'-m',$run.model,'-c',('model_reasoning_effort="{0}"' -f $run.effort),'--color','never','-o',$lastPath,'-')
  }
  foreach ($a in $argList) { [void]$psi.ArgumentList.Add([string]$a) }
  $p=[Diagnostics.Process]::new(); $p.StartInfo=$psi
  $out=''; $err=''; $code=2; $deadlineHit=$false; $timedOut=$false
  try {
    $null=$p.Start(); $run.pid=$p.Id; Save-Status $run
    $outTask=$p.StandardOutput.ReadToEndAsync(); $errTask=$p.StandardError.ReadToEndAsync()
    if ($resumeMode) { $prompt='继续执行未完成的任务。先检查工作区当前状态，不要重复已经完成的工作；如果任务已经完成，直接给出最终结论。' }
    else { $prompt=Get-Content -LiteralPath $run.promptPath -Raw -Encoding UTF8 }
    $promptBytes=[Text.UTF8Encoding]::new($false).GetBytes($prompt)
    $p.StandardInput.BaseStream.Write($promptBytes,0,$promptBytes.Length); $p.StandardInput.BaseStream.Flush(); $p.StandardInput.Close()
    $sw=[Diagnostics.Stopwatch]::StartNew(); $timeoutMin=[double]$run.attemptTimeoutMinutes
    while (-not $p.HasExited) {
      if ($script:StopRequested) { try{$p.Kill($true)}catch{}; break }
      if($run.deadline -and ([DateTime]::Now -ge [DateTime]::Parse($run.deadline))){$deadlineHit=$true;try{$p.Kill($true)}catch{};break}
      if($timeoutMin -gt 0 -and $sw.Elapsed.TotalMinutes -ge $timeoutMin){$timedOut=$true;try{$p.Kill($true)}catch{};break}
      Start-Sleep -Milliseconds 200
    }
    $p.WaitForExit()
    try { $out=$outTask.GetAwaiter().GetResult() } catch { $out='' }
    try { $err=$errTask.GetAwaiter().GetResult() } catch { $err='' }
    $code=if ($script:StopRequested) { 130 } elseif($deadlineHit) { 3 } elseif($timedOut) { 124 } else { $p.ExitCode }
  } catch { $err = if($err){$err+"`n"}else{''}; $err += $_.Exception.Message; $code=2 }
  finally { if($p){$p.Dispose()} }
  Write-CappedText $stdoutPath (Redact-Sensitive $out); Write-CappedText $stderrPath (Redact-Sensitive $err)
  if (Test-Path -LiteralPath $lastPath) { Write-CappedText $lastPath (Redact-Sensitive (Read-LogText $lastPath)) }
  if (-not (Test-Path -LiteralPath $lastPath)) { try { Set-Content -LiteralPath $lastPath -Value (Redact-Sensitive $out) -Encoding UTF8 } catch { } }
  try { Copy-Item -LiteralPath $lastPath -Destination (Join-Path $run.dir 'last-message.md') -Force -ErrorAction SilentlyContinue } catch { }
  $run.pid=$null; Save-Status $run
  $all=$out+"`n"+$err+"`n"+(Read-LogText $lastPath)
  $smac=($code -ne 0 -and (Test-SmacText $all))
  $sid=$null
  try { $m=[regex]::Match($all,'(?im)^\s*session id:\s*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'); if($m.Success){$sid=$m.Groups[1].Value} } catch {}
  $hadWork=$false
  try { $hadWork = [bool](($all -match '(?m)^(exec|apply_patch|web_search|shell)\s*$') -or ($all -match '(?i)succeeded in \d')) } catch {}
  return [pscustomobject]@{ exitCode=$code; smac=[bool]$smac; timedOut=[bool]$timedOut; sessionId=$sid; hadWork=$hadWork; stdout=$out; stderr=$err; attemptDir=$adir }
}
function Invoke-Run($run) {
  $cancelHandler = [ConsoleCancelEventHandler]{ param($s,$e); $e.Cancel=$true; $script:StopRequested=$true }
  [Console]::add_CancelKeyPress($cancelHandler)
  $started=[DateTime]::Parse($run.startedAt); $completed=$false; $reason=''; $exit=2
  try {
    while ($true) {
      if ($script:StopRequested) { $reason='用户中断';$exit=130;break }
      if ($run.deadline -and ([DateTime]::Now -ge [DateTime]::Parse($run.deadline))) { $reason='已到截止时间';$exit=3;break }
      $run.round=[int]$run.round+1; $run.attemptInRound=0; $run.state='running'; Save-Status $run
      for ($i=1;$i -le [int]$run.attemptsPerRound;$i++) {
        if ($script:StopRequested) { $reason='用户中断';$exit=130;break }
        if ($run.deadline -and ([DateTime]::Now -ge [DateTime]::Parse($run.deadline))) { $reason='已到截止时间';$exit=3;break }
        $run.attemptInRound=$i; $run.totalAttempts=[int]$run.totalAttempts+1; $run.currentAttempt=('attempt-{0:000}-{1:000}' -f $run.round,$i); Save-Status $run
        $res=Invoke-CodexAttempt $run $run.round $i $run.codexCmd $nextResume; $run.lastExitCode=$res.exitCode; $run.lastError=if($res.stderr.Trim()){Redact-Sensitive ($res.stderr.Trim().Substring(0,[Math]::Min(500,$res.stderr.Trim().Length)))}else{$null}
        if ($res.timedOut) {
          $run.timeoutCount=[int]$run.timeoutCount+1
          Append-Event (Join-Path $run.dir 'events.jsonl') 'attempt-timeout' @{round=$run.round;attempt=$i;minutes=[double]$run.attemptTimeoutMinutes}
          Write-Host ("[{0}] 第 {1} 轮 · 第 {2}/{3} 次 · 单次超时（{4} 分钟）· 累计超时 {5}" -f (Get-Date -Format HH:mm:ss),$run.round,$i,$run.attemptsPerRound,$run.attemptTimeoutMinutes,$run.timeoutCount) -ForegroundColor Red
          $run.lastError='单次 attempt 超时'
          $nextResume=$null
          if ([int]$run.timeoutCount -ge 2) { $reason='连续两次单次超时'; $exit=2; break }
        }
        elseif ($res.smac) { $run.smacCount=[int]$run.smacCount+1; Append-Event (Join-Path $run.dir 'events.jsonl') 'smac' @{round=$run.round;attempt=$i}; Write-Host ("[{0}] 第 {1} 轮 · 第 {2}/{3} 次 · 上次: SMAC · 累计 SMAC {4} · 已用 {5} · Ctrl+C 停止" -f (Get-Date -Format HH:mm:ss),$run.round,$i,$run.attemptsPerRound,$run.smacCount,(Format-Duration ((Get-Date)-$started).TotalSeconds)) -ForegroundColor Yellow
          if ([bool]$run.resumeOnSmac -and $res.sessionId -and $res.hadWork) { $nextResume=$res.sessionId; Append-Event (Join-Path $run.dir 'events.jsonl') 'resume-armed' @{session=$res.sessionId;round=$run.round;attempt=$i}; Write-Host ("    → 已记录会话 {0}，下次改用 resume 续跑" -f $res.sessionId.Substring(0,8)) -ForegroundColor DarkYellow }
          else { $nextResume=$null }
        }
        elseif ($res.exitCode -eq 0) { $completed=$true;$reason='成功';$exit=0;break }
        elseif ($res.exitCode -eq 3) { $reason='已到截止时间';$exit=3;break }
        elseif ($nextResume -and $res.exitCode -ne 130) { Append-Event (Join-Path $run.dir 'events.jsonl') 'resume-fallback' @{round=$run.round;attempt=$i;exitCode=$res.exitCode}; Write-Host ("    → resume 失败（exit={0}），下次回退为完整 prompt" -f $res.exitCode) -ForegroundColor DarkYellow; $nextResume=$null }
        elseif (-not [bool]$run.retryNonCapacity) { $reason=if($run.lastError){$run.lastError}else{"Codex 退出码 $($res.exitCode)"};$exit=2;break }
        else { $run.nonCapacityRetries=[int]$run.nonCapacityRetries+1 }
        Save-Status $run
        $delay=[Math]::Min([double]$run.backoffMaxSeconds,[double]$run.backoffBaseSeconds*[Math]::Pow(2,[Math]::Min(8,$i-1))); if($delay -gt 0){$j=[Math]::Round((Get-Random -Minimum 0 -Maximum ([int]([Math]::Max(1,$delay*.25)+1))),1);$delay+=$j;Start-Sleep -Milliseconds ([int]($delay*1000))}
      }
      if ($completed -or $reason -or $script:StopRequested) { break }
      if ($run.maxRounds -and [int]$run.round -ge [int]$run.maxRounds) { $reason='达到最大轮数';$exit=2;break }
      $run.state='cooling'; $run.cooldownRemainingSec=[int]$run.cooldownSeconds; Append-Event (Join-Path $run.dir 'events.jsonl') 'cooldown-start' @{round=$run.round;seconds=$run.cooldownSeconds}; Save-Status $run; $cool=[int]$run.cooldownSeconds; while($cool -gt 0){ if($script:StopRequested){$reason='用户中断';$exit=130;break}; if($run.deadline -and ([DateTime]::Now -ge [DateTime]::Parse($run.deadline))){$reason='已到截止时间';$exit=3;break}; $run.cooldownRemainingSec=$cool; Save-Status $run; Write-Host ("[{0}] 第 {1} 轮耗尽，冷却剩余 {2}s · Ctrl+C 停止" -f (Get-Date -Format HH:mm:ss),$run.round,$cool) -ForegroundColor DarkYellow; Start-Sleep -Seconds ([Math]::Min(1,$cool)); $cool-- }; $run.cooldownRemainingSec=0; Save-Status $run; if($reason){break}
    }
  } finally { [Console]::remove_CancelKeyPress($cancelHandler) }
  if ($completed) { $run.state='succeeded' } elseif($exit -eq 130){$run.state='interrupted'} elseif($exit -eq 3){$run.state='deadline'} else {$run.state='failed'}
  $reason=Redact-Sensitive $reason; $run.endedAt=(Get-Date).ToString('o');$run.reason=$reason;$run.exitCode=$exit;Save-Status $run; Append-Event (Join-Path $run.dir 'events.jsonl') 'finished' @{state=$run.state;exitCode=$exit;reason=$reason}
  try { $row = [ordered]@{runId=$run.runId;model=$run.model;startedAt=$run.startedAt;endedAt=$run.endedAt;totalAttempts=$run.totalAttempts;attempts=$run.totalAttempts;rounds=$run.round;smacCount=$run.smacCount;success=($exit -eq 0);firstSuccessAttempt=if($exit -eq 0){$run.totalAttempts}else{$null};durationSeconds=((Get-Date)-$started).TotalSeconds;reason=$reason}; [void](Add-StatsRow $row) } catch { }
  Write-Host ("结束：{0}，尝试 {1} 次，SMAC {2} 次，退出码 {3}" -f $run.state,$run.totalAttempts,$run.smacCount,$exit)
  return $exit
}
function Trim-Runs($retain) { try { $dirs=Get-ChildItem -LiteralPath $script:RunsRoot -Directory | Sort-Object LastWriteTime -Descending; if($dirs.Count -gt [int]$retain){$dirs | Select-Object -Skip ([int]$retain) | ForEach-Object {Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue}} } catch{} }
function Test-RunPidAlive($run) {
  if ($run.ownerPid) {
    try { Get-Process -Id ([int]$run.ownerPid) -ErrorAction Stop | Out-Null; return $true } catch { return $false }
  }
  if (-not $run.pid) { return $false }
  try {
    $proc = Get-Process -Id ([int]$run.pid) -ErrorAction Stop
    $startedAt = [DateTime]::Parse([string]$run.startedAt)
    if ($proc.StartTime -gt $startedAt.AddMinutes(15)) { return $false }
    return $true
  } catch { return $false }
}
function Repair-StaleRuns {
  if (-not (Test-Path -LiteralPath $script:RunsRoot)) { return 0 }
  $fixed = 0
  foreach ($d in (Get-ChildItem -LiteralPath $script:RunsRoot -Directory -ErrorAction SilentlyContinue)) {
    $sp = Join-Path $d.FullName 'status.json'
    if (-not (Test-Path -LiteralPath $sp)) { continue }
    $s = Read-JsonFile $sp
    if (-not $s) { continue }
    $h = @{}; foreach ($p in $s.PSObject.Properties) { $h[$p.Name] = $p.Value }
    if (@('running','cooling','starting') -notcontains [string]$h.state) { continue }
    $alive = Test-RunPidAlive $h
    if ($alive) { continue }
    $h.state = 'interrupted'
    $h.exitCode = 130
    $h.reason = '进程已退出（可能被强制终止），由 csg 自动修复'
    $h.endedAt = (Get-Date).ToString('o')
    $h.pid = $null
    Save-Status $h
    $s = $h
    $fixed++
    try {
      $startedAt = [DateTime]::Parse([string]$s.startedAt)
      $row = [ordered]@{ runId=$s.runId; model=$s.model; startedAt=$s.startedAt; endedAt=$s.endedAt; totalAttempts=$s.totalAttempts; attempts=$s.totalAttempts; rounds=$s.round; smacCount=$s.smacCount; success=$false; firstSuccessAttempt=$null; durationSeconds=((Get-Date)-$startedAt).TotalSeconds; reason=$s.reason }
      [void](Add-StatsRow $row)
    } catch { }
    Append-Event (Join-Path $d.FullName 'events.jsonl') 'stale-repaired' @{ state='interrupted' }
  }
  return $fixed
}
function Start-DashForRun($cfg, [string[]]$argv) {
  if ($env:CSG_NO_DASH) { return $null }
  if (Has-Opt $argv '--no-dash') { return $null }
  $auto = $true
  if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'autoDash')) { $auto = [bool]$cfg.autoDash }
  if (-not $auto) { return $null }
  $st = Start-Dash
  if ($st.running) { Write-Host ("仪表盘: 已拉起 (pid {0}) · 桌面右上角实时查看进度" -f $st.pid) -ForegroundColor DarkCyan }
  else { Write-Warning '仪表盘拉起失败（可能没有交互桌面）；可手动执行 csg dash，用 csg dash status 复查' }
  return $st
}
function Start-Run([string[]]$argv) {
  $cfg=Get-Config; $resume=Get-Opt $argv '--resume'
  $repaired = Repair-StaleRuns
  if ($repaired -gt 0) { Write-Host "已修复 $repaired 个被强制终止的 run（状态改为 interrupted）" -ForegroundColor DarkYellow };
  if ($resume) { $dir=Join-Path $script:RunsRoot $resume; $run=Read-JsonFile (Join-Path $dir 'status.json'); if(-not $run){throw "找不到 run: $resume"}; $run.dir=$dir; $run.promptPath=Join-Path $dir 'prompt.md'; try{$run|Add-Member -NotePropertyName ownerPid -NotePropertyValue $PID -Force}catch{}; $script:StopRequested=$false; Write-Host "恢复 run $resume"; [void](Start-DashForRun $cfg $argv); return (Invoke-Run $run) }
  $prompt=''; $file=Get-Opt $argv '--file'; if($file){$prompt=Get-Content -LiteralPath $file -Raw -Encoding UTF8}else{$prompt=Get-PromptFromArgs $argv}
  if ([string]::IsNullOrWhiteSpace($prompt)) { throw '任务文本为空：请使用 csg run "任务" 或 --file task.md' }
  $work=Get-Opt $argv '--cd' (Get-Location).Path; $model=Get-Opt $argv '--model' $cfg.model; $effort=Get-Opt $argv '--effort' $cfg.effort; $codex=Resolve-Codex (Get-Opt $argv '--codex-cmd'); $apr=[int](Get-Opt $argv '--attempts-per-round' (Get-Opt $argv '--round-attempts' $cfg.attemptsPerRound)); $cool=[int](Get-Opt $argv '--cooldown-seconds' (Get-Opt $argv '--cooldown' $cfg.cooldownSeconds)); $maxr=Get-Opt $argv '--max-rounds'; $deadline=Parse-Deadline (Get-Opt $argv '--deadline'); $bbRaw=Get-Opt $argv '--backoff-base-seconds'; if($null -eq $bbRaw -and $env:CSG_BACKOFF_BASE_SECONDS){$bbRaw=$env:CSG_BACKOFF_BASE_SECONDS}; if($null -eq $bbRaw){$bbRaw=$cfg.backoffBaseSeconds}; $bb=[double]$bbRaw; $bm=[double](Get-Opt $argv '--backoff-max-seconds' $cfg.backoffMaxSeconds); $toMin=[double](Get-Opt $argv '--attempt-timeout-minutes' $cfg.attemptTimeoutMinutes); $resumeOnSmac=([bool](Has-Opt $argv '--resume-on-smac') -or [bool]$cfg.resumeOnSmac); if(-not $deadline -and [double]$cfg.deadlineMinutes -gt 0){$deadline=(Get-Date).AddMinutes([double]$cfg.deadlineMinutes)}
  if ($apr -lt 1) { throw '每轮尝试次数必须大于 0' }
  if ($cool -lt 0) { throw '冷却秒数不能为负数' }
  $id=New-RunId;$dir=Join-Path $script:RunsRoot $id;New-Item -ItemType Directory -Force -Path $dir | Out-Null; $pp=Join-Path $dir 'prompt.md'; [IO.File]::WriteAllText($pp,$prompt,[Text.UTF8Encoding]::new($false))
  $deadlineText=if($deadline){$deadline.ToString('o')}else{$null}; $deadlineDisplay=if($deadline){$deadline.ToString('yyyy-MM-dd HH:mm:ss')}else{'无'}
  $run=[ordered]@{runId=$id;dir=$dir;promptPath=$pp;ownerPid=$PID;workDir=(Resolve-WorkDirectory $work);model=$model;effort=$effort;codexCmd=$codex;attemptsPerRound=$apr;cooldownSeconds=$cool;cooldownRemainingSec=0;backoffBaseSeconds=$bb;backoffMaxSeconds=$bm;attemptTimeoutMinutes=$toMin;resumeOnSmac=$resumeOnSmac;timeoutCount=0;retryNonCapacity=([bool](Has-Opt $argv '--retry-non-capacity') -or [bool]$cfg.retryNonCapacity);maxRounds=if($maxr){[int]$maxr}else{$null};deadline=$deadlineText;startedAt=(Get-Date).ToString('o');state='starting';round=0;attemptInRound=0;totalAttempts=0;smacCount=0;nonCapacityRetries=0;lastExitCode=$null;lastError=$null}
  Save-Status $run; Set-Content -LiteralPath (Join-Path $dir 'events.jsonl') -Value '' -Encoding UTF8; Write-Host "CSG · Codex SMAC Guard v$script:Version" -ForegroundColor Cyan; Write-Host ("模型: {0} · 工作目录: {1} · 每轮: {2} · 冷却: {3}s · 截止: {4} · 单次超时: {5} · SMAC续跑: {6}" -f $model,$run.workDir,$apr,$cool,$deadlineDisplay,$(if($toMin -gt 0){"$toMin 分钟"}else{'关'}),$(if($resumeOnSmac){'开'}else{'关'})); [void](Start-DashForRun $cfg $argv); $script:StopRequested=$false; $r=Invoke-Run $run; Trim-Runs $cfg.retainRuns; return $r
}
function Show-Status {
  New-Item -ItemType Directory -Force -Path $script:RunsRoot | Out-Null
  $all=@(); $bad=0
  foreach($d in (Get-ChildItem -LiteralPath $script:RunsRoot -Directory -ErrorAction SilentlyContinue)) {
    $sp=Join-Path $d.FullName 'status.json'; $s=Read-JsonFile $sp
    if ((Test-Path -LiteralPath $sp) -and $null -eq $s) { $bad++ }
    if($s){$all+=$s}
  }
  if ($bad -gt 0) { Write-Warning "已跳过 $bad 条损坏 status 记录。" }
  $now=Get-Date
  $active=@($all|Where-Object {
    $fresh=$false
    if($_.updatedAt){try{$fresh=(($now-[DateTime]::Parse([string]$_.updatedAt)).TotalMinutes -lt 5)}catch{$fresh=$false}}
    $live=$false
    if($_.state -eq 'running'){ $live = Test-RunPidAlive $_ }
    ($_.state -in @('cooling','starting') -and $fresh) -or $live
  })
  if($active){foreach($s in $active){Write-Host ("活跃 run {0}: 第 {1} 轮/第 {2} 次，状态 {3}，冷却剩余 {4}s，累计 SMAC {5}，最后错误: {6}" -f $s.runId,$s.round,$s.attemptInRound,$s.state,$s.cooldownRemainingSec,$s.smacCount,$s.lastError)}} else {Write-Host '当前没有活跃 run。'}
  $all|Sort-Object startedAt -Descending|Select-Object -First 10|ForEach-Object { $why = if($_.reason){$_.reason}elseif($_.lastError){$_.lastError}else{''}; if($why.Length -gt 60){$why=$why.Substring(0,60)+'…'}; $stale=''; if(@('running','cooling','starting') -contains [string]$_.state){ if(-not (Test-RunPidAlive $_)){$stale='（stale，可用 csg repair 修复）'} }; Write-Host ("{0}  {1}{6}  尝试:{2} SMAC:{3} 退出:{4} 最后错误:{5}" -f $_.runId,$_.state,$_.totalAttempts,$_.smacCount,$_.exitCode,$why,$stale) }
   $ds = Get-DashStatus
  if ($ds.running) { Write-Host ("仪表盘: 运行中 (pid {0})" -f $ds.pid) -ForegroundColor DarkCyan } else { Write-Host '仪表盘: 未启动（csg dash 拉起）' -ForegroundColor DarkGray }
}
function Show-Stats {
  $rows=@(); $bad=0; if(Test-Path -LiteralPath $script:StatsPath){foreach($l in (Get-Content -LiteralPath $script:StatsPath -Encoding UTF8)){try{$rows+=($l|ConvertFrom-Json)}catch{$bad++}}}; if($bad -gt 0){Write-Warning "已跳过 $bad 条损坏统计行。"}; if(-not $rows){Write-Host '暂无统计。';return}; $dedup=@{}; foreach($r in $rows){$dedup[[string]$r.runId]=$r}; $rows=@($dedup.Values|Sort-Object startedAt); $a=($rows|Measure-Object totalAttempts -Sum).Sum; $s=($rows|Measure-Object smacCount -Sum).Sum; $ok=@($rows|Where-Object success).Count; $intr=@($rows|Where-Object { -not $_.success -and ([string]$_.reason -match '中断|进程已退出|超时') }).Count; $fail=$rows.Count-$ok; $dur=($rows|Where-Object success|Measure-Object durationSeconds -Average).Average; $first=($rows|Where-Object success|Measure-Object firstSuccessAttempt -Average).Average; $durText=if($dur){Format-Duration $dur}else{'-'}; $firstText=if($first){('{0:N1} 次' -f $first)}else{'-'}; Write-Host ("总 run: {0} · 总尝试: {1} · SMAC: {2} · 成功率: {3:P1} · 未成功: {4}（其中中断/超时 {5}） · 成功平均耗时: {6} · 平均首次成功: {7}" -f $rows.Count,$a,$s,($ok/$rows.Count),$fail,$intr,$durText,$firstText); $rows|Group-Object model|ForEach-Object{Write-Host ("模型 {0}: {1} run, SMAC {2}" -f $_.Name,$_.Count,(($_.Group|Measure-Object smacCount -Sum).Sum))}; $rows|Group-Object { ([DateTime]$_.startedAt).ToString('yyyy-MM-dd') }|ForEach-Object{Write-Host ("日期 {0}: {1} run, SMAC {2}" -f $_.Name,$_.Count,(($_.Group|Measure-Object smacCount -Sum).Sum))}
}
function Doctor {
  Write-Host "CSG 版本: $script:Version（数据目录: $script:DataRoot）"
  $c=Resolve-Codex $null; Write-Host "Codex 路径: $c"; try{$v=& $c --version 2>&1 | Select-Object -First 1;Write-Host "版本: $v"}catch{Write-Host '版本: 无法读取'}; $cfg=Get-Config;Write-Host "默认模型: $($cfg.model)，推理档: $($cfg.effort)"; if(Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.codex\config.toml')){Write-Host '登录配置: 已找到 ~/.codex/config.toml'}else{Write-Host '登录配置: 未找到，请先运行 codex login'}
}
function Config-Command([string[]]$argv) { $op=$argv[0];$cfg=Get-Config; if($op -eq 'set'){if($argv.Count -lt 3){throw '用法: csg config set key value'};$k=$argv[1];$v=$argv[2];if($v -match '^(true|false)$'){$v=[bool]::Parse($v)}elseif($v -match '^\d+(\.\d+)?$'){$v=[double]$v};$cfg|Add-Member -NotePropertyName $k -NotePropertyValue $v -Force;Save-Config $cfg;Write-Host "已设置 $k=$v"}else{$cfg|ConvertTo-Json -Depth 5}}
function Install-Csg {
  $bin=Join-Path $env:USERPROFILE 'bin'; $rootState=Join-Path $script:Root 'install-state.json'; $p=[Environment]::GetEnvironmentVariable('Path','User')
  $old=Read-JsonFile $rootState; $original=if($old -and $old.originalUserPath -ne $null){[string]$old.originalUserPath}else{$p}
  $targets=@{ 'csg.ps1'=(Join-Path $script:Root 'csg.ps1'); 'csg.cmd'=(Join-Path $script:Root 'csg.cmd') }
  $backups=@{}; $changedPath=$false; $tmpFiles=@(); $installedDests=@()
  try {
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    foreach($name in $targets.Keys){$dst=Join-Path $bin $name; if(Test-Path -LiteralPath $dst){$bak="$dst.csg-backup.$PID"; Copy-Item -LiteralPath $dst -Destination $bak -Force; $backups[$dst]=$bak}; $tmp="$dst.csg-tmp.$PID"; Copy-Item -LiteralPath $targets[$name] -Destination $tmp -Force; $tmpFiles += $tmp}
    $state=[pscustomobject]@{bin=$bin;originalUserPath=$original;installedAt=(Get-Date).ToString('o')}
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $bin 'install-state.json.tmp') -Encoding UTF8
    foreach($tmp in $tmpFiles){$dst=$tmp -replace '\.csg-tmp\.\d+$',''; Move-Item -LiteralPath $tmp -Destination $dst -Force; $installedDests += $dst}
    Move-Item -LiteralPath (Join-Path $bin 'install-state.json.tmp') -Destination (Join-Path $bin 'install-state.json') -Force
    Write-JsonFile $rootState $state
    if(-not (($p -split ';') -contains $bin)){[Environment]::SetEnvironmentVariable('Path',(($p.TrimEnd(';')+';'+$bin).Trim(';')),'User');$changedPath=$true}
    foreach($bak in $backups.Values){Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue}
    $dataDir=$script:DataRoot;[IO.Directory]::CreateDirectory($dataDir)|Out-Null;$dataCfg=Join-Path $dataDir 'csg.config.json';if(-not(Test-Path -LiteralPath $dataCfg)){ $srcCfg=Join-Path $script:Root 'csg.config.json'; if(Test-Path -LiteralPath $srcCfg){Copy-Item -LiteralPath $srcCfg -Destination $dataCfg -Force}else{[pscustomobject]@{model='gpt-6-astra';effort='ultra';attemptsPerRound=100;cooldownSeconds=1800;deadlineMinutes=0;retainRuns=30;backoffBaseSeconds=1;backoffMaxSeconds=120;retryNonCapacity=$false;attemptTimeoutMinutes=0;resumeOnSmac=$false}|ConvertTo-Json|Set-Content -LiteralPath $dataCfg -Encoding UTF8} };Write-Host "已安装到 $bin；数据目录 $dataDir；请打开新终端后使用 csg"
  } catch {
    foreach($tmp in $tmpFiles){Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath (Join-Path $bin 'install-state.json.tmp') -Force -ErrorAction SilentlyContinue
    foreach($dst in $backups.Keys){try{Copy-Item -LiteralPath $backups[$dst] -Destination $dst -Force}catch{};Remove-Item -LiteralPath $backups[$dst] -Force -ErrorAction SilentlyContinue}
    foreach($dst in $installedDests){if(-not $backups.ContainsKey($dst)){Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue}}
    if($changedPath){[Environment]::SetEnvironmentVariable('Path',$p,'User')}
    throw "安装失败，已回滚：$($_.Exception.Message)"
  }
}
function Uninstall-Csg { $bin=Join-Path $env:USERPROFILE 'bin';$state=Read-JsonFile (Join-Path $script:Root 'install-state.json');Remove-Item -LiteralPath (Join-Path $bin 'csg.cmd') -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath (Join-Path $bin 'csg.ps1') -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath (Join-Path $bin 'install-state.json') -Force -ErrorAction SilentlyContinue;if($state -and $state.originalUserPath -ne $null){[Environment]::SetEnvironmentVariable('Path',[string]$state.originalUserPath,'User')}else{$p=[Environment]::GetEnvironmentVariable('Path','User');[Environment]::SetEnvironmentVariable('Path', (($p -split ';'|Where-Object{$_ -and $_ -ne $bin}) -join ';'),'User')};Remove-Item -LiteralPath (Join-Path $script:Root 'install-state.json') -Force -ErrorAction SilentlyContinue;Write-Host '已卸载 csg shim，并恢复安装前 PATH。'}

# ===================== 桌面仪表盘（只读旁路） =====================
# 数据全部来自既有产物：runs\<id>\status.json、events.jsonl、Codex rollout-*.jsonl。
# 仪表盘不写 run 数据，只在数据目录写一个 dash.json 记录自身 pid；单实例靠命名 Mutex。

function ConvertTo-DashLocalTime($v) {
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
function Read-DashJsonQuiet([string]$Path) {
  try {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
    if (-not $raw.Trim()) { return $null }
    return $raw | ConvertFrom-Json -ErrorAction Stop
  } catch { return $null }
}
function Test-DashProcessAlive($Id) {
  if (-not $Id) { return $false }
  try { return [bool](Get-Process -Id ([int]$Id) -ErrorAction Stop) } catch { return $false }
}
function Get-DashPidPath { return (Join-Path $script:DataRoot 'dash.json') }
function Get-DashStatus {
  $s = Read-DashJsonQuiet (Get-DashPidPath)
  if ($s -and (Test-DashProcessAlive $s.pid)) {
    return [pscustomobject]@{ running = $true; pid = [int]$s.pid; startedAt = $s.startedAt }
  }
  return [pscustomobject]@{ running = $false; pid = $null; startedAt = $null }
}
function Get-DashMutexName {
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$script:DataRoot)
    $hash = [Security.Cryptography.MD5]::Create().ComputeHash($bytes)
    return 'Local\csg-dash-' + ([Convert]::ToHexString($hash).Substring(0, 10))
  } catch { return 'Local\csg-dash' }
}

function Test-DashRunAlive($run) {
  if (Test-DashProcessAlive $run.pid)      { return $true }
  if (Test-DashProcessAlive $run.ownerPid) { return $true }
  return $false
}
function Get-DashRuns {
  $out = @()
  if (-not (Test-Path -LiteralPath $script:RunsRoot)) { return $out }
  foreach ($d in (Get-ChildItem -LiteralPath $script:RunsRoot -Directory -ErrorAction SilentlyContinue)) {
    $s = Read-DashJsonQuiet (Join-Path $d.FullName 'status.json')
    if (-not $s) { continue }
    $state = [string]$s.state
    if ($state -notin @('running', 'cooling', 'starting')) { continue }
    $fresh = $false
    if ($s.updatedAt) { $u = ConvertTo-DashLocalTime $s.updatedAt; if ($u) { $fresh = (((Get-Date) - $u).TotalMinutes -lt 5) } }
    $alive = Test-DashRunAlive $s
    if ($state -eq 'running' -and -not $alive) { continue }
    if ($state -ne 'running' -and -not $fresh) { continue }
    $s | Add-Member -NotePropertyName finished -NotePropertyValue $false -Force
    $out += $s
  }
  return @($out | Sort-Object { [string]$_.startedAt })
}
function Get-DashFinishedRuns([int]$Minutes = 15, [int]$Max = 2) {
  $out = @()
  if (-not (Test-Path -LiteralPath $script:RunsRoot)) { return $out }
  $cut = (Get-Date).AddMinutes(-$Minutes)
  foreach ($d in (Get-ChildItem -LiteralPath $script:RunsRoot -Directory -ErrorAction SilentlyContinue)) {
    $s = Read-DashJsonQuiet (Join-Path $d.FullName 'status.json')
    if (-not $s) { continue }
    if ([string]$s.state -notin @('succeeded', 'failed', 'interrupted', 'deadline')) { continue }
    $ended = ConvertTo-DashLocalTime $s.endedAt
    if (-not $ended -or $ended -lt $cut) { continue }
    $s | Add-Member -NotePropertyName finished -NotePropertyValue $true -Force
    $s | Add-Member -NotePropertyName endedLocal -NotePropertyValue $ended -Force
    $out += $s
  }
  return @($out | Sort-Object endedLocal -Descending | Select-Object -First $Max)
}

function Get-DashRolloutHeader([string]$Path) {
  $mtime = (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).LastWriteTimeUtc
  $c = $script:DashRolloutIndex[$Path]
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
        $info.ts = ConvertTo-DashLocalTime $o.payload.timestamp
        $info.ok = $true
      }
    } finally { $fs.Close() }
  } catch { }
  $script:DashRolloutIndex[$Path] = $info
  return $info
}
function Get-DashRecentRollouts {
  $dirs = @()
  foreach ($delta in 0, -1) {
    $d = (Get-Date).AddDays($delta)
    $p = Join-Path $script:DashCodexHome ('sessions\{0}\{1}\{2}' -f $d.ToString('yyyy'), $d.ToString('MM'), $d.ToString('dd'))
    if (Test-Path -LiteralPath $p) { $dirs += $p }
  }
  $files = @()
  foreach ($d in $dirs) { $files += Get-ChildItem -LiteralPath $d -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue }
  return $files
}
function Find-DashRollout($run) {
  if (-not $run.startedAt) { return $null }
  $start = ConvertTo-DashLocalTime $run.startedAt
  if (-not $start) { return $null }
  $start = $start.AddMinutes(-3)
  $best = $null
  foreach ($f in (Get-DashRecentRollouts)) {
    $h = Get-DashRolloutHeader $f.FullName
    if (-not $h.ok) { continue }
    if ($h.threadSource -ne 'user') { continue }
    if ($h.cwd -ne [string]$run.workDir) { continue }
    if (-not $h.ts -or $h.ts -lt $start) { continue }
    if (-not $best -or $h.ts -gt $best.ts) { $best = $h }
  }
  return $best
}
function Format-DashAgo([double]$seconds) {
  if ($seconds -lt 0) { return '0s' }
  if ($seconds -lt 60) { return ('{0:0}s' -f $seconds) }
  if ($seconds -lt 3600) { return ('{0:0}m{1:00}s' -f [Math]::Floor($seconds / 60), ([int]$seconds % 60)) }
  return ('{0}h{1:00}m' -f [Math]::Floor($seconds / 3600), [Math]::Floor(($seconds % 3600) / 60))
}
function Format-DashElapsed([double]$s) {
  if ($s -lt 0) { return '0:00:00' }
  $ts = [TimeSpan]::FromSeconds($s)
  return ('{0}:{1:00}:{2:00}' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
}
function Get-DashToolLabel($name, $payloadText) {
  $s = [string]$payloadText
  $label = [string]$name
  if (-not $s.Trim()) { return $label }
  if ($label -eq 'exec') {
    $m = [regex]::Match($s, 'cmd:\s*"((?:[^"\\]|\\.){1,160})"')
    if (-not $m.Success) { $m = [regex]::Match($s, "cmd:\s*'((?:[^'\\]|\\.){1,160})'") }
    if ($m.Success) { $label = 'exec: ' + $m.Groups[1].Value } else { $label = 'exec: ' + $s }
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
function Update-DashTrace($run) {
  $id = [string]$run.runId
  $t = $script:DashTrace[$id]
  if (-not $t) {
    $t = @{ path = $null; offset = 0; items = (New-Object System.Collections.ArrayList); tokens = $null; lastProgressAt = $null }
    $script:DashTrace[$id] = $t
  }
  if (-not $t.path -or -not (Test-Path -LiteralPath $t.path)) {
    $h = Find-DashRollout $run
    if ($h) { $t.path = $h.path; $t.offset = 0; $t.items.Clear(); $t.tokens = $null } else { return $t }
  }
  $fs = $null
  try { $fs = [IO.File]::Open($t.path, 'Open', 'Read', 'ReadWrite') } catch { return $t }
  try {
    $len = $fs.Length
    if ($len -lt $t.offset) { $t.offset = 0; $t.items.Clear() }
    $firstRead = ($t.offset -eq 0 -and $t.items.Count -eq 0)
    if ($firstRead -and $len -gt 524288) { $t.offset = $len - 524288 }
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
      $i = $complete.IndexOf("`n")
      $complete = if ($i -ge 0) { $complete.Substring($i + 1) } else { '' }
    }
    foreach ($line in ($complete -split "`n")) {
      if ($line.Length -lt 8 -or $line.Length -gt 262144) { continue }
      if ($line.IndexOf('"response_item"') -lt 0 -and $line.IndexOf('"token_usage_record"') -lt 0) { continue }
      $o = $null
      try { $o = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
      if (-not $o) { continue }
      if ($o.type -eq 'token_usage_record') { if ($o.payload.usage) { $t.tokens = $o.payload.usage }; continue }
      if ($o.type -ne 'response_item') { continue }
      $p = $o.payload
      $ts = ConvertTo-DashLocalTime $o.timestamp
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
          [void]$t.items.Add([pscustomobject]@{ kind = 'tool'; ts = $ts; text = (Get-DashToolLabel $p.name ([string]$p.input + [string]$p.arguments)) })
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
function Get-DashView($run) {
  $t = Update-DashTrace $run
  $now = Get-Date
  $start = ConvertTo-DashLocalTime $run.startedAt
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
  if ($t.tokens) { $tok = ('{0:N0}k↑ {1:N0}↓' -f ([double]$t.tokens.input_tokens / 1000), [double]$t.tokens.output_tokens) }
  $deadlineLeft = $null
  $dl = ConvertTo-DashLocalTime $run.deadline
  if ($dl) { $deadlineLeft = ($dl - $now).TotalSeconds }
  return [pscustomobject]@{
    run = $run; elapsed = $elapsed; message = $msg; think = $think; tool = $tool; tokens = $tok
    idleSeconds = if ($t.lastProgressAt) { ($now - $t.lastProgressAt).TotalSeconds } else { $null }
    deadlineLeft = $deadlineLeft; hasTrace = [bool]$t.path
  }
}
function Get-DashBadge($run) {
  switch ([string]$run.state) {
    'running'  { return @{ text = '运行中'; color = '#5fd75f' } }
    'cooling'  { return @{ text = ('冷却中 ' + [string]$run.cooldownRemainingSec + 's'); color = '#e0b040' } }
    'starting' { return @{ text = '启动中'; color = '#8ab4f8' } }
    default    { return @{ text = [string]$run.state; color = '#9aa0aa' } }
  }
}
function Show-DashOnce([int]$MaxRuns = 4) {
  $runs = @(Get-DashRuns | Select-Object -First $MaxRuns)
  Write-Host ('CSG 监视器  ·  ' + (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Cyan
  if ($runs.Count -eq 0) { Write-Host '当前没有活跃的 csg run' }
  foreach ($r in $runs) {
    $v = Get-DashView $r
    $badge = Get-DashBadge $r
    Write-Host ''
    Write-Host ('● ' + $r.runId) -ForegroundColor Cyan
    Write-Host ('  {0}  ·  {1}/{2}  ·  {3}' -f $badge.text, $r.model, $r.effort, (Format-DashElapsed $v.elapsed)) -ForegroundColor Green
    Write-Host ('  第 {0} 轮/第 {1} 次 · 累计 {2} 次 · SMAC {3}' -f $r.round, $r.attemptInRound, $r.totalAttempts, $r.smacCount)
    if ($v.deadlineLeft -ne $null) { Write-Host ('  截止剩 ' + (Format-DashAgo $v.deadlineLeft) + ' · ' + (Split-Path -Leaf ([string]$r.workDir))) -ForegroundColor DarkGray }
    if ($v.tool)    { Write-Host ('  ⏵ ' + $v.tool.text) -ForegroundColor Gray }
    if ($v.message) { Write-Host ('  💬 ' + ($v.message.text -replace '\s+', ' ')) -ForegroundColor DarkCyan }
    elseif (-not $v.hasTrace) { Write-Host '  （等待 Codex 会话流…）' -ForegroundColor DarkGray }
    $tail = @()
    if ($v.tokens) { $tail += $v.tokens }
    if ($v.idleSeconds -ne $null) { $tail += ('最新事件 ' + (Format-DashAgo $v.idleSeconds) + ' 前') }
    if ($tail.Count) { Write-Host ('  ' + ($tail -join ' · ')) -ForegroundColor DarkGray }
  }
  foreach ($f in (Get-DashFinishedRuns)) {
    $why = if ($f.reason) { [string]$f.reason } else { [string]$f.state }
    Write-Host ('○ {0}  {1} · attempts {2} · SMAC {3} · {4} 前' -f $f.runId, $f.state, $f.totalAttempts, $f.smacCount, (Format-DashAgo ((Get-Date) - $f.endedLocal).TotalSeconds)) -ForegroundColor DarkGray
  }
}

# --- 窗口 ---
function Get-DashElided([string]$text, $font, [int]$maxWidth) {
  if (-not $text) { return '' }
  if ([System.Windows.Forms.TextRenderer]::MeasureText($text, $font).Width -le $maxWidth) { return $text }
  $t = $text
  while ($t.Length -gt 4) {
    $t = $t.Substring(0, $t.Length - 2)
    if ([System.Windows.Forms.TextRenderer]::MeasureText($t + '…', $font).Width -le $maxWidth) { return $t + '…' }
  }
  return $t
}
function Add-DashLine($list, $text, $font, $color, [int]$indent, $runId, [int]$extra = 0) {
  [void]$list.Add([pscustomobject]@{ text = [string]$text; font = $font; color = $color; indent = $indent; runId = $runId; extra = $extra })
}
function New-DashTextLine($text, $font, $color, $indent, $runId, [switch]$Wrap, [int]$MaxLines = 2) {
  $out = New-Object System.Collections.ArrayList
  $avail = $script:DashWidth - ($script:DashPadX * 2) - $indent
  if (-not $Wrap) { Add-DashLine $out (Get-DashElided $text $font $avail) $font $color $indent $runId; return , $out }
  $s = [string]$text; $line = ''; $count = 0
  foreach ($ch in $s.ToCharArray()) {
    $try = $line + $ch
    if ([System.Windows.Forms.TextRenderer]::MeasureText($try, $font).Width -gt $avail -and $line.Length -gt 0) {
      $count++
      if ($count -ge $MaxLines) {
        Add-DashLine $out (Get-DashElided ($line + '…') $font $avail) $font $color $indent $runId
        return , $out
      }
      Add-DashLine $out $line $font $color $indent $runId
      $line = [string]$ch
    } else { $line = $try }
  }
  if ($line) { Add-DashLine $out $line $font $color $indent $runId }
  return , $out
}
function Convert-DashColor([string]$hex) {
  if ($hex -match '^#[0-9a-fA-F]{6}$') { return [Drawing.ColorTranslator]::FromHtml($hex) }
  return $script:DashColors.text
}
function Measure-DashLineHeight($font) { return [Math]::Max([int]$font.Height, 11) + 2 }
function Build-DashLayout($views, $finished) {
  $lines = New-Object System.Collections.ArrayList
  $cnt = if ($views) { $views.Count } else { 0 }
  $cntText = if ($cnt -gt 0) { ' · ' + $cnt + ' 个任务' } else { ' · 空闲' }
  Add-DashLine $lines ('CSG 监视器' + $cntText + ' · ' + (Get-Date -Format 'HH:mm:ss')) $script:DashFonts.title $script:DashColors.title 0 $null
  if ($cnt -eq 0) {
    Add-DashLine $lines '' $script:DashFonts.meta $script:DashColors.bg 0 $null 4
    Add-DashLine $lines '当前没有活跃的 csg run' $script:DashFonts.head $script:DashColors.dim 0 $null
    Add-DashLine $lines 'csg run 启动时自动拉起本窗口' $script:DashFonts.hint $script:DashColors.faint 0 $null
  }
  foreach ($v in $views) {
    $r = $v.run
    $badge = Get-DashBadge $r
    Add-DashLine $lines '' $script:DashFonts.meta $script:DashColors.bg 0 $null 6
    Add-DashLine $lines ('● ' + [string]$r.runId) $script:DashFonts.id $script:DashColors.id 0 ([string]$r.runId)
    Add-DashLine $lines ('{0}   {1}/{2}   {3}' -f $badge.text, $r.model, $r.effort, (Format-DashElapsed $v.elapsed)) $script:DashFonts.head (Convert-DashColor $badge.color) 14 ([string]$r.runId)
    $meta = ('第 {0} 轮/第 {1} 次 · 累计 {2} 次 · SMAC {3}' -f $r.round, $r.attemptInRound, $r.totalAttempts, $r.smacCount)
    $metaColor = if ([int]$r.smacCount -gt 0) { $script:DashColors.amber } else { $script:DashColors.dim }
    Add-DashLine $lines $meta $script:DashFonts.meta $metaColor 14 ([string]$r.runId)
    if ($v.deadlineLeft -ne $null) {
      $dl = if ($v.deadlineLeft -gt 0) { '截止剩 ' + (Format-DashAgo $v.deadlineLeft) } else { '已过截止' }
      Add-DashLine $lines ($dl + ' · ' + (Split-Path -Leaf ([string]$r.workDir))) $script:DashFonts.meta $script:DashColors.dim 14 ([string]$r.runId)
    } elseif ($r.workDir) {
      Add-DashLine $lines (Split-Path -Leaf ([string]$r.workDir)) $script:DashFonts.meta $script:DashColors.dim 14 ([string]$r.runId)
    }
    if ($v.tool) {
      foreach ($l in (New-DashTextLine ('⏵ ' + $v.tool.text) $script:DashFonts.mono $script:DashColors.text 14 ([string]$r.runId) -Wrap -MaxLines 1)) { [void]$lines.Add($l) }
    }
    if ($v.message) {
      foreach ($l in (New-DashTextLine ('» ' + ($v.message.text -replace '\s+', ' ')) $script:DashFonts.meta $script:DashColors.msg 14 ([string]$r.runId) -Wrap -MaxLines 2)) { [void]$lines.Add($l) }
    } elseif ($v.think) {
      foreach ($l in (New-DashTextLine ('» ' + ($v.think.text -replace '\s+', ' ')) $script:DashFonts.meta $script:DashColors.msg 14 ([string]$r.runId) -Wrap -MaxLines 2)) { [void]$lines.Add($l) }
    } elseif (-not $v.hasTrace) {
      Add-DashLine $lines '（等待 Codex 会话流…）' $script:DashFonts.meta $script:DashColors.faint 14 ([string]$r.runId)
    }
    $tail = @()
    if ($v.tokens) { $tail += $v.tokens }
    if ($v.idleSeconds -ne $null) { $tail += ('最新事件 ' + (Format-DashAgo $v.idleSeconds) + ' 前') }
    if ($tail.Count) { Add-DashLine $lines ($tail -join ' · ') $script:DashFonts.hint $script:DashColors.dim 14 ([string]$r.runId) }
  }
  if ($finished -and $finished.Count -gt 0) {
    Add-DashLine $lines '' $script:DashFonts.meta $script:DashColors.bg 0 $null 6
    foreach ($f in $finished) {
      $ago = Format-DashAgo ((Get-Date) - $f.endedLocal).TotalSeconds
      Add-DashLine $lines ('○ ' + $f.runId + '  ' + $f.state + ' · attempts ' + $f.totalAttempts + ' · SMAC ' + $f.smacCount + ' · ' + $ago + ' 前') $script:DashFonts.hint $script:DashColors.faint 0 ([string]$f.runId)
    }
  }
  Add-DashLine $lines '' $script:DashFonts.meta $script:DashColors.bg 0 $null 6
  Add-DashLine $lines '双击打开 run 目录 · 右键菜单 · 拖动移动' $script:DashFonts.hint $script:DashColors.faint 2 $null
  return , $lines
}

function Start-DashWindow {
  $oldEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $mutex = New-Object System.Threading.Mutex($false, (Get-DashMutexName))
    $acquired = $false
    try { $acquired = $mutex.WaitOne(0) } catch { $acquired = $true }
    if (-not $acquired) { return }   # 已有实例

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $script:DashPadX = 12; $script:DashPadY = 10; $script:DashWidth = 420
    $script:DashTrace = @{}
    $script:DashRolloutIndex = @{}
    $script:DashCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $script:DashFonts = @{
      title = New-Object Drawing.Font('Microsoft YaHei UI', [single]9, [Drawing.FontStyle]::Bold)
      id    = New-Object Drawing.Font('Consolas', [single]10, [Drawing.FontStyle]::Bold)
      head  = New-Object Drawing.Font('Microsoft YaHei UI', [single]9, [Drawing.FontStyle]::Regular)
      meta  = New-Object Drawing.Font('Microsoft YaHei UI', [single]8, [Drawing.FontStyle]::Regular)
      mono  = New-Object Drawing.Font('Consolas', [single]8.5, [Drawing.FontStyle]::Regular)
      hint  = New-Object Drawing.Font('Microsoft YaHei UI', [single]7.5, [Drawing.FontStyle]::Regular)
    }
    $script:DashColors = @{
      bg    = [Drawing.ColorTranslator]::FromHtml('#12141a'); edge = [Drawing.ColorTranslator]::FromHtml('#22262f')
      title = [Drawing.ColorTranslator]::FromHtml('#8ab4f8'); id = [Drawing.ColorTranslator]::FromHtml('#8ab4f8')
      green = [Drawing.ColorTranslator]::FromHtml('#5fd75f'); amber = [Drawing.ColorTranslator]::FromHtml('#e0b040')
      text  = [Drawing.ColorTranslator]::FromHtml('#d7dae2'); msg = [Drawing.ColorTranslator]::FromHtml('#b9c6ff')
      dim   = [Drawing.ColorTranslator]::FromHtml('#6b7280'); faint = [Drawing.ColorTranslator]::FromHtml('#4b5563')
    }

    $script:DashForm = New-Object System.Windows.Forms.Form
    $script:DashForm.Text = 'csg-dash'
    $script:DashForm.FormBorderStyle = 'None'
    $script:DashForm.StartPosition = 'Manual'
    $script:DashForm.ShowInTaskbar = $false
    $script:DashForm.BackColor = $script:DashColors.bg
    $script:DashForm.TopMost = $true
    $script:DashForm.ClientSize = New-Object Drawing.Size($script:DashWidth, 150)

    $script:DashPanel = New-Object System.Windows.Forms.Panel
    $script:DashPanel.Dock = 'Fill'
    $script:DashPanel.BackColor = $script:DashColors.bg
    $script:DashForm.Controls.Add($script:DashPanel)

    $null = $script:DashForm.Handle; $null = $script:DashPanel.Handle
    $scale = [Math]::Max(1.0, ($script:DashPanel.DeviceDpi / 96.0))
    $script:DashWidth = [int](420 * $scale); $script:DashPadX = [int](12 * $scale); $script:DashPadY = [int](10 * $scale)
    $script:DashForm.ClientSize = New-Object Drawing.Size($script:DashWidth, [int](150 * $scale))

    $script:DashPhys = New-Object System.Collections.ArrayList
    $script:DashLineMap = @()
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $script:DashForm.Location = New-Object Drawing.Point(($screen.Right - $script:DashWidth - 16), ($screen.Top + 16))

    $script:DashPanel.Add_Paint({
      param($s, $e)
      try {
        $g = $e.Graphics
        $g.Clear($script:DashColors.bg)
        $pen = New-Object Drawing.Pen($script:DashColors.edge)
        $g.DrawRectangle($pen, 0, 0, $script:DashPanel.Width - 1, $script:DashPanel.Height - 1)
        $pen.Dispose()
        $y = $script:DashPadY
        $script:DashLineMap = @()
        $brushes = @{}
        foreach ($l in $script:DashPhys) {
          $lh = Measure-DashLineHeight $l.font
          $script:DashLineMap += [pscustomobject]@{ y0 = $y; y1 = $y + $lh + $l.extra; runId = $l.runId }
          if ($l.text) {
            $fmt = New-Object System.Drawing.StringFormat
            $fmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
            $rect = New-Object Drawing.RectangleF(($script:DashPadX + $l.indent), $y, ($script:DashWidth - 24 - $l.indent), $lh)
            $key = $l.color.ToArgb()
            if (-not $brushes.ContainsKey($key)) { $brushes[$key] = New-Object Drawing.SolidBrush($l.color) }
            $g.DrawString($l.text, $l.font, $brushes[$key], $rect, $fmt)
            $fmt.Dispose()
          }
          $y += $lh + $l.extra
        }
      } catch { }
    })

    $script:DashDrag = $false
    $script:DashDragOffset = New-Object Drawing.Point(0, 0)
    $script:DashPanel.Add_MouseDown({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $script:DashDrag = $true; $script:DashDragOffset = $e.Location } })
    $script:DashPanel.Add_MouseMove({
        param($s, $e)
        if ($script:DashDrag) {
          $p = $script:DashPanel.PointToScreen($e.Location)
          $script:DashForm.Location = New-Object Drawing.Point(($p.X - $script:DashDragOffset.X), ($p.Y - $script:DashDragOffset.Y))
        }
      })
    $script:DashPanel.Add_MouseUp({ param($s, $e) $script:DashDrag = $false })
    $script:DashPanel.Add_DoubleClick({
        param($s, $e)
        try {
          $hit = $script:DashLineMap | Where-Object { $e.Y -ge $_.y0 -and $e.Y -lt $_.y1 } | Select-Object -First 1
          $target = if ($hit -and $hit.runId) { $hit.runId } else { $script:DashFirstRunId }
          if ($target) { Start-Process explorer.exe -ArgumentList ('"' + (Join-Path $script:RunsRoot $target) + '"') }
        } catch { }
      })

    $script:DashMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $mi1 = New-Object System.Windows.Forms.ToolStripMenuItem('打开最新 run 目录')
    $mi1.Add_Click({ if ($script:DashFirstRunId) { Start-Process explorer.exe -ArgumentList ('"' + (Join-Path $script:RunsRoot $script:DashFirstRunId) + '"') } })
    [void]$script:DashMenu.Items.Add($mi1)
    $mi2 = New-Object System.Windows.Forms.ToolStripMenuItem('复制最新 run id')
    $mi2.Add_Click({ if ($script:DashFirstRunId) { [System.Windows.Forms.Clipboard]::SetText($script:DashFirstRunId) } })
    [void]$script:DashMenu.Items.Add($mi2)
    $mi3 = New-Object System.Windows.Forms.ToolStripMenuItem('立即刷新')
    $mi3.Add_Click({ & $script:DashUpdate })
    [void]$script:DashMenu.Items.Add($mi3)
    [void]$script:DashMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $mi4 = New-Object System.Windows.Forms.ToolStripMenuItem('退出')
    $mi4.Add_Click({ $script:DashForm.Close() })
    [void]$script:DashMenu.Items.Add($mi4)
    $script:DashPanel.ContextMenuStrip = $script:DashMenu

    $script:DashUpdate = {
      try {
        $runs = @(Get-DashRuns | Select-Object -First 4)
        $script:DashFirstRunId = if ($runs.Count -gt 0) { [string]$runs[0].runId } else { $null }
        $views = @($runs | ForEach-Object { Get-DashView $_ })
        $finished = @(Get-DashFinishedRuns)
        $script:DashPhys = Build-DashLayout $views $finished
        $h = $script:DashPadY * 2
        foreach ($l in $script:DashPhys) { $h += (Measure-DashLineHeight $l.font) + $l.extra }
        $h = [Math]::Max(96, [Math]::Min(($screen.Height - 60), ($h + 4)))
        if ([Math]::Abs($script:DashForm.ClientSize.Height - $h) -gt 2) { $script:DashForm.ClientSize = New-Object Drawing.Size($script:DashWidth, $h) }
        $script:DashPanel.Invalidate()
      } catch { }
    }

    $script:DashTimer = New-Object System.Windows.Forms.Timer
    $script:DashTimer.Interval = 2000
    $script:DashTimer.Add_Tick({ & $script:DashUpdate })

    $script:DashForm.Add_Shown({
        try { Write-JsonFile (Get-DashPidPath) ([pscustomobject]@{ pid = $PID; startedAt = (Get-Date).ToString('o'); version = $script:Version }) } catch { }
        & $script:DashUpdate
        $script:DashTimer.Start()
      })
    $script:DashForm.Add_FormClosing({ try { $script:DashTimer.Stop() } catch { } })
    $script:DashForm.Add_FormClosed({
        try { $script:DashTimer.Stop() } catch { }
        try { Remove-Item -LiteralPath (Get-DashPidPath) -Force -ErrorAction SilentlyContinue } catch { }
        try { $mutex.ReleaseMutex() } catch { }
      })

    [void]$script:DashForm.ShowDialog()
  } catch {
    try { Write-Warning ("仪表盘窗口异常：{0}" -f $_.Exception.Message) } catch { }
  } finally {
    $ErrorActionPreference = $oldEap
    try { if ($mutex) { $mutex.Dispose() } } catch { }
  }
}

function Start-Dash {
  $st = Get-DashStatus
  if ($st.running) { return $st }
  $pwshPath = $null
  try { $pwshPath = (Get-Process -Id $PID -ErrorAction Stop).Path } catch { }
  if (-not $pwshPath) { $pwshPath = Join-Path $PSHOME 'pwsh.exe' }
  if (-not (Test-Path -LiteralPath $pwshPath)) { $pwshPath = 'pwsh' }
  $argLine = '-NoProfile -STA -WindowStyle Hidden -File "{0}" dash --window' -f $script:ScriptPath
  try { Start-Process -FilePath $pwshPath -ArgumentList $argLine -WindowStyle Hidden | Out-Null } catch { }
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 200
    $st = Get-DashStatus
    if ($st.running) { return $st }
  }
  return (Get-DashStatus)
}
function Stop-Dash {
  $st = Get-DashStatus
  $removed = $false
  if ($st.running) { try { Stop-Process -Id $st.pid -Force -ErrorAction Stop; $removed = $true } catch { } }
  try { Remove-Item -LiteralPath (Get-DashPidPath) -Force -ErrorAction SilentlyContinue } catch { }
  return $removed
}
function Invoke-DashCommand([string[]]$argv) {
  $op = if ($argv -and $argv.Count -gt 0 -and $argv[0]) { [string]$argv[0].ToLowerInvariant() } else { 'start' }
  switch ($op) {
    { $_ -in @('start', 'show', 'open') } {
      if ($env:CSG_NO_DASH) { Write-Host 'CSG_NO_DASH 已设置，跳过仪表盘'; return 0 }
      $st = Start-Dash
      if ($st.running) { Write-Host ("仪表盘已拉起 (pid {0})" -f $st.pid) -ForegroundColor DarkCyan; return 0 }
      Write-Warning '仪表盘拉起失败（可能没有交互桌面/被策略拦截），可用 csg dash status 复查'
      return 1
    }
    'stop' { if (Stop-Dash) { Write-Host '仪表盘已关闭'; return 0 } else { Write-Host '仪表盘未在运行'; return 0 } }
    'status' {
      $st = Get-DashStatus
      if ($st.running) {
        $n = @(Get-DashRuns).Count
        Write-Host ("仪表盘: 运行中 · pid {0} · 显示 {1} 个活跃 run" -f $st.pid, $n) -ForegroundColor Green
        return 0
      }
      Write-Host '仪表盘: 未启动（csg dash 可拉起）' -ForegroundColor DarkYellow
      return 1
    }
    'once' {
      $n = 4
      $mx = Get-Opt $argv '--max'
      if ($mx -and [int]::TryParse([string]$mx, [ref]$n)) { } else { $n = 4 }
      Show-DashOnce -MaxRuns $n
      return 0
    }
    '--window' { Start-DashWindow; return 0 }
    default {
      Write-Host '用法: csg dash [start|stop|status|once]'
      Write-Host '  start   拉起桌面仪表盘（默认）'
      Write-Host '  stop    关闭仪表盘'
      Write-Host '  status  查看是否已拉起'
      Write-Host '  once    在终端打印一次快照'
      return 2
    }
  }
}

try {
  switch ($Command.ToLowerInvariant()) {
    'run' { exit (Start-Run $Remaining) }
    'resume' { exit (Start-Run (@('--resume')+$Remaining)) }
    'repair' { $n=Repair-StaleRuns; Write-Host "已修复 $n 个中断 run。"; exit 0 }
    'status' { Show-Status; exit 0 }
    'dash' { exit (Invoke-DashCommand $Remaining) }
    'stats' { Show-Stats; exit 0 }
    'doctor' { Doctor; exit 0 }
    'config' { Config-Command $Remaining; exit 0 }
    'install' { Install-Csg; exit 0 }
    'uninstall' { Uninstall-Csg; exit 0 }
    default { Write-Host '用法: csg run "任务" [--model m] [--effort e] [--cd dir] [--file f] [--attempts-per-round 100] [--cooldown-seconds 1800] [--deadline ISO|分钟] [--attempt-timeout-minutes n] [--resume-on-smac] | csg status | csg stats | csg doctor | csg repair | csg dash [start|stop|status|once] | csg config set k v | csg install'; exit 2 }
  }
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 2 }






