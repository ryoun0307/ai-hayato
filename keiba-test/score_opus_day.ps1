# Opus の予想（predictions_opus）と、数字モデル（weekend\pred）、1番人気を、同じ日のレースで比べる。
#   powershell -ExecutionPolicy Bypass -File score_opus_day.ps1 -Date 20261122
param([string]$Date = "20261122")
$utf8 = New-Object Text.UTF8Encoding($false)
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
function J($p) { [IO.File]::ReadAllText($p, $utf8) | ConvertFrom-Json }
function Um($pay, $x, $y) { $c = (@([int]$x, [int]$y) | Sort-Object) -join "-"; $s = 0
  foreach ($l in @($pay.umaren)) { $lc = (@("$($l.combo)" -split '-' | ForEach-Object { [int]$_ } | Sort-Object) -join "-"); if ($lc -eq $c) { $s += [int]$l.yen } }; return $s }
$rows = @()
foreach ($af in Get-ChildItem (Join-Path $root "data\weekend\a") -Filter "${Date}_*.json" | Sort-Object Name) {
  $race = $af.BaseName
  $of = Join-Path $root "predictions_opus\${race}_最終.json"; $nf = Join-Path $root "weekend\pred\${race}.json"
  if (-not (Test-Path $of) -or -not (Test-Path $nf)) { continue }
  $a = J $af.FullName; $o = J $of; $nm = J $nf; $pay = $a.payouts
  $fin = @{}; $pop = @{}; foreach ($x in $a.results) { $fin["$($x.number)"] = [int]("0" + ("$($x.finish)" -replace '\D', '')); $pop["$($x.number)"] = [int]$x.popularity }
  $p1 = @($a.results | Where-Object { $_.popularity -eq 1 } | Select-Object -First 1)[0].number
  $sets = [ordered]@{}
  $om = @($o.marks); $sets["Opus"] = @{ hon = $om[0]; aite = @($om[1..3]) }
  $sets["数字モデル"] = @{ hon = $nm.honmei.num; aite = @($nm.aite | ForEach-Object { $_.num }) }
  $po = @($nm.pop_order); $sets["1番人気"] = @{ hon = $p1; aite = @($po[1..3]) }
  $r = [ordered]@{ race = $race; name = $a.race.name; heads = @($a.results).Count; conf = $o.confidence }
  foreach ($k in $sets.Keys) {
    $h = [string]$sets[$k].hon
    $t = 0; foreach ($l in @($pay.tansho)) { if ([string]$l.combo -eq $h) { $t += [int]$l.yen } }
    $f = 0; foreach ($l in @($pay.fukusho)) { if ([string]$l.combo -eq $h) { $f += [int]$l.yen } }
    $u = 0; foreach ($z in $sets[$k].aite) { $u += (Um $pay $h $z) }
    $r[($k + "_fin")] = $fin[$h]; $r[($k + "_hon")] = $h; $r[($k + "_tan")] = $t; $r[($k + "_fuk")] = $f; $r[($k + "_um")] = $u
  }
  $r["top3"] = (@($a.results | Where-Object { $_.finish -match '^[123]$' } | Sort-Object { [int]$_.finish } | ForEach-Object { "{0}番({1}人気)" -f $_.number, $_.popularity }) -join " → ")
  $rows += [pscustomobject]$r
}
$N = $rows.Count
$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine("# Opus と数字モデルと1番人気の比較：$Date（$N レース）"); [void]$sb.AppendLine("")
[void]$sb.AppendLine("Opus の予想はレース前の情報（人気・馬体重・過去10走）だけで作り、結果は見ていない。馬連は◎→次の3頭（3点）。"); [void]$sb.AppendLine("")
[void]$sb.AppendLine("| | ◎が1着 | ◎が3着以内 | 単勝回収率 | 複勝回収率 | 馬連3点回収率 |"); [void]$sb.AppendLine("|---|---|---|---|---|---|")
foreach ($k in @("Opus", "数字モデル", "1番人気")) {
  $w = @($rows | Where-Object { $_."${k}_fin" -eq 1 }).Count; $t3 = @($rows | Where-Object { $_."${k}_fin" -ge 1 -and $_."${k}_fin" -le 3 }).Count
  $tan = ($rows | Measure-Object -Property "${k}_tan" -Sum).Sum; $fuk = ($rows | Measure-Object -Property "${k}_fuk" -Sum).Sum; $um = ($rows | Measure-Object -Property "${k}_um" -Sum).Sum
  [void]$sb.AppendLine(("| {0} | {1}/{2}（{3:0}%） | {4}/{2}（{5:0}%） | {6:0}% | {7:0}% | {8:0}% |" -f $k, $w, $N, (100 * $w / $N), $t3, (100 * $t3 / $N), (100 * $tan / (100 * $N)), (100 * $fuk / (100 * $N)), (100 * $um / (300 * $N))))
}
[void]$sb.AppendLine(""); [void]$sb.AppendLine("## Opus の◎が1番人気と違ったレース")
$diff = @($rows | Where-Object { "$($_.Opus_hon)" -ne "$($_.'1番人気_hon')" })
[void]$sb.AppendLine("全 $N レース中 $($diff.Count) レース。"); [void]$sb.AppendLine("")
[void]$sb.AppendLine("| レース | Opusの◎ | 着順 | 1番人気の着順 | 実際の1〜3着 |"); [void]$sb.AppendLine("|---|---|---|---|---|")
foreach ($d in $diff) { [void]$sb.AppendLine(("| {0} | {1}番 | {2}着 | {3}着 | {4} |" -f $d.race, $d.Opus_hon, $d.Opus_fin, $d.'1番人気_fin', $d.top3)) }
[void]$sb.AppendLine(""); [void]$sb.AppendLine("## 自信度ごと（Opus の◎）"); [void]$sb.AppendLine(""); [void]$sb.AppendLine("| 自信度 | レース数 | ◎が1着 | ◎が3着以内 |"); [void]$sb.AppendLine("|---|---|---|---|")
foreach ($c in "A", "B", "C") { $g = @($rows | Where-Object { $_.conf -eq $c }); if ($g.Count) { [void]$sb.AppendLine(("| {0} | {1} | {2} | {3} |" -f $c, $g.Count, @($g | Where-Object { $_.Opus_fin -eq 1 }).Count, @($g | Where-Object { $_.Opus_fin -ge 1 -and $_.Opus_fin -le 3 }).Count)) } }
[void]$sb.AppendLine(""); [void]$sb.AppendLine("## レースごと"); [void]$sb.AppendLine(""); [void]$sb.AppendLine("| レース | 自信度 | Opus◎(着) | 数字◎(着) | 1番人気(着) | 実際の1〜3着 |"); [void]$sb.AppendLine("|---|---|---|---|---|---|")
foreach ($r in $rows) { [void]$sb.AppendLine(("| {0} {1} | {2} | {3}番({4}) | {5}番({6}) | {7}番({8}) | {9} |" -f $r.race, $r.name, $r.conf, $r.Opus_hon, $r.Opus_fin, $r.'数字モデル_hon', $r.'数字モデル_fin', $r.'1番人気_hon', $r.'1番人気_fin', $r.top3)) }
$out = Join-Path $root ("weekend\結果_Opus比較_" + $Date + ".md")
[IO.File]::WriteAllText($out, $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
Get-Content $out -Encoding UTF8
