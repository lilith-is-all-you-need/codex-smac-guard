param(
  [Parameter(Mandatory)][string]$Local,
  [Parameter(Mandatory)][string]$Remote,
  [switch]$Download
)
$ErrorActionPreference = 'Stop'
$key = 'C:\ProgramData\csg\vm_key'
$kh = 'C:/ProgramData/csg/known_hosts'
$base = @('-i', $key, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no', '-o', "UserKnownHostsFile=$kh")
if ($Download) { & scp @base "lls@192.168.1.79:$Remote" $Local }
else { & scp @base $Local "lls@192.168.1.79:$Remote" }
exit $LASTEXITCODE
