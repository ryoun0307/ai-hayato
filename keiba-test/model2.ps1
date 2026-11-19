# 数字モデル2：能力（上がり・タイム差・着順）、適性、展開、騎手・調教師、人気（比重は学習で決まる）を点数にして勝ちやすさを計算する。
#   powershell -ExecutionPolicy Bypass -File model2.ps1 [-PopScale 1.0]
#   学習：予想済みの218レース（predictions にあるレース）／試験：それ以外の障害を除くレース
# 出力：predictions_model2\日付_場_R_最終.json（印5頭、split=train/hold）、model2_weights.txt
param([double]$PopFix = 0, [string]$OutDir = "predictions_model2")
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$qdir = Join-Path $root "data\question10"
$outDirP = Join-Path $root $OutDir; New-Item -ItemType Directory -Force $outDirP | Out-Null

function Num($s) { if ("$s" -match '^\d+$') { return [int]$s } else { return $null } }
function Clip($x, $lo, $hi) { if ($x -lt $lo) { return $lo } elseif ($x -gt $hi) { return $hi } else { return $x } }
function Sec([string]$t) { $m = [regex]::Match($t, '^(\d+):(\d+\.\d)$'); if ($m.Success) { return 60 * [int]$m.Groups[1].Value + [double]$m.Groups[2].Value } else { return $null } }
function Shrink([int]$hit, [int]$n, [double]$prior, [double]$k) { return (($hit + $prior * $k) / ($n + $k)) - $prior }

$trainIds = @{}
foreach ($f in Get-ChildItem (Join-Path $root "predictions") -Filter *_最終.json) { $trainIds[($f.BaseName -replace "_最終$", "")] = $true }

# ---- 過去レースの結果（上がり・通過順位・タイム）を読み込む ----
$pr = @{}
foreach ($f in Get-ChildItem (Join-Path $root "data\pastrace") -Filter *.json) {
  $o = [IO.File]::ReadAllText($f.FullName, $utf8) | ConvertFrom-Json
  $hs = @($o.horses)
  $tmin = 1e9; foreach ($h in $hs) { if ($h.finish -eq "1") { $s = Sec $h.time; if ($null -ne $s) { $tmin = [math]::Min($tmin, $s) } } }
  $l3 = @($hs | Where-Object { $_.last3f -match '^\d+\.\d$' } | ForEach-Object { [double]$_.last3f } | Sort-Object)
  $map = @{}
  foreach ($h in $hs) {
    $nm = $h.name -replace '\s.*$', ''
    $s = Sec $h.time
    $td = if ($null -ne $s -and $tmin -lt 1e8) { $s - $tmin } else { $null }
    $lr = $null; if ($h.last3f -match '^\d+\.\d$' -and $l3.Count -gt 1) { $rk = @($l3 | Where-Object { $_ -lt [double]$h.last3f }).Count; $lr = $rk / [double]($l3.Count - 1) }
    $er = $null; if ($h.corner -match '^(\d+)') { $er = ([int]$Matches[1] - 1.0) / [math]::Max($hs.Count - 1, 1) }
    $map[$nm] = @{ td = $td; lr = $lr; er = $er }
  }
  $pr[$o.race.cname] = $map
}
Write-Host ("過去レース結果：{0}件" -f $pr.Count)

