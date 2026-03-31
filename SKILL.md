---
name: audio-transcribe
description: soundcore.comから音声ファイルを取得し、faster-whisperで文字起こし、子エージェントで要約して、Google Docsにまとめる音声処理スキル。会議録・インタビュー・音声メモの自動ドキュメント化に使用する。「音声を文字起こしして」「soundcoreの録音をドキュメントにして」「会議の音声をまとめて」などのリクエストに使用する。
---

# audio-transcribe

soundcore.com から音声を取得 → faster-whisper で文字起こし → 子エージェントで要約 → Google Docs に保存する。

## 前提条件

| 項目 | 設定 |
|---|---|
| `faster-whisper` | インストール済み（v1.2.1） |
| `gog` CLI | `g.sugimura@nodi-an.com` で認証済み（drive,docs） |
| `browser` ツール | OpenClaw組み込み。有効化済み |
| `ffmpeg` | インストール済み。25MB超の音声ファイル分割用 |

## 処理フロー

スキル呼び出し時、**必ず `sessions_spawn` で子エージェントにパイプライン全体を委譲**する。
メインセッションは「処理を開始しました」と即応答し、他の指示を受け付け続ける。

```
[ユーザー] → スキル呼び出し
     ↓
[メイン] 即応答「🎙️ 処理を開始しました」
     ↓ sessions_spawn
[子エージェント: パイプライン全体]
  Step 1: browser ツール → soundcore.com から音声取得
  Step 2: faster-whisper (medium/int8) → 文字起こし
  Step 3: LLM自身が要約生成
  Step 4: gog drive upload → Google Docs作成
  Step 5: /tmp クリーンアップ
     ↓ 完了通知
[メイン] Google Docs URL をユーザーに報告
```

---

## Step 1: 音声ファイルの取得（browser ツール）

OpenClawの **組み込み `browser` ツール** を使って soundcore.com を操作する。

1. `browser(action="navigate", url="https://ai.soundcore.com/home")` でページを開く
2. `browser(action="snapshot")` でページ構造を取得し、音声ファイル一覧を確認
3. `browser(action="screenshot")` で表示状態を目視確認
4. ユーザーが指定した音声ファイル（または最新）を特定
5. **ダウンロード前にユーザーへ対象ファイル名を提示して許可を得る**
6. `browser(action="act", kind="click", ref="<対象ref>")` でダウンロード実行
7. ダウンロードしたファイルを `/tmp/openclaw_audio/` に移動

```bash
mkdir -p /tmp/openclaw_audio
```

- 対応形式: `mp3` / `m4a` / `wav` / `webm`
- ログインが必要な場合: スクリーンショットでログイン画面を確認し、sugimuraさんにVNC経由での操作を依頼する
- UI変更時: snapshot + screenshot を繰り返して適応する

---

## Step 2: 文字起こし（faster-whisper ローカル実行）

**APIキー不要。** faster-whisper を使いCPU上でint8量子化実行する。
デフォルトモデル: `medium`（精度と速度のバランス最良）

```python
#!/usr/bin/env python3
"""faster-whisper による文字起こし"""
import sys
from faster_whisper import WhisperModel

audio_file = sys.argv[1]
output_file = sys.argv[2] if len(sys.argv) > 2 else "/tmp/openclaw_audio/transcript.txt"

model = WhisperModel("medium", device="cpu", compute_type="int8")
segments, info = model.transcribe(audio_file, language="ja")

with open(output_file, "w") as f:
    for segment in segments:
        f.write(segment.text + "\n")

print(f"完了: {output_file}")
```

**実行:**
```bash
python3 -c "
from faster_whisper import WhisperModel
model = WhisperModel('medium', device='cpu', compute_type='int8')
segments, info = model.transcribe('/tmp/openclaw_audio/<ファイル名>', language='ja')
with open('/tmp/openclaw_audio/transcript.txt', 'w') as f:
    for seg in segments:
        f.write(seg.text + '\n')
print('文字起こし完了')
"
```

**性能目安（2コアCPU、GPUなし）:**
| 音声の長さ | 処理時間 |
|---|---|
| 5分 | 約3分 |
| 30分 | 約16分 |
| 1時間 | 約32分 |

**25MB超の音声ファイルの場合:**
faster-whisperはファイルサイズ制限がないため分割不要。そのまま渡せる。
（Whisper APIと違い、ローカル実行なので制限なし）

---

## Step 3: 要約

子エージェント自身が文字起こしテキストを読み、以下の形式で要約を生成する。
外部CLIは不要。

**要約フォーマット:**
- 要点を箇条書きで整理
- 最後に3行以内の総括
- プレーンテキストのみ（マークダウン記号不要）

要約結果を `/tmp/openclaw_audio/summary.txt` に書き出す。

---

## Step 4: Google Docs 作成（gog CLI）

```bash
TITLE="文字起こし — $(TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M')"
SUMMARY=$(cat /tmp/openclaw_audio/summary.txt)
TRANSCRIPT=$(cat /tmp/openclaw_audio/transcript.txt)

cat > /tmp/openclaw_audio/output.txt << CONTENT
概要

${SUMMARY}


文字起こし全文

${TRANSCRIPT}
CONTENT

gog drive upload /tmp/openclaw_audio/output.txt \
  -a g.sugimura@nodi-an.com \
  --convert-to=doc \
  --name "$TITLE" \
  ${GOOGLE_DRIVE_FOLDER_ID:+--parent "$GOOGLE_DRIVE_FOLDER_ID"} \
  --json
```

出力からドキュメントIDを取得し、`https://docs.google.com/document/d/<ID>/edit` をユーザーに報告する。

---

## Step 5: クリーンアップ

```bash
rm -rf /tmp/openclaw_audio/
```

---

## エラーハンドリング

| エラー | 対処 |
|---|---|
| faster-whisper import エラー | `pip3 install faster-whisper` を実行 |
| メモリ不足（medium） | `small` モデルにフォールバック |
| soundcore.com ログイン要求 | VNC経由でsugimuraさんに操作を依頼 |
| soundcore.com UI変更 | snapshot + screenshot で適応 |
| gog 認証エラー | `gog auth list` で状態確認、再認証を案内 |
