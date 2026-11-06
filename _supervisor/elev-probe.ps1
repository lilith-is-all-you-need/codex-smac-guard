$id=[Security.Principal.WindowsIdentity]::GetCurrent()
$p=New-Object Security.Principal.WindowsPrincipal($id)
$out=[ordered]@{ user=$id.Name; admin=$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator); integrity=(whoami /groups | Select-String 'Mandatory Label').ToString().Trim() }
$out | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'elev-probe.json') -Encoding utf8
