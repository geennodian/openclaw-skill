#!/bin/bash
# design.sh — Claude に設計書を作成させる
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SPEC_DIR="$PROJECT_DIR/spec"

if [ $# -lt 1 ]; then
  echo "使い方: $0 <タスクの説明>"
  exit 1
fi

TASK="$1"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SPEC_FILE="$SPEC_DIR/${TIMESTAMP}_spec.md"

echo "Claude に設計を依頼中..."

claude --print "
あなたは設計担当です。以下のタスクの設計書を作成してください。

## タスク
${TASK}

## 出力フォーマット (マークダウン)
以下のセクションを含めてください:

# タスク名
## 概要
タスクの目的と背景

## 要件
- 機能要件を箇条書き

## 技術方針
- 使用する技術・ライブラリ
- アーキテクチャの方針

## ファイル構成
作成・変更するファイルの一覧と役割

## インターフェース定義
関数シグネチャ、API エンドポイント等

## 実装上の注意点
- エッジケースや考慮事項

## 完了条件
この設計が満たされたと判断する基準
" > "$SPEC_FILE"

echo "設計書を作成しました: $SPEC_FILE"
