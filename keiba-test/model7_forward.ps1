# 3案の並行記録（2026-11-28 から、土日の本番レースで）
#   powershell -ExecutionPolicy Bypass -File model7_forward.ps1 -Date 20261128
# その日のレースが終わったあと、JRA の出馬表・結果・各馬の過去成績を集め、「発走前に分かっていた情報だけ」で
# 人気順／現行モデル／案1／案2（買う・見送り）／案3 の予想を作り、結果と比べて記録する（結果は予想に使わない）。
# 重みは、10月〜11/22 のテスト用データ（data\question10 と data\weekend\q10 の 11/21・22）で一度だけ学習して weekend\model7.json に保存し、以後は固定。
# 出力：weekend\3案\<日付>.json（レースごと）と weekend\3案_累計.md。Claude API は使わない（料金なし）。
param([string]$Date = (Get-Date -Format "yyyyMMdd"), [switch]$NoCollect, [int]$Iter = 150)
$ErrorActionPreference = "Stop"
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$outDir = Join-Path $root "weekend\3案"; New-Item -ItemType Directory -Force $outDir | Out-Null
$logFile = Join-Path $root "weekend\log.txt"
function Log([string]$s) { $line = "{0} [3案] {1}" -f (Get-Date -Format "MM/dd HH:mm:ss"), $s; Write-Host $line; [IO.File]::AppendAllText($logFile, $line + "`r`n", $utf8) }

