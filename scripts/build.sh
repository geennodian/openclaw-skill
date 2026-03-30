#!/bin/bash
# build.sh — Codex CLI に設計書に基づいて実装させる
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ $# -lt 1 ]; then
  echo "使い方: $0 <設計書のパス>"
  exit 1
fi

SPEC_FILE="$1"

if [ ! -f "$SPEC_FILE" ]; then
  echo "エラー: 設計書が見つかりません: $SPEC_FILE"
  exit 1
fi

echo "Codex に実装を依頼中..."
echo "設計書: $SPEC_FILE"

SPEC_CONTENT=$(cat "$SPEC_FILE")

codex exec --full-auto "
以下の設計書に従って実装してください。
設計書に記載されたスコープのみ実装し、スコープ外の変更は行わないでください。

--- 設計書 ---
${SPEC_CONTENT}
--- 設計書ここまで ---

上記の設計に従い、ファイルの作成・編集を行ってください。
"

echo "実装が完了しました"
