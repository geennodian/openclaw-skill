#!/bin/bash
# workflow.sh — Claude(設計) → Codex(実装) → Claude(レビュー) の一括実行
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [ $# -lt 1 ]; then
  echo "使い方: $0 <タスクの説明>"
  echo "例:     $0 'ユーザー認証APIを実装する'"
  exit 1
fi

TASK="$1"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SPEC_FILE="$PROJECT_DIR/spec/${TIMESTAMP}_spec.md"

echo "=== Step 1/3: 設計 (Claude) ==="
"$SCRIPT_DIR/design.sh" "$TASK"
# design.sh が最新の spec ファイルを作成する
SPEC_FILE=$(ls -t "$PROJECT_DIR/spec/"*_spec.md 2>/dev/null | head -1)

if [ -z "$SPEC_FILE" ]; then
  echo "エラー: 設計書が作成されませんでした"
  exit 1
fi
echo "設計書: $SPEC_FILE"

echo ""
echo "=== Step 2/3: 実装 (Codex) ==="
"$SCRIPT_DIR/build.sh" "$SPEC_FILE"

echo ""
echo "=== Step 3/3: レビュー (Claude) ==="
"$SCRIPT_DIR/review.sh" "$SPEC_FILE"

echo ""
echo "=== 完了 ==="
echo "設計書:     $SPEC_FILE"
REVIEW_FILE=$(ls -t "$PROJECT_DIR/reviews/"*_review.md 2>/dev/null | head -1)
if [ -n "$REVIEW_FILE" ]; then
  echo "レビュー:   $REVIEW_FILE"
fi
