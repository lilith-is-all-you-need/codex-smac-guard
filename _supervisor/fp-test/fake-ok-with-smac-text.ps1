$in=[Console]::OpenStandardInput(); $ms=[IO.MemoryStream]::new(); $in.CopyTo($ms); [void][Text.Encoding]::UTF8.GetString($ms.ToArray())
$a=@($args); for($i=0;$i -lt $a.Count;$i++){ if([string]$a[$i] -eq '-o'){ try{ Set-Content -LiteralPath ([string]$a[$i+1]) -Value 'ERROR: Selected model is at capacity. Please try a different model.' -Encoding UTF8 }catch{} } }
Write-Output 'task finished: the doc quotes ERROR: Selected model is at capacity. Please try a different model.'
exit 0