# ---------- その日のデータを集める（出馬表の10走・結果・過去レースの結果） ----------
if (-not $NoCollect) {
  Log "$Date のデータを集めます"
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "collect.ps1") -From $Date -To $Date -Venue "札幌,函館,福島,新潟,東京,中山,中京,京都,阪神,小倉" -PastN 10 -QSub "weekend\q10" -ASub "weekend\a10" | Out-Null
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "collect_past.ps1") | Out-Null
}
Add-Type -TypeDefinition @"
using System;
public static class Fit7 {
  // init と prior が null なら 0 から学習。lam＝prior へ引き戻す強さ。
  public static double[] Train(double[][][] F, int[][] Y, bool[] mask, double[] init, double[] prior, double lam, int iter) {
    int nf = mask.Length; double[] w = new double[nf];
    if (init != null) Array.Copy(init, w, nf); else if (mask[0]) w[0] = 1.0;
    int R = F.Length;
    for (int it = 0; it < iter; it++) {
      double[] g = new double[nf];
      for (int r = 0; r < R; r++) {
        int n = F[r].Length; double[] z = new double[n]; double mx = -1e9;
        for (int i = 0; i < n; i++) { double s = 0; for (int k = 0; k < nf; k++) if (mask[k]) s += w[k] * F[r][i][k]; z[i] = s; if (s > mx) mx = s; }
        double sum = 0; for (int i = 0; i < n; i++) { z[i] = Math.Exp(z[i] - mx); sum += z[i]; }
        for (int i = 0; i < n; i++) { double p = z[i] / sum; double d = Y[r][i] - p; for (int k = 0; k < nf; k++) if (mask[k]) g[k] += d * F[r][i][k]; }
      }
      for (int k = 0; k < nf; k++) {
        if (!mask[k]) continue;
        double pull = (prior != null) ? lam * (w[k] - prior[k]) : lam * w[k];
        w[k] += 1.0 * (g[k] / R - pull);
      }
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
function Best3([double[]]$vals) {
  $m = $vals.Count; if ($m -eq 0) { return 0.0 }
  $top = @($vals | Sort-Object -Descending | Select-Object -First 3); $s = 0.0; foreach ($x in $top) { $s += $x }
  return (($s + 0.5 * [math]::Max(0, 3 - $m)) / 3.0) - 0.5
}

# ---------- 過去レースの結果（上がり・タイム差） ----------
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
  $d = @{}; if (-not (Test-Path $cf)) { return $d }
  $html = [IO.File]::ReadAllText($cf, $utf8); $i = $html.IndexOf("出走レース")
  if ($i -lt 0) { return $d }
  foreach ($m in [regex]::Matches($html.Substring($i), '<td class="date">(\d+)年(\d+)月(\d+)日</td>.*?CNAME=(pw01sde10[0-9A-F/]+)', 'Singleline')) {
    $k = "{0:0000}{1:00}{2:00}" -f [int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value
    if (-not $d.ContainsKey($k)) { $d[$k] = $m.Groups[4].Value }
  }
  return $d
}

# ---------- 騎手・調教師の成績表（そのレース日より前だけを使う。確認用のレースの結果は入れない） ----------
$qsH = @{}; $ansH = @{}
foreach ($qf in Get-ChildItem (Join-Path $root "data\question10") -Filter *.json) {
  $qsH[$qf.BaseName] = [IO.File]::ReadAllText($qf.FullName, $utf8) | ConvertFrom-Json
  $ansH[$qf.BaseName] = [IO.File]::ReadAllText((Join-Path $root ("data\answer\" + $qf.BaseName + ".json")), $utf8) | ConvertFrom-Json
}
# 週末分（記録する日より前だけ。騎手・調教師の成績表に使う）
$wkQ = @{}; $wkA = @{}
foreach ($qf in Get-ChildItem (Join-Path $root "data\weekend\q10") -Filter *.json -ErrorAction SilentlyContinue) {
  $af = Join-Path $root ("data\weekend\a10\" + $qf.Name); if (-not (Test-Path $af)) { continue }
  $wkQ[$qf.BaseName] = [IO.File]::ReadAllText($qf.FullName, $utf8) | ConvertFrom-Json
  $wkA[$qf.BaseName] = [IO.File]::ReadAllText($af, $utf8) | ConvertFrom-Json
  if ($qf.BaseName.Substring(0, 8) -lt $Date) { $qsH[$qf.BaseName] = $wkQ[$qf.BaseName]; $ansH[$qf.BaseName] = $wkA[$qf.BaseName] }
}
$jk = @{}; $seen = @{}
foreach ($q in $qsH.Values) { foreach ($hh in $q.horses) { foreach ($p in $hh.past_runs) {
  $k = $hh.jra_id + $p.date; if ($seen[$k]) { continue }; $seen[$k] = $true
  $fn = Num $p.finish; if ($null -eq $fn) { continue }
  $j = ("$($p.jockey)" -replace '\s', ''); if (-not $jk[$j]) { $jk[$j] = New-Object Collections.ArrayList }
  [void]$jk[$j].Add(@($p.date, $fn))
} } }
$tk = @{}
foreach ($id in ($qsH.Keys | Sort-Object)) {
  $q = $qsH[$id]; $af = $ansH[$id]
  $fin = @{}; foreach ($x in $af.results) { $fin["$($x.number)"] = Num $x.finish }
  foreach ($hh in $q.horses) { $fn = $fin["$($hh.number)"]; if ($null -eq $fn) { continue }
    $t = "$($hh.trainer)" -replace '\s', ''; if (-not $tk[$t]) { $tk[$t] = New-Object Collections.ArrayList }
    [void]$tk[$t].Add(@($q.race.date, $fn)) }
}
function Rate($list, [string]$before) { $n = 0; $hit = 0; if ($list) { foreach ($e in $list) { if ($e[0] -lt $before) { $n++; if ($e[1] -le 3) { $hit++ } } } }; return @($n, $hit) }

$NF = 21
# ---------- レースごとの数値（model5 と同じ21項目） ----------
function Build-Race($q, $af, [string]$id) {
  if ($q.race.category -like "障害*") { return $null }
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
  $FR = New-Object 'double[][]' $raw.Count; $yv = New-Object int[] $raw.Count; $rank = New-Object int[] $raw.Count; $nums = New-Object int[] $raw.Count; $ix = 0
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
    $trr = Rate $tk[("$($hh.trainer)" -replace '\s', '')] $rdate; $fv[10] = Shrink $trr[1] $trr[0] 0.25 20
    $rest = 60; if ($x.n) { $rest = ($rd - [datetime]::ParseExact($hh.past_runs[0].date, "yyyyMMdd", $null)).TotalDays }
    $fv[11] = [math]::Log([math]::Max($rest, 7)) - [math]::Log(35)
    $bd = $null; if ("$($hh.final.body_weight_diff)" -match '^[+-]?\d+$') { $bd = [int]($hh.final.body_weight_diff -replace '^\+', '') }
    $fv[12] = if ($null -ne $bd -and [math]::Abs($bd) -ge 10) { 1 } else { 0 }
    $fv[13] = if ($hh.past_runs.Count) { $a = Num $hh.past_runs[0].finish; $h2 = [int]$hh.past_runs[0].heads; if ($null -ne $a -and $h2 -ge 2) { 0.5 - ($a - 1.0) / ($h2 - 1.0) } else { 0 } } else { 0 }
    $fv[14] = Best3 $x.qL
    $fv[15] = Best3 $x.qT
    $fv[16] = Best3 $x.qF
    $fv[17] = if ($x.qL.Count) { (($x.qL | Measure-Object -Maximum).Maximum) - 0.5 } else { 0 }
    $mC = $x.qC.Count
    $goodN = @($x.qC | Where-Object { $_ -ge 0.65 }).Count; $badN = @($x.qC | Where-Object { $_ -le 0.35 }).Count
    $fv[18] = (($goodN + 0.25 * 2) / ($mC + 2)) - 0.25
    $fv[19] = ($goodN - $badN) / [double]($mC + 2)
    if ($mC -ge 2) { $sr = @($x.qC | Sort-Object -Descending); $half = [int][math]::Floor($mC / 2); $topH = Avg @($sr | Select-Object -First $half); $botH = Avg @($sr | Select-Object -Last $half); $fv[20] = ($topH - $botH) * ($mC / ($mC + 2.0)) - 0.3 } else { $fv[20] = 0 }
    $FR[$ix] = $fv; $nums[$ix] = [int]$hh.number
    $yv[$ix] = $(if ($fin["$($hh.number)"] -eq "1") { 1 } else { 0 })
    $rk0 = Num $fin["$($hh.number)"]; $rank[$ix] = $(if ($null -ne $rk0) { $rk0 } else { 99 }); $ix++
  }
  if (($yv | Measure-Object -Sum).Sum -ne 1) { return $null }
  $pay = $af.payouts; $tan = @{}; $fuk = @{}; $uma = @{}
  foreach ($l in @($pay.tansho)) { $tan["$($l.combo)"] = [int]$l.yen }
  foreach ($l in @($pay.fukusho)) { $fuk["$($l.combo)"] = [int]$l.yen }
  foreach ($l in @($pay.umaren)) { $c = (@("$($l.combo)" -split '-' | ForEach-Object { [int]$_ } | Sort-Object) -join "-"); $uma[$c] = [int]$l.yen }
  # レースの種類
  $isShinba = ("$($q.race.name)" -match 'メイクデビュー') -or ("$($q.race.class)" -match '新馬')
  $isHandi = ("$($q.race.weight_rule)" -match 'ハンデ')
  $isGrade = ("$($q.race.name)" -match '[GＧ][ⅠⅡⅢ123]')
  $typ = if ("$($q.race.class)" -match '新馬|未勝利') { "新馬・未勝利" } elseif ($isGrade) { "重賞" } else { "条件戦" }
  return [pscustomobject]@{ id = $id; date = $rdate; nums = $nums; F = $FR; y = $yv; rank = $rank; tan = $tan; fuk = $fuk; uma = $uma
    heads = $raw.Count; shinba = $isShinba; handi = $isHandi; group = ($surf + "/" + $typ); name = "$($q.race.name)" }
}

# ---------- 評価（券種：◎単勝・複勝、馬連流し4点＝◎→2〜5番手、馬連BOX6点＝上位4頭） ----------
function Eval1($RR, [int[]]$marks) {
  $rk = $RR.rank; $hon = $marks[0]; $hn = "$($RR.nums[$hon])"
  $win = [int]($rk[$hon] -eq 1); $t3 = [int]($rk[$hon] -le 3)
  $tanY = [int]$RR.tan[$hn]; $fukY = [int]$RR.fuk[$hn]
  $ry = 0; foreach ($j in 1..4) { $c = (@([int]$RR.nums[$hon], [int]$RR.nums[$marks[$j]]) | Sort-Object) -join "-"; $ry += [int]$RR.uma[$c] }
  $bx = 0; for ($a = 0; $a -lt 4; $a++) { for ($b = $a + 1; $b -lt 4; $b++) { $c = (@([int]$RR.nums[$marks[$a]], [int]$RR.nums[$marks[$b]]) | Sort-Object) -join "-"; $bx += [int]$RR.uma[$c] } }
  return @($win, $t3, [int]($ry -gt 0), [int]($bx -gt 0), $tanY, $fukY, $ry, $bx)
}
function New-Acc { return @{ n = 0; s = (New-Object double[] 8) } }
function Add-Acc($acc, $ev) { $acc.n++; for ($k = 0; $k -lt 8; $k++) { $acc.s[$k] += $ev[$k] } }
function Sum-Acc($accs) { $t = New-Acc; foreach ($a in $accs) { $t.n += $a.n; for ($k = 0; $k -lt 8; $k++) { $t.s[$k] += $a.s[$k] } }; return $t }
function Hit4($acc) { if ($acc.n -eq 0) { return 0 }; return (100.0 * ($acc.s[0] + $acc.s[1] + $acc.s[2] + $acc.s[3]) / (4.0 * $acc.n)) }
function Ret($acc) { if ($acc.n -eq 0) { return 0 }; return (100.0 * ($acc.s[4] + $acc.s[5] + $acc.s[6] + $acc.s[7]) / (1200.0 * $acc.n)) }
function Row($label, $acc) {
  if ($acc.n -eq 0) { return ("| {0} | 0 | - | - | - | - | - | - | - |" -f $label) }
  $n = $acc.n; $s = $acc.s
  return ("| {0} | {1} | {2:0.0}% | {3:0.0}% | {4:0.0}% | {5:0.0}% | {6:0.0}% | {7:0}% | 単勝{9:0}% 複勝{10:0}% 流し{11:0}% BOX{12:0}% |" -f $label, $n, (100 * $s[0] / $n), (100 * $s[1] / $n), (100 * $s[2] / $n), (100 * $s[3] / $n), (Hit4 $acc), (Ret $acc), (Ret $acc), (100 * $s[4] / (100 * $n)), (100 * $s[5] / (100 * $n)), (100 * $s[6] / (400 * $n)), (100 * $s[7] / (600 * $n)))
}
$TBL = "| 方法 | レース数 | ◎1着 | ◎3着内 | 馬連流し的中 | 馬連BOX的中 | 的中率の平均（4つ） | 回収率（合計） | 内訳 |`n|---|---|---|---|---|---|---|---|---|"

# ---------- 予想の作り方 ----------
$ALL = New-Object bool[] $NF; for ($k = 0; $k -lt $NF; $k++) { $ALL[$k] = $true }
$NOPOP = [bool[]]$ALL.Clone(); $NOPOP[0] = $false
$M8 = New-Object bool[] $NF; foreach ($k in @(0, 1, 2, 5, 6, 9, 12, 13)) { $M8[$k] = $true }   # 本番（weekend）と同じ8項目
function Order($z) { return @(0..($z.Count - 1) | Sort-Object { -$z[$_] }) }
function Pop-Marks($RR) { $z = @($RR.F | ForEach-Object { $_[0] }); return @((Order $z) | Select-Object -First 5) }
function Plan1-Marks($RR, $w21) {
  $zA = [Fit7]::Score($RR.F, $w21, $ALL); $zN = [Fit7]::Score($RR.F, $w21, $NOPOP)
  $cand = @(0..($RR.F.Count - 1) | Where-Object { $RR.F[$_][0] -ge -[math]::Log(5.0) - 1e-9 })   # 人気5位以内（-ln(人気) が -ln5 以上）
  if ($cand.Count -eq 0) { return @((Order $zA) | Select-Object -First 5) }
  $hon = @($cand | Sort-Object { -$zN[$_] })[0]
  $rest = @((Order $zA) | Where-Object { $_ -ne $hon } | Select-Object -First 4)
  return @(, $hon) + $rest
}
function Plan2-Pick($RR, $w8) {   # 現行モデルの上位5頭と、買うかどうか
  $z = [Fit7]::Score($RR.F, $w8, $M8); $o = Order $z
  $mx = ($z | Measure-Object -Maximum).Maximum; $ex = @($z | ForEach-Object { [math]::Exp($_ - $mx) }); $sum = ($ex | Measure-Object -Sum).Sum
  $p1 = $ex[$o[0]] / $sum
  $buy = (-not $RR.shinba) -and (-not $RR.handi) -and ($RR.heads -le 14) -and ($p1 -ge 0.30)
  return @{ marks = @($o | Select-Object -First 5); buy = $buy }
}
function Plan3-Marks($RR, $wGroup) { $z = [Fit7]::Score($RR.F, $wGroup[$RR.group], $ALL); return @((Order $z) | Select-Object -First 5) }
function Fit-All($trn) {   # 学習：全体B、現行8項目、種類ごと
  $FA = New-Object 'double[][][]' $trn.Count; $YA = New-Object 'int[][]' $trn.Count
  for ($i = 0; $i -lt $trn.Count; $i++) { $FA[$i] = $trn[$i].F; $YA[$i] = $trn[$i].y }
  $w21 = [Fit7]::Train($FA, $YA, $ALL, $null, $null, 0.02, $Iter)
  $w8 = [Fit7]::Train($FA, $YA, $M8, $null, $null, 0.02, $Iter)
  $wg = @{}
  foreach ($g in @($trn | ForEach-Object { $_.group } | Select-Object -Unique)) {
    $sub = @($trn | Where-Object { $_.group -eq $g })
    $FG = New-Object 'double[][][]' $sub.Count; $YG = New-Object 'int[][]' $sub.Count
    for ($i = 0; $i -lt $sub.Count; $i++) { $FG[$i] = $sub[$i].F; $YG[$i] = $sub[$i].y }
    $wg[$g] = [Fit7]::Train($FG, $YG, $ALL, $w21, $w21, 0.2, 100)
  }
  foreach ($g in @("芝/新馬・未勝利", "芝/条件戦", "芝/重賞", "ダ/新馬・未勝利", "ダ/条件戦", "ダ/重賞")) { if (-not $wg.ContainsKey($g)) { $wg[$g] = $w21 } }
  return @{ w21 = $w21; w8 = $w8; wg = $wg }
}
function Eval-Set($set, $m) {   # 1つの重みのセットで、全方法を評価して返す
  $o = @{ base = (New-Acc); cur = (New-Acc); p1 = (New-Acc); p2 = (New-Acc); base2 = (New-Acc); p3 = (New-Acc) }
  foreach ($RR in $set) {
    $bm = Pop-Marks $RR; Add-Acc $o.base (Eval1 $RR $bm)
    $c8 = Plan2-Pick $RR $m.w8; Add-Acc $o.cur (Eval1 $RR $c8.marks)
    if ($c8.buy) { Add-Acc $o.p2 (Eval1 $RR $c8.marks); Add-Acc $o.base2 (Eval1 $RR $bm) }
    Add-Acc $o.p1 (Eval1 $RR (Plan1-Marks $RR $m.w21))
    Add-Acc $o.p3 (Eval1 $RR (Plan3-Marks $RR $m.wg))
  }
  return $o
}

# ---------- 重み（一度だけ学習して固定） ----------
$mf = Join-Path $root "weekend\model7.json"
if (Test-Path $mf) {
  $mj = [IO.File]::ReadAllText($mf, $utf8) | ConvertFrom-Json
  $m = @{ w21 = [double[]]@($mj.w21); w8 = [double[]]@($mj.w8); wg = @{} }
  foreach ($p in $mj.wg.PSObject.Properties) { $m.wg[$p.Name] = [double[]]@($p.Value) }
} else {
  $trn = @()
  foreach ($id in ($qsH.Keys | Sort-Object)) {
    if ($id.Substring(0, 8) -gt "20261122") { continue }
    $RR = Build-Race $qsH[$id] $ansH[$id] $id; if ($null -ne $RR) { $trn += $RR }
  }
  Log ("重みを学習します（{0}レース）" -f $trn.Count)
  $m = Fit-All $trn
  [IO.File]::WriteAllText($mf, (@{ w21 = $m.w21; w8 = $m.w8; wg = $m.wg; trained = (Get-Date -Format "yyyy-MM-dd HH:mm"); races = $trn.Count } | ConvertTo-Json -Depth 5 -Compress), $utf8)
}

# ---------- その日のレースを記録 ----------
$rows = @()
foreach ($id in ($wkQ.Keys | Where-Object { $_.Substring(0, 8) -eq $Date } | Sort-Object)) {
  $q = $wkQ[$id]; $RR = Build-Race $q $wkA[$id] $id
  if ($null -eq $RR) { continue }
  $bm = Pop-Marks $RR; $c8 = Plan2-Pick $RR $m.w8
  $isMain = ([int]$q.race.race_no -eq 11) -or ("$($q.race.name)" -match '[GＧ][ⅠⅡⅢ123]')
  $num = { param($marks) @($marks | ForEach-Object { [int]$RR.nums[$_] }) }
  $rows += [ordered]@{ id = $id; name = "$($q.race.name)"; heads = $RR.heads; main = $isMain; buy = $c8.buy
    base = @(Eval1 $RR $bm); cur = @(Eval1 $RR $c8.marks); p1 = @(Eval1 $RR (Plan1-Marks $RR $m.w21)); p3 = @(Eval1 $RR (Plan3-Marks $RR $m.wg))
    marks = [ordered]@{ base = (& $num $bm); cur = (& $num $c8.marks); p1 = (& $num (Plan1-Marks $RR $m.w21)); p3 = (& $num (Plan3-Marks $RR $m.wg)) } }
}
if ($rows.Count) {
  [IO.File]::WriteAllText((Join-Path $outDir ($Date + ".json")), (@{ date = $Date; races = $rows } | ConvertTo-Json -Depth 6), $utf8)
  Log ("{0}：{1}レースを記録しました" -f $Date, $rows.Count)
} else { Log "$Date：記録できるレースがありません（結果がまだ、または開催なし）" }

# ---------- 累計の表 ----------
$all = @()
foreach ($f in Get-ChildItem $outDir -Filter *.json | Sort-Object Name) {
  $j = [IO.File]::ReadAllText($f.FullName, $utf8) | ConvertFrom-Json
  foreach ($r in $j.races) { $all += $r }
}
function AccOf($rs, [string]$k) { $a = New-Acc; foreach ($r in $rs) { Add-Acc $a ([double[]]@($r.$k)) }; return $a }
$md = New-Object Text.StringBuilder
[void]$md.AppendLine("# 3案の並行記録（本番の土日、2026-11-28 から）"); [void]$md.AppendLine("")
[void]$md.AppendLine("発走前に分かっていた情報（確定した人気・馬体重・過去10走など）だけで作った予想を、結果と比べたもの。重みは 11/22 までのデータで学習して固定。")
[void]$md.AppendLine("券種：◎単勝・複勝 各100円、馬連流し4点（◎→2〜5番手）、馬連BOX6点（上位4頭）。的中率の平均＝◎1着・◎3着内・流し的中・BOX的中の平均。"); [void]$md.AppendLine("")
[void]$md.AppendLine(("記録した日：{0}" -f ((@(Get-ChildItem $outDir -Filter *.json | ForEach-Object { $_.BaseName }) | Sort-Object) -join "、"))); [void]$md.AppendLine("")
foreach ($blk in @(@("全レース", $all), @("メインレース（11R）・重賞だけ", @($all | Where-Object { $_.main })))) {
  $rs = $blk[1]
  [void]$md.AppendLine("## " + $blk[0] + ("（{0}レース）" -f $rs.Count)); [void]$md.AppendLine("")
  [void]$md.AppendLine($TBL)
  [void]$md.AppendLine((Row "人気順で買っただけ" (AccOf $rs "base"))); [void]$md.AppendLine((Row "現行モデル（8項目）" (AccOf $rs "cur")))
  [void]$md.AppendLine((Row "案1：人気5位以内から選ぶ" (AccOf $rs "p1"))); [void]$md.AppendLine((Row "案3：レースの種類ごとに比重" (AccOf $rs "p3")))
  $b = @($rs | Where-Object { $_.buy })
  [void]$md.AppendLine((Row "案2：絞ったレースだけ（現行モデル）" (AccOf $b "cur"))); [void]$md.AppendLine((Row "　同じレースを人気順で買った場合" (AccOf $b "base")))
  [void]$md.AppendLine("")
}
[void]$md.AppendLine("※ レース数が少ないうちは、的中率は偶然で数ポイント動きます。判断は 12/20 まで記録してから。")
[IO.File]::WriteAllText((Join-Path $root "weekend\3案_累計.md"), $md.ToString(), (New-Object Text.UTF8Encoding($true)))
Log "weekend\3案_累計.md を更新しました"
