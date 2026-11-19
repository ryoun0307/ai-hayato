# 各馬の「過去の出走レース」の結果ページを集め、上がり3ハロン・通過順位・タイム・着差などを保存する。
#   powershell -ExecutionPolicy Bypass -File collect_past.ps1 [-Max 5]
# 出力：data\pastrace\<CNAME の / を _ にしたもの>.json（走った馬ごとの結果だけ。軽い）。できているものは飛ばす（再開できる）。
# 1回読むごとに 1 秒待つ（JRA に負担をかけない）。
param([int]$Max = 0, [int]$WaitMs = 1000, [int]$PerHorse = 10)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$sjis = [Text.Encoding]::GetEncoding(932)
$utf8 = New-Object Text.UTF8Encoding($false)
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $root "data\pastrace"; New-Item -ItemType Directory -Force $out | Out-Null

function Strip([string]$s) {
  $s = [regex]::Replace($s, '<img[^>]*alt="([^"]*)"[^>]*>', ' $1 ')
  $s = [regex]::Replace($s, '<[^>]+>', ' ')
  $s = [Net.WebUtility]::HtmlDecode($s)
  return ([regex]::Replace($s, '\s+', ' ')).Trim()
}
function Pick([string]$s, [string]$re) { $m = [regex]::Match($s, $re, 'Singleline'); if ($m.Success) { return (Strip $m.Groups[1].Value) } else { return "" } }

# 集める対象：馬のページの控え（cache\horse_*.html）に出てくる、各馬の直近 $PerHorse 走ぶんのレース
$todo = [ordered]@{}
foreach ($f in Get-ChildItem (Join-Path $root "cache") -Filter horse_*.html) {
  $h = [IO.File]::ReadAllText($f.FullName, $utf8)
  $i = $h.IndexOf("出走レース"); if ($i -lt 0) { continue }
  $n = 0
  foreach ($m in [regex]::Matches($h.Substring($i), 'CNAME=(pw01sde10[0-9A-F/]+)')) {
    $n++; if ($n -gt $PerHorse) { break }
    $todo[$m.Groups[1].Value] = 1
  }
}
Write-Host ("対象のレース：{0}" -f $todo.Count)
$done = 0
foreach ($cn in $todo.Keys) {
  $file = Join-Path $out (($cn -replace '[^0-9A-Za-z]', '_') + ".json")
  if (Test-Path $file) { continue }
  Start-Sleep -Milliseconds $WaitMs
  $html = $null
  for ($try = 1; $try -le 3; $try++) {
    try {
      $r = Invoke-WebRequest -Uri "https://www.jra.go.jp/JRADB/accessS.html" -Method Post -Body @{ cname = $cn } -UseBasicParsing
      $html = $sjis.GetString($r.RawContentStream.ToArray()); break
    } catch { if ($try -eq 3) { Write-Host "失敗: $cn"; } else { Start-Sleep -Seconds (3 * $try) } }
  }
  if (-not $html) { continue }
  $baba = @()
  foreach ($m in [regex]::Matches($html, '<li class="(?:weather|durt|turf)"><span class="inner"><span class="cap">(.*?)</span><span class="txt">(.*?)</span>', 'Singleline')) { $baba += ((Strip $m.Groups[1].Value) + ":" + (Strip $m.Groups[2].Value)) }
  $dateM = [regex]::Match($cn, '(\d{8})/')
  $info = [ordered]@{ cname = $cn; date = $dateM.Groups[1].Value
    name = Pick $html '<span class="race_name">(.*?)</span>'; category = Pick $html '<div class="cell category">(.*?)</div>'
    class = Pick $html '<div class="cell class">(.*?)</div>'; course = Pick $html '<div class="cell course">(.*?)</div>\s*</div>'
    track = ($baba -join " ") }
  $hs = @()
  $tbody = [regex]::Match($html, '<tbody>(.*?)</tbody>', 'Singleline').Groups[1].Value
  foreach ($tr in [regex]::Matches($tbody, '<tr>(.*?)</tr>', 'Singleline')) {
    $t = $tr.Groups[1].Value
    $name = Pick $t '<td class="horse">(.*?)</td>'; if (-not $name) { continue }
    $corner = @([regex]::Matches($t, '<li title="[^"]*">(\d+)</li>') | ForEach-Object { $_.Groups[1].Value }) -join "-"
    $hs += [ordered]@{ name = $name; finish = (Pick $t '<td class="place">(.*?)</td>'); num = (Pick $t '<td class="num">(.*?)</td>')
      time = (Pick $t '<td class="time">(.*?)</td>'); margin = (Pick $t '<td class="margin">(.*?)</td>'); corner = $corner
      last3f = (Pick $t '<td class="f_time">(.*?)</td>'); pop = (Pick $t '<td class="pop">(.*?)</td>') }
  }
  $o = [ordered]@{ race = $info; horses = $hs }
  [IO.File]::WriteAllText($file, ($o | ConvertTo-Json -Depth 6 -Compress), $utf8)
  $done++
  if ($done % 100 -eq 0) { Write-Host ("{0} 件保存" -f $done) }
  if ($Max -gt 0 -and $done -ge $Max) { Write-Host "指定の数に達したので止めます"; break }
}
Write-Host ("終わりました：今回 {0} 件、保存済みは全部で {1} 件" -f $done, @(Get-ChildItem $out -Filter *.json).Count)
