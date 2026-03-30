#!/bin/bash
# review.sh — Claude に設計書と実装の整合性をレビューさせる
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REVIEW_DIR="$PROJECT_DIR/reviews"

if [ $# -lt 1 ]; then
  echo "使い方: $0 <設計書のパス>"
  exit 1
fi

SPEC_FILE="$1"

if [ ! -f "$SPEC_FILE" ]; then
  echo "エラー: 設計書が見つかりません: $SPEC_FILE"
  exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REVIEW_FILE="$REVIEW_DIR/${TIMESTAMP}_review.md"

# git diff があれば取得、なければ変更ファイル一覧をfind で取得
CHANGES=""
if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  CHANGES=$(git diff --stat 2>/dev/null || true)
  if [ -z "$CHANGES" ]; then
    CHANGES=$(git diff --cached --stat 2>/dev/null || true)
  fi
fi

SPEC_CONTENT=$(cat "$SPEC_FILE")

echo "Claude にレビューを依頼中..."

claude --print "
あなたはコードレビュー担当です。
設計書の仕様に対して、現在のプロジェクトの実装をレビューしてください。

## 設計書
${SPEC_CONTENT}

## 変更概要
${CHANGES:-変更情報なし (git 管理外の可能性あり)}

## レビュー観点
以下の観点でレビューし、マークダウンで出力してください:

# レビュー結果
## 判定
PASS / FAIL / 要修正

## 設計との整合性
- 要件が満たされているか
- インターフェースが設計通りか

## コード品質
- 可読性
- エラーハンドリング
- セキュリティ上の懸念

## 指摘事項
具体的な問題点と修正案

## 総評
全体的な評価とコメント
" > "$REVIEW_FILE"

echo "レビュー結果: $REVIEW_FILE"
