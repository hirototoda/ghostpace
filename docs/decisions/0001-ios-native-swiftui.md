---
status: draft
date: 2026-09-28
---
# 0001. iPhoneネイティブ（SwiftUI）で作る
## 背景
Opalのようなアプリブロックが必須機能。オーナーはiPhoneを使用。
## 決定
SwiftUIのネイティブアプリとして作る。
## 理由
アプリブロックにはScreen Time API（FamilyControls等）が必要で、WebやPWAでは実現できない。クロスプラットフォーム（Flutter等）でも拡張機能はSwiftで書く必要があり、利点が薄い。
## 影響・トレードオフ
Android対応はしない。Macが開発に必須。
