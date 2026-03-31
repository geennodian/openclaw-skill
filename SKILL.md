---
name: openclaw-audio-transcribe
description: soundcore.comから音声ファイルを取得し、Whisper APIで文字起こし、Codex CLIで要約して、Google Docsにまとめる音声処理スキル。会議録・インタビュー・音声メモの自動ドキュメント化に使用する。
version: 1.0.0
homepage: https://github.com/geennodian/openclaw-skill
metadata: {"openclaw": {"emoji": "🎙️", "requires": {"env": ["OPENAI_API_KEY"], "bins": ["python3", "codex"], "anyBins": ["ffmpeg"]}, "primaryEnv": "OPENAI_API_KEY", "install": [{"id": "google-api-python", "kind": "uv", "package": "google-api-python-client google-auth-oauthlib", "label": "Install Google API Python client"}, {"id": "ffmpeg", "kind": "brew", "formula": "ffmpeg", "bins": ["ffmpeg"], "label": "Install ffmpeg（25MB超の音声ファイル分割用・任意）"}]}}
---

# OpenClaw Audio Transcribe

soundcore.com から音声を取得 → Whisper API で文字起こし → Codex CLI で要約 → Google Docs に保存する、一気通貫の音声ドキュメント化スキル。

## 前提条件

| 項目 | 内容 |
|---|---|
| `OPENAI_API_KEY` | OpenAI API キー（Whisper API 利用） |
| `~/.openclaw/credentials.json` | GCP OAuth 2.0 クライアント認証情報 |
| `python3` | Python 3.8 以上 |
| `codex` | Codex CLI（要約生成） |
| `ffmpeg` | 任意。25MB 超の音声ファイルを分割する場合に必要 |

## 使い方

```
/openclaw-audio-transcribe
/openclaw-audio-transcribe 今日の定例会議
```

引数に音声の説明を渡すと、soundcore.com 上で該当ファイルを優先的に選択する。

---

## 処理フロー

このスキルが呼び出されたら、**必ずサブエージェント（`run_in_background: true`）** で以下 Step 1〜5 を実行すること。
メイン側はユーザーに「処理を開始しました」と即座に応答し、他の指示を受け付け続ける。

```
[ユーザー] → スキル呼び出し
     ↓
[メイン] 即応答「処理を開始しました」
     ↓ Agent(run_in_background: true)
[サブエージェント]
  Step 1: Chrome MCP → 音声取得
  Step 2: Whisper API → 文字起こし
  Step 3: Codex CLI → 要約
  Step 4: Google Docs API → ドキュメント作成・Drive保存
  Step 5: /tmp クリーンアップ
     ↓ 完了通知
[メイン] Google Docs URL をユーザーに報告
```

---

## Step 1: 音声ファイルの取得（Chrome MCP）

1. `tabs_context_mcp` でブラウザタブを確認する
2. 必要に応じ `tabs_create_mcp` で新規タブを作成する
3. `navigate` で `https://ai.soundcore.com/home` にアクセスする
4. `screenshot` でページの状態を確認する
5. ユーザーが指定した音声ファイル（または最新）を特定する
6. `find` / `read_page` でダウンロードリンク・ボタンを探す
7. **ダウンロード前にユーザーへ確認する**（セキュリティルール）
8. `/tmp/openclaw_audio/` へダウンロードする

対応形式: `mp3` / `m4a` / `wav` / `webm`

> **注意**: soundcore.com の UI が変更されている場合は `screenshot` → `find` を繰り返して適応する。

---

## Step 2: 文字起こし（OpenAI Whisper API）

```bash
mkdir -p /tmp/openclaw_audio

# ファイルサイズ確認
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

## Step 3: 要約（Codex CLI）

```bash
cat /tmp/openclaw_audio/transcript.txt \
  | codex "以下の文字起こしテキストの概要を日本語で作成してください。要点を箇条書きで整理し、最後に3行以内の総括を付けてください。" \
  > /tmp/openclaw_audio/summary.txt
```

`codex` が見つからない場合（`which codex` が失敗）:
- ユーザーに通知し、`npm install -g @openai/codex` を案内する
- ユーザーの許可を得た上でインストールを試みる

---

## Step 4: Google Docs 作成・Drive 保存（Python）

以下スクリプトを `/tmp/openclaw_audio/create_gdoc.py` として書き出し実行する。

```python
#!/usr/bin/env python3
"""OpenClaw: Google Docs 作成スクリプト"""
import sys, os, pickle
from datetime import datetime
from google_auth_oauthlib.flow import InstalledAppFlow
from google.auth.transport.requests import Request
from googleapiclient.discovery import build

