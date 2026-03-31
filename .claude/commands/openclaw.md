---
name: openclaw
description: soundcore.comから音声を取得し、文字起こし・要約・Google Docs出力を行う音声処理スキル
user-invocable: true
---

# OpenClaw — 音声→文字起こし→要約→Google Docs パイプライン

## 概要

soundcore.com から音声ファイルを取得し、Whisper APIで文字起こし、Codex CLIで要約、Google Docsに出力する。
全処理をサブエージェントで実行し、OpenClaw本体をブロックしない。

## 実行方法

ユーザーが `/openclaw` または `/openclaw <対象の音声の説明>` で呼び出す。

## 処理フロー

このスキルが呼び出されたら、以下の手順を **Agent ツール（サブエージェント）** で実行すること。
メインのコンテキストをブロックしないよう、`run_in_background: true` で起動する。

### サブエージェントへ渡すプロンプト

以下の4ステップを順番に実行してください:

---

### Step 1: 音声ファイルの取得（Chrome MCP）

1. `tabs_context_mcp` でブラウザタブを確認する
2. 必要に応じ `tabs_create_mcp` で新規タブを作成する
3. `navigate` で `https://ai.soundcore.com/home` にアクセスする
4. `screenshot` でページの状態を確認する
5. ユーザーが指定した音声ファイル、または最新の音声ファイルを特定する
6. ダウンロードリンクまたはボタンを `find` / `read_page` で探す
7. **ダウンロード前にユーザーに確認を取る**（セキュリティルール）
8. 音声ファイルをダウンロードし、ローカルの一時パスを取得する

- ダウンロード先: `/tmp/openclaw_audio/` 配下
- 対応形式: mp3, m4a, wav, webm

**注意**: soundcore.com のUI構造は変更される可能性がある。要素が見つからない場合は `screenshot` → `find` を繰り返して適応すること。

---

### Step 2: 文字起こし（OpenAI Whisper API）

ダウンロードした音声ファイルを Whisper API で文字起こしする。

```bash
# 環境変数 OPENAI_API_KEY が設定されていることを確認
# ファイルサイズが25MB以下ならそのまま送信
curl -s https://api.openai.com/v1/audio/transcriptions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: multipart/form-data" \
  -F file="@/tmp/openclaw_audio/<ファイル名>" \
  -F model="whisper-1" \
  -F language="ja" \
  -F response_format="text"
```

**25MB超の場合の分割処理:**

```bash
# ffmpegで10分ごとに分割
ffmpeg -i <入力ファイル> -f segment -segment_time 600 -c copy /tmp/openclaw_audio/chunk_%03d.mp3
# 各チャンクを順番にWhisper APIへ送信し、結果を結合
```

- ffmpegが未インストールの場合: `brew install ffmpeg` を実行（ユーザーに確認の上）
- 文字起こし結果は `/tmp/openclaw_audio/transcript.txt` に保存

---

### Step 3: 要約（Codex CLI）

文字起こし全文をCodex CLIに渡して要約を生成する。

```bash
# Codex CLI で要約を生成
cat /tmp/openclaw_audio/transcript.txt | codex "以下の文字起こしテキストの概要を日本語で作成してください。要点を箇条書きで整理し、最後に3行以内の総括を付けてください。" > /tmp/openclaw_audio/summary.txt
```

**Codex CLIが利用できない場合の代替:**

```bash
# codex コマンドの存在確認
which codex || echo "CODEX_NOT_FOUND"
```

codex が見つからない場合はユーザーに通知し、代替手段を提案すること。

---

### Step 4: Google Docsに出力（Google Drive保存）

Pythonスクリプトを使ってGoogle Docsを作成し、指定フォルダに格納する。

以下のPythonスクリプトを `/tmp/openclaw_audio/create_gdoc.py` として作成・実行する:

```python
#!/usr/bin/env python3
"""OpenClaw: Google Docs作成スクリプト"""
import sys
import os
from datetime import datetime
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
import pickle

SCOPES = [
    'https://www.googleapis.com/auth/documents',
    'https://www.googleapis.com/auth/drive.file'
]

def get_credentials():
    """認証情報を取得（トークンキャッシュ対応）"""
    creds = None
    token_path = os.path.expanduser('~/.openclaw/token.pickle')
    creds_path = os.path.expanduser('~/.openclaw/credentials.json')

    os.makedirs(os.path.dirname(token_path), exist_ok=True)

    if os.path.exists(token_path):
        with open(token_path, 'rb') as token:
            creds = pickle.load(token)

    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            if not os.path.exists(creds_path):
                print(f"ERROR: {creds_path} が見つかりません。")
                print("GCPコンソールからOAuth 2.0クライアントIDのJSONをダウンロードし、")
                print(f"{creds_path} に配置してください。")
                sys.exit(1)
            flow = InstalledAppFlow.from_client_secrets_file(creds_path, SCOPES)
            creds = flow.run_local_server(port=0)

        with open(token_path, 'wb') as token:
            pickle.dump(creds, token)

    return creds

def create_doc(title, summary_text, transcript_text, folder_id=None):
    """Google Docsを作成してDriveフォルダに格納"""
    creds = get_credentials()
    docs_service = build('docs', 'v1', credentials=creds)
    drive_service = build('drive', 'v3', credentials=creds)

    # ドキュメント作成
    doc = docs_service.documents().create(body={'title': title}).execute()
    doc_id = doc['documentId']

    # コンテンツ挿入（末尾から逆順に挿入）
    requests = [
        # 概要セクション
        {'insertText': {'location': {'index': 1}, 'text': '概要\n'}},
        {'updateParagraphStyle': {
            'range': {'startIndex': 1, 'endIndex': 4},
            'paragraphStyle': {'namedStyleType': 'HEADING_1'},
            'fields': 'namedStyleType'
        }},
        {'insertText': {'location': {'index': 4}, 'text': f'{summary_text}\n\n'}},
        # 全文セクション
        {'insertText': {
            'location': {'index': 4 + len(summary_text) + 2},
            'text': '文字起こし全文\n'
        }},
        {'updateParagraphStyle': {
            'range': {
                'startIndex': 4 + len(summary_text) + 2,
                'endIndex': 4 + len(summary_text) + 2 + 8
            },
            'paragraphStyle': {'namedStyleType': 'HEADING_1'},
            'fields': 'namedStyleType'
        }},
        {'insertText': {
            'location': {'index': 4 + len(summary_text) + 2 + 8},
            'text': f'{transcript_text}\n'
        }},
    ]

    docs_service.documents().batchUpdate(
        documentId=doc_id, body={'requests': requests}
    ).execute()

    # フォルダに移動（指定があれば）
    if folder_id:
        drive_service.files().update(
            fileId=doc_id,
            addParents=folder_id,
            removeParents='root',
            fields='id, parents'
        ).execute()

    doc_url = f'https://docs.google.com/document/d/{doc_id}/edit'
    print(f'CREATED: {doc_url}')
    return doc_url

if __name__ == '__main__':
    transcript_path = sys.argv[1] if len(sys.argv) > 1 else '/tmp/openclaw_audio/transcript.txt'
    summary_path = sys.argv[2] if len(sys.argv) > 2 else '/tmp/openclaw_audio/summary.txt'
    folder_id = sys.argv[3] if len(sys.argv) > 3 else None

    with open(transcript_path, 'r') as f:
        transcript = f.read()
    with open(summary_path, 'r') as f:
        summary = f.read()

    title = f"OpenClaw 文字起こし — {datetime.now().strftime('%Y-%m-%d %H:%M')}"
    create_doc(title, summary, transcript, folder_id)
```

実行:

```bash
python3 /tmp/openclaw_audio/create_gdoc.py \
  /tmp/openclaw_audio/transcript.txt \
  /tmp/openclaw_audio/summary.txt \
  "<Google DriveフォルダID（任意）>"
```

---

### Step 5: クリーンアップ

```bash
rm -rf /tmp/openclaw_audio/
```

一時ファイルを削除する（ユーザーに確認の上）。

---

## エラーハンドリング

| エラー | 対処 |
|---|---|
| OPENAI_API_KEY 未設定 | ユーザーに `export OPENAI_API_KEY=...` を案内 |
| soundcore.com のUI変更 | スクリーンショットを撮り、ユーザーに状況を報告 |
| 音声ファイル 25MB超 | ffmpegで分割してから処理 |
| ffmpeg 未インストール | `brew install ffmpeg` を提案 |
| codex CLI 未インストール | ユーザーに通知し、インストール方法を案内 |
| Google API 認証エラー | `~/.openclaw/credentials.json` の配置を案内 |
| Python パッケージ不足 | `pip3 install google-api-python-client google-auth-oauthlib` を実行 |

## サブエージェント構成

```
[ユーザー] → /openclaw
    ↓
[OpenClaw メイン] — ユーザーに「処理を開始しました」と即応答
    ↓ Agent(run_in_background: true)
[サブエージェント] — Step 1〜5 を順次実行
    ↓ 完了通知
[OpenClaw メイン] — ユーザーにGoogle DocsのURLを報告
```

**重要**: サブエージェントで実行することで、処理中もOpenClawは他の指示を受け付けられる。

## 前提条件

- `OPENAI_API_KEY` 環境変数が設定済み
- `~/.openclaw/credentials.json` にGCP OAuth認証情報が配置済み
- Python3 + `google-api-python-client`, `google-auth-oauthlib` がインストール済み
- Chrome MCPが接続済み
- （オプション）`codex` CLIがインストール済み
- （オプション）`ffmpeg` がインストール済み（大容量ファイル用）