# ---- 馬のページの控えから「日付→結果ページの印」 ----
function RunLinks([string]$jraId) {
  $cf = Join-Path $root ("cache\horse_" + ($jraId -replace '[^0-9A-Za-z]', '_') + ".html")
  $html = [IO.File]::ReadAllText($cf, $utf8); $i = $html.IndexOf("出走レース"); $d = @{}
  if ($i -lt 0) { return $d }
  foreach ($m in [regex]::Matches($html.Substring($i), '<td class="date">(\d+)年(\d+)月(\d+)日</td>.*?CNAME=(pw01sde10[0-9A-F/]+)', 'Singleline')) {
    $k = "{0:0000}{1:00}{2:00}" -f [int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value
    if (-not $d.ContainsKey($k)) { $d[$k] = $m.Groups[4].Value }
  }
  return $d
}

# ---- 騎手・調教師の成績表（そのレース日より前だけを使う） ----
$qs = @{}
foreach ($qf in Get-ChildItem $qdir -Filter *.json) { $qs[$qf.BaseName] = [IO.File]::ReadAllText($qf.FullName, $utf8) | ConvertFrom-Json }
$jk = @{}; $seen = @{}
foreach ($q in $qs.Values) { foreach ($h in $q.horses) { foreach ($p in $h.past_runs) {
  $k = $h.jra_id + $p.date; if ($seen[$k]) { continue }; $seen[$k] = $true
  $fn = Num $p.finish; if ($null -eq $fn) { continue }
  $j = ("$($p.jockey)" -replace '\s', ''); if (-not $jk[$j]) { $jk[$j] = New-Object Collections.ArrayList }
  [void]$jk[$j].Add(@($p.date, $fn))
} } }
$tk = @{}
foreach ($id in ($qs.Keys | Sort-Object)) {
  $q = $qs[$id]
  $af = [IO.File]::ReadAllText((Join-Path $root ("data\answer\" + $id + ".json")), $utf8) | ConvertFrom-Json
  $fin = @{}; foreach ($x in $af.results) { $fin["$($x.number)"] = Num $x.finish }
  foreach ($h in $q.horses) { $fn = $fin["$($h.number)"]; if ($null -eq $fn) { continue }
    $t = "$($h.trainer)" -replace '\s', ''; if (-not $tk[$t]) { $tk[$t] = New-Object Collections.ArrayList }
    [void]$tk[$t].Add(@($q.race.date, $fn)) }
}
function Rate($list, [string]$before) { $n = 0; $h = 0; if ($list) { foreach ($e in $list) { if ($e[0] -lt $before) { $n++; if ($e[1] -le 3) { $h++ } } } }; return @($n, $h) }

$NF = 14
$names = @("人気(-ln)", "近5走の着順率", "近10走の3着内率", "近走の上がり順位", "近走のタイム差", "同距離・同芝ダの3着内率", "同競馬場の3着内率", "同馬場状態の3着内率", "脚質×展開", "騎手の3着内率", "調教師の3着内率", "休養(log日数)", "馬体重の大増減", "前走の着順率")
$races = @()
foreach ($id in ($qs.Keys | Sort-Object)) {
  $q = $qs[$id]
  if ($q.race.category -like "障害*") { continue }
  $af = [IO.File]::ReadAllText((Join-Path $root ("data\answer\" + $id + ".json")), $utf8) | ConvertFrom-Json
  $cm = [regex]::Match($q.race.course, '([\d,]+)\s*メートル\s*（(芝|ダート)')
  $dist = [int]($cm.Groups[1].Value -replace ',', ''); $surf = if ($cm.Groups[2].Value -eq "芝") { "芝" } else { "ダ" }
  $rdate = $q.race.date; $rd = [datetime]::ParseExact($rdate, "yyyyMMdd", $null)
  $fin = @{}; foreach ($x in $af.results) { $fin["$($x.number)"] = "$($x.finish)" }
  $raw = @()
  foreach ($h in $q.horses) {
    $links = RunLinks $h.jra_id
    $past = @($h.past_runs)
    $r5 = @(); $t3 = 0; $n = 0; $sc = 0; $st = 0; $vc = 0; $vt = 0; $gc = 0; $gt = 0; $lr5 = @(); $td5 = @(); $er5 = @()
    foreach ($p in $past) {
      $fn = Num $p.finish; $hd = [int]$p.heads
      if ($null -eq $fn -or $hd -lt 2) { continue }
      $n++; $ratio = ($fn - 1.0) / ($hd - 1.0)
      if ($n -le 5) { $r5 += $ratio
        $lk = $links[$p.date]; $m = $null; if ($lk) { $m = $pr[$lk] }
        if ($m) { $e = $m[("$($h.name)" -replace '\s.*$', '')]
          if ($e) { if ($null -ne $e.lr) { $lr5 += $e.lr }; if ($null -ne $e.td) { $td5 += (Clip $e.td 0 4) }; if ($null -ne $e.er) { $er5 += $e.er } } } }
      if ($fn -le 3) { $t3++ }
      $pm = [regex]::Match($p.distance, '^(芝|ダ)(\d+)')
      if ($pm.Success -and $pm.Groups[1].Value -eq $surf -and [math]::Abs([int]$pm.Groups[2].Value - $dist) -le 200) { $sc++; if ($fn -le 3) { $st++ } }
      if ($p.venue -eq $q.race.venue) { $vc++; if ($fn -le 3) { $vt++ } }
      $g1 = ("$($p.going)" -split '/')[0]; $good = ($g1 -eq "良"); $tg = ("$($q.race.track_condition)" -match '(良)') -and ("$($q.race.track_condition)" -notmatch '稍重|重|不良')
      if ($good -eq $tg) { $gc++; if ($fn -le 3) { $gt++ } }
    }
    $pop = [int]$h.final.popularity; if ($pop -lt 1) { $pop = 10 }
    $early = if ($er5.Count) { ($er5 | Measure-Object -Average).Average } else { $null }
    $raw += [pscustomobject]@{ h = $h; pop = $pop; n = $n; r5 = $r5; t3 = $t3; lr5 = $lr5; td5 = $td5; early = $early; sc = $sc; st = $st; vc = $vc; vt = $vt; gc = $gc; gt = $gt }
  }
  $nFront = @($raw | Where-Object { $null -ne $_.early -and $_.early -lt 0.3 }).Count
  $hsF = @(); $y = @(); $nums = @()
  foreach ($x in $raw) {
    $h = $x.h; $f = New-Object double[] $NF
    $f[0] = -[math]::Log($x.pop)
    $f[1] = if ($x.r5.Count) { 0.5 - ($x.r5 | Measure-Object -Average).Average } else { 0 }
    $f[2] = (($x.t3 + 0.25 * 2) / ($x.n + 2)) - 0.25
    $f[3] = if ($x.lr5.Count) { 0.5 - ($x.lr5 | Measure-Object -Average).Average } else { 0 }
    $f[4] = if ($x.td5.Count) { 0.8 - ($x.td5 | Measure-Object -Average).Average } else { 0 }
    $f[5] = Shrink $x.st $x.sc 0.25 2
    $f[6] = Shrink $x.vt $x.vc 0.25 2
    $f[7] = Shrink $x.gt $x.gc 0.25 2
    $f[8] = if ($null -ne $x.early) { ($x.early - 0.5) * (($nFront - 3) / 3.0) } else { 0 }
    $jr = Rate $jk[("$($h.jockey)" -replace '\s', '')] $rdate; $f[9] = Shrink $jr[1] $jr[0] 0.25 20
    $tr = Rate $tk[("$($h.trainer)" -replace '\s', '')] $rdate; $f[10] = Shrink $tr[1] $tr[0] 0.25 20
    $rest = 60; if ($x.n) { $rest = ($rd - [datetime]::ParseExact($h.past_runs[0].date, "yyyyMMdd", $null)).TotalDays }
    $f[11] = [math]::Log([math]::Max($rest, 7)) - [math]::Log(35)
    $bd = $null; if ("$($h.final.body_weight_diff)" -match '^[+-]?\d+$') { $bd = [int]($h.final.body_weight_diff -replace '^\+', '') }
    $f[12] = if ($null -ne $bd -and [math]::Abs($bd) -ge 10) { 1 } else { 0 }
    $f[13] = if ($h.past_runs.Count) { $a = Num $h.past_runs[0].finish; $hh = [int]$h.past_runs[0].heads; if ($null -ne $a -and $hh -ge 2) { 0.5 - ($a - 1.0) / ($hh - 1.0) } else { 0 } } else { 0 }
    $hsF += , $f; $nums += $h.number; $y += ($(if ($fin["$($h.number)"] -eq "1") { 1 } else { 0 }))
  }
  if (($y | Measure-Object -Sum).Sum -ne 1) { continue }
  $races += [pscustomobject]@{ id = $id; nums = $nums; F = $hsF; y = $y; train = [bool]$trainIds[$id] }
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
$w = New-Object double[] $NF; $w[0] = $(if ($PopFix -gt 0) { $PopFix } else { 1.0 })
$lr = 0.5; $l2 = 0.02
for ($it = 0; $it -lt 400; $it++) {
  $g = New-Object double[] $NF
  foreach ($R in $tr) { $p = Probs $R $w
    for ($i = 0; $i -lt $p.Count; $i++) { $d = $R.y[$i] - $p[$i]; for ($k = 0; $k -lt $NF; $k++) { $g[$k] += $d * $R.F[$i][$k] } } }
  for ($k = $(if ($PopFix -gt 0) { 1 } else { 0 }); $k -lt $NF; $k++) { $w[$k] += $lr * ($g[$k] / $tr.Count - $l2 * $w[$k]) }
}
# 比重の目安：特徴量のばらつき（標準偏差）×重みの絶対値を、全体に対する割合にする
$share = New-Object double[] $NF; $tot = 0.0
$all = @($races | ForEach-Object { $_.F })
for ($k = 0; $k -lt $NF; $k++) { $v = @($all | ForEach-Object { $_[$k] }); $m = ($v | Measure-Object -Average).Average; $sd = [math]::Sqrt((($v | ForEach-Object { ($_ - $m) * ($_ - $m) }) | Measure-Object -Average).Average); $share[$k] = [math]::Abs($w[$k]) * $sd; $tot += $share[$k] }
$lines = @(); for ($k = 0; $k -lt $NF; $k++) { $lines += ("{0}  重み{1:0.000}  比重{2:0}%" -f $names[$k], $w[$k], (100 * $share[$k] / $tot)) }
$lines | ForEach-Object { Write-Host $_ }
[IO.File]::WriteAllLines((Join-Path $root "model2_weights.txt"), $lines, (New-Object Text.UTF8Encoding($true)))

function LL($set, $w) { $s = 0.0; foreach ($R in $set) { $p = Probs $R $w; for ($i = 0; $i -lt $p.Count; $i++) { if ($R.y[$i] -eq 1) { $s += [math]::Log([math]::Max($p[$i], 1e-9)) } } }; return $s / $set.Count }
$wp = New-Object double[] $NF; $wp[0] = 1.0
Write-Host ("1レースあたりの対数尤度（試験）：人気だけ={0:0.000} / 数字モデル2={1:0.000}" -f (LL $ho $wp), (LL $ho $w))

foreach ($R in $races) {
  $p = Probs $R $w
  $idx = 0..($p.Count - 1) | Sort-Object { -$p[$_] }
  $marks = @($idx | Select-Object -First 5 | ForEach-Object { $R.nums[$_] })
  $o = [ordered]@{ race = $R.id; stage = "最終"; model = "数字モデル2"; confidence = "-"; marks = $marks; win_pct = [math]::Round(100 * $p[$idx[0]], 1); split = $(if ($R.train) { "train" } else { "hold" }) }
  [IO.File]::WriteAllText((Join-Path $outDirP ($R.id + "_最終.json")), ($o | ConvertTo-Json), $utf8)
}
