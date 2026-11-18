# 予想の保存：powershell -File sp.ps1 -Race 日付_場_RR -Stage 仮 -Conf B -Marks "5,1,6,2,7" -Pct "5=22,1=17,6=16,2=13,7=11" -Reason "..."
param([string]$Race,[string]$Stage,[string]$Conf,[string]$Marks,[string]$Pct,[string]$Reason)
$m = @($Marks -split ',' | % { [int]$_ })
$p = [ordered]@{}
foreach ($kv in ($Pct -split ',')) { $a = $kv -split '='; $p[$a[0]] = [int]$a[1] }
$o = [ordered]@{ race=$Race; stage=$Stage; model="sonnet"; confidence=$Conf; marks=$m; win_pct=$p; reason=$Reason }
$dir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "predictions"
[IO.File]::WriteAllText((Join-Path $dir "${Race}_${Stage}.json"), ($o | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
