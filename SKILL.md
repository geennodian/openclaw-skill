---
name: openclaw-audio-transcribe
description: soundcore.comから音声ファイルを取得し、Whisper APIで文字起こし、子エージェントで要約して、Google Docsにまとめる音声処理スキル。会議録・インタビュー・音声メモの自動ドキュメント化に使用する。
version: 1.2.0
homepage: https://github.com/geennodian/openclaw-skill
allowed-tools: Bash(agent-browser:*)
metadata: {"openclaw": {"emoji": "🎙️", "requires": {"env": ["OPENAI_API_KEY", "GOG_ACCOUNT"], "bins": ["agent-browser", "gog", "curl"]}, "primaryEnv": "OPENAI_API_KEY", "install": [{"id": "agent-browser", "kind": "brew", "formula": "agent-browser", "bins": ["agent-browser"], "label": "Install agent-browser（OpenClaw公式ブラウザCLI）"}, {"id": "gogcli", "kind": "brew", "formula": "gogcli", "bins": ["gog"], "label": "Install gog CLI（Google認証・Docs/Drive操作）"}, {"id": "ffmpeg", "kind": "brew", "formula": "ffmpeg", "bins": ["ffmpeg"], "label": "Install ffmpeg（25MB超の音声ファイル分割用・任意）"}]}}
---

# OpenClaw Audio Transcribe

soundcore.com から音声を取得 → Whisper API で文字起こし → **子エージェント**で要約 → Google Docs に保存する、一気通貫の音声ドキュメント化スキル。

## 前提条件

| 項目 | 設定方法 |
|---|---|
| `OPENAI_API_KEY` | `export OPENAI_API_KEY=sk-...` |
| `GOG_ACCOUNT` | `export GOG_ACCOUNT=you@gmail.com` |
| `gog` CLI | `brew install gogcli` → `gog auth add $GOG_ACCOUNT --services drive,docs` |
| `agent-browser` | `brew install agent-browser`（OpenClaw公式ブラウザCLI） |
| `ffmpeg` | 任意。`brew install ffmpeg`（25MB超の音声のみ必要） |

## 使い方

```
/openclaw-audio-transcribe
/openclaw-audio-transcribe 今日の定例会議
```

引数に音声の説明を渡すと、soundcore.com 上で該当ファイルを優先的に選択する。

---

## サブエージェント構成

このスキルが呼び出されたら、**必ず `run_in_background: true` でサブエージェントを起動**すること。
メイン側は「処理を開始しました」とユーザーに即応答し、他の指示を受け付け続ける。

```
[ユーザー] → スキル呼び出し
     ↓
[メイン] 即応答「処理を開始しました」
     ↓ Agent(run_in_background: true)
[サブエージェントA: パイプライン全体]
  Step 1: ブラウザ操作 → 音声取得
  Step 2: Whisper API → 文字起こし
  Step 3: 子エージェントB（要約専任）← Agent を入れ子で起動
  Step 4: gog CLI + Docs API → Google Docs作成・Drive保存
  Step 5: /tmp クリーンアップ
     ↓ 完了
[メイン] Google Docs URL をユーザーに報告
```

---

## Step 1: 音声ファイルの取得（agent-browser）

**OpenClaw 公式ブラウザ CLI `agent-browser`** を使って soundcore.com を操作する。
操作パターン: `open → snapshot → interact（refで） → re-snapshot → verify`

```bash
mkdir -p /tmp/openclaw_audio

# 1. soundcore.com を開く
agent-browser open https://ai.soundcore.com/home

# 2. ページの対話要素を取得（アクセシビリティツリー）
agent-browser snapshot -i

# 3. スクリーンショットでページ状態を確認
agent-browser screenshot --out /tmp/openclaw_audio/page.png

# 4. ユーザーが指定した音声ファイル（または最新）の ref を特定
#    → snapshot の出力から対象ファイルの @ref（例: @e3）を読み取る

# 5. [確認] ダウンロード前にユーザーへ対象ファイル名を提示して許可を得る

# 6. ダウンロードボタンを ref でクリック
agent-browser click @e3   # ← ref は snapshot の出力から置き換える

# 7. ダウンロード完了後、ファイルを /tmp/openclaw_audio/ に移動
#    （ブラウザのデフォルトダウンロード先から mv する）
```

