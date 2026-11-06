#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$script:RawArgs = @($args)
$Mode = if ($env:CSG_FAKE_MODE) { $env:CSG_FAKE_MODE } else { 'smac-then-success' }
$SmacCount = if ($env:CSG_FAKE_SMAC_COUNT) { [int]$env:CSG_FAKE_SMAC_COUNT } else { 0 }
$StateFile = $env:CSG_FAKE_STATE
$ExpectedHash = $env:CSG_FAKE_EXPECT_HASH
$DelayMs = if ($env:CSG_FAKE_DELAY_MS) { [int]$env:CSG_FAKE_DELAY_MS } else { 0 }
$DumpPrompt = $env:CSG_FAKE_DUMP_PROMPT
$Variant = if ($env:CSG_FAKE_VARIANT) { [string]$env:CSG_FAKE_VARIANT } else { '' }
$ArgsFile = $env:CSG_FAKE_ARGS
$IsResume = ($script:RawArgs -contains 'resume')
for ($j = 0; $j -lt $script:RawArgs.Count; $j++) {
  switch ([string]$script:RawArgs[$j]) {
    '-Mode' { if ($j + 1 -lt $script:RawArgs.Count) { $Mode = [string]$script:RawArgs[++$j] } }
    '-SmacCount' { if ($j + 1 -lt $script:RawArgs.Count) { $SmacCount = [int]$script:RawArgs[++$j] } }
    '-StateFile' { if ($j + 1 -lt $script:RawArgs.Count) { $StateFile = [string]$script:RawArgs[++$j] } }
    '-ExpectedHash' { if ($j + 1 -lt $script:RawArgs.Count) { $ExpectedHash = [string]$script:RawArgs[++$j] } }
    '-DelayMs' { if ($j + 1 -lt $script:RawArgs.Count) { $DelayMs = [int]$script:RawArgs[++$j] } }
  }
}
if ([string]::IsNullOrWhiteSpace($Mode)) { $Mode = 'smac-then-success' }
if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
$in = [Console]::OpenStandardInput(); $ms = [IO.MemoryStream]::new(); $in.CopyTo($ms); $prompt = [Text.Encoding]::UTF8.GetString($ms.ToArray()); $ms.Dispose()
if ($DumpPrompt) { try { [IO.File]::WriteAllBytes($DumpPrompt, [Text.Encoding]::UTF8.GetBytes($prompt)) } catch {} }
if ($ExpectedHash) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $actual = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($prompt)))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
  if ($actual -ne $ExpectedHash.ToLowerInvariant()) { [Console]::Error.WriteLine("PROMPT_HASH_MISMATCH expected=$ExpectedHash actual=$actual"); exit 9 }
}
function Get-Count { if (-not $StateFile) { return 0 }; try { if (Test-Path -LiteralPath $StateFile) { return [int](Get-Content -LiteralPath $StateFile -Raw) } } catch {}; return 0 }
function Set-Count([int]$n) { if ($StateFile) { $parent = Split-Path -Parent $StateFile; if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }; Set-Content -LiteralPath $StateFile -Value $n -Encoding utf8 } }
function Write-LastMessage([string]$text) { $a = $script:RawArgs; $idx = -1; for ($i = 0; $i -lt $a.Count; $i++) { if ([string]$a[$i] -eq '-o') { $idx = $i; break } }; if ($idx -ge 0 -and $idx + 1 -lt $a.Count) { try { Set-Content -LiteralPath ([string]$a[$idx + 1]) -Value $text -Encoding utf8 } catch {} } }
$count = (Get-Count) + 1; Set-Count $count; $shouldSmac = $false
if ($ArgsFile) { try { ($script:RawArgs -join ' ') | Add-Content -LiteralPath $ArgsFile -Encoding utf8 } catch {} }
if ($Mode -eq 'midrun-smac') {
  if (-not $IsResume) {
    [Console]::Out.WriteLine('OpenAI Codex v0.166.0')
    [Console]::Out.WriteLine('session id: 11111111-2222-3333-4444-555555555555')
    [Console]::Out.WriteLine('exec')
    [Console]::Out.WriteLine('succeeded in 12ms:')
    [Console]::Error.WriteLine('ERROR: Selected model is at capacity. Please try a different model.')
    Write-LastMessage 'partial work'
    exit 1
  }
  [Console]::Out.WriteLine('CSG-FAKE-RESUMED-OK')
  Write-LastMessage 'CSG-FAKE-RESUMED-OK'
  exit 0
}
switch ($Mode.ToLowerInvariant()) {
  'always-smac' { $shouldSmac = $true }
  'smac-then-success' { $shouldSmac = $count -le $SmacCount }
  'non-capacity' { $shouldSmac = $false }
  'timeout' { Start-Sleep -Seconds 3600; exit 124 }
  'hash' { $shouldSmac = $false }
  'smac-variant' { $shouldSmac = $true }
  'disk-capacity' { $shouldSmac = $false }
  'success-with-smac-text' { $shouldSmac = $false }
  'secret-output' { $shouldSmac = $false }
  default { $shouldSmac = $count -le $SmacCount }
}
if ($Mode -eq 'non-capacity') { [Console]::Error.WriteLine('ERROR: authentication failed (fake-codex)'); Write-LastMessage 'authentication failed'; exit 1 }
if ($shouldSmac) {
  $smacLine = 'ERROR: Selected model is at capacity. Please try a different model.'
  if ($Mode -eq 'smac-variant') { $smacLine = switch ($Variant.ToLowerInvariant()) { 'upper' { '  error: SELECTED MODEL IS AT CAPACITY. PLEASE TRY A DIFFERENT MODEL.  ' }; 'crlf' { "`r`n ERROR:  Selected   model is at capacity. Please try a different model. `r`n" }; default { ' ERROR: Selected model is at capacity. Please try a different model. ' } } }
  [Console]::Error.WriteLine($smacLine); Write-LastMessage 'Selected model is at capacity'; exit 1
}
if ($Mode -eq 'disk-capacity') { [Console]::Error.WriteLine('disk at capacity (fake-codex)'); Write-LastMessage 'disk at capacity'; exit 1 }
$ok = if ($Mode -eq 'hash') { 'CSG-FAKE-HASH-OK' } elseif ($Mode -eq 'disk-capacity') { 'disk at capacity (fake-codex)' } elseif ($Mode -eq 'success-with-smac-text') { 'ERROR: Selected model is at capacity. Please try a different model.' } elseif ($Mode -eq 'secret-output') { 'Authorization: Bearer sk-super-secret-12345678 token=super-secret-value' } else { 'CSG-FAKE-OK' }
[Console]::Out.WriteLine($ok); Write-LastMessage $ok; exit 0