SCOPES = [
    "https://www.googleapis.com/auth/documents",
    "https://www.googleapis.com/auth/drive.file",
]
TOKEN_PATH  = os.path.expanduser("~/.openclaw/token.pickle")
CREDS_PATH  = os.path.expanduser("~/.openclaw/credentials.json")

def get_credentials():
    creds = None
    os.makedirs(os.path.dirname(TOKEN_PATH), exist_ok=True)
    if os.path.exists(TOKEN_PATH):
        with open(TOKEN_PATH, "rb") as f:
            creds = pickle.load(f)
    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            if not os.path.exists(CREDS_PATH):
                print(f"ERROR: {CREDS_PATH} が見つかりません。")
                print("GCP コンソールから OAuth 2.0 クライアント ID の JSON をダウンロードし")
                print(f"{CREDS_PATH} に配置してください。")
                sys.exit(1)
            flow = InstalledAppFlow.from_client_secrets_file(CREDS_PATH, SCOPES)
            creds = flow.run_local_server(port=0)
        with open(TOKEN_PATH, "wb") as f:
            pickle.dump(creds, f)
    return creds

def build_requests(summary: str, transcript: str):
    """batchUpdate 用リクエストリストを構築"""
    reqs = []
    cursor = 1

    def insert(text):
        nonlocal cursor
        reqs.append({"insertText": {"location": {"index": cursor}, "text": text}})
        cursor += len(text)

    def heading(start, end):
        reqs.append({"updateParagraphStyle": {
            "range": {"startIndex": start, "endIndex": end},
            "paragraphStyle": {"namedStyleType": "HEADING_1"},
            "fields": "namedStyleType",
        }})

    # 概要セクション
    h1_start = cursor
    insert("概要\n")
    heading(h1_start, cursor)
    insert(summary + "\n\n")

    # 全文セクション
    h2_start = cursor
    insert("文字起こし全文\n")
    heading(h2_start, cursor)
    insert(transcript + "\n")

    return reqs

def create_doc(summary: str, transcript: str, folder_id: str | None = None):
    creds = get_credentials()
    docs  = build("docs",  "v1", credentials=creds)
    drive = build("drive", "v3", credentials=creds)

    title = f"OpenClaw 文字起こし — {datetime.now().strftime('%Y-%m-%d %H:%M')}"
    doc   = docs.documents().create(body={"title": title}).execute()
    doc_id = doc["documentId"]

    docs.documents().batchUpdate(
        documentId=doc_id,
        body={"requests": build_requests(summary, transcript)},
    ).execute()

    if folder_id:
        drive.files().update(
            fileId=doc_id,
            addParents=folder_id,
            removeParents="root",
            fields="id, parents",
        ).execute()

    url = f"https://docs.google.com/document/d/{doc_id}/edit"
    print(f"CREATED: {url}")
    return url

if __name__ == "__main__":
    transcript_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/openclaw_audio/transcript.txt"
    summary_path    = sys.argv[2] if len(sys.argv) > 2 else "/tmp/openclaw_audio/summary.txt"
    folder_id       = sys.argv[3] if len(sys.argv) > 3 else None

    with open(transcript_path) as f: transcript = f.read()
    with open(summary_path)    as f: summary    = f.read()

    create_doc(summary, transcript, folder_id)
```

```bash
# 依存パッケージ確認・インストール
pip3 show google-api-python-client google-auth-oauthlib > /dev/null 2>&1 \
  || pip3 install google-api-python-client google-auth-oauthlib

# 実行（フォルダ ID は任意）
python3 /tmp/openclaw_audio/create_gdoc.py \
  /tmp/openclaw_audio/transcript.txt \
  /tmp/openclaw_audio/summary.txt \
  "${GOOGLE_DRIVE_FOLDER_ID:-}"
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
| soundcore.com UI 変更 | `screenshot` で状況確認しユーザーに報告する |
| 音声ファイル 25MB 超 | `ffmpeg` で分割してから処理する |
| `ffmpeg` 未インストール | `brew install ffmpeg` を提案する |
| `codex` 未インストール | `npm install -g @openai/codex` を案内する |
| Google API 認証エラー | `~/.openclaw/credentials.json` の配置を案内する |
| Python パッケージ不足 | `pip3 install google-api-python-client google-auth-oauthlib` を実行する |
