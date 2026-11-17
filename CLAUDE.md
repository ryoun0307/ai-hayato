# AIハヤト プロジェクトの作業ルール

## このプロジェクト
- 私（ユーザー）専属の音声AIアシスタント「AIハヤト」。
- `index.html` 1ファイルに HTML・CSS・JavaScript をまとめた構成。
- 会話は Claude。ブラウザから Anthropic の公式SDK（esm.sh 経由）で直接呼ぶ。
  - モデル：設定画面の「いつも使うモデル」（初期値「速さ重視のおまかせ」＝ 判定なしでふだん Sonnet、「じっくり」「詳しく」・競馬は Opus。
    「おまかせ」＝ Haiku が easy/normal/hard を判定 → Haiku/Sonnet/Opus。待ち時間が出るのでユーザーは速さ重視を選んだ）。
  - 読み上げは文ごと。返事の最初の一言だけ「、」でも区切って早く話し始める（Fish Audio はその一言を latency low で作る）。エフォートは effortFor（じっくり=high、競馬=medium、Opus=medium、他=low）。話しかけた言葉に「オーパスで／ソネットで／ハイクで」があればその質問だけ切り替え（`detectMode`）。
  - 「じっくり」→ effort high、「詳しく」→【要点】だけ読み上げ・【詳細】は画面のみ。競馬の話題は両方オン。
  - Web検索（server tool）は常に渡し、使うかは Claude が判断（人格設定で「最新情報が必要なときだけ」と指示）。
  - 見た目：背景は media/space.mp4（くり返し再生）、キャラは media/hayato_talk.mp4（緑の背景を WebGL で透明化。話す間だけ再生、黙ると0.4秒の場面で停止）。動画が使えないときは描いた宇宙を表示し、キャラは出さない（仮のキャラは削除済み）。セリフ欄は左右それぞれ直近2個だけ残す。
  - iPhone はブラウザの音声認識が読み上げ後に壊れるため、キーボードの音声入力方式（`startDictation`）。
  - 声：設定で「Fish Audio の声を使う」をオンにすると、文ごとに中継経由で Fish Audio の声を作って再生（`speakFish`）。
    Fish Audio の API はブラウザから直接呼べない（CORS なし）ため中継が必要。中継は2種類（URL で自動判別）：
    ・Cloudflare Workers（`cloudflare/hayato-voice.js`、本命）：PCM 24kHz を流し読みし、Web Audio で届いた分から再生。GAS より速い（GAS は全部届くまで待つため約2秒遅れた）。
    ・GAS（`gas/fish-relay.gs`、予備）：mp3 を base64 で返す。
    Fish のキーは中継側（Cloudflare のシークレット／GAS のスクリプトプロパティ）の `FISH_API_KEY` にだけ置く。
    失敗したらブラウザの読み上げに自動で戻る。料金：s2.1-pro-free は 2026-11-30 まで無料、s2.1-pro は $15/100万バイト（日本語1文字=3バイト）。
- ハヤトの人格（システムプロンプト）は `index.html` の `buildSystemPrompt` にある。
- 記憶：返事のあと Haiku（`updateMemories`）が会話を読み、覚えることを add/remove（JSON）で返す → localStorage `hayato.memories` に保存（端末ごと・最大80件）。
  次の会話のシステムプロンプトに `memoryPromptSection` で入れる（会話途中では前提を変えない＝署名の制約）。設定画面で一覧・削除・オンオフ。4文字未満の発言は調べない。
  共有：設定の「記憶の合言葉」（8文字以上）と Cloudflare の中継 URL があれば、Worker の `/memory`（KV バインディング名 `MEMORY`、
  キーは合言葉の SHA-256）に置いて PC と iPhone で共有。開いたとき・画面に戻ったときに読み込み（`pullMemories`）、変更は最新を読んでから書く（`changeMemories`）。
- 地図：設定の「Google マップの APIキー」（Maps Embed API・無料、Google Cloud プロジェクト AI-Kaito、
  ウェブサイト制限 ryoun0307.github.io と 127.0.0.1:8766）を入れると、システムプロンプトに `mapPromptSection` が入り、
  ハヤトは返事の最後に【地図：検索語】と書く → `stripMapTag` で画面・読み上げから消し、`attachMap` でセリフ欄と履歴に地図（iframe）を付ける。
- 下のボタン列に「🔄 更新」（ホーム画面から開いたときは引っ張って更新できないため）。ホーム画面版と Safari は保存場所が別（設定を入れ直す必要あり）。
- 公開先：GitHub Pages（リポジトリ `ryoun0307/ai-hayato` の `main`）。公開は無料・回数制限なし。
- APIキーは各端末のブラウザ（localStorage）にだけ保存する。ユーザーが画面の「⚙ 設定」で自分で入力する。
  **APIキーをファイルやチャットに書かない。コミットしない。**
- リポジトリは Public。人格設定などが見られることは、ユーザーが了承済み。

## 経緯（同じ失敗をしないために）
- 以前は Netlify（中継サーバー）で公開していたが、Netlify 無料プランは本番公開1回で約15クレジット（月300）を使い、
  修正のたびに公開してクレジットを大きく減らしてしまった。2026-11-13 に GitHub Pages へ移行した。
- **料金が発生する操作（有料サービスへの公開、API の呼び出しなど）は、事前にユーザーへ費用を伝えて確認する。**

## GitHub のルール
1. 作業は `dev` ブランチでコミットし、区切りで `git push origin dev` して GitHub に保存する。
2. 公開（`dev` を `main` にマージして `git push origin main`）は、ユーザーが「公開して」と言ったときに行う。
   GitHub Pages は無料なので確認は軽くてよいが、何を公開するかはひと言伝える。
3. 作業を始めるときは `git switch dev` と `git pull origin dev` で最新にする。

## 動作確認
- 画面の見た目は `index.html` をブラウザで開いて確認できる（APIキーを入れれば会話も可能。ただし Claude の料金がかかる）。
- iPhone（Safari）での音声入力・読み上げは、公開URLを実機で開かないと確認できない。
- Claude Code アプリ内のブラウザではマイクが使えない。

## 説明のしかた
- ユーザーはエンジニアではない。日本語で、専門用語は言い換えて、手順は1つずつ具体的に説明する。
- 画面操作は、ボタン名や場所まで書く。
- ユーザーは iPhone（Safari）とPC（プライベートの Chrome）で使う。会社の Chrome では個人アカウントを使わない。

- 競馬データ：`gas/keiba.gs`（スプレッドシートに付ける GAS）が JRA 公式サイトの出馬表（JRADB accessD.html、Shift_JIS）を読み、
  シート「出馬表」に1レース1行（データ列に、馬体重・オッズ・過去4走・血統を短い文章にまとめたもの）で保存。毎日8時台・18時台に `collectAll`。
  ウェブアプリ `?action=list|race`（合言葉なし＝ユーザーの判断）。当日のレースは呼ばれた時に取り直す。
  ハヤトは設定「競馬データの URL」があれば、Claude に自前の道具 `keiba_races` / `keiba_race` を渡し（`keibaTools`）、tool_use を `runKeibaTool` で実行して続きを頼む。
  無料の JRA 公式のみ（robots.txt は全許可、私的使用の範囲）。対象はその日の中央競馬の全レース（主に東京・京都）。

## 今後の予定
- 競馬予想：実際の開催日に、GAS から JRA を読めるか・予想の質と1回の料金を確認する。
