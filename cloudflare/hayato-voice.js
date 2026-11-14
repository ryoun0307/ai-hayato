// ============================================================
//  AIハヤト用：Fish Audio の声を作る中継（Cloudflare Workers）
//
//  ・Fish Audio の APIキーは、このプログラムには書きません。
//    Cloudflare の「設定」→「変数とシークレット」に
//    種類「シークレット」、名前 FISH_API_KEY で保存してください。
//  ・ハヤトから文章が届くと、Fish Audio が声を作りながら送ってくるデータを、
//    そのまま少しずつハヤトへ流します（届いた分から再生できるので速い）。
// ============================================================

// 声を指定しなかったときに使う声（Fish Audio のモデルID）
const DEFAULT_VOICE = "0b5f5d693bf84621aea50e0f39e36c97";

// このホームページからの呼び出しだけを受け付ける（他のサイトから使われないように）
const ALLOWED_ORIGINS = [
  "https://ryoun0307.github.io",
  "http://127.0.0.1:8766",
  "http://localhost:8766",
];

export default {
  async fetch(request, env) {
    const origin = request.headers.get("Origin") || "";
    const cors = {
      "Access-Control-Allow-Origin": ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0],
      "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
      "Vary": "Origin",
    };
    const json = (obj, status = 200) =>
      new Response(JSON.stringify(obj), { status, headers: { ...cors, "Content-Type": "application/json; charset=utf-8" } });

    if (request.method === "OPTIONS") return new Response(null, { headers: cors });
    // ブラウザでURLを開いたときの確認用
    if (request.method === "GET") return json({ ok: true, message: "AIハヤトの声の中継は動いています" });
    if (request.method !== "POST") return json({ error: "使えない呼び出し方です" }, 405);
    if (!ALLOWED_ORIGINS.includes(origin)) return json({ error: "このサイトからは使えません" }, 403);
    if (!env.FISH_API_KEY) return json({ error: "Cloudflare に FISH_API_KEY が設定されていません" }, 500);

    let p = {};
    try { p = await request.json(); } catch { /* 空のまま */ }
    const text = String(p.text || "").slice(0, 500); // 1回に読む長さの上限（使いすぎ防止）
    if (!text.trim()) return json({ error: "文章が空です" }, 400);
    const model = /^[a-z0-9.\-]+$/.test(p.model || "") ? p.model : "s2.1-pro-free";
    const voice = /^[0-9a-f]{32}$/.test(p.voice || "") ? p.voice : DEFAULT_VOICE;
    const speed = Math.min(1.6, Math.max(0.7, Number(p.speed) || 1));
    const latency = ["low", "balanced", "normal"].includes(p.latency) ? p.latency : "balanced";
    const format = p.format === "mp3" ? "mp3" : "pcm"; // pcm = 少しずつ再生しやすい形

    const body = {
      text,
      reference_id: voice,
      format,
      latency,
      normalize: true,
      language: "ja",
      prosody: { speed },
    };
    if (format === "pcm") body.sample_rate = 24000;
    else body.mp3_bitrate = 64;

    const res = await fetch("https://api.fish.audio/v1/tts", {
      method: "POST",
      headers: { Authorization: "Bearer " + env.FISH_API_KEY, "Content-Type": "application/json", model },
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      const detail = (await res.text()).slice(0, 200);
      return json({ error: "Fish Audio のエラー（" + res.status + "）：" + detail }, 502);
    }
    // 届いた声のデータを、ためずにそのまま流す
    return new Response(res.body, {
      headers: { ...cors, "Content-Type": format === "pcm" ? "audio/pcm" : "audio/mpeg", "Cache-Control": "no-store" },
    });
  },
};
