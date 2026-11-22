# ============================================================
#  競馬予想テスト用：JRA 公式サイトから過去レースのデータを集める道具
#  （このパソコンの PowerShell で動く。GAS・スプレッドシート・Claude API は使わない）
#
#  使い方（PowerShell で keiba-test フォルダに移動して実行）：
#    powershell -ExecutionPolicy Bypass -File collect.ps1 -From 20261115 -To 20261115 -Venue 東京 -MaxRaces 2
#
#  できるファイル（data フォルダ）：
#    data\question\日付_場_R.json … 予想に渡してよいデータ（発走前に分かっていたことだけ）
#    data\answer\日付_場_R.json   … 答え（着順・払戻金）。予想するときは絶対に読まない。
#    cache\                        … JRA から読んだページの控え（読み直しを減らすため。コミットしない）
#
#  ・1回 JRA を読むごとに 1 秒待つ（JRA に負担をかけないため）。
#  ・すでにできているレースは飛ばす（途中で止めても、続きから再開できる）。
# ============================================================
param(
  [string]$From = "20261004",
  [string]$To = "20261115",
  [string[]]$Venue = @("東京", "京都"),
  [int]$MaxRaces = 0,        # 0 = 全部。試すときは 2 など
  [int]$WaitMs = 1000,
  [int]$PastN = 4,           # 各馬の過去何走分を入れるか（10走版は 10）
  [string]$QSub = "question", # 予想用データの出力先（10走版は question10）
  [string]$ASub = "answer"    # 答えの出力先
)

