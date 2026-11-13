# AIハヤト プロジェクトの作業ルール

## このプロジェクト
- 私（ユーザー）専属の音声AIアシスタント「AIハヤト」。
- 画面：`index.html`（HTML・CSS・JavaScript を1ファイルに）
- 中継サーバー：`netlify/functions/chat.mjs`（Netlify Functions。APIキーはここだけで使う）
- ハヤトの人格（システムプロンプト）は `chat.mjs` の `buildSystemPrompt` にある。
- 公開先：https://ai-hayato-ryo.netlify.app （Netlify、GitHub `ryoun0307/ai-hayato` と連携）
- APIキー `ANTHROPIC_API_KEY` は Netlify の環境変数にだけ置く。ファイルにもチャットにも書かない。

## GitHub と公開のルール（必ず守る）
Netlify の無料プランは月300クレジットで、本番を公開し直すたびに約15クレジット使う。

1. 作業中の変更は **`dev` ブランチ** にコミットし、作業の区切りで `git push origin dev` して GitHub に保存する。
   `dev` は netlify.toml の `ignore` 設定で公開されない（クレジットを使わない）。
2. **`main`（本番）には直接コミット・プッシュしない。**
3. 本番に出すのは、ユーザーが「公開して」「本番に出して」と言ったときだけ。
   その前に必ず「公開すると Netlify のクレジットを約15使います。よいですか？」と確認する。
4. 公開するときは、修正をまとめて1回で出す（`dev` を `main` にマージして `git push origin main`）。
5. 作業を始めるときは、まず `git switch dev` と `git pull origin dev` で最新の状態にする。

## 動作確認
- このPCには Node.js がないので、中継サーバーを手元で動かせない。
- 画面の見た目は、`index.html` をブラウザで開いて確認する（返事は来ない）。
- 本番の会話テストで Claude API を呼ぶと、少額だが Anthropic の料金がかかる。必要最小限にする。

## 説明のしかた
- ユーザーはエンジニアではない。日本語で、専門用語は言い換えて、手順は1つずつ具体的に説明する。
- 画面操作は、ボタン名や場所まで書く。
- ユーザーは iPhone（Safari）とPC（プライベートの Chrome）で使う。会社の Chrome では個人アカウントを使わない。

## 今後の予定
- 競馬予想の機能（テキストで回答）。GAS でデータ収集 → Opus が判断する構成を検討中。
  データの取得元（サイト・有料データの有無）はまだ決めていない。