- ダウンロード先: `/tmp/openclaw_audio/`
- 対応形式: `mp3` / `m4a` / `wav` / `webm`
- UI が変更されていた場合: `snapshot -i` → `screenshot` を繰り返し、ref を再取得して適応する

---

## Step 2: 文字起こし（OpenAI Whisper API）

```bash
mkdir -p /tmp/openclaw_audio
FILE="/tmp/openclaw_audio/<ダウンロードしたファイル名>"
SIZE=$(stat -f%z "$FILE" 2>/dev/null || stat -c%s "$FILE")

if [ "$SIZE" -le 26214400 ]; then
  # 25MB 以下: そのまま送信
  curl -s https://api.openai.com/v1/audio/transcriptions \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -F file="@${FILE}" \
    -F model="whisper-1" \
    -F language="ja" \
    -F response_format="text" \
    > /tmp/openclaw_audio/transcript.txt
else
  # 25MB 超: ffmpeg で 10 分ごとに分割して順次送信・結合
  ffmpeg -i "$FILE" -f segment -segment_time 600 -c copy \
    /tmp/openclaw_audio/chunk_%03d.mp3

  > /tmp/openclaw_audio/transcript.txt
  for CHUNK in /tmp/openclaw_audio/chunk_*.mp3; do
    curl -s https://api.openai.com/v1/audio/transcriptions \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -F file="@${CHUNK}" \
      -F model="whisper-1" \
      -F language="ja" \
      -F response_format="text" \
      >> /tmp/openclaw_audio/transcript.txt
  done
fi
```

---

## Step 3: 要約（子エージェント）

**Codex CLI は不要。** Agent ツールで子エージェントを起動し、要約を生成させる。

サブエージェントへのプロンプト:

```
以下の文字起こしテキストの概要を日本語で作成してください。
- 要点を箇条書きで整理する
- 最後に 3 行以内の総括を付ける
- 出力はプレーンテキストのみ（マークダウン記号不要）

--- 文字起こし ---
<transcript.txt の全文>
--- ここまで ---
```

子エージェントの返答を `/tmp/openclaw_audio/summary.txt` に書き出す。

---

## Step 4: Google Docs 作成・Drive 保存（gog CLI）

概要と全文をテキストファイルに書き出し、`gog drive upload --convert-to=doc` で**1コマンド**でGoogle Docに変換してDriveに保存する。
トークン取得・API直呼び不要。gog が認証を完全に内部管理する。

```bash
TITLE="OpenClaw 文字起こし — $(date '+%Y-%m-%d %H:%M')"
SUMMARY=$(cat /tmp/openclaw_audio/summary.txt)
TRANSCRIPT=$(cat /tmp/openclaw_audio/transcript.txt)

# 概要＋全文をテキストファイルに整形
cat > /tmp/openclaw_audio/output.txt << CONTENT
概要

${SUMMARY}


文字起こし全文

${TRANSCRIPT}
CONTENT

# gog でアップロード → Google Doc に変換（フォルダ指定は任意）
DOC_JSON=$(gog drive upload /tmp/openclaw_audio/output.txt \
  --convert-to=doc \
  --name "$TITLE" \
  ${GOOGLE_DRIVE_FOLDER_ID:+--parent "$GOOGLE_DRIVE_FOLDER_ID"} \
  --json)

DOC_ID=$(echo "$DOC_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "CREATED: https://docs.google.com/document/d/${DOC_ID}/edit"
```

---

## Step 5: クリーンアップ

```bash
rm -rf /tmp/openclaw_audio/
```

ユーザーに確認の上、一時ファイルを削除する。

---

## エラーハンドリング

| エラー | 対処 |
|---|---|
| `OPENAI_API_KEY` 未設定 | `export OPENAI_API_KEY=sk-...` を案内する |
| `GOG_ACCOUNT` 未設定 | `export GOG_ACCOUNT=you@gmail.com` を案内する |
| `gog` 未認証 | `gog auth add $GOG_ACCOUNT --services drive,docs` を実行するよう案内する |
| soundcore.com UI 変更 | `agent-browser snapshot -i` → `agent-browser screenshot` で状況確認しユーザーに報告する |
| `agent-browser` 未インストール | `brew install agent-browser` を案内する |
| 音声ファイル 25MB 超 | `ffmpeg` で分割してから処理する |
| `ffmpeg` 未インストール | `brew install ffmpeg` を提案する |
| gog 認証エラー | `gog auth add $GOG_ACCOUNT --services drive,docs` を再実行する |
