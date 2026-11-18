# 予想用データ（data\question）を読みやすい文章にして表示する。答え（data\answer）は読まない。
#   powershell -ExecutionPolicy Bypass -File render.ps1 -Race 20261115_京都_11 -Stage 仮     （仮予想：馬体重・人気・馬場は隠す）
#   powershell -ExecutionPolicy Bypass -File render.ps1 -Race 20261115_京都_11 -Stage 最終
param([string]$Race, [ValidateSet("仮", "最終", "最終差分")][string]$Stage = "仮")
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$q = [IO.File]::ReadAllText((Join-Path $root "data\question\$Race.json"), $utf8) | ConvertFrom-Json
$r = $q.race
"【{0}{1}R】{2} {3} 発走{4}" -f $r.venue, $r.race_no, $r.day_label, $r.name, $r.start_time
"{0} {1} {2} {3} {4}" -f $r.category, $r.class, $r.rule, $r.weight_rule, $r.course
if ($Stage -eq "最終") { "当日：" + $r.track_condition } else { "（仮予想：当日の天候・馬場、馬体重、人気は未発表）" }
"出走 {0}頭" -f @($q.horses).Count
""
foreach ($h in ($q.horses | Sort-Object number)) {
  $line = "{0}枠{1}番 {2} {3} {4}kg {5} 調教師{6} 父{7} 母父{8}" -f $h.frame, $h.number, $h.name, $h.sex_age, $h.weight_carried, $h.jockey, $h.trainer, $h.sire, $h.damsire
  if ($Stage -eq "最終") { $line += " 【馬体重{0}({1}) {2}番人気】" -f $h.final.body_weight, $h.final.body_weight_diff, $h.final.popularity }
  $line
  $i = 0
  foreach ($p in $h.past_runs) {
    $i++
    "  {0}走前 {1} {2} {3} {4}{5} {6}頭{7}人気{8}着 {9} {10}kg 体{11} {12} 勝:{13}" -f $i, $p.date, $p.venue, $p.race, $p.distance, $p.going, $p.heads, $p.popularity, $p.finish, $p.jockey, $p.weight, $p.body_weight, $p.time, $p.winner
  }
  if (-not @($h.past_runs).Count) { "  （過去の出走なし＝初出走）" }
}
