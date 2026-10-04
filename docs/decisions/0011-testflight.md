---
status: draft
date: 2026-09-30
---
# 0011. iPhone への配布は TestFlight で行う
## 背景
オーナーは普段テザリングで開発している。Mac から iPhone へ直接インストールする方法（Wi-Fi・ケーブル）は、Mac と iPhone がつながっているときしか使えず、テザリング中に届くかも確かでない。マージした内容がいつスマホに反映されるのかも分かりにくかった。
## 決定
- 画面や動きが変わる PR をマージしたら、Claude が main から `scripts/testflight.sh` で TestFlight に送る
- iPhone は TestFlight アプリの自動更新で新しい版を受け取る（送ってから10〜30分）
- 署名とアップロードは Xcode にサインイン済みの Apple ID で行う。App Store Connect API キーは必要になったときだけ使い、リポジトリには置かない
- 急ぐとき・TestFlight が使えないときは、従来どおり `devicectl` で直接インストールする（CLAUDE.md）
## 理由
アップロードは数MBなのでテザリングでも送れる。Mac と iPhone の距離やネットワークに関係なく届き、オーナーの操作も要らない。
## 影響・トレードオフ
- 届くまで10〜30分かかる（直接インストールは数分）
- TestFlight の版は Release ビルドなので、開発用の「見本 ▾」メニューや起動引数は使えない
- ビルドの有効期限は90日。毎日使っていれば問題にならない
- 公開前に App Store の審査用の情報（スクリーンショット・説明文など）を別に用意する必要がある（ADR-0008 で公開を決めたとき）

## 追記（2026-10-04）
送るのは GitHub Actions（main にアプリが変わるコミットが入るたび）、認証は App Store Connect の API キー（GitHub の環境「testflight」の秘密の設定）に変えた。この Mac の `scripts/testflight.sh` は CI が使えないときだけ（[ADR-0021](0021-github-actions.md)）。
