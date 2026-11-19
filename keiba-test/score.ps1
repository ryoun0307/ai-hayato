param([string]$Set = "all", [string]$OutFile = "結果.md")
# 答え合わせ：予想（predictions）と実際の払戻金（data\answer）を突き合わせて、的中率・回収率を出す。
#   powershell -ExecutionPolicy Bypass -File score.ps1            … 全部の予想を採点
#   結果は画面に出し、結果.md にも保存する。
# 買い目（1点100円）：◎単勝・◎複勝・馬連ボックス(◎○▲△の4頭=6点)・馬連流し(◎→○▲△△=4点)・3連単(◎1着固定→○▲△△の2・3着=12点)
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$BETS = @("単勝", "複勝", "馬連ボックス", "馬連流し", "3連単")

function Norm2([string]$c) { (@($c -split '-' | ForEach-Object { [int]$_ } | Sort-Object) -join "-") }
function Pay($lines, [string]$combo, [bool]$ordered) {
  $sum = 0
  foreach ($l in @($lines)) {
    $lc = if ($ordered) { "$($l.combo)" } else { Norm2 "$($l.combo)" }
    if ($lc -eq $combo) { $sum += [int]$l.yen }
  }
  return $sum
}
# 印（5頭の馬番）から、券種ごとの [払った金額, 戻った金額] を出す
function Eval-Bets($marks, $p) {
  $m = @($marks | ForEach-Object { [int]$_ })
  $r = [ordered]@{}
  $r["単勝"] = @(100, (Pay $p.tansho "$($m[0])" $true))
  $r["複勝"] = @(100, (Pay $p.fukusho "$($m[0])" $true))
  $s = 0; $t = 0
  for ($i = 0; $i -lt 4; $i++) { for ($j = $i + 1; $j -lt 4; $j++) { $s += 100; $t += (Pay $p.umaren (Norm2 "$($m[$i])-$($m[$j])") $false) } }
  $r["馬連ボックス"] = @($s, $t)
  $s = 0; $t = 0
  for ($j = 1; $j -le 4; $j++) { $s += 100; $t += (Pay $p.umaren (Norm2 "$($m[0])-$($m[$j])") $false) }
  $r["馬連流し"] = @($s, $t)
  $s = 0; $t = 0
  for ($a = 1; $a -le 4; $a++) { for ($b = 1; $b -le 4; $b++) { if ($a -eq $b) { continue }; $s += 100; $t += (Pay $p.sanrentan "$($m[0])-$($m[$a])-$($m[$b])" $true) } }
  $r["3連単"] = @($s, $t)
  return $r
}

