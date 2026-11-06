param(
  [Parameter(Mandatory)][string]$Script,
  [int]$TimeoutSec = 900
)
$ErrorActionPreference = 'Stop'
$key = 'C:\ProgramData\csg\vm_key'
$kh = 'C:/ProgramData/csg/known_hosts'
$b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
$sshArgs = @('-i', $key, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no', '-o', "UserKnownHostsFile=$kh", '-o', 'ConnectTimeout=10', 'lls@192.168.1.79', "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64")
& ssh @sshArgs
exit $LASTEXITCODE


