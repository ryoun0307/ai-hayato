// ============================================================
//  AIハヤト用：Fish Audio の声を作る中継（Cloudflare Workers）
//
//  ・Fish Audio の APIキーは、このプログラムには書きません。
//    Cloudflare の「設定」→「変数とシークレット」に
//    種類「シークレット」、名前 FISH_API_KEY で保存してください。
//  ・ハヤトから文章が届くと、Fish Audio が声を作りながら送ってくるデータを、
//    そのまま少しずつハヤトへ流します（届いた分から再生できるので速い）。
//  ・/memory では、ハヤトの記憶を保存・読み出しします（PC と iPhone で共有するため）。
//    保存先は Cloudflare の KV。「バインディング」で名前 MEMORY としてつないでください。
//  ・/keiba では、PC が自動で作った競馬の予想・結果を保存し、ハヤトが読み出します（同じ KV・同じ合言葉）。
//  ・/keiba-view では、ハヤト自身が出した競馬の予想（仮・最終）をレースごとに記録し、読み出します（同じ KV）。
//    同じレースを何回聞かれても同じ答えにするためと、後日の答え合わせのため。
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
    let p = {};
    try { p = await request.json(); } catch { /* 空のまま */ }

    // ---- ハヤトの記憶（PC と iPhone で共有）----
    // 合言葉をそのまま保存せず、変換（ハッシュ）した値を名前にして保存する
    if (new URL(request.url).pathname === "/memory") {
      if (!env.MEMORY) return json({ error: "Cloudflare に記憶の保存先（KV・名前 MEMORY）がつながっていません" }, 500);
      const code = String(p.code || "");
      if (code.length < 8) return json({ error: "記憶の合言葉は8文字以上にしてください" }, 400);
      const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("hayato-memory:" + code));
      const key = "mem:" + [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
      if (p.action === "get") {
        const saved = await env.MEMORY.get(key, "json");
        return json({ memories: (saved && saved.memories) || [], exists: !!saved });
      }
      if (p.action === "put") {
        const list = (Array.isArray(p.memories) ? p.memories : []).slice(-100).map((m) => ({
          text: String((m && m.text) || "").slice(0, 120),
          at: String((m && m.at) || "").slice(0, 20),
        })).filter((m) => m.text);
        await env.MEMORY.put(key, JSON.stringify({ memories: list, updated: Date.now() }));
        return json({ ok: true, count: list.length });
      }
      return json({ error: "使えない呼び出し方です" }, 400);
    }

    // ---- 競馬の予想と結果（PC が送り、ハヤトが読む）----
    // 記憶と同じ合言葉を使う。保存先も同じ KV（MEMORY）。日付ごとに1つ保存。
    if (new URL(request.url).pathname === "/keiba") {
      if (!env.MEMORY) return json({ error: "Cloudflare に保存先（KV・名前 MEMORY）がつながっていません" }, 500);
      // 合言葉は使わない（競馬データの GAS と同じ考え方）。保存先は1つだけ。
      const base = "keiba:all:";
      if (p.action === "put") {
        const date = String(p.date || "");
        if (!/^\d{8}$/.test(date)) return json({ error: "日付は YYYYMMDD で送ってください" }, 400);
        const races = (Array.isArray(p.races) ? p.races : []).slice(0, 40);
        const value = JSON.stringify({ date, races, updated: String(p.updated || "") });
        if (value.length > 200000) return json({ error: "データが大きすぎます" }, 400);
        await env.MEMORY.put(base + date, value, { expirationTtl: 60 * 60 * 24 * 60 }); // 60日で消える
        await env.MEMORY.put(base + "latest", date, { expirationTtl: 60 * 60 * 24 * 60 });
        return json({ ok: true, count: races.length });
      }
      if (p.action === "get") {
        let date = String(p.date || "");
        if (!/^\d{8}$/.test(date)) date = (await env.MEMORY.get(base + "latest")) || "";
        const saved = date ? await env.MEMORY.get(base + date, "json") : null;
        return json(saved ? { ok: true, ...saved } : { ok: false, date, error: "その日の予想はまだ届いていません" });
      }
      return json({ error: "使えない呼び出し方です" }, 400);
    }

    // ---- ハヤト自身の競馬の予想（レースごとに仮・最終を記録）----
    if (new URL(request.url).pathname === "/keiba-view") {
      if (!env.MEMORY) return json({ error: "Cloudflare に保存先（KV・名前 MEMORY）がつながっていません" }, 500);
      const base = "keiba:view:";
      const TTL = 60 * 60 * 24 * 180; // 180日で消える
      const clip = (v, n) => String(v == null ? "" : v).slice(0, n);
      const horses = (a) => (Array.isArray(a) ? a : []).slice(0, 6).map((h) => clip(h, 40)).filter(Boolean);
      if (p.action === "dates") {
        const dates = (await env.MEMORY.get(base + "dates", "json")) || [];
        return json({ ok: true, dates });
      }
      const date = String(p.date || "");
      if (!/^\d{8}$/.test(date)) return json({ error: "日付は YYYYMMDD で送ってください" }, 400);
      const saved = (await env.MEMORY.get(base + date, "json")) || { date, races: {} };
      if (p.action === "get") return json({ ok: true, ...saved });
      if (p.action === "save") {
        const venue = clip(p.venue, 6), race = Number(p.race);
        if (!venue || !(race >= 1 && race <= 12)) return json({ error: "競馬場とレース番号（1〜12）を送ってください" }, 400);
        const stage = p.stage === "最終" ? "最終" : "仮";
        const key = venue + "_" + race;
        const r = saved.races[key] || { history: [] };
        const view = {
          stage, at: new Date().toISOString(),
          honmei: clip(p.honmei, 40), aite: horses(p.aite), ana: horses(p.ana),
          confidence: clip(p.confidence, 4), summary: clip(p.summary, 400), reason: clip(p.reason, 300),
        };
        if (!view.honmei) return json({ error: "本命の馬（馬番と馬名）を送ってください" }, 400);
        r[stage === "最終" ? "final" : "provisional"] = view;
        r.history = [...(r.history || []), { stage, at: view.at, honmei: view.honmei, reason: view.reason }].slice(-10);
        saved.races[key] = r;
        const value = JSON.stringify(saved);
        if (value.length > 200000) return json({ error: "データが大きすぎます" }, 400);
        await env.MEMORY.put(base + date, value, { expirationTtl: TTL });
        const dates = (await env.MEMORY.get(base + "dates", "json")) || [];
        if (!dates.includes(date)) {
          dates.push(date); dates.sort();
          await env.MEMORY.put(base + "dates", JSON.stringify(dates.slice(-60)), { expirationTtl: TTL });
        }
        return json({ ok: true, saved: key, stage });
      }
      return json({ error: "使えない呼び出し方です" }, 400);
    }

    // ---- Fish Audio の声 ----
    if (!env.FISH_API_KEY) return json({ error: "Cloudflare に FISH_API_KEY が設定されていません" }, 500);
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
