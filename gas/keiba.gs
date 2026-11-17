// ============================================================
//  AIハヤト用：競馬データを集める GAS（スプレッドシートに付ける）
//
//  ・JRA 公式サイトの出馬表（馬体重・オッズ・過去4走・血統など）を読み取り、
//    このスプレッドシートの「出馬表」シートに1レース1行で保存します。
//  ・前日の夕方と当日の朝に自動で集めます（setupTriggers を1回実行すると設定されます）。
//  ・ハヤトから「このレースのデータをください」と頼まれたら、当日のレースは
//    その場で JRA から最新の内容（馬体重・オッズ）を取り直して返します。
//  ・個人で使う範囲のための仕組みです。JRA のサーバーに負担をかけないよう、
//    読み取りの間に少し間を空けています。
// ============================================================

const JRA = "https://www.jra.go.jp";
const VENUES = {
  "01": "札幌", "02": "函館", "03": "福島", "04": "新潟", "05": "東京",
  "06": "中山", "07": "中京", "08": "京都", "09": "阪神", "10": "小倉",
};
const SHEET_NAME = "出馬表";
const HEAD = ["日付", "競馬場", "R", "発走", "レース名", "取得時刻", "CNAME", "データ"];

// ---------------- JRA のページを読む ----------------
function jraFetch(path, cname) {
  Utilities.sleep(700); // 続けて読むときは少し間を空ける
  const opt = { muteHttpExceptions: true, followRedirects: true };
  if (cname) { opt.method = "post"; opt.payload = { cname: cname }; }
  const res = UrlFetchApp.fetch(JRA + path, opt);
  if (res.getResponseCode() !== 200) throw new Error("JRA のページを読めませんでした（" + res.getResponseCode() + "）");
  const html = res.getContentText("Shift_JIS");
  if (html.indexOf("パラメータエラー") >= 0 && html.indexOf('id="syutsuba"') < 0 && html.indexOf("pw01d") < 0) {
    throw new Error("JRA のページの場所が変わったようです");
  }
  return html;
}
function uniq(arr) { return arr.filter(function (v, i) { return arr.indexOf(v) === i; }); }

// 今週の開催日（競馬場ごと）の一覧：[{cname, venue, date}]
function getMeetings() {
  const html = jraFetch("/JRADB/accessD.html", "pw01dli00/F3");
  const out = [];
  const re = /(pw01drl10(\d\d)\d{4}\d\d\d\d(\d{8})\/[0-9A-F]{2})/g;
  let m;
  while ((m = re.exec(html))) out.push({ cname: m[1], venue: VENUES[m[2]] || m[2], date: m[3] });
  return uniq(out.map(JSON.stringify)).map(JSON.parse);
}
// 1日・1場のレース（出馬表）の CNAME 一覧
function getRaceCnames(meetingCname) {
  const html = jraFetch("/JRADB/accessD.html", meetingCname);
  const out = [];
  const re = /accessD\.html\?CNAME=(pw01dde[0-9A-Za-z\/]+)/g;
  let m;
  while ((m = re.exec(html))) out.push(m[1]);
  return uniq(out);
}

// ---------------- 出馬表のページを短い文章にまとめる ----------------
function strip(s) {
  return String(s || "")
    .replace(/<img[^>]*alt="([^"]*)"[^>]*>/gi, " $1 ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&#(\d+);/g, function (_, n) { return String.fromCharCode(Number(n)); })
    .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"')
    .replace(/\s+/g, " ")
    .replace(/ ?\( ?/g, "(").replace(/ ?\) ?/g, ")")
    .replace(/ (着|頭|番人気|番|kg)(?=[ ()]|$)/g, "$1")
    .trim();
}
function pick(s, re) { const m = String(s).match(re); return m ? strip(m[1]) : ""; }

