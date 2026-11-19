# 数字だけで「勝ちやすさ」を計算する仕組み（過去10走の成績＋人気）。
#   学習：予想済みの219レース（本番200＋試運転19）の答えから、どの数字が効くかを学ぶ。
#   試験：それ以外のレース（障害を除く）で、学習に使っていないレースだけで確かめる。
#   powershell -ExecutionPolicy Bypass -File model.ps1
# 出力：predictions_model\日付_場_R_最終.json（印5頭と split=train/hold）、model_weights.txt
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$qdir = Join-Path $root "data\question10"
$outDir = Join-Path $root "predictions_model"
New-Item -ItemType Directory -Force $outDir | Out-Null

$trainIds = @{}
foreach ($f in Get-ChildItem (Join-Path $root "predictions") -Filter *_最終.json) { $trainIds[($f.BaseName -replace "_最終$", "")] = $true }

function Num($s) { if ("$s" -match '^\d+$') { return [int]$s } else { return $null } }
function Clip($x, $lo, $hi) { if ($x -lt $lo) { return $lo } elseif ($x -gt $hi) { return $hi } else { return $x } }
$NF = 9
$names = @("人気(-ln)", "近5走の着順率", "近10走の3着内率", "近10走の勝率", "同条件の3着内率", "人気より着順が良い度", "休養(log日数)", "馬体重の大増減", "前走の着順率")