$ErrorActionPreference = "Stop"
$Venue = @($Venue | ForEach-Object { $_ -split ',' })   # 「東京,京都」の形でも指定できる
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$sjis = [Text.Encoding]::GetEncoding(932)
$utf8 = New-Object Text.UTF8Encoding($false)
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$qDir = Join-Path $root ("data\" + $QSub)
$aDir = Join-Path $root ("data\" + $ASub)
$cDir = Join-Path $root "cache"
foreach ($d in @($qDir, $aDir, $cDir)) { New-Item -ItemType Directory -Force $d | Out-Null }

$VENUES = @{ "01"="札幌"; "02"="函館"; "03"="福島"; "04"="新潟"; "05"="東京"; "06"="中山"; "07"="中京"; "08"="京都"; "09"="阪神"; "10"="小倉" }
$venueCode = @{}; foreach ($k in $VENUES.Keys) { $venueCode[$VENUES[$k]] = $k }

# ---------- JRA のページを読む（1秒待つ） ----------
function Get-Jra([string]$Method, [string]$Url, [string]$Cname, [string]$CacheKey) {
  $cf = if ($CacheKey) { Join-Path $cDir ($CacheKey + ".html") } else { $null }
  if ($cf -and (Test-Path $cf)) { return [IO.File]::ReadAllText($cf, $utf8) }
  Start-Sleep -Milliseconds $WaitMs
  for ($try = 1; $try -le 3; $try++) {
    try {
      if ($Method -eq "POST") { $r = Invoke-WebRequest -Uri $Url -Method Post -Body @{ cname = $Cname } -UseBasicParsing }
      else { $r = Invoke-WebRequest -Uri $Url -UseBasicParsing }
      $html = $sjis.GetString($r.RawContentStream.ToArray())
      if ($cf) { [IO.File]::WriteAllText($cf, $html, $utf8) }
      return $html
    } catch {
      if ($try -eq 3) { throw }
      Start-Sleep -Seconds (3 * $try)
    }
  }
}

# ---------- HTML を文字にする ----------
function Strip([string]$s) {
  if (-not $s) { return "" }
  $s = [regex]::Replace($s, '<img[^>]*alt="([^"]*)"[^>]*>', ' $1 ')
  $s = [regex]::Replace($s, '<[^>]+>', ' ')
  $s = [Net.WebUtility]::HtmlDecode($s)
  return ([regex]::Replace($s, '\s+', ' ')).Trim()
}
function Pick([string]$s, [string]$re) {
  $m = [regex]::Match($s, $re, 'Singleline')
  if ($m.Success) { return (Strip $m.Groups[1].Value) } else { return "" }
}
function ToInt([string]$s) {
  $t = ($s -replace '[^\d]', '')
  if ($t) { return [int]$t } else { return $null }
}

# ---------- 各馬の成績ページ：このレースの日付より前の4走と血統 ----------
function Get-HorseInfo([string]$HorseCname, [string]$RaceDate) {
  $key = "horse_" + ($HorseCname -replace '[^0-9A-Za-z]', '_')
  $html = Get-Jra "GET" ("https://www.jra.go.jp/JRADB/accessU.html?CNAME=" + $HorseCname) $null $key
  $prof = @{}
  foreach ($label in @("父", "母", "母の父", "生年月日")) {
    $prof[$label] = Pick $html ('<dt>' + $label + '</dt>\s*<dd>(.*?)</dd>')
  }
  $start = $html.IndexOf("出走レース")
  $runs = @()
  if ($start -ge 0) {
    $tb = $html.Substring($start)
    $e = $tb.IndexOf("</tbody>")
    if ($e -ge 0) { $tb = $tb.Substring(0, $e) }
    foreach ($tr in [regex]::Matches($tb, '<tr>(.*?)</tr>', 'Singleline')) {
      $cells = @([regex]::Matches($tr.Groups[1].Value, '<td[^>]*>(.*?)</td>', 'Singleline') | ForEach-Object { Strip $_.Groups[1].Value })
      if ($cells.Count -lt 14) { continue }
      $dm = [regex]::Match($cells[0], '(\d+)年(\d+)月(\d+)日')
      if (-not $dm.Success) { continue }
      $d8 = "{0:0000}{1:00}{2:00}" -f [int]$dm.Groups[1].Value, [int]$dm.Groups[2].Value, [int]$dm.Groups[3].Value
      if ($d8 -ge $RaceDate) { continue }     # ★ そのレース当日以降の成績は絶対に入れない
      $runs += [ordered]@{
        date = $d8; venue = $cells[1]; race = $cells[2]; distance = $cells[3]; going = $cells[4]
        heads = (ToInt $cells[5]); popularity = (ToInt $cells[6]); finish = $cells[7]
        jockey = $cells[8]; weight = $cells[9]; body_weight = $cells[10]; time = $cells[11]
        winner = $cells[13]
      }
    }
  }
  # 新しい順に並んでいるが、念のため日付で並べ直して直近4走
  $runs = @($runs | Sort-Object { $_.date } -Descending | Select-Object -First $PastN)
  return @{ sire = $prof["父"]; dam = $prof["母"]; damsire = $prof["母の父"]; birth = $prof["生年月日"]; past = $runs }
}

# ---------- 1レースを集める ----------
function Collect-Race([string]$RaceCname, [string]$Date, [string]$VenueName, [int]$R) {
  $name = "{0}_{1}_{2:00}" -f $Date, $VenueName, $R
  $qf = Join-Path $qDir ($name + ".json")
  $af = Join-Path $aDir ($name + ".json")
  if (Test-Path $qf) { Write-Host "  飛ばす（できている）: $name"; return }

  $html = Get-Jra "POST" "https://www.jra.go.jp/JRADB/accessS.html" $RaceCname ("result_" + $Date + "_" + $VenueName + "_" + $R)
  $wait = ""

  # --- レース情報 ---
  $baba = @()
  foreach ($m in [regex]::Matches($html, '<li class="(?:weather|durt|turf)"><span class="inner"><span class="cap">(.*?)</span><span class="txt">(.*?)</span>', 'Singleline')) {
    $baba += ((Strip $m.Groups[1].Value) + ":" + (Strip $m.Groups[2].Value))
  }
  $course = Pick $html '<div class="cell course">(.*?)</div>\s*</div>'
  $race = [ordered]@{
    date = $Date; venue = $VenueName; race_no = $R
    day_label = Pick $html '<div class="cell date">(.*?)</div>'
    start_time = Pick $html '発走時刻：\s*<strong>(.*?)</strong>'
    name = Pick $html '<span class="race_name">(.*?)</span>'
    category = Pick $html '<div class="cell category">(.*?)</div>'
    class = Pick $html '<div class="cell class">(.*?)</div>'
    rule = Pick $html '<div class="cell rule">(.*?)</div>'
    weight_rule = Pick $html '<div class="cell weight">(.*?)</div>'
    course = $course
    track_condition = ($baba -join " ")     # 天候・馬場状態（当日の発表。最終予想でだけ使う）
  }

  # --- 出走馬 ---
  $tbody = [regex]::Match($html, '<tbody>(.*?)</tbody>', 'Singleline').Groups[1].Value
  $horsesQ = @(); $horsesA = @()
  foreach ($tr in [regex]::Matches($tbody, '<tr>(.*?)</tr>', 'Singleline')) {
    $t = $tr.Groups[1].Value
    $place = Pick $t '<td class="place">(.*?)</td>'
    $num = ToInt (Pick $t '<td class="num">(.*?)</td>')
    if ($null -eq $num) { continue }
    if ($place -match '^(取|除)') { continue }        # 取消・除外は出走していない
    $hname = Pick $t '<td class="horse">(.*?)</td>'
    $hcn = [regex]::Match($t, 'accessU\.html\?CNAME=([0-9A-Za-z/]+)').Groups[1].Value
    $bwRaw = [regex]::Match($t, '<td class="h_weight">(.*?)</td>', 'Singleline').Groups[1].Value
    $bw = ToInt (Pick $bwRaw '^(.*?)(?:<span|$)')
    $bwd = Pick $bwRaw '<span>\((.*?)\)</span>'
    $info = Get-HorseInfo $hcn $Date
    $horsesQ += [ordered]@{
      number = $num
      frame = Pick $t 'alt="枠(\d+)'
      name = $hname
      jra_id = $hcn
      sex_age = Pick $t '<td class="age">(.*?)</td>'
      weight_carried = Pick $t '<td class="weight">(.*?)</td>'
      jockey = Pick $t '<td class="jockey">(.*?)</td>'
      trainer = Pick $t '<td class="trainer">(.*?)</td>'
      sire = $info.sire; dam = ($info.dam -replace '\s*産駒\s*$', ''); damsire = $info.damsire
      past_runs = $info.past
      final = [ordered]@{                                 # 最終予想でだけ渡す（仮予想では隠す）
        body_weight = $bw; body_weight_diff = $bwd
        popularity = (ToInt (Pick $t '<td class="pop">(.*?)</td>'))
      }
    }
    $corner = @([regex]::Matches($t, '<li title="[^"]*">(\d+)</li>') | ForEach-Object { $_.Groups[1].Value }) -join "-"
    $horsesA += [ordered]@{
      number = $num; name = $hname; finish = $place
      time = Pick $t '<td class="time">(.*?)</td>'
      margin = Pick $t '<td class="margin">(.*?)</td>'
      corner = $corner
      last3f = Pick $t '<td class="f_time">(.*?)</td>'
      popularity = (ToInt (Pick $t '<td class="pop">(.*?)</td>'))
    }
  }

  # --- 払戻金 ---
  $pay = [ordered]@{}
  $kinds = [ordered]@{ win = "tansho"; place = "fukusho"; wakuren = "wakuren"; wide = "wide"; umaren = "umaren"; umatan = "umatan"; trio = "sanrenpuku"; tierce = "sanrentan" }
  foreach ($cls in $kinds.Keys) {
    $blk = [regex]::Match($html, '<li class="' + $cls + '">\s*<dl>(.*?)</dl>', 'Singleline').Groups[1].Value
    $lines = @()
    foreach ($ln in [regex]::Matches($blk, '<div class="num">(.*?)</div>\s*<div class="yen">([\d,]+)', 'Singleline')) {
      $lines += [ordered]@{ combo = (Strip $ln.Groups[1].Value); yen = (ToInt $ln.Groups[2].Value) }
    }
    $pay[$kinds[$cls]] = $lines
  }

  $q = [ordered]@{ race = $race; horses = $horsesQ }
  $a = [ordered]@{ race = [ordered]@{ date = $Date; venue = $VenueName; race_no = $R; name = $race.name }; results = $horsesA; payouts = $pay }
  [IO.File]::WriteAllText($qf, ($q | ConvertTo-Json -Depth 8), $utf8)
  [IO.File]::WriteAllText($af, ($a | ConvertTo-Json -Depth 8), $utf8)
  Write-Host ("  保存: {0}（{1}頭）" -f $name, $horsesQ.Count)
}

# ---------- 開催日の一覧 → レースの一覧 ----------
$list = Get-Jra "POST" "https://www.jra.go.jp/JRADB/accessS.html" "pw01sli00/AF" $null   # 開催日の一覧は控えを使わず、毎回最新を読む
$meetings = @()
foreach ($m in [regex]::Matches($list, '(pw01srl(?:10|00)(\d\d)\d{4}\d\d\d\d(\d{8})/[0-9A-F]{2})')) {
  $v = $VENUES[$m.Groups[2].Value]; $d = $m.Groups[3].Value
  if ($Venue -notcontains $v) { continue }
  if ($d -lt $From -or $d -gt $To) { continue }
  if ($meetings | Where-Object { $_.cname -eq $m.Groups[1].Value }) { continue }
  $meetings += [pscustomobject]@{ cname = $m.Groups[1].Value; venue = $v; date = $d }
}
$meetings = @($meetings | Sort-Object date, venue)
Write-Host ("対象の開催：{0}（{1} 〜 {2}）" -f $meetings.Count, $From, $To)

$done = 0
foreach ($mt in $meetings) {
  Write-Host ("{0} {1}" -f $mt.date, $mt.venue)
  $dayHtml = Get-Jra "POST" "https://www.jra.go.jp/JRADB/accessS.html" $mt.cname ("day_" + $mt.date + "_" + $mt.venue)
  $races = @([regex]::Matches($dayHtml, 'pw01sde(?:10|01)\d\d\d{4}\d\d\d\d(\d\d)\d{8}/[0-9A-F]{2}') | ForEach-Object { $_.Value } | Select-Object -Unique)
  foreach ($rc in $races) {
    $R = [int]([regex]::Match($rc, '^pw01sde(?:10|01)\d\d\d{4}\d\d\d\d(\d\d)').Groups[1].Value)
    Collect-Race $rc $mt.date $mt.venue $R
    $done++
    if ($MaxRaces -gt 0 -and $done -ge $MaxRaces) { Write-Host "指定の数に達したので止めます"; exit 0 }
  }
}
Write-Host "終わりました"