function parsePast(cell) {
  cell = cell.slice(cell.indexOf(">") + 1);
  const end = cell.indexOf("</td>");
  if (end >= 0) cell = cell.slice(0, end);
  if (!strip(cell)) return "";
  cell = cell
    .replace(/<\/li>\s*<li[^>]*>/g, "-")                 // 通過順位 6-6
    .replace(/<p class="rating">/g, "<p>レート")
    .replace(/<p class="h_weight">/g, "<p>馬体重")
    .replace(/<div class="f3">\s*3F\s*/g, "<div>上がり")
    .replace(/<div class="corner_list">/g, "<div>通過")
    .replace(/<p class="fin">/g, "<p>相手");
  return strip(cell).replace(/^勝負服の画像 /, "");
}
function parseHorse(tr) {
  const waku = pick(tr, /alt="枠(\d+)/);
  const num = pick(tr, /<td class="num">([\s\S]*?)<\/td>/);
  const name = pick(tr, /<div class="name">([\s\S]*?)<\/div>/);
  if (!name) return "";
  const odds = pick(tr, /<div class="odds_line">([\s\S]*?)<\/div>/);
  const bw = pick(tr, /<div class="cell weight">([\s\S]*?)<\/div>/);
  const trainer = pick(tr, /<p class="trainer">([\s\S]*?)<\/p>/);
  const sire = pick(tr, /<li class="sire">([\s\S]*?)<\/li>/).replace(/^父：\s*/, "");
  const mare = pick(tr, /<li class="mare">([\s\S]*?)<\/li>/).replace(/^母：\s*/, "");
  const age = pick(tr, /<p class="age">([\s\S]*?)<\/p>/);
  const kg = pick(tr, /<p class="weight">([\s\S]*?)<\/p>/);
  const jockey = pick(tr, /<p class="jockey">([\s\S]*?)<\/p>/);
  // 取消・除外などの表示（あれば）
  const note = pick(tr, /<div class="(?:cancel|scratch)[^"]*">([\s\S]*?)<\/div>/);
  let line = (waku ? waku + "枠" : "") + num + "番 " + name + " " + age + " " + kg + " " + jockey +
    (odds ? " 単勝" + odds : "") + (bw ? " 馬体重" + bw : " 馬体重未発表") +
    " 調教師" + trainer + " 父" + sire + " 母" + mare + (note ? " 【" + note + "】" : "");
  const pasts = tr.split(/<td class="past/).slice(1).map(parsePast);
  pasts.forEach(function (p, i) { if (p) line += "\n　" + (i + 1) + "走前: " + p; });
  return line;
}
function parseCard(html, cname) {
  // CNAME の形：pw01dde 10 場(2) 年(4) 回(2) 日(2) R(2) 日付(8) /xx
  const c = cname.match(/^pw01dde10(\d\d)\d{4}\d\d\d\d(\d\d)(\d{8})/);
  const venue = c ? (VENUES[c[1]] || c[1]) : "";
  const R = c ? Number(c[2]) : Number(pick(html, /alt="(\d+)レース"/));
  const date = c ? c[3] : "";
  const day = pick(html, /<div class="cell date">([\s\S]*?)<\/div>/);
  const time = pick(html, /発走時刻：\s*<strong>([\s\S]*?)<\/strong>/);
  const name = pick(html, /<span class="race_name">([\s\S]*?)<\/h2>/);
  const cells = ["category", "class", "rule", "weight", "course"].map(function (k) {
    return pick(html, new RegExp('<div class="cell ' + k + '">([\\s\\S]*?)</div>'));
  }).filter(String).join(" ");
  const oddsTime = pick(html, /<p class="odds_line">([\s\S]*?)<\/p>/);
  const start = html.indexOf('<div id="syutsuba">');
  const tb = html.slice(html.indexOf("<tbody", start), html.indexOf("</tbody>", start));
  const horses = tb.split(/<tr[\s>]/).slice(1).map(parseHorse).filter(String);
  const now = Utilities.formatDate(new Date(), "Asia/Tokyo", "M/d H:mm");
  const text =
    "【" + venue + R + "R】" + day + " 発走" + time + "\n" +
    name + " " + cells + "\n" +
    (oddsTime ? oddsTime + "　" : "") + "（データ取得：" + now + "）\n" +
    horses.join("\n");
  return { date: date, venue: venue, R: R, time: time, name: name, text: text, fetched: now };
}
function fetchRace(cname) {
  return parseCard(jraFetch("/JRADB/accessD.html?CNAME=" + cname), cname);
}

// ---------------- スプレッドシートに保存・読み出し ----------------
function sheet() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sh = ss.getSheetByName(SHEET_NAME);
  if (!sh) {
    sh = ss.insertSheet(SHEET_NAME);
    sh.appendRow(HEAD);
    sh.setFrozenRows(1);
    sh.getRange("A:A").setNumberFormat("@"); // 日付は文字として保存（20261115 の形）
  }
  return sh;
}
function saveRace(sh, race, cname) {
  const rows = sh.getDataRange().getValues();
  const row = [race.date, race.venue, race.R, race.time, race.name, race.fetched, cname, race.text.slice(0, 49000)];
  for (let i = 1; i < rows.length; i++) {
    if (String(rows[i][0]) === race.date && rows[i][1] === race.venue && Number(rows[i][2]) === race.R) {
      sh.getRange(i + 1, 1, 1, row.length).setValues([row]);
      return;
    }
  }
  sh.appendRow(row);
}
function findRows(date, venue, R) {
  const rows = sheet().getDataRange().getValues().slice(1);
  return rows.filter(function (r) {
    return String(r[0]) === date && (!venue || r[1] === venue) && (!R || Number(r[2]) === R);
  });
}

// ---------------- 自動で集める（トリガーから呼ばれる） ----------------
// 今週の開催分（土日など、出馬表が出ている日すべて）を集める。
function collectAll() {
  const sh = sheet();
  const meetings = getMeetings();
  let count = 0;
  meetings.forEach(function (mt) {
    getRaceCnames(mt.cname).forEach(function (cn) {
      try { saveRace(sh, fetchRace(cn), cn); count++; }
      catch (e) { console.warn(cn + " を読めませんでした：" + e); }
    });
  });
  console.log("集めたレース：" + count + "（開催 " + meetings.length + "）");
  return count;
}
// 指定した日のレースだけ集める（シートにまだないとき用）
function collectDate(date) {
  const sh = sheet();
  let count = 0;
  getMeetings().filter(function (mt) { return mt.date === date; }).forEach(function (mt) {
    getRaceCnames(mt.cname).forEach(function (cn) {
      try { saveRace(sh, fetchRace(cn), cn); count++; } catch (e) { console.warn(e); }
    });
  });
  return count;
}

// 最初に1回だけ実行：自動で集める時間（毎日 朝8時台・夕方18時台）を設定する
function setupTriggers() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === "collectAll") ScriptApp.deleteTrigger(t);
  });
  [8, 18].forEach(function (h) {
    ScriptApp.newTrigger("collectAll").timeBased().atHour(h).everyDays(1).inTimezone("Asia/Tokyo").create();
  });
  console.log("自動で集める時間を設定しました（毎日 8時台・18時台）");
}