$races = @()
foreach ($qf in Get-ChildItem $qdir -Filter *.json | Sort-Object Name) {
  $id = $qf.BaseName
  $q = [IO.File]::ReadAllText($qf.FullName, $utf8) | ConvertFrom-Json
  if ($q.race.category -like "障害*") { continue }
  $af = [IO.File]::ReadAllText((Join-Path $root ("data\answer\" + $id + ".json")), $utf8) | ConvertFrom-Json
  $cm = [regex]::Match($q.race.course, '([\d,]+)\s*メートル\s*（(芝|ダート)')
  $dist = [int]($cm.Groups[1].Value -replace ',', ''); $surf = if ($cm.Groups[2].Value -eq "芝") { "芝" } else { "ダ" }
  $rd = [datetime]::ParseExact($q.race.date, "yyyyMMdd", $null)
  $fin = @{}; foreach ($x in $af.results) { $fin["$($x.number)"] = "$($x.finish)" }
  $hs = @(); $y = @()
  foreach ($h in $q.horses) {
    $pop = [int]$h.final.popularity; if ($pop -lt 1) { $pop = 10 }
    $past = @($h.past_runs)
    $f = New-Object double[] $NF
    $f[0] = - [math]::Log($pop)
    $r5 = @(); $t3 = 0; $w = 0; $n = 0; $sc = 0; $st = 0; $ov = @()
    foreach ($p in $past) {
      $fn = Num $p.finish; $hd = [int]$p.heads
      if ($null -eq $fn -or $hd -lt 2) { continue }
      $n++
      $ratio = ($fn - 1.0) / ($hd - 1.0)
      if ($n -le 5) { $r5 += $ratio; if ($p.popularity) { $ov += (([int]$p.popularity - $fn) / [double]$hd) } }
      if ($fn -le 3) { $t3++ }; if ($fn -eq 1) { $w++ }
      $pm = [regex]::Match($p.distance, '^(芝|ダ)(\d+)')
      if ($pm.Success -and $pm.Groups[1].Value -eq $surf -and [math]::Abs([int]$pm.Groups[2].Value - $dist) -le 200) { $sc++; if ($fn -le 3) { $st++ } }
    }
    $f[1] = if ($r5.Count) { 0.5 - ($r5 | Measure-Object -Average).Average } else { 0 }
    $f[2] = (($t3 + 0.25 * 2) / ($n + 2)) - 0.25
    $f[3] = (($w + 0.08 * 2) / ($n + 2)) - 0.08
    $f[4] = (($st + 0.25 * 2) / ($sc + 2)) - 0.25
    $f[5] = if ($ov.Count) { Clip (($ov | Measure-Object -Average).Average) -0.5 0.5 } else { 0 }
    $rest = 60; if ($past.Count) { $rest = ($rd - [datetime]::ParseExact($past[0].date, "yyyyMMdd", $null)).TotalDays }
    $f[6] = [math]::Log([math]::Max($rest, 7)) - [math]::Log(35)
    $bd = Num (($h.final.body_weight_diff -replace '^\+', '')); if ($null -eq $bd -and "$($h.final.body_weight_diff)" -match '^-?\d+$') { $bd = [int]$h.final.body_weight_diff }
    $f[7] = if ($null -ne $bd -and [math]::Abs($bd) -ge 10) { 1 } else { 0 }
    $f[8] = if ($past.Count) { $a = Num $past[0].finish; $hh = [int]$past[0].heads; if ($null -ne $a -and $hh -ge 2) { 0.5 - ($a - 1.0) / ($hh - 1.0) } else { 0 } } else { 0 }
    $hs += , $f
    $y += ($(if ($fin["$($h.number)"] -eq "1") { 1 } else { 0 }))
  }
  if (($y | Measure-Object -Sum).Sum -ne 1) { continue }
  $races += [pscustomobject]@{ id = $id; nums = @($q.horses | ForEach-Object { $_.number }); F = $hs; y = $y; train = [bool]$trainIds[$id] }
}
$tr = @($races | Where-Object { $_.train }); $ho = @($races | Where-Object { -not $_.train })
Write-Host ("学習 {0}レース / 試験 {1}レース" -f $tr.Count, $ho.Count)

function Probs($R, $w) {
  $n = $R.F.Count; $z = New-Object double[] $n; $mx = -1e9
  for ($i = 0; $i -lt $n; $i++) { $s = 0.0; for ($k = 0; $k -lt $NF; $k++) { $s += $w[$k] * $R.F[$i][$k] }; $z[$i] = $s; if ($s -gt $mx) { $mx = $s } }
  $e = New-Object double[] $n; $sum = 0.0
  for ($i = 0; $i -lt $n; $i++) { $e[$i] = [math]::Exp($z[$i] - $mx); $sum += $e[$i] }
  for ($i = 0; $i -lt $n; $i++) { $e[$i] /= $sum }
  return , $e
}
# 勾配上昇（L2 で過学習を抑える）
$w = New-Object double[] $NF; $w[0] = 1.0
$lr = 0.5; $l2 = 0.02
for ($it = 0; $it -lt 400; $it++) {
  $g = New-Object double[] $NF
  foreach ($R in $tr) {
    $p = Probs $R $w
    for ($i = 0; $i -lt $p.Count; $i++) {
      $d = $R.y[$i] - $p[$i]
      for ($k = 0; $k -lt $NF; $k++) { $g[$k] += $d * $R.F[$i][$k] }
    }
  }
  for ($k = 0; $k -lt $NF; $k++) { $w[$k] += $lr * ($g[$k] / $tr.Count - $l2 * $w[$k]) }
}
$lines = @(); for ($k = 0; $k -lt $NF; $k++) { $lines += ("{0}\t{1:0.000}" -f $names[$k], $w[$k]) }
$lines | ForEach-Object { Write-Host $_ }
[IO.File]::WriteAllLines((Join-Path $root "model_weights.txt"), $lines, (New-Object Text.UTF8Encoding($true)))

# 対数尤度（高いほど良い）：人気だけ vs 全部の数字
function LL($set, $w) { $s = 0.0; foreach ($R in $set) { $p = Probs $R $w; for ($i = 0; $i -lt $p.Count; $i++) { if ($R.y[$i] -eq 1) { $s += [math]::Log([math]::Max($p[$i], 1e-9)) } } }; return $s / $set.Count }
$wp = New-Object double[] $NF; $wp[0] = 1.0
Write-Host ("1レースあたりの対数尤度（試験）：人気だけ={0:0.000} / 数字モデル={1:0.000}" -f (LL $ho $wp), (LL $ho $w))

foreach ($R in $races) {
  $p = Probs $R $w
  $idx = 0..($p.Count - 1) | Sort-Object { -$p[$_] }
  $marks = @($idx | Select-Object -First 5 | ForEach-Object { $R.nums[$_] })
  $o = [ordered]@{ race = $R.id; stage = "最終"; model = "数字モデル"; confidence = "-"; marks = $marks; win_pct = [math]::Round(100 * $p[$idx[0]], 1); split = $(if ($R.train) { "train" } else { "hold" }) }
  [IO.File]::WriteAllText((Join-Path $outDir ($R.id + "_最終.json")), ($o | ConvertTo-Json), $utf8)
}
