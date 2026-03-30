# Claude + Codex CLI 連携ワークフロー

## 役割分担

### Claude (設計・レビュー担当)
- タスクの設計書を `spec/` ディレクトリにマークダウンで出力する
- 設計書には要件、技術方針、ファイル構成、インターフェース定義を含める
- Codex の実装後、`spec/` の仕様との整合性をレビューする
- レビュー結果は `reviews/` ディレクトリに出力する

### Codex CLI (実装担当)
- `spec/` ディレクトリの設計書に従って実装を行う
- 設計書に記載のないスコープ外の変更は行わない

## ディレクトリ構成

```
spec/       # 設計書 (Claude が作成)
reviews/    # レビュー結果 (Claude が作成)
scripts/    # ワークフロー自動化スクリプト
```

## ワークフロー

1. `scripts/design.sh <タスク>` — Claude が設計書を作成
2. `scripts/build.sh <設計書>` — Codex が設計書に従い実装
3. `scripts/review.sh <設計書>` — Claude が実装をレビュー
4. `scripts/workflow.sh <タスク>` — 上記 1〜3 を一括実行