// ---------------- ハヤトからの呼び出し ----------------
// ?action=list&date=20261115           → その日のレース一覧
// ?action=race&date=20261115&venue=東京&race=11 → そのレースのデータ（当日なら最新に取り直す）
function doGet(e) {
  const p = (e && e.parameter) || {};
  try {
    if (!p.action) return reply({ ok: true, message: "AIハヤトの競馬データは動いています" });
    const today = Utilities.formatDate(new Date(), "Asia/Tokyo", "yyyyMMdd");
    const date = String(p.date || today).replace(/\D/g, "").slice(0, 8);
    const venue = String(p.venue || "").replace(/競馬場?$/, "");
    const R = Number(p.race || 0);

    let rows = findRows(date, p.action === "race" ? venue : "", 0);
    if (!rows.length && date >= today) { collectDate(date); rows = findRows(date, "", 0); }

    if (p.action === "list") {
      if (!rows.length) return reply({ ok: false, error: date + " の出馬表は見つかりませんでした（JRA の出馬表は開催の前日ごろに出ます）" });
      rows.sort(function (a, b) { return a[1] === b[1] ? a[2] - b[2] : (a[1] < b[1] ? -1 : 1); });
      return reply({ ok: true, date: date, races: rows.map(function (r) { return { venue: r[1], race: Number(r[2]), time: r[3], name: r[4] }; }) });
    }
    if (p.action === "race") {
      let row = rows.filter(function (r) { return r[1] === venue && Number(r[2]) === R; })[0];
      if (!row) return reply({ ok: false, error: date + " の" + venue + R + "R は見つかりませんでした" });
      // 当日のレースは、馬体重・オッズを最新にするため、その場で取り直す
      if (date === today && p.fresh !== "0") {
        try {
          const race = fetchRace(row[6]);
          saveRace(sheet(), race, row[6]);
          return reply({ ok: true, fresh: true, text: race.text });
        } catch (err) { /* 取り直せなければ、保存してある内容を返す */ }
      }
      return reply({ ok: true, fresh: false, text: row[7] });
    }
    return reply({ ok: false, error: "使えない呼び出し方です" });
  } catch (err) {
    return reply({ ok: false, error: String(err && err.message || err) });
  }
}
function reply(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}
