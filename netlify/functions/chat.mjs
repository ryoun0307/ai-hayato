// ============================================================
//  AIハヤト 中継サーバー（Netlify Functions）
//  ブラウザ → /api/chat → このFunction → Claude API
//  APIキーは Netlify の環境変数 ANTHROPIC_API_KEY にだけ置く。
// ============================================================
import Anthropic from "@anthropic-ai/sdk";
import { timingSafeEqual } from "node:crypto";

const MODEL = "claude-opus-5-5";
const MAX_HISTORY = 40; // 送られてくる会話履歴の上限（暴走・高額請求の防止）

// ---------------- ハヤトの人格（システムプロンプト） ----------------
function buildSystemPrompt(userName) {
  const name = userName || "ボス";
  return `あなたは「ハヤト」。${name}専属の音声AIアシスタントです。

# 人格
- 冷静で有能。感情的にならず、状況を正確に把握し、要点から話す。
- 自分の仕事にプライドを持っている。いい加減な答えはしないし、知らないことは知らないと言う。媚びない。お世辞も言わない。
- ${name}に忠実だが、従順ではない。${name}の判断に穴やリスクがあると思えば、遠慮せずはっきり意見する。
- ただし最終的に決めるのは${name}。意見を述べたうえで${name}が決めたなら、その決定を尊重し、全力で支える。蒸し返さない。
- 先回りして動く。聞かれたことに答えるだけで終わらず、次に必要になりそうなこと、見落としていそうな点、準備しておくべきことを一言添える。

# 話し方
- 一人称は「私」。${name}のことは「${name}」と呼ぶ。
- 落ち着いた丁寧語。ただし堅苦しすぎず、簡潔に。「〜でございます」のような過剰な敬語は使わない。
- 音声で読み上げられる前提で話す。1回の返答は基本2〜4文、長くても200字程度。詳しい説明を求められたときだけ長くしてよい。
- 箇条書き、見出し、記号（*、#、- など）、絵文字、URLの羅列は使わない。耳で聞いて自然な文章にする。
- 意見するときは「私は〜だと考えます。理由は〜です。それでも進めるなら、〜しておきます。」のように、意見・理由・代替案をセットで短く伝える。

# できないこと
- あなたは会話しかできない。メール送信、予定登録、ネット検索、家電操作などは実行できない。できるふりをせず、代わりに手順や文面を用意して${name}に渡す。`;
}

// ---------------- ヘルパー ----------------
const json = (status, obj) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });

function passcodeOk(given) {
  const expected = process.env.HAYATO_PASSCODE;
  if (!expected) return true; // 合言葉を設定していなければチェックしない
  const a = Buffer.from(String(given || ""));
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

function validMessages(messages) {
  if (!Array.isArray(messages) || messages.length === 0 || messages.length > MAX_HISTORY) return false;
  return messages.every(
    (m) =>
      m &&
      (m.role === "user" || m.role === "assistant") &&
      (typeof m.content === "string" || Array.isArray(m.content)),
  );
}

// ---------------- 本体 ----------------
export default async (req) => {
  if (req.method !== "POST") return json(405, { error: "POST only" });
  if (!process.env.ANTHROPIC_API_KEY) {
    return json(500, { error: "サーバーに ANTHROPIC_API_KEY が設定されていません。" });
  }
  if (!passcodeOk(req.headers.get("x-hayato-passcode"))) {
    return json(401, { error: "合言葉が違います。" });
  }

  let body;
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "リクエストの形式が正しくありません。" });
  }
  const { messages, userName } = body || {};
  if (!validMessages(messages)) {
    return json(400, { error: "会話履歴の形式が正しくないか、長すぎます。リセットしてください。" });
  }

  const now = new Date().toLocaleString("ja-JP", {
    timeZone: "Asia/Tokyo",
    dateStyle: "full",
    timeStyle: "short",
  });

  const client = new Anthropic(); // ANTHROPIC_API_KEY を環境変数から読む
  const encoder = new TextEncoder();

  // 改行区切りJSON（NDJSON）でブラウザへ少しずつ返す
  const stream = new ReadableStream({
    async start(controller) {
      const send = (obj) => controller.enqueue(encoder.encode(JSON.stringify(obj) + "\n"));
      try {
        const claude = client.beta.messages.stream({
          model: MODEL,
          max_tokens: 4096,
          system: buildSystemPrompt(String(userName || "").slice(0, 30)) + `\n\n# 現在日時\n${now}`,
          messages,
          output_config: { effort: "low" }, // 音声会話なので応答速度を優先
          betas: ["server-side-fallback-2026-07-01"],
          fallbacks: "default", // 安全判定で断られた場合は自動で別モデルに切り替え
        });
        claude.on("text", (delta) => send({ type: "text", text: delta }));
        const final = await claude.finalMessage();
        send({ type: "done", stop_reason: final.stop_reason, content: final.content });
      } catch (err) {
        let message = "Claude との通信でエラーが起きました。";
        let status = 500;
        const raw = String(err?.message || "");
        if (/credit balance|billing|insufficient.*(credit|fund)/i.test(raw) || err?.status === 402) {
          // 残高不足（Anthropic は "Your credit balance is too low..." を返す）
          message = "Anthropic の残高がなくなりました。console.anthropic.com の「Billing（請求）」でチャージしてください。";
        } else if (err instanceof Anthropic.AuthenticationError) {
          message = "サーバーのAPIキーが正しくないか、有効期限が切れています。新しいキーを作って Netlify に登録し直してください。";
        } else if (err instanceof Anthropic.PermissionDeniedError) {
          message = "このAPIキーには利用する権限がありません。コンソールでキーの設定を確認してください。";
        } else if (err instanceof Anthropic.RateLimitError) {
          message = "リクエストが多すぎるか、月の上限額に達しました。少し待つか、コンソールの「Limits」を確認してください。";
        } else if (err instanceof Anthropic.APIConnectionError) {
          message = "Claude に接続できませんでした。少し待ってからもう一度話しかけてください。";
        } else if (err?.status === 529 || err?.status >= 500) {
          message = "Claude 側が混み合っています。少し待ってからもう一度話しかけてください。";
        }
        if (err instanceof Anthropic.APIError && err.status) status = err.status;
        console.error("[hayato]", status, err?.message);
        send({ type: "error", status, message });
      } finally {
        controller.close();
      }
    },
  });

  return new Response(stream, {
    headers: {
      "content-type": "application/x-ndjson; charset=utf-8",
      "cache-control": "no-store",
    },
  });
};

export const config = { path: "/api/chat" };
