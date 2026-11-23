# 数字モデル5（試験）：model2/3 の項目に「ポテンシャル（実力の片鱗）」の項目を足して、交差検証で比べる。
#   powershell -ExecutionPolicy Bypass -File model5.ps1 [-Folds 5] [-Repeats 2]
# 本番（weekend）は変えない。試験用。結果：model5_cv.md / model5_cv.txt
#
# ポテンシャル（過去10走ぜんぶ。新馬戦を含む。そのレース日より前の走だけ）
#   各走の「良さ」＝上がり順位（速いほど1）・勝ち馬とのタイム差（小さいほど1）・着順率（上位ほど1）
#   14 上がり3Fのベスト3走の平均 / 15 タイム差のベスト3走の平均 / 16 着順のベスト3走の平均
#   17 ベスト1走の上がり（ものすごい末脚が1回でもあるか）
#   18 良い走り（総合0.65以上）の割合 / 19 良い走り−悪い走り（総合0.35以下）の差の割合
#   20 良い半分の走りの平均−悪い半分の走りの平均
param([int]$Folds = 5, [int]$Repeats = 2, [int]$Iter = 150)
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$qdir = Join-Path $root "data\question10"

Add-Type -TypeDefinition @"
using System;
public static class Fit {
  // 条件付きロジット（レース内の softmax）を勾配上昇で学習する
  public static double[] Train(double[][][] F, int[][] Y, bool[] mask, double popFix, int iter) {
    int nf = mask.Length; double[] w = new double[nf];
    if (mask[0]) w[0] = popFix > 0 ? popFix : 1.0;
    int R = F.Length;
    for (int it = 0; it < iter; it++) {
      double[] g = new double[nf];
      for (int r = 0; r < R; r++) {
        int n = F[r].Length; double[] z = new double[n]; double mx = -1e9;
        for (int i = 0; i < n; i++) { double s = 0; for (int k = 0; k < nf; k++) if (mask[k]) s += w[k] * F[r][i][k]; z[i] = s; if (s > mx) mx = s; }
        double sum = 0; for (int i = 0; i < n; i++) { z[i] = Math.Exp(z[i] - mx); sum += z[i]; }
        for (int i = 0; i < n; i++) { double p = z[i] / sum; double d = Y[r][i] - p; for (int k = 0; k < nf; k++) if (mask[k]) g[k] += d * F[r][i][k]; }
      }
      for (int k = 0; k < nf; k++) { if (!mask[k]) continue; if (k == 0 && popFix > 0) continue; w[k] += 1.0 * (g[k] / R - 0.02 * w[k]); }
    }
    return w;
  }
  public static double[] Score(double[][] Fr, double[] w, bool[] mask) {
    int n = Fr.Length; double[] z = new double[n];
    for (int i = 0; i < n; i++) { double s = 0; for (int k = 0; k < w.Length; k++) if (mask[k]) s += w[k] * Fr[i][k]; z[i] = s; }
    return z;
  }
}
"@

function Num($s) { if ("$s" -match '^\d+$') { return [int]$s } else { return $null } }
function Clip($x, $lo, $hi) { if ($x -lt $lo) { return $lo } elseif ($x -gt $hi) { return $hi } else { return $x } }
function Sec([string]$t) { $m = [regex]::Match($t, '^(\d+):(\d+\.\d)$'); if ($m.Success) { return 60 * [int]$m.Groups[1].Value + [double]$m.Groups[2].Value } else { return $null } }
function Shrink([int]$hit, [int]$n, [double]$prior, [double]$k) { return (($hit + $prior * $k) / ($n + $k)) - $prior }
function Avg($a) { if (@($a).Count) { return (@($a) | Measure-Object -Average).Average } else { return $null } }
function StableHash([string]$s) { $h = 7; foreach ($c in $s.ToCharArray()) { $h = (($h * 31) + [int]$c) % 1000003 }; return $h }

