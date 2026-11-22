# 週末の自動検証：出馬表を読んで予想（◎・相手・穴候補・堅さ判定）を保存し、結果が出たら答え合わせをする。
#   powershell -File weekend.ps1 -Mode train                    … 過去324レースから重みを学ぶ（1回だけ）
#   powershell -File weekend.ps1 -Mode predict -Date 20261121   … その日の出馬表を読んで、まだ予想していないレースを予想（何回実行してもよい）
#   powershell -File weekend.ps1 -Mode result  -Date 20261121   … 結果を集めて答え合わせ（weekend\結果_日付.md と 結果_累計.md）
#   powershell -File weekend.ps1 -Mode install                  … タスクスケジューラに 11/21・11/22 の自動実行を登録する
# 料金はかからない（Claude API 不使用）。JRA には1回読むごとに 1 秒待つ。
param([ValidateSet("train", "predict", "result", "install", "uninstall")][string]$Mode = "predict",
      [string]$Date = (Get-Date -Format "yyyyMMdd"), [switch]$Force, [int]$MinMinutes = 10)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$sjis = [Text.Encoding]::GetEncoding(932)
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$wk = Join-Path $root "weekend"
$predDir = Join-Path $wk "pred"; $rawDir = Join-Path $wk "raw"; $cacheDir = Join-Path $root "cache"
foreach ($d in @($wk, $predDir, $rawDir, $cacheDir)) { New-Item -ItemType Directory -Force $d | Out-Null }
$logFile = Join-Path $wk "log.txt"
function Log([string]$s) { $line = "{0} {1}" -f (Get-Date -Format "MM/dd HH:mm:ss"), $s; Write-Host $line; [IO.File]::AppendAllText($logFile, $line + "`r`n", $utf8) }

