#requires -Version 7.0
# Runs the full [Lilith]Mythware local chain under an elevated token.
# Invoked by the supervisor via: Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-File',<this>
$ErrorActionPreference = 'Continue'
$root = 'C:\Users\LLS\Desktop\[Lilith]Mythware'
$out  = Join-Path $root 'out\evidence\csg-chain\final-elevated'
New-Item -ItemType Directory -Force -Path $out | Out-Null
Set-Location -LiteralPath $root
$results = [System.Collections.Generic.List[object]]::new()
$suiteLog = Join-Path $out 'suite.log'

function Log([string]$m) { $m | Out-File -LiteralPath $suiteLog -Append -Encoding utf8; Write-Host $m }

function Invoke-Step([string]$Name, [scriptblock]$Action, [string]$LogName) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $logPath = Join-Path $out $LogName
    $code = 0
    try {
        $global:LASTEXITCODE = 0
        & $Action 2>&1 | Out-File -LiteralPath $logPath -Encoding utf8
        $code = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    } catch {
        $code = 1
        ('EXCEPTION: ' + ($_ | Out-String)) | Out-File -LiteralPath $logPath -Append -Encoding utf8
    }
    $sw.Stop()
    $r = [pscustomobject]@{ name = $Name; exitCode = $code; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); pass = ($code -eq 0) }
    $results.Add($r)
    Log ("{0} exit={1} sec={2}" -f $Name, $code, $r.seconds)
    return $r
}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($id)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Log ("identity={0} admin={1} time={2}" -f $id.Name, $isAdmin, (Get-Date).ToString('o'))

$who = Invoke-Step 'whoami /groups' { whoami.exe /groups } 'whoami-groups.log'
$high = $false
if (Test-Path -LiteralPath (Join-Path $out 'whoami-groups.log')) {
    $high = (Get-Content -LiteralPath (Join-Path $out 'whoami-groups.log') -Raw) -match 'High Mandatory Level'
}

$test = Invoke-Step 'tools/test.ps1 (Win32+x64 offline)' {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\test.ps1')
} 'elevated-test.log'

$smoke = Invoke-Step 'feature_extension_smoke.py' {
    & python (Join-Path $root 'tests\feature_extension_smoke.py')
} 'elevated-smoke.log'

$summary = [ordered]@{
    generatedAt = (Get-Date).ToString('o')
    elevated = $isAdmin
    highIntegrity = $high
    steps = @($results)
    overallPass = [bool]($high -and $test.pass -and $smoke.pass)
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $out 'elevated-result.json') -Encoding utf8
Log ("overallPass={0}" -f $summary.overallPass)