# ---- 過去レースの結果（上がり・通過順位・タイム）を読み込む ----
$pr = @{}
foreach ($pf in Get-ChildItem (Join-Path $root "data\pastrace") -Filter *.json) {
  $o = [IO.File]::ReadAllText($pf.FullName, $utf8) | ConvertFrom-Json
  $hs = @($o.horses)
  $tmin = 1e9; foreach ($hh in $hs) { if ($hh.finish -eq "1") { $s = Sec $hh.time; if ($null -ne $s) { $tmin = [math]::Min($tmin, $s) } } }
  $l3 = @($hs | Where-Object { $_.last3f -match '^\d+\.\d$' } | ForEach-Object { [double]$_.last3f } | Sort-Object)
  $map = @{}
  foreach ($hh in $hs) {
    $nm = $hh.name -replace '\s.*$', ''
    $s = Sec $hh.time
    $td = if ($null -ne $s -and $tmin -lt 1e8) { $s - $tmin } else { $null }
    $lr = $null; if ($hh.last3f -match '^\d+\.\d$' -and $l3.Count -gt 1) { $rk = @($l3 | Where-Object { $_ -lt [double]$hh.last3f }).Count; $lr = $rk / [double]($l3.Count - 1) }
    $er = $null; if ($hh.corner -match '^(\d+)') { $er = ([int]$Matches[1] - 1.0) / [math]::Max($hs.Count - 1, 1) }
    $map[$nm] = @{ td = $td; lr = $lr; er = $er }
  }
  $pr[$o.race.cname] = $map
}
Write-Host ("過去レース結果：{0}件" -f $pr.Count)

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
foreach ($q in $qs.Values) { foreach ($hh in $q.horses) { foreach ($p in $hh.past_runs) {
  $k = $hh.jra_id + $p.date; if ($seen[$k]) { continue }; $seen[$k] = $true
  $fn = Num $p.finish; if ($null -eq $fn) { continue }
  $j = ("$($p.jockey)" -replace '\s', ''); if (-not $jk[$j]) { $jk[$j] = New-Object Collections.ArrayList }
  [void]$jk[$j].Add(@($p.date, $fn))
} } }
$tk = @{}; $ans = @{}
foreach ($id in ($qs.Keys | Sort-Object)) {
  $q = $qs[$id]
  $af = [IO.File]::ReadAllText((Join-Path $root ("data\answer\" + $id + ".json")), $utf8) | ConvertFrom-Json
  $ans[$id] = $af
  $fin = @{}; foreach ($x in $af.results) { $fin["$($x.number)"] = Num $x.finish }
  foreach ($hh in $q.horses) { $fn = $fin["$($hh.number)"]; if ($null -eq $fn) { continue }
    $t = "$($hh.trainer)" -replace '\s', ''; if (-not $tk[$t]) { $tk[$t] = New-Object Collections.ArrayList }
    [void]$tk[$t].Add(@($q.race.date, $fn)) }
}
function Rate($list, [string]$before) { $n = 0; $hit = 0; if ($list) { foreach ($e in $list) { if ($e[0] -lt $before) { $n++; if ($e[1] -le 3) { $hit++ } } } }; return @($n, $hit) }

$NF = 21
$names = @("人気(-ln)", "近5走の着順率", "近10走の3着内率", "近走の上がり順位", "近走のタイム差", "同距離・同芝ダの3着内率", "同競馬場の3着内率", "同馬場状態の3着内率", "脚質×展開", "騎手の3着内率", "調教師の3着内率", "休養(log日数)", "馬体重の大増減", "前走の着順率",
  "上がり3Fのベスト3走平均", "タイム差のベスト3走平均", "着順のベスト3走平均", "ベスト1走の上がり", "良い走りの割合", "良い走り−悪い走りの割合", "良い半分−悪い半分の平均")
# 項目のグループ（比重の集計用）
$group = @("人気", "実力", "実力", "実力", "実力", "適性", "適性", "適性", "適性", "騎手・調教師", "騎手・調教師", "適性", "適性", "実力",
  "ポテンシャル", "ポテンシャル", "ポテンシャル", "ポテンシャル", "ポテンシャル", "ポテンシャル", "ポテンシャル")

function Best3([double[]]$vals) {   # 良い順に3走の平均（3走に足りない分は 0.5＝ふつう で埋める）
  $m = $vals.Count; if ($m -eq 0) { return 0.0 }
  $top = @($vals | Sort-Object -Descending | Select-Object -First 3); $s = 0.0; foreach ($x in $top) { $s += $x }
  return (($s + 0.5 * [math]::Max(0, 3 - $m)) / 3.0) - 0.5
}

$races = @()
foreach ($id in ($qs.Keys | Sort-Object)) {
  $q = $qs[$id]
  if ($q.race.category -like "障害*") { continue }
  $af = $ans[$id]
  $cm = [regex]::Match($q.race.course, '([\d,]+)\s*メートル\s*（(芝|ダート)')
  $dist = [int]($cm.Groups[1].Value -replace ',', ''); $surf = if ($cm.Groups[2].Value -eq "芝") { "芝" } else { "ダ" }
  $rdate = $q.race.date; $rd = [datetime]::ParseExact($rdate, "yyyyMMdd", $null)
  $fin = @{}; foreach ($x in $af.results) { $fin["$($x.number)"] = "$($x.finish)" }
  $raw = @()
  foreach ($hh in $q.horses) {
    $links = RunLinks $hh.jra_id
    $past = @($hh.past_runs)
    $r5 = @(); $t3 = 0; $n = 0; $sc = 0; $st = 0; $vc = 0; $vt = 0; $gc = 0; $gt = 0; $lr5 = @(); $td5 = @(); $er5 = @()
    $qL = New-Object Collections.ArrayList; $qT = New-Object Collections.ArrayList; $qF = New-Object Collections.ArrayList; $qC = New-Object Collections.ArrayList
    foreach ($p in $past) {
      $fn = Num $p.finish; $hd = [int]$p.heads
      if ($null -eq $fn -or $hd -lt 2) { continue }
      $n++; $ratio = ($fn - 1.0) / ($hd - 1.0)
      $lk = $links[$p.date]; $mp = $null; if ($lk) { $mp = $pr[$lk] }
      $e = $null; if ($mp) { $e = $mp[("$($hh.name)" -replace '\s.*$', '')] }
      # ポテンシャル用：10走ぜんぶ
      $one = @(); $qf1 = 1.0 - $ratio; [void]$qF.Add($qf1); $one += $qf1
      if ($e -and $null -ne $e.lr) { $qlv = 1.0 - $e.lr; [void]$qL.Add($qlv); $one += $qlv }
      if ($e -and $null -ne $e.td) { $qtv = 1.0 - (Clip $e.td 0 4) / 4.0; [void]$qT.Add($qtv); $one += $qtv }
      [void]$qC.Add((Avg $one))
      if ($n -le 5) { $r5 += $ratio
        if ($e) { if ($null -ne $e.lr) { $lr5 += $e.lr }; if ($null -ne $e.td) { $td5 += (Clip $e.td 0 4) }; if ($null -ne $e.er) { $er5 += $e.er } } }
      if ($fn -le 3) { $t3++ }
      $pm = [regex]::Match($p.distance, '^(芝|ダ)(\d+)')
      if ($pm.Success -and $pm.Groups[1].Value -eq $surf -and [math]::Abs([int]$pm.Groups[2].Value - $dist) -le 200) { $sc++; if ($fn -le 3) { $st++ } }
      if ($p.venue -eq $q.race.venue) { $vc++; if ($fn -le 3) { $vt++ } }
      $g1 = ("$($p.going)" -split '/')[0]; $good = ($g1 -eq "良"); $tg = ("$($q.race.track_condition)" -match '(良)') -and ("$($q.race.track_condition)" -notmatch '稍重|重|不良')
      if ($good -eq $tg) { $gc++; if ($fn -le 3) { $gt++ } }
    }
    $pop = [int]$hh.final.popularity; if ($pop -lt 1) { $pop = 10 }
    $early = if ($er5.Count) { ($er5 | Measure-Object -Average).Average } else { $null }
    $raw += [pscustomobject]@{ h = $hh; pop = $pop; n = $n; r5 = $r5; t3 = $t3; lr5 = $lr5; td5 = $td5; early = $early; sc = $sc; st = $st; vc = $vc; vt = $vt; gc = $gc; gt = $gt
      qL = [double[]]@($qL); qT = [double[]]@($qT); qF = [double[]]@($qF); qC = [double[]]@($qC) }
  }
  $nFront = @($raw | Where-Object { $null -ne $_.early -and $_.early -lt 0.3 }).Count
  $FR = New-Object 'double[][]' $raw.Count; $yv = New-Object int[] $raw.Count; $rank = New-Object int[] $raw.Count; $nums = @(); $ix = 0
  foreach ($x in $raw) {
    $hh = $x.h; $fv = New-Object double[] $NF
    $fv[0] = -[math]::Log($x.pop)
    $fv[1] = if ($x.r5.Count) { 0.5 - ($x.r5 | Measure-Object -Average).Average } else { 0 }
    $fv[2] = (($x.t3 + 0.25 * 2) / ($x.n + 2)) - 0.25
    $fv[3] = if ($x.lr5.Count) { 0.5 - ($x.lr5 | Measure-Object -Average).Average } else { 0 }
    $fv[4] = if ($x.td5.Count) { 0.8 - ($x.td5 | Measure-Object -Average).Average } else { 0 }
    $fv[5] = Shrink $x.st $x.sc 0.25 2
    $fv[6] = Shrink $x.vt $x.vc 0.25 2
    $fv[7] = Shrink $x.gt $x.gc 0.25 2
    $fv[8] = if ($null -ne $x.early) { ($x.early - 0.5) * (($nFront - 3) / 3.0) } else { 0 }
    $jr = Rate $jk[("$($hh.jockey)" -replace '\s', '')] $rdate; $fv[9] = Shrink $jr[1] $jr[0] 0.25 20
    $tr = Rate $tk[("$($hh.trainer)" -replace '\s', '')] $rdate; $fv[10] = Shrink $tr[1] $tr[0] 0.25 20
    $rest = 60; if ($x.n) { $rest = ($rd - [datetime]::ParseExact($hh.past_runs[0].date, "yyyyMMdd", $null)).TotalDays }
    $fv[11] = [math]::Log([math]::Max($rest, 7)) - [math]::Log(35)
    $bd = $null; if ("$($hh.final.body_weight_diff)" -match '^[+-]?\d+$') { $bd = [int]($hh.final.body_weight_diff -replace '^\+', '') }
    $fv[12] = if ($null -ne $bd -and [math]::Abs($bd) -ge 10) { 1 } else { 0 }
    $fv[13] = if ($hh.past_runs.Count) { $a = Num $hh.past_runs[0].finish; $h2 = [int]$hh.past_runs[0].heads; if ($null -ne $a -and $h2 -ge 2) { 0.5 - ($a - 1.0) / ($h2 - 1.0) } else { 0 } } else { 0 }
    # ---- ポテンシャル ----
    $fv[14] = Best3 $x.qL
    $fv[15] = Best3 $x.qT
    $fv[16] = Best3 $x.qF
    $fv[17] = if ($x.qL.Count) { (($x.qL | Measure-Object -Maximum).Maximum) - 0.5 } else { 0 }
    $mC = $x.qC.Count
    $goodN = @($x.qC | Where-Object { $_ -ge 0.65 }).Count; $badN = @($x.qC | Where-Object { $_ -le 0.35 }).Count
    $fv[18] = (($goodN + 0.25 * 2) / ($mC + 2)) - 0.25
    $fv[19] = ($goodN - $badN) / [double]($mC + 2)
    if ($mC -ge 2) { $sr = @($x.qC | Sort-Object -Descending); $half = [int][math]::Floor($mC / 2); $topH = Avg @($sr | Select-Object -First $half); $botH = Avg @($sr | Select-Object -Last $half); $fv[20] = ($topH - $botH) * ($mC / ($mC + 2.0)) - 0.3 } else { $fv[20] = 0 }
    $FR[$ix] = $fv; $nums += $hh.number
    $yv[$ix] = $(if ($fin["$($hh.number)"] -eq "1") { 1 } else { 0 })
    $rk0 = Num $fin["$($hh.number)"]; $rank[$ix] = $(if ($null -ne $rk0) { $rk0 } else { 99 }); $ix++
  }
  if (($yv | Measure-Object -Sum).Sum -ne 1) { continue }
  # 払戻金（◎への単勝・複勝、馬連）
  $pay = $af.payouts; $tan = @{}; $fuk = @{}; $uma = @{}
  foreach ($l in @($pay.tansho)) { $tan["$($l.combo)"] = [int]$l.yen }
  foreach ($l in @($pay.fukusho)) { $fuk["$($l.combo)"] = [int]$l.yen }
  foreach ($l in @($pay.umaren)) { $c = (@("$($l.combo)" -split '-' | ForEach-Object { [int]$_ } | Sort-Object) -join "-"); $uma[$c] = [int]$l.yen }
  $races += [pscustomobject]@{ id = $id; nums = $nums; F = $FR; y = $yv; rank = $rank; tan = $tan; fuk = $fuk; uma = $uma }
}
Write-Host ("レース数：{0}" -f $races.Count)

function MaskOf([int[]]$on) { $m = New-Object bool[] $NF; foreach ($k in $on) { $m[$k] = $true }; return , $m }
$base14 = @(0..13); $pot = @(14..20)
$variants = [ordered]@{
  "人気順そのまま"                  = @{ kind = "pop" }
  "A model2相当（14項目）"         = @{ mask = (MaskOf $base14); fix = 0 }
  "B model2＋ポテンシャル（21項目）"  = @{ mask = (MaskOf (@(0..20))); fix = 0 }
  "C B＋人気を弱めに固定（重み0.4）"  = @{ mask = (MaskOf (@(0..20))); fix = 0.4 }
  "D B＋人気を弱めに固定（重み0.25）" = @{ mask = (MaskOf (@(0..20))); fix = 0.25 }
  "E 人気＋ポテンシャルだけ"         = @{ mask = (MaskOf (@(0) + $pot)); fix = 0 }
  "F 人気＋実力＋ポテンシャル"        = @{ mask = (MaskOf (@(0, 1, 2, 3, 4, 13) + $pot)); fix = 0 }
}
# 全レースの項目のばらつき（比重の計算用）
$sdK = New-Object double[] $NF
for ($k = 0; $k -lt $NF; $k++) { $v = @(); foreach ($RR in $races) { foreach ($row in $RR.F) { $v += $row[$k] } }; $mu = ($v | Measure-Object -Average).Average; $sdK[$k] = [math]::Sqrt((($v | ForEach-Object { ($_ - $mu) * ($_ - $mu) }) | Measure-Object -Average).Average) }

function Metrics($RR, $score) {
  $idx = @(0..($score.Count - 1) | Sort-Object { -$score[$_] })
  $top = @($idx | Select-Object -First 5); $rk = $RR.rank
  $win = [int]($RR.y[$top[0]] -eq 1); $t3 = [int]($rk[$top[0]] -le 3); $c3 = @($top | Where-Object { $rk[$_] -le 3 }).Count
  $q12 = [int](($rk[$top[0]] -le 2) -and ($rk[$top[1]] -le 2))
  $hon = "$($RR.nums[$top[0]])"
  $tanY = [int]$RR.tan[$hon]; $fukY = [int]$RR.fuk[$hon]
  $u3 = 0; foreach ($j in 1..3) { $c = (@([int]$RR.nums[$top[0]], [int]$RR.nums[$top[$j]]) | Sort-Object) -join "-"; $u3 += [int]$RR.uma[$c] }
  $uB = 0; for ($a = 0; $a -lt 4; $a++) { for ($b = $a + 1; $b -lt 4; $b++) { $c = (@([int]$RR.nums[$top[$a]], [int]$RR.nums[$top[$b]]) | Sort-Object) -join "-"; $uB += [int]$RR.uma[$c] } }
  return @($win, $t3, $c3, $q12, $tanY, $fukY, $u3, $uB, [int]($u3 -gt 0), [int]($uB -gt 0))
}

$out = @(); $wavg = @{}
foreach ($vn in $variants.Keys) {
  $v = $variants[$vn]; $acc = New-Object double[] 10; $cnt = 0
  $wsum = New-Object double[] $NF; $wn = 0
  for ($rep = 0; $rep -lt $Repeats; $rep++) {
    $shuf = @($races | Sort-Object { StableHash ($_.id + "#" + $rep) })
    $fold = @{}; for ($i = 0; $i -lt $shuf.Count; $i++) { $fold[$shuf[$i].id] = $i % $Folds }
    for ($fo = 0; $fo -lt $Folds; $fo++) {
      $trn = @($races | Where-Object { $fold[$_.id] -ne $fo }); $tst = @($races | Where-Object { $fold[$_.id] -eq $fo })
      $wv = $null
      if ($v.kind -ne "pop") {
        $FA = New-Object 'double[][][]' $trn.Count; $YA = New-Object 'int[][]' $trn.Count
        for ($i = 0; $i -lt $trn.Count; $i++) { $FA[$i] = $trn[$i].F; $YA[$i] = $trn[$i].y }
        $wv = [Fit]::Train($FA, $YA, [bool[]]$v.mask, [double]$v.fix, $Iter)
        for ($k = 0; $k -lt $NF; $k++) { $wsum[$k] += $wv[$k] }; $wn++
      }
      foreach ($RR in $tst) {
        if ($wv) { $sc = [Fit]::Score($RR.F, $wv, [bool[]]$v.mask) } else { $sc = @($RR.F | ForEach-Object { $_[0] }) }
        $mm = Metrics $RR $sc; for ($k = 0; $k -lt 10; $k++) { $acc[$k] += $mm[$k] }; $cnt++
      }
    }
    Write-Host ("  {0} 繰り返し {1}/{2} 完了" -f $vn, ($rep + 1), $Repeats)
  }
  $res = [ordered]@{ name = $vn; n = $cnt; win = 100 * $acc[0] / $cnt; t3 = 100 * $acc[1] / $cnt; c3 = $acc[2] / $cnt; q12 = 100 * $acc[3] / $cnt
    tan = 100 * $acc[4] / (100 * $cnt); fuk = 100 * $acc[5] / (100 * $cnt); u3 = 100 * $acc[6] / (300 * $cnt); uB = 100 * $acc[7] / (600 * $cnt); u3hit = 100 * $acc[8] / $cnt; uBhit = 100 * $acc[9] / $cnt }
  $out += [pscustomobject]$res
  if ($wn) {
    $wa = New-Object double[] $NF; for ($k = 0; $k -lt $NF; $k++) { $wa[$k] = $wsum[$k] / $wn }
    $wavg[$vn] = $wa
  }
  Write-Host ("{0}｜◎1着 {1:0.0}%｜◎3着内 {2:0.0}%｜上位2頭が1-2着 {3:0.0}%｜単勝回収 {4:0}%｜馬連流し的中 {5:0.0}% 回収 {6:0}%｜馬連BOX的中 {7:0.0}% 回収 {8:0}%" -f $vn, $res.win, $res.t3, $res.q12, $res.tan, $res.u3hit, $res.u3, $res.uBhit, $res.uB)
}

# ---- 比重（%）：|重み|×項目のばらつき を、グループごとに合計して割合にする ----
$md = New-Object Text.StringBuilder
[void]$md.AppendLine("# 数字モデル5（試験）：ポテンシャル項目を足した比較"); [void]$md.AppendLine("")
[void]$md.AppendLine(("交差検証（{0}分割×{1}回。学習に使っていないレースだけで評価）。レース数 {2}。" -f $Folds, $Repeats, $races.Count)); [void]$md.AppendLine("")
[void]$md.AppendLine("| 方法 | ◎1着 | ◎3着内 | 上位2頭が1-2着 | 単勝回収 | 馬連流し(3点)的中 | 同回収 | 馬連BOX(6点)的中 | 同回収 |"); [void]$md.AppendLine("|---|---|---|---|---|---|---|---|---|")
foreach ($r1 in $out) { [void]$md.AppendLine(("| {0} | {1:0.0}% | {2:0.0}% | {3:0.0}% | {4:0}% | {5:0.0}% | {6:0}% | {7:0.0}% | {8:0}% |" -f $r1.name, $r1.win, $r1.t3, $r1.q12, $r1.tan, $r1.u3hit, $r1.u3, $r1.uBhit, $r1.uB)) }
[void]$md.AppendLine(""); [void]$md.AppendLine("## 学習で決まった比重（%）"); [void]$md.AppendLine("")
[void]$md.AppendLine("| 方法 | 人気 | 実力 | ポテンシャル | 適性 | 騎手・調教師 |"); [void]$md.AppendLine("|---|---|---|---|---|---|")
foreach ($vn in $wavg.Keys) {
  $wa = $wavg[$vn]; $mk = [bool[]]$variants[$vn].mask; $gs = @{ "人気" = 0.0; "実力" = 0.0; "ポテンシャル" = 0.0; "適性" = 0.0; "騎手・調教師" = 0.0 }; $tot = 0.0
  for ($k = 0; $k -lt $NF; $k++) { if (-not $mk[$k]) { continue }; $sv = [math]::Abs($wa[$k]) * $sdK[$k]; $gs[$group[$k]] += $sv; $tot += $sv }
  [void]$md.AppendLine(("| {0} | {1:0}% | {2:0}% | {3:0}% | {4:0}% | {5:0}% |" -f $vn, (100 * $gs["人気"] / $tot), (100 * $gs["実力"] / $tot), (100 * $gs["ポテンシャル"] / $tot), (100 * $gs["適性"] / $tot), (100 * $gs["騎手・調教師"] / $tot)))
}
[void]$md.AppendLine(""); [void]$md.AppendLine("## B（21項目）の各項目の重み（5分割の平均。正＝大きいほど勝ちやすい）"); [void]$md.AppendLine("")
[void]$md.AppendLine("| 項目 | グループ | 重み |"); [void]$md.AppendLine("|---|---|---|")
$wb = $wavg["B model2＋ポテンシャル（21項目）"]
for ($k = 0; $k -lt $NF; $k++) { [void]$md.AppendLine(("| {0} | {1} | {2:0.000} |" -f $names[$k], $group[$k], $wb[$k])) }
[IO.File]::WriteAllText((Join-Path $root "model5_cv.md"), $md.ToString(), (New-Object Text.UTF8Encoding($true)))
Write-Host "model5_cv.md に保存しました"