# ---- 予想と結果を Cloudflare の中継（/keiba）へ送る：ハヤトが「今日の予想は？」に答えるため ----
# 設定は weekend\sync.txt（GitHub には上げない）。1行目 url=中継のURL　2行目 code=記憶の合言葉。無ければ何もしない。
function Push-Sync([string]$D) {
  try {
    $cf = Join-Path $wk "sync.txt"; if (-not (Test-Path $cf)) { return }
    $cfg = @{}; foreach ($ln in [IO.File]::ReadAllLines($cf, $utf8)) { $kv = $ln -split '=', 2; if ($kv.Count -eq 2) { $cfg[$kv[0].Trim()] = $kv[1].Trim() } }
    if (-not $cfg.url -or -not $cfg.code) { return }
    $syncRaces = @()
    foreach ($pf in Get-ChildItem $predDir -Filter "${D}_*.json" | Sort-Object Name) {
      $p = [IO.File]::ReadAllText($pf.FullName, $utf8) | ConvertFrom-Json
      $o = [ordered]@{ race = $p.race; name = $p.name; class = $p.class; start = $p.start; heads = $p.heads; dist = $p.dist; surf = $p.surf; kind = $p.kind
        honmei = $p.honmei; aite = @($p.aite); ana = @($p.ana); fetched = $p.fetched }
      $af = Join-Path $root ("data\weekend\a\" + $pf.Name)
      if (Test-Path $af) {
        $a = [IO.File]::ReadAllText($af, $utf8) | ConvertFrom-Json
        $top = @($a.results | Where-Object { $_.finish -match '^[123]$' } | Sort-Object { [int]$_.finish } | ForEach-Object { [ordered]@{ finish = [int]$_.finish; num = $_.number; name = ("$($_.name)" -replace '\s*ブリンカー着用', ''); pop = $_.popularity } })
        $hf = @($a.results | Where-Object { "$($_.number)" -eq "$($p.honmei.num)" } | Select-Object -First 1)
        $o["result"] = [ordered]@{ top3 = $top; honmei_finish = $(if ($hf.Count) { "$($hf[0].finish)" } else { "" }) }
      }
      $syncRaces += $o
    }
    if (-not $syncRaces.Count) { return }
    $body = [ordered]@{ action = "put"; code = $cfg.code; date = $D; races = $syncRaces; updated = (Get-Date -Format "MM/dd HH:mm") } | ConvertTo-Json -Depth 8 -Compress
    $uri = ($cfg.url.TrimEnd('/') -replace '/(memory|keiba)$', '') + "/keiba"
    $r = Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json; charset=utf-8" -Headers @{ Origin = "https://ryoun0307.github.io" } -Body ([Text.Encoding]::UTF8.GetBytes($body))
    Log ("ハヤトへ送りました：{0} {1}レース" -f $D, $syncRaces.Count)
  } catch { Log ("ハヤトへ送れませんでした：" + $_.Exception.Message) }
}

$VENUES = @{ "01"="札幌"; "02"="函館"; "03"="福島"; "04"="新潟"; "05"="東京"; "06"="中山"; "07"="中京"; "08"="京都"; "09"="阪神"; "10"="小倉" }
$NF = 8
$FNAMES = @("人気(-ln)", "近5走の着順率", "近10走の3着内率", "同距離・同芝ダの3着内率", "同競馬場の3着内率", "騎手の3着内率", "馬体重の大増減", "前走の着順率")

function Num($s) { if ("$s" -match '^\d+$') { return [int]$s } else { return $null } }
function Shrink([int]$hit, [int]$n, [double]$prior, [double]$k) { return (($hit + $prior * $k) / ($n + $k)) - $prior }
function Strip([string]$s) {
  $s = [regex]::Replace($s, '<img[^>]*alt="([^"]*)"[^>]*>', ' $1 ')
  $s = [regex]::Replace($s, '<[^>]+>', ' ')
  $s = [Net.WebUtility]::HtmlDecode($s)
  return ([regex]::Replace($s, '\s+', ' ')).Trim()
}
function Pick([string]$s, [string]$re) { $m = [regex]::Match($s, $re, 'Singleline'); if ($m.Success) { return (Strip $m.Groups[1].Value) } else { return "" } }

# ---------- 特徴量（学習のときも本番も同じ関数を使う） ----------
# $h: @{ pop; past(新しい順の過去走); jockey; bwdiff }、$race: @{ venue; dist; surf; date }、$jt: 騎手の成績表
function Get-Features($h, $race, $jt) {
  $f = New-Object double[] $NF
  $pop = [int]$h.pop; if ($pop -lt 1) { $pop = 10 }
  $f[0] = -[math]::Log($pop)
  $r5 = @(); $t3 = 0; $n = 0; $sc = 0; $st = 0; $vc = 0; $vt = 0
  foreach ($p in @($h.past)) {
    $fn = Num $p.finish; $hd = [int]$p.heads
    if ($null -eq $fn -or $hd -lt 2) { continue }
    $n++
    if ($n -le 5) { $r5 += (($fn - 1.0) / ($hd - 1.0)) }
    if ($fn -le 3) { $t3++ }
    $pm = [regex]::Match("$($p.distance)", '^(芝|ダ)(\d+)')
    if ($pm.Success -and $pm.Groups[1].Value -eq $race.surf -and [math]::Abs([int]$pm.Groups[2].Value - $race.dist) -le 200) { $sc++; if ($fn -le 3) { $st++ } }
    if ($p.venue -eq $race.venue) { $vc++; if ($fn -le 3) { $vt++ } }
  }
  $f[1] = if ($r5.Count) { 0.5 - ($r5 | Measure-Object -Average).Average } else { 0 }
  $f[2] = (($t3 + 0.5) / ($n + 2)) - 0.25
  $f[3] = Shrink $st $sc 0.25 2
  $f[4] = Shrink $vt $vc 0.25 2
  $jn = 0; $jh = 0; $jl = $jt[("$($h.jockey)" -replace '\s', '')]
  if ($jl) { foreach ($e in $jl) { if ([string]$e[0] -lt [string]$race.date) { $jn++; if ([int]$e[1] -le 3) { $jh++ } } } }
  $f[5] = Shrink $jh $jn 0.25 20
  $f[6] = if ($null -ne $h.bwdiff -and [math]::Abs([int]$h.bwdiff) -ge 10) { 1 } else { 0 }
  $f[7] = 0
  $pl = @($h.past); if ($pl.Count) { $a = Num $pl[0].finish; $hh = [int]$pl[0].heads; if ($null -ne $a -and $hh -ge 2) { $f[7] = 0.5 - ($a - 1.0) / ($hh - 1.0) } }
  return , $f
}
function Softmax([double[]]$z) {
  $mx = ($z | Measure-Object -Maximum).Maximum; $e = @($z | ForEach-Object { [math]::Exp($_ - $mx) }); $s = ($e | Measure-Object -Sum).Sum
  return , @($e | ForEach-Object { $_ / $s })
}

# ================= 学習 =================
if ($Mode -eq "train") {
  $qdir = Join-Path $root "data\question10"
  $jt = @{}; $seen = @{}
  foreach ($qf in Get-ChildItem $qdir -Filter *.json) {
    $q = [IO.File]::ReadAllText($qf.FullName, $utf8) | ConvertFrom-Json
    foreach ($h in $q.horses) { foreach ($p in $h.past_runs) {
      $k = $h.jra_id + $p.date; if ($seen[$k]) { continue }; $seen[$k] = $true
      $fn = Num $p.finish; if ($null -eq $fn) { continue }
      $j = ("$($p.jockey)" -replace '\s', ''); if (-not $jt[$j]) { $jt[$j] = New-Object Collections.ArrayList }
      [void]$jt[$j].Add(@($p.date, $fn)) } }
  }
  $races = @()
  foreach ($qf in Get-ChildItem $qdir -Filter *.json | Sort-Object Name) {
    $q = [IO.File]::ReadAllText($qf.FullName, $utf8) | ConvertFrom-Json
    if ($q.race.category -like "障害*") { continue }
    $af = [IO.File]::ReadAllText((Join-Path $root ("data\answer\" + $qf.Name)), $utf8) | ConvertFrom-Json
    $cm = [regex]::Match($q.race.course, '([\d,]+)\s*メートル\s*（(芝|ダート)')
    $race = @{ venue = $q.race.venue; dist = [int]($cm.Groups[1].Value -replace ',', ''); surf = $(if ($cm.Groups[2].Value -eq "芝") { "芝" } else { "ダ" }); date = $q.race.date }
    $fin = @{}; foreach ($x in $af.results) { $fin["$($x.number)"] = "$($x.finish)" }
    $F = @(); $y = @()
    foreach ($h in $q.horses) {
      $bd = $null; if ("$($h.final.body_weight_diff)" -match '^[+-]?\d+$') { $bd = [int]($h.final.body_weight_diff -replace '^\+', '') }
      $F += , (Get-Features @{ pop = $h.final.popularity; past = $h.past_runs; jockey = $h.jockey; bwdiff = $bd } $race $jt)
      $y += $(if ($fin["$($h.number)"] -eq "1") { 1 } else { 0 })
    }
    if (($y | Measure-Object -Sum).Sum -ne 1) { continue }
    $races += [pscustomobject]@{ F = $F; y = $y }
  }
  Log ("学習するレース：{0}" -f $races.Count)
  $w = New-Object double[] $NF; $w[0] = 1.0
  for ($it = 0; $it -lt 300; $it++) {
    $g = New-Object double[] $NF
    foreach ($R in $races) {
      $z = New-Object double[] $R.F.Count
      for ($i = 0; $i -lt $z.Length; $i++) { $s = 0.0; for ($k = 0; $k -lt $NF; $k++) { $s += $w[$k] * $R.F[$i][$k] }; $z[$i] = $s }
      $p = Softmax $z
      for ($i = 0; $i -lt $p.Count; $i++) { $d = $R.y[$i] - $p[$i]; for ($k = 0; $k -lt $NF; $k++) { $g[$k] += $d * $R.F[$i][$k] } }
    }
    for ($k = 0; $k -lt $NF; $k++) { $w[$k] += 1.0 * ($g[$k] / $races.Count - 0.02 * $w[$k]) }
  }
  for ($k = 0; $k -lt $NF; $k++) { Log ("{0}  重み {1:0.000}" -f $FNAMES[$k], $w[$k]) }
  $jtOut = @{}; foreach ($k in $jt.Keys) { $jtOut[$k] = @($jt[$k] | ForEach-Object { , @($_[0], $_[1]) }) }
  $model = [ordered]@{ weights = @($w | ForEach-Object { [double]$_ }); names = $FNAMES; jockey = $jtOut }
  [IO.File]::WriteAllText((Join-Path $wk "model.json"), ($model | ConvertTo-Json -Depth 5 -Compress), $utf8)
  Log "model.json を保存しました"
  exit 0
}

# ================= JRA を読む =================
function Get-Jra([string]$Method, [string]$Url, [string]$Cname, [string]$CacheKey) {
  $cf = if ($CacheKey) { Join-Path $cacheDir ($CacheKey + ".html") } else { $null }
  if ($cf -and (Test-Path $cf)) { return [IO.File]::ReadAllText($cf, $utf8) }
  Start-Sleep -Milliseconds 1000
  for ($try = 1; $try -le 3; $try++) {
    try {
      if ($Method -eq "POST") { $r = Invoke-WebRequest -Uri $Url -Method Post -Body @{ cname = $Cname } -UseBasicParsing } else { $r = Invoke-WebRequest -Uri $Url -UseBasicParsing }
      $html = $sjis.GetString($r.RawContentStream.ToArray())
      if ($cf) { [IO.File]::WriteAllText($cf, $html, $utf8) }
      return $html
    } catch { if ($try -eq 3) { throw }; Start-Sleep -Seconds (3 * $try) }
  }
}
function Get-HorsePast([string]$HorseCname, [string]$RaceDate) {
  $html = Get-Jra "GET" ("https://www.jra.go.jp/JRADB/accessU.html?CNAME=" + $HorseCname) $null ("horse_" + ($HorseCname -replace '[^0-9A-Za-z]', '_'))
  $start = $html.IndexOf("出走レース"); $runs = @()
  if ($start -ge 0) {
    $tb = $html.Substring($start); $e = $tb.IndexOf("</tbody>"); if ($e -ge 0) { $tb = $tb.Substring(0, $e) }
    foreach ($tr in [regex]::Matches($tb, '<tr>(.*?)</tr>', 'Singleline')) {
      $cells = @([regex]::Matches($tr.Groups[1].Value, '<td[^>]*>(.*?)</td>', 'Singleline') | ForEach-Object { Strip $_.Groups[1].Value })
      if ($cells.Count -lt 14) { continue }
      $dm = [regex]::Match($cells[0], '(\d+)年(\d+)月(\d+)日'); if (-not $dm.Success) { continue }
      $d8 = "{0:0000}{1:00}{2:00}" -f [int]$dm.Groups[1].Value, [int]$dm.Groups[2].Value, [int]$dm.Groups[3].Value
      if ($d8 -ge $RaceDate) { continue }
      $runs += [pscustomobject]@{ date = $d8; venue = $cells[1]; race = $cells[2]; distance = $cells[3]; going = $cells[4]; heads = (Num ($cells[5] -replace '\D', '')); popularity = (Num ($cells[6] -replace '\D', '')); finish = $cells[7]; jockey = $cells[8] }
    }
  }
  return @($runs | Sort-Object { $_.date } -Descending | Select-Object -First 10)
}
function Get-Meetings([string]$D) {
  $list = Get-Jra "POST" "https://www.jra.go.jp/JRADB/accessD.html" "pw01dli00/F3" $null
  $ms = @()
  foreach ($m in [regex]::Matches($list, '(pw01drl\d\d(\d\d)\d{4}\d{4}(\d{8})/[0-9A-F]{2})')) {
    if ($m.Groups[3].Value -ne $D) { continue }
    if ($ms | Where-Object { $_.cname -eq $m.Groups[1].Value }) { continue }
    $ms += [pscustomobject]@{ cname = $m.Groups[1].Value; venue = $VENUES[$m.Groups[2].Value]; date = $D }
  }
  return $ms
}

# ================= 結果の答え合わせ =================
if ($Mode -eq "result") {
  $qd = "weekend\q"; $ad = "weekend\a"
  Log "結果を集めます：$Date"
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "collect.ps1") -From $Date -To $Date -Venue "札幌,函館,福島,新潟,東京,中山,中京,京都,阪神,小倉" -PastN 1 -QSub $qd -ASub $ad | Out-Null
  $rows = @()
  foreach ($pf in Get-ChildItem $predDir -Filter "${Date}_*.json" | Sort-Object Name) {
    $p = [IO.File]::ReadAllText($pf.FullName, $utf8) | ConvertFrom-Json
    $af = Join-Path $root ("data\weekend\a\" + $pf.Name)
    if (-not (Test-Path $af)) { continue }
    $a = [IO.File]::ReadAllText($af, $utf8) | ConvertFrom-Json
    $fin = @{}; $popOf = @{}; foreach ($x in $a.results) { $fin["$($x.number)"] = Num $x.finish; $popOf["$($x.number)"] = [int]$x.popularity }
    $win = @($a.results | Where-Object { $_.finish -eq "1" } | Select-Object -First 1)
    $hon = "$($p.honmei.num)"; $pop1 = @($a.results | Where-Object { $_.popularity -eq 1 } | Select-Object -First 1)
    $pay = $a.payouts
    $tan = 0; foreach ($l in @($pay.tansho)) { if ("$($l.combo)" -eq $hon) { $tan += [int]$l.yen } }
    $fuk = 0; foreach ($l in @($pay.fukusho)) { if ("$($l.combo)" -eq $hon) { $fuk += [int]$l.yen } }
    $um = { param($x, $y) $c = (@([int]$x, [int]$y) | Sort-Object) -join "-"; $s = 0; foreach ($l in @($pay.umaren)) { $lc = (@("$($l.combo)" -split '-' | ForEach-Object { [int]$_ } | Sort-Object) -join "-"); if ($lc -eq $c) { $s += [int]$l.yen } }; $s }
    $umRet = 0; foreach ($o in @($p.aite | ForEach-Object { $_.num })) { $umRet += (& $um $hon $o) }
    $popRet = 0; $pp = @($p.pop_order); foreach ($o in $pp[1..3]) { $popRet += (& $um $pp[0] $o) }
    $anaIn = @($p.ana | Where-Object { $fin["$($_.num)"] -le 3 }).Count
    $rows += [pscustomobject]@{ race = $p.race; name = $p.name; heads = $p.heads; kind = $p.kind; honmei = $hon; fin = $fin[$hon]; hpop = $p.honmei.pop
      pop1fin = $(if ($pop1.Count) { Num $pop1[0].finish } else { $null }); tan = $tan; fuk = $fuk; umRet = $umRet; popRet = $popRet; anaIn = $anaIn; anaN = @($p.ana).Count
      top3 = @($a.results | Where-Object { $_.finish -match '^[123]$' } | Sort-Object { [int]$_.finish } | ForEach-Object { "{0}番({1}人気)" -f $_.number, $_.popularity }) -join " → " }
  }
  $md = New-Object Text.StringBuilder
  [void]$md.AppendLine("# 週末の検証：$Date"); [void]$md.AppendLine("")
  $n = $rows.Count
  if ($n -eq 0) { [void]$md.AppendLine("答え合わせできるレースがまだありません（予想が保存されていない、または結果がまだ出ていません）。") }
  else {
    $w1 = @($rows | Where-Object { $_.fin -eq 1 }).Count; $w3 = @($rows | Where-Object { $_.fin -le 3 }).Count
    $p1 = @($rows | Where-Object { $_.pop1fin -eq 1 }).Count; $p13 = @($rows | Where-Object { $_.pop1fin -le 3 }).Count
    $tr = ($rows | Measure-Object tan -Sum).Sum; $fr = ($rows | Measure-Object fuk -Sum).Sum
    $ur = ($rows | Measure-Object umRet -Sum).Sum; $pr = ($rows | Measure-Object popRet -Sum).Sum
    [void]$md.AppendLine("## 全体（{0}レース）" -f $n)
    [void]$md.AppendLine("| | ◎（システム） | 1番人気（比べる相手） |"); [void]$md.AppendLine("|---|---|---|")
    [void]$md.AppendLine(("| 1着 | {0}/{1}（{2:0}%） | {3}/{1}（{4:0}%） |" -f $w1, $n, (100.0 * $w1 / $n), $p1, (100.0 * $p1 / $n)))
    [void]$md.AppendLine(("| 3着以内 | {0}/{1}（{2:0}%） | {3}/{1}（{4:0}%） |" -f $w3, $n, (100.0 * $w3 / $n), $p13, (100.0 * $p13 / $n)))
    [void]$md.AppendLine(("| 単勝の回収率 | {0:0}%（{1}円/{2}円） | |" -f (100.0 * $tr / ($n * 100)), $tr, ($n * 100)))
    [void]$md.AppendLine(("| 複勝の回収率 | {0:0}%（{1}円/{2}円） | |" -f (100.0 * $fr / ($n * 100)), $fr, ($n * 100)))
    [void]$md.AppendLine(("| 馬連3点（◎→相手3頭 / 1番人気→2〜4番人気） | {0:0}% | {1:0}% |" -f (100.0 * $ur / ($n * 300)), (100.0 * $pr / ($n * 300))))
    [void]$md.AppendLine("")
    [void]$md.AppendLine("## 堅さ判定ごと（◎が3着以内）")
    [void]$md.AppendLine("| 判定 | レース数 | ◎が1着 | ◎が3着以内 | 穴候補が3着以内に入った | ")
    [void]$md.AppendLine("|---|---|---|---|---|")
    foreach ($g in ($rows | Group-Object kind | Sort-Object Name)) {
      $gn = $g.Count; $gw = @($g.Group | Where-Object { $_.fin -eq 1 }).Count; $g3 = @($g.Group | Where-Object { $_.fin -le 3 }).Count
      $ga = ($g.Group | Measure-Object anaIn -Sum).Sum; $gp = ($g.Group | Measure-Object anaN -Sum).Sum
      [void]$md.AppendLine(("| {0} | {1} | {2}/{1} | {3}/{1} | {4}/{5}頭 |" -f $g.Name, $gn, $gw, $g3, $ga, $gp))
    }
    [void]$md.AppendLine(""); [void]$md.AppendLine("## レースごと")
    [void]$md.AppendLine("| レース | 頭数 | 判定 | ◎ | ◎の人気 | ◎の着順 | 実際の1〜3着 |"); [void]$md.AppendLine("|---|---|---|---|---|---|---|")
    foreach ($r in $rows) { [void]$md.AppendLine(("| {0} {1} | {2} | {3} | {4}番 | {5}番人気 | {6}着 | {7} |" -f $r.race, $r.name, $r.heads, $r.kind, $r.honmei, $r.hpop, $r.fin, $r.top3)) }
  }
  [IO.File]::WriteAllText((Join-Path $wk ("結果_" + $Date + ".md")), $md.ToString(), (New-Object Text.UTF8Encoding($true)))
  Log ("答え合わせ：{0}レース → weekend\結果_{1}.md" -f $n, $Date)
  Push-Sync $Date
  exit 0
}

# ================= タスクスケジューラへの登録・削除 =================
$taskNames = @("AIハヤト競馬_予想", "AIハヤト競馬_結果")
if ($Mode -eq "uninstall") { foreach ($t in $taskNames) { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }; Log "自動実行を削除しました"; exit 0 }
if ($Mode -eq "install") {
  $script = Join-Path $root "weekend.ps1"
  $dates = @("2026-11-28", "2026-11-29", "2026-12-05", "2026-12-06", "2026-12-12", "2026-12-13", "2026-12-19", "2026-12-20")
  $trigP = @(); $trigR = @()
  foreach ($d in $dates) {
    $trigP += New-ScheduledTaskTrigger -Once -At ([datetime]"$d 08:30") -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration (New-TimeSpan -Hours 7)
    $trigR += New-ScheduledTaskTrigger -Once -At ([datetime]"$d 10:15") -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Hours 7)   # レースが終わるたびに結果を集める
    $trigR += New-ScheduledTaskTrigger -Once -At ([datetime]"$d 17:30")
    $trigR += New-ScheduledTaskTrigger -Once -At ([datetime]"$d 19:30")
  }
  $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
  # 予想：その日の日付を渡して実行（日付は実行時に今日を使う）
  $actP = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Mode predict"
  $actR = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Mode result"
  Register-ScheduledTask -TaskName $taskNames[0] -Action $actP -Trigger $trigP -Settings $set -Force | Out-Null
  Register-ScheduledTask -TaskName $taskNames[1] -Action $actR -Trigger $trigR -Settings $set -Force | Out-Null
  Log "自動実行を登録しました（11/28・29、12/5・6、12/12・13、12/19・20）：予想＝8:30から30分おき(15:30まで)、答え合わせ＝10:15から15分おき(17:15まで)と17:30・19:30"
  exit 0
}

# ================= 予想 =================
$mf = Join-Path $wk "model.json"
if (-not (Test-Path $mf)) { Log "model.json がありません。先に -Mode train を実行してください"; exit 1 }
$model = [IO.File]::ReadAllText($mf, $utf8) | ConvertFrom-Json
$wv = $model.weights; if ($wv.value) { $wv = $wv.value }; $w = @($wv | ForEach-Object { [double]$_ })
$jt = @{}; foreach ($pr in $model.jockey.PSObject.Properties) { $jt[$pr.Name] = @($pr.Value) }
$now = Get-Date
Log "予想：$Date の出馬表を読みます"
$meetings = @(Get-Meetings $Date)
if (-not $meetings.Count) { Log "この日の開催が見つかりません"; exit 0 }
$mdAll = @()
foreach ($mt in $meetings) {
  $day = Get-Jra "POST" "https://www.jra.go.jp/JRADB/accessD.html" $mt.cname $null
  $rcs = @([regex]::Matches($day, 'pw01dde\d\d\d\d\d{4}\d{4}\d\d\d{8}/[0-9A-F]{2}') | ForEach-Object { $_.Value } | Select-Object -Unique)
  foreach ($rc in $rcs) {
    $m = [regex]::Match($rc, '^pw01dde\d\d(\d\d)\d{4}\d{4}(\d\d)(\d{8})')
    $R = [int]$m.Groups[2].Value; $name = "{0}_{1}_{2:00}" -f $Date, $mt.venue, $R
    $pf = Join-Path $predDir ($name + ".json")
    if ((Test-Path $pf) -and -not $Force) { continue }
    try {
      $html = Get-Jra "POST" "https://www.jra.go.jp/JRADB/accessD.html" $rc $null
      [IO.File]::WriteAllText((Join-Path $rawDir ("{0}_{1:yyyyMMdd_HHmm}.html" -f $name, $now)), $html, $utf8)
      $tm = [regex]::Match($html, '発走時刻：\s*<strong>\s*(\d+)時(\d+)分')
      if ($tm.Success) { $st = [datetime]::ParseExact($Date + $tm.Groups[1].Value.PadLeft(2, '0') + $tm.Groups[2].Value.PadLeft(2, '0'), "yyyyMMddHHmm", $null)
        if (($st - $now).TotalMinutes -lt $MinMinutes -and -not $Force) { continue } }   # もう始まる／始まった
      $rname = Pick $html '<span class="race_name">(.*?)</span>'
      $cls = Pick $html '<div class="cell class">(.*?)</div>'
      $cat = Pick $html '<div class="cell category">(.*?)</div>'
      $cm = [regex]::Match($html, '<div class="cell course">.*?>\s*([\d,]+)\s*<span class="unit">.*?<span class="detail">\s*（(芝|ダート)', 'Singleline')
      if (-not $cm.Success) { $cm = [regex]::Match((Strip ([regex]::Match($html, '<div class="cell course">(.*?)</div>\s*</div>', 'Singleline').Groups[1].Value)), '([\d,]+)\s*メートル\s*（(芝|ダート)') }
      $dist = [int]($cm.Groups[1].Value -replace ',', ''); $surf = if ($cm.Groups[2].Value -eq "芝") { "芝" } else { "ダ" }
      if ($cat -like "障害*") { continue }
      $si = $html.IndexOf('<div id="syutsuba">'); $tb = $html.Substring($html.IndexOf("<tbody", $si)); $tb = $tb.Substring(0, $tb.IndexOf("</tbody>"))
      $hs = @()
      foreach ($tr in ($tb -split '<tr[\s>]' | Select-Object -Skip 1)) {
        $hname = Pick $tr '<div class="name">(.*?)</div>'; if (-not $hname) { continue }
        $numTxt = Pick $tr '<td class="num">(.*?)</td>'; $nm0 = [regex]::Match($numTxt, '^\s*(\d+)'); $num = if ($nm0.Success) { [int]$nm0.Groups[1].Value } else { $null }   # ブリンカー等の記号が付くことがある
        $odds = Pick $tr '<div class="odds_line">(.*?)</div>'
        if (-not $odds) { $odds = Pick $tr '<(?:div|td|p|span)[^>]*class="[^"]*odds[^"]*"[^>]*>(.*?)</(?:div|td|p|span)>' }
        if (-not $odds -and -not $diagDone) { $diagDone = $true; Log ("診断：オッズ欄が見つかりません。1頭目の行：" + ((Strip $tr).Substring(0, [math]::Min(300, (Strip $tr).Length)))) }
        $popv = $null; $pm = [regex]::Match($odds, '(\d+)\s*番人気'); if ($pm.Success) { $popv = [int]$pm.Groups[1].Value }
        $ov = $null; $om = [regex]::Match($odds, '(\d+\.\d)'); if ($om.Success) { $ov = [double]$om.Groups[1].Value }
        $bwraw = Pick $tr '<div class="cell weight">(.*?)</div>'
        $bwd = $null; $bm = [regex]::Match($bwraw, '\(([+-]?\d+)\)'); if ($bm.Success) { $bwd = [int]$bm.Groups[1].Value }
        $cn = [regex]::Match($tr, 'accessU\.html\?CNAME=(pw01dud[0-9A-Za-z/]+)').Groups[1].Value
        $cancel = Pick $tr '<div class="(?:cancel|scratch)[^"]*">(.*?)</div>'
        if ($cancel) { continue }
        $hs += [pscustomobject]@{ num = $num; name = $hname; cname = $cn; jockey = (Pick $tr '<p class="jockey">(.*?)</p>'); odds = $ov; pop = $popv; bwd = $bwd }
      }
      if (-not $hs.Count) { Log "$name：馬が読めません（出馬表がまだ？）"; continue }
      if (@($hs | Where-Object { $null -eq $_.num }).Count) { Log "$name：馬番がまだ決まっていません。あとでもう一度"; continue }
      if (@($hs | Where-Object { $null -eq $_.pop }).Count) {
        if (@($hs | Where-Object { $null -eq $_.odds }).Count -eq 0) {     # 人気が無くてもオッズがあれば、オッズの低い順を人気にする
          $ord = @($hs | Sort-Object odds); for ($i = 0; $i -lt $ord.Count; $i++) { $ord[$i].pop = $i + 1 } }
        else { Log "$name：人気・オッズがまだ出ていません。あとでもう一度"; continue } }
      $rd = $Date
      $FM = @(); $detail = @()
      foreach ($h in $hs) {
        $past = if ($h.cname) { @(Get-HorsePast $h.cname $rd) } else { @() }
        $fv = Get-Features @{ pop = $h.pop; past = $past; jockey = $h.jockey; bwdiff = $h.bwd } @{ venue = $mt.venue; dist = $dist; surf = $surf; date = $rd } $jt
        $FM += , $fv
        $detail += [pscustomobject]@{ past = $past }
      }
      $z = New-Object double[] $hs.Count
      for ($i = 0; $i -lt $z.Length; $i++) { $s = 0.0; for ($k = 0; $k -lt $NF; $k++) { $s += $w[$k] * $FM[$i][$k] }; $z[$i] = $s }
      $pr = Softmax $z
      $idx = @(0..($hs.Count - 1) | Sort-Object { -$pr[$_] })
      $n = $hs.Count
      # 堅さの判定：頭数とクラス
      $open = ($cls -match 'オープン|ＧⅠ|ＧⅡ|ＧⅢ|G[123Ⅰ-Ⅲ]|リステッド')
      if ($n -le 10) { $kind = "堅い寄り" } elseif ($n -ge 15 -or $open) { $kind = "荒れやすい" } else { $kind = "ふつう" }
      $hon = $idx[0]
      $aite = @($idx[1..3])
      $anaC = @($idx | Where-Object { $hs[$_].pop -ge 5 -and $hs[$_].pop -le 9 -and $_ -ne $hon } | Select-Object -First $(if ($kind -eq "荒れやすい") { 2 } elseif ($kind -eq "ふつう") { 1 } else { 0 }))
      $popOrder = @($hs | Sort-Object pop | Select-Object -First 5 | ForEach-Object { $_.num })
      # ◎の短いコメント（数字から自動で作る）
      $hh = $hs[$hon]; $cm2 = @("{0}番人気" -f $hh.pop)
      $pl = @($detail[$hon].past); if ($pl.Count) { $last = $pl | Select-Object -First 3 | ForEach-Object { $_.finish } ; $cm2 += ("近3走の着順 " + ($last -join "-")) } else { $cm2 += "初出走または過去走なし" }
      if ($FM[$hon][3] -gt 0.1) { $cm2 += "同距離・同芝ダが得意" } elseif ($FM[$hon][3] -lt -0.1) { $cm2 += "同距離・同芝ダは不得意" }
      if ($FM[$hon][4] -gt 0.1) { $cm2 += "この競馬場が得意" } elseif ($FM[$hon][4] -lt -0.1) { $cm2 += "この競馬場は不得意" }
      if ($FM[$hon][6] -ge 1) { $cm2 += "馬体重が大きく増減（注意）" }
      $o = [ordered]@{ race = $name; name = "$rname"; class = $cls; start = $(if ($tm.Success) { "{0}:{1}" -f $tm.Groups[1].Value, $tm.Groups[2].Value } else { "" }); fetched = (Get-Date -Format "MM/dd HH:mm")
        heads = $n; dist = $dist; surf = $surf; kind = $kind
        honmei = [ordered]@{ num = $hh.num; name = $hh.name; pop = $hh.pop; win_pct = [math]::Round(100 * $pr[$hon], 1); comment = ($cm2 -join "／") }
        aite = @($aite | ForEach-Object { [ordered]@{ num = $hs[$_].num; name = $hs[$_].name; pop = $hs[$_].pop; win_pct = [math]::Round(100 * $pr[$_], 1) } })
        ana = @($anaC | ForEach-Object { [ordered]@{ num = $hs[$_].num; name = $hs[$_].name; pop = $hs[$_].pop; win_pct = [math]::Round(100 * $pr[$_], 1) } })
        pop_order = $popOrder }
      [IO.File]::WriteAllText($pf, ($o | ConvertTo-Json -Depth 6), $utf8)
      Log ("保存：{0} {1} ◎{2}番 {3}（{4}）" -f $name, $rname, $hh.num, $hh.name, $kind)
    } catch { Log ("エラー {0}：{1} ／場所 {2}" -f $name, $_.Exception.Message, (($_.InvocationInfo.PositionMessage) -replace '\s+', ' ')) }
  }
}
# その日の予想を読みやすい表にまとめる
$md = New-Object Text.StringBuilder
[void]$md.AppendLine("# 予想：$Date"); [void]$md.AppendLine("")
[void]$md.AppendLine("◎＝システムの本命（人気＋過去の成績の数字）／相手＝次の3頭／穴候補＝人気5〜9番で点数が高い馬（参考。当てになるか検証中）／堅さ判定＝頭数とクラスから。"); [void]$md.AppendLine("")
[void]$md.AppendLine("| レース | 発走 | 頭数 | 判定 | ◎ | 相手 | 穴候補 | ◎のコメント |"); [void]$md.AppendLine("|---|---|---|---|---|---|---|---|")
foreach ($pf in Get-ChildItem $predDir -Filter "${Date}_*.json" | Sort-Object Name) {
  $p = [IO.File]::ReadAllText($pf.FullName, $utf8) | ConvertFrom-Json
  $a = (@($p.aite | ForEach-Object { "{0}番{1}" -f $_.num, $_.name }) -join "、"); $an = (@($p.ana | ForEach-Object { "{0}番{1}({2}人気)" -f $_.num, $_.name, $_.pop }) -join "、")
  [void]$md.AppendLine(("| {0} {1} | {2} | {3} | {4} | {5}番{6}({7}人気) | {8} | {9} | {10} |" -f $p.race, $p.name, $p.start, $p.heads, $p.kind, $p.honmei.num, $p.honmei.name, $p.honmei.pop, $a, $an, $p.honmei.comment))
}
[IO.File]::WriteAllText((Join-Path $wk ("予想_" + $Date + ".md")), $md.ToString(), (New-Object Text.UTF8Encoding($true)))
Log "予想を weekend\予想_$Date.md にまとめました"
Push-Sync $Date
