param([string]$QSub = "question", [int]$PastN = 4)
# 集めたデータが正しいかを確かめる道具（特に「過去4走にそのレース以降の成績が混ざっていないか」）
#   powershell -ExecutionPolicy Bypass -File verify.ps1
$ErrorActionPreference = "Stop"
$utf8 = New-Object Text.UTF8Encoding($false)
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ng = 0; $horsesChecked = 0; $dropped = 0

foreach ($qf in Get-ChildItem (Join-Path $root ("data\" + $QSub)) -Filter *.json) {
  $q = [IO.File]::ReadAllText($qf.FullName, $utf8) | ConvertFrom-Json
  $af = Join-Path $root ("data\answer\" + $qf.Name)
  $a = [IO.File]::ReadAllText($af, $utf8) | ConvertFrom-Json
  $rd = $q.race.date
  $problems = @()

  foreach ($h in $q.horses) {
    $horsesChecked++
    $past = @($h.past_runs)
    if ($past.Count -gt $PastN) { $problems += "$($h.name): 過去が規定より多い" }
    $prev = "99999999"
    foreach ($p in $past) {
      if ($p.date -ge $rd) { $problems += "$($h.name): ★レース日以降の成績が混ざっている $($p.date)" }
      if ($p.date -ge $prev) { $problems += "$($h.name): 新しい順になっていない" }
      $prev = $p.date
    }
    # 別の方法で確認：JRA の成績ページの控えから、日付だけを取り出して数え直す
    $cf = Join-Path $root ("cache\horse_" + ($h.jra_id -replace '[^0-9A-Za-z]', '_') + ".html")
    $html = [IO.File]::ReadAllText($cf, $utf8)
    $s = $html.IndexOf("出走レース")
    $dates = @([regex]::Matches($html.Substring($s), '<td class="date">(\d+)年(\d+)月(\d+)日</td>') | ForEach-Object { "{0:0000}{1:00}{2:00}" -f [int]$_.Groups[1].Value, [int]$_.Groups[2].Value, [int]$_.Groups[3].Value })
    $dropped += @($dates | Where-Object { $_ -ge $rd }).Count
    $expect = @($dates | Where-Object { $_ -lt $rd } | Select-Object -First $PastN)
    $got = @($past | ForEach-Object { $_.date })
    if (($expect -join ",") -ne ($got -join ",")) { $problems += "$($h.name): 過去4走の日付が一致しない（期待 $($expect -join ',') / 実際 $($got -join ','))" }
  }

  # 予想用データに、このレースの結果（着順・タイム・払戻）が入っていないか
  $raw = [IO.File]::ReadAllText($qf.FullName, $utf8)
  foreach ($bad in @('"finish":  "1"', '"payouts"', '"last3f"', '"corner"')) {
    if ($raw -cmatch [regex]::Escape($bad) -and $bad -ne '"finish":  "1"') { $problems += "予想用データに '$bad' が入っている" }
  }
  # 答えとの整合
  $qn = @($q.horses | ForEach-Object { $_.number } | Sort-Object)
  $an = @($a.results | ForEach-Object { $_.number } | Sort-Object)
  if (($qn -join ",") -ne ($an -join ",")) { $problems += "出走馬の馬番が予想用と答えで違う" }
  $winner = @($a.results | Where-Object { $_.finish -eq "1" })
  if ($winner.Count -lt 1) { $problems += "1着の馬がいない" }
  elseif ("$($a.payouts.tansho[0].combo)" -ne "$($winner[0].number)") { $problems += "単勝の払戻の馬番が1着馬と違う" }
  if (-not $a.payouts.sanrentan) { $problems += "3連単の払戻がない" }

  if ($problems.Count) { $ng++; Write-Host ("× " + $qf.Name); $problems | ForEach-Object { Write-Host ("    " + $_) } }
  else { Write-Host ("○ " + $qf.Name + "（" + @($q.horses).Count + "頭）") }
}
Write-Host ""
Write-Host ("調べた馬：{0}頭 / そのレース日以降として除いた成績：{1}件 / 問題のあったレース：{2}" -f $horsesChecked, $dropped, $ng)
