---
status: draft
date: 2026-09-28
---
# 0003. Xcodeプロジェクトは XcodeGen で生成する
## 背景
実装はClaude Codeが行う。Xcodeのプロジェクトファイル（.pbxproj）はAIが編集すると壊れやすい。
## 決定
`project.yml` を正とし、`xcodegen generate` でプロジェクトを生成する。生成物はコミットしない。
## 理由
YAMLは読みやすく差分も明確。拡張機能の追加などもClaudeが安全に扱える。
## 影響・トレードオフ
XcodeGenのインストールが必要。Xcodeで設定を変えた場合は project.yml に反映しないと消える。
