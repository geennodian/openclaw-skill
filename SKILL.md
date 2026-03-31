---
name: openclaw-audio-transcribe
description: soundcore.comから音声ファイルを取得し、Whisper APIで文字起こし、子エージェントで要約して、Google Docsにまとめる音声処理スキル。会議録・インタビュー・音声メモの自動ドキュメント化に使用する。
version: 1.1.0
homepage: https://github.com/geennodian/openclaw-skill
metadata: {"openclaw": {"emoji": "🎙️", "requires": {"env": ["OPENAI_API_KEY", "GOG_ACCOUNT"], "bins": ["gog", "curl"]}, "primaryEnv": "OPENAI_API_KEY", "install": [{"id": "gogcli", "kind": "brew", "formula": "gogcli", "bins": ["gog"], "label": "Install gog CLI（Google認証・Docs/Drive操作）"}, {"id": "ffmpeg", "kind": "brew", "formula": "ffmpeg", "bins": ["ffmpeg"], "label": "Install ffmpeg（25MB超の音声ファイル分割用・任意）"}]}}
---

# OpenClaw Audio Transcribe

soundcore.com から音声を取得 → Whisper API で文字起こし → **子エージェント**で要約 → Google Docs に保存する、一気通貫の音声ドキュメント化スキル。

## 前提条件

| 項目 | 設定方法 |
|---|---|
| `OPENAI_API_KEY` | `export OPENAI_API_KEY=sk-...` |
| `GOG_ACCOUNT` | `export GOG_ACCOUNT=you@gmail.com` |
| `gog` CLI | `brew install gogcli` → `gog auth add $GOG_ACCOUNT --services drive,docs` |
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

## Step 1: 音声ファイルの取得（ブラウザ操作）

以下の操作を **OpenClaw のブラウザツール**（`mcp__Claude_in_Chrome__` 系）で実行する。

```
1. mcp__Claude_in_Chrome__tabs_context_mcp  → 現在のタブ状態を確認
2. mcp__Claude_in_Chrome__tabs_create_mcp   → 新規タブを作成（必要な場合）
3. mcp__Claude_in_Chrome__navigate          → https://ai.soundcore.com/home にアクセス
4. mcp__Claude_in_Chrome__screenshot        → ページ状態を画像で確認
5. mcp__Claude_in_Chrome__read_page         → ページ全文を取得し音声ファイル一覧を特定
6. mcp__Claude_in_Chrome__find              → ダウンロードリンク・ボタンの DOM 要素を特定
7. [確認] ダウンロード前にユーザーへ対象ファイル名を提示して許可を得る
8. mcp__Claude_in_Chrome__navigate          → ダウンロード URL に直接アクセスしてファイル取得
```

- ダウンロード先: `/tmp/openclaw_audio/`（`mkdir -p` で作成）
- 対応形式: `mp3` / `m4a` / `wav` / `webm`
- UI が変更されていた場合: `screenshot` → `find` → `read_page` を繰り返して適応する

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

### 4-1. ドキュメント作成

```bash
# タイトルを日付入りで生成
TITLE="OpenClaw 文字起こし — $(date '+%Y-%m-%d %H:%M')"

# gog CLI で Google Doc を作成し、Doc ID を取得
DOC_ID=$(gog docs create --title "$TITLE" --json | python3 -c "import sys,json; print(json.load(sys.stdin)['documentId'])")

echo "Doc ID: $DOC_ID"
```

### 4-2. 認証トークン取得 → コンテンツ挿入（Docs API）

```bash
# gog が管理する OAuth トークンを取得
TOKEN=$(gog auth token "$GOG_ACCOUNT")

SUMMARY=$(cat /tmp/openclaw_audio/summary.txt)
TRANSCRIPT=$(cat /tmp/openclaw_audio/transcript.txt)

# batchUpdate で概要・全文を挿入
python3 - <<EOF
import json, urllib.request, os

doc_id   = "$DOC_ID"
token    = "$TOKEN"
summary  = open("/tmp/openclaw_audio/summary.txt").read()
transcript = open("/tmp/openclaw_audio/transcript.txt").read()

# 挿入リクエスト（末尾→先頭の逆順で index がずれない）
body = {"requests": [
    {"insertText": {"location": {"index": 1}, "text": "概要\n" + summary + "\n\n文字起こし全文\n" + transcript + "\n"}},
    {"updateParagraphStyle": {
        "range": {"startIndex": 1, "endIndex": 4},
        "paragraphStyle": {"namedStyleType": "HEADING_1"},
        "fields": "namedStyleType"
    }},
]}

req = urllib.request.Request(
    f"https://docs.googleapis.com/v1/documents/{doc_id}:batchUpdate",
    data=json.dumps(body).encode(),
    headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    method="POST"
)
urllib.request.urlopen(req)
print(f"CREATED: https://docs.google.com/document/d/{doc_id}/edit")
EOF
```

### 4-3. Drive フォルダへ移動（任意）

```bash
# GOOGLE_DRIVE_FOLDER_ID が設定されていれば移動
if [ -n "${GOOGLE_DRIVE_FOLDER_ID:-}" ]; then
  TOKEN=$(gog auth token "$GOG_ACCOUNT")
  # 現在の親を取得して移動
  curl -s -X PATCH \
    "https://www.googleapis.com/drive/v3/files/${DOC_ID}?addParents=${GOOGLE_DRIVE_FOLDER_ID}&removeParents=root&fields=id,parents" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json"
fi

echo "URL: https://docs.google.com/document/d/${DOC_ID}/edit"
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
| soundcore.com UI 変更 | `screenshot` で状況確認しユーザーに報告する |
| 音声ファイル 25MB 超 | `ffmpeg` で分割してから処理する |
| `ffmpeg` 未インストール | `brew install ffmpeg` を提案する |
| gog トークン期限切れ | `gog auth refresh $GOG_ACCOUNT` を実行する |
