// ============================================================
//  AIハヤト用：Fish Audio の声を作る中継（Google Apps Script）
//
//  ・Fish Audio の APIキーは、このプログラムには書きません。
//    「プロジェクトの設定」→「スクリプト プロパティ」に
//    名前 FISH_API_KEY で保存してください。
//  ・ハヤトから文章が届くと、Fish Audio で声（mp3）を作って返します。
// ============================================================

// 声を指定しなかったときに使う声（Fish Audio のモデルID）
const DEFAULT_VOICE = "0b5f5d693bf84621aea50e0f39e36c97";

function doPost(e) {
  try {
    const p = JSON.parse((e && e.postData && e.postData.contents) || "{}");
    const key = PropertiesService.getScriptProperties().getProperty("FISH_API_KEY");
    if (!key) return reply({ error: "GAS に FISH_API_KEY が設定されていません" });

    const text = String(p.text || "").slice(0, 500); // 1回に読む長さの上限（使いすぎ防止）
    if (!text.trim()) return reply({ error: "文章が空です" });
    const model = /^[a-z0-9.\-]+$/.test(p.model || "") ? p.model : "s2.1-pro-free";
    const voice = /^[0-9a-f]{32}$/.test(p.voice || "") ? p.voice : DEFAULT_VOICE;
    const speed = Math.min(1.6, Math.max(0.7, Number(p.speed) || 1));
    // low = 一番速い（返事の最初の一言）、balanced = 速さと質のバランス
    const latency = ["low", "balanced", "normal"].indexOf(p.latency) >= 0 ? p.latency : "balanced";

    const res = UrlFetchApp.fetch("https://api.fish.audio/v1/tts", {
      method: "post",
      contentType: "application/json",
      headers: { Authorization: "Bearer " + key, model: model },
      payload: JSON.stringify({
        text: text,
        reference_id: voice,
        format: "mp3",
        mp3_bitrate: 64,
        latency: latency,
        normalize: true,
        language: "ja",
        prosody: { speed: speed },
      }),
      muteHttpExceptions: true,
    });
    const code = res.getResponseCode();
    if (code !== 200) {
      return reply({ error: "Fish Audio のエラー（" + code + "）：" + res.getContentText().slice(0, 200) });
    }
    return reply({ audio: Utilities.base64Encode(res.getContent()) });
  } catch (err) {
    return reply({ error: String(err) });
  }
}

// ブラウザでURLを開いたときの確認用
function doGet() {
  return reply({ ok: true, message: "AIハヤトの声の中継は動いています" });
}

function reply(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

// 最初に1回だけ実行する：許可の確認と、Fish Audio のキーが使えるかのテスト
function testFish() {
  const out = doPost({ postData: { contents: JSON.stringify({ text: "テストです。ハヤトです。" }) } });
  const r = JSON.parse(out.getContent());
  if (r.audio) Logger.log("成功：声のデータができました（" + r.audio.length + " 文字分）");
  else Logger.log("失敗：" + r.error);
}