$rows = @()   # 1予想=1行
$mainList = @([IO.File]::ReadAllLines((Join-Path $root "本番レース一覧.txt"), $utf8) | ForEach-Object { $_.Trim([char]0xFEFF).Trim() } | Where-Object { $_ })
foreach ($pf in Get-ChildItem (Join-Path $root "predictions") -Filter *.json | Sort-Object Name) {
  $rn = $pf.BaseName -replace "_(仮|最終)$",""
  if ($Set -eq "main" -and ($mainList -notcontains $rn)) { continue }
  if ($Set -eq "ref" -and ($mainList -contains $rn)) { continue }
  $pr = [IO.File]::ReadAllText($pf.FullName, $utf8) | ConvertFrom-Json
  $ans = [IO.File]::ReadAllText((Join-Path $root ("data\answer\" + $pr.race + ".json")), $utf8) | ConvertFrom-Json
  $fin = @{}; $pop = @{}
  foreach ($x in $ans.results) { $fin["$($x.number)"] = "$($x.finish)"; $pop["$($x.number)"] = [int]$x.popularity }
  # 人気順の上位5頭（比べる相手：1番人気から順に同じ組み方）
  $byPop = @($ans.results | Where-Object { $_.popularity } | Sort-Object { [int]$_.popularity } | Select-Object -First 5 | ForEach-Object { $_.number })
  $rows += [pscustomobject]@{
    race = $pr.race; stage = $pr.stage; conf = $pr.confidence
    ai = (Eval-Bets $pr.marks $ans.payouts)
    pop = (Eval-Bets $byPop $ans.payouts)
    honmei = "$($pr.marks[0])"; honmeiFin = $fin["$($pr.marks[0])"]; honmeiPop = $pop["$($pr.marks[0])"]
    top3 = @($pr.marks[0..4] | Where-Object { $fin["$_"] -match '^[123]$' }).Count
  }
}

$out = New-Object Text.StringBuilder
function Say([string]$s) { Write-Host $s; [void]$out.AppendLine($s) }

function Summarize($subset, [string]$key) {
  Say ("| 買い方 | 払った金額 | 戻った金額 | 回収率 | 的中したレース数 |")
  Say ("|---|---|---|---|---|")
  $tot = @(0, 0)
  foreach ($b in $BETS) {
    $stake = 0; $ret = 0; $hit = 0
    foreach ($r in $subset) { $v = $r.$key[$b]; $stake += $v[0]; $ret += $v[1]; if ($v[1] -gt 0) { $hit++ } }
    $tot[0] += $stake; $tot[1] += $ret
    Say ("| {0} | {1:N0}円 | {2:N0}円 | {3:0.0}% | {4}/{5} |" -f $b, $stake, $ret, $(if ($stake) { 100.0 * $ret / $stake } else { 0 }), $hit, @($subset).Count)
  }
  Say ("| **全部まとめて** | {0:N0}円 | {1:N0}円 | **{2:0.0}%** | |" -f $tot[0], $tot[1], $(if ($tot[0]) { 100.0 * $tot[1] / $tot[0] } else { 0 }))
  $s3 = 0; $r3 = 0; foreach ($rr in $subset) { foreach ($b in @("単勝","複勝","馬連ボックス","馬連流し")) { $s3 += $rr.$key[$b][0]; $r3 += $rr.$key[$b][1] } }
  Say ("| 3連単を除いた回収率 | {0:N0}円 | {1:N0}円 | {2:0.0}% | |" -f $s3, $r3, $(if ($s3) { 100.0 * $r3 / $s3 } else { 0 }))
}

Say "# 答え合わせの結果"
Say ""
foreach ($stage in @("仮", "最終")) {
  $sub = @($rows | Where-Object { $_.stage -eq $stage })
  Say ("## {0}予想（{1}レース）：AI の買い目" -f $stage, $sub.Count)
  Summarize $sub "ai"
  Say ""
  Say ("### 同じ{0}のレースで「人気順に買っただけ」（1番人気=◎、2〜5番人気=○▲△△）" -f $stage)
  Summarize $sub "pop"
  Say ""
  $w = @($sub | Where-Object { $_.honmeiFin -eq "1" }).Count
  $p3 = @($sub | Where-Object { $_.honmeiFin -match '^[123]$' }).Count
  Say ("◎が1着：{0}/{1}　◎が3着以内：{2}/{1}　5頭の印のうち3着以内に入った頭数の平均：{3:0.00}頭" -f $w, $sub.Count, $p3, (($sub | Measure-Object top3 -Average).Average))
  Say ""
}

Say "## 自信度ごと（最終予想・AI の買い目の全部まとめ）"
Say "| 自信度 | レース数 | 払った金額 | 戻った金額 | 回収率 | ◎が1着 |"
Say "|---|---|---|---|---|---|"
foreach ($c in @("A", "B", "C")) {
  $sub = @($rows | Where-Object { $_.stage -eq "最終" -and $_.conf -eq $c })
  if (-not $sub.Count) { continue }
  $s = 0; $t = 0
  foreach ($r in $sub) { foreach ($b in $BETS) { $s += $r.ai[$b][0]; $t += $r.ai[$b][1] } }
  Say ("| {0} | {1} | {2:N0}円 | {3:N0}円 | {4:0.0}% | {5}/{1} |" -f $c, $sub.Count, $s, $t, (100.0 * $t / $s), @($sub | Where-Object { $_.honmeiFin -eq "1" }).Count)
}
Say ""
Say "## レースごと（最終予想の◎の結果）"
Say "| レース | 自信度 | ◎ | ◎の着順 | ◎の人気 | 5頭中3着以内 | 戻った金額（全券種） | 払った金額 |"
Say "|---|---|---|---|---|---|---|---|"
foreach ($r in ($rows | Where-Object { $_.stage -eq "最終" })) {
  $s = 0; $t = 0; foreach ($b in $BETS) { $s += $r.ai[$b][0]; $t += $r.ai[$b][1] }
  Say ("| {0} | {1} | {2}番 | {3} | {4}番人気 | {5}頭 | {6:N0}円 | {7:N0}円 |" -f $r.race, $r.conf, $r.honmei, $r.honmeiFin, $r.honmeiPop, $r.top3, $t, $s)
}
[IO.File]::WriteAllText((Join-Path $root $OutFile), $out.ToString(), (New-Object Text.UTF8Encoding($true)))
