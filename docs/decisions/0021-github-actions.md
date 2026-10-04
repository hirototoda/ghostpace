---
status: draft
date: 2026-10-04
---
# 0021. コードと仕様は公開リポジトリに置き、テストと TestFlight は GitHub Actions で回す
## 背景
- いくつものチャットが同時に開発していて、この Mac でテストの順番を待つ時間（ADR-0020）が開発を止めていた
- テストを GitHub Actions に移すと、非公開のリポジトリのままでは今のペース（PR が1日12本前後、TestFlight が1日3回）で月1.6万〜7万円かかり、無料枠も数日で尽きる。公開リポジトリなら標準の Mac が無料で、同時に5つまで動かせる
- この Mac から TestFlight に送ると、書き出しで毎回「Failed to Use Accounts」と出て止まり、オーナーが Xcode の Organizer から手で送っていた

## 決定（2026-10-04 オーナー決定）
### リポジトリを2つに分ける
- 公開：**ghostpace**。アプリのコード・テスト・仕様の docs（product・design・decisions・plan・verification）・Claude の決まりごと（CLAUDE.md・.claude）。履歴は作り直した（最初のコミットから）。ライセンスは付けず、README に「個人のアプリ。複製・利用は不可（All rights reserved）」と書く
- 非公開：**focus-app**（今までのリポジトリ）。報告（docs/reports）、判断待ちと決定済みの表（docs/owner/open-questions）、オーナーの作業（checklist・testflight-setup）、売り方（docs/business・docs/product/research・ADR-0015）、発信の下書き、実機の情報。ghostpace に移したコードと仕様は、移し替えを確かめたあと focus-app から消す
- 公開側には、個人の情報・値段・自分の数字（スクリーンタイムなど）・経緯・秘密の情報を書かない。非公開の文書に触れるときは「Q33（非公開の判断表）」「売り方の資料（非公開）」のように書く。仕様が参照する画面の画像は、見本データのものだけ公開側の docs/product/assets/ に置く
- 公開側の CLAUDE.md は共通のルールだけ。この Mac とオーナーの iPhone の情報は非公開側の CLAUDE.md に置き、公開側の最後の1行で読み込む（この Mac 以外では何も読まれない）

### 「docs が仕様の正」を2つのリポジトリで保つ
- 仕様（features・requirements・data-model・ADR・受け入れ基準）は、今までどおりコードと**同じ PR** で直す（ADR-0006）
- 報告・open-questions・checklist は、PR を出したときに Claude が focus-app の main に直接入れる（PR は作らない）。報告の「PR:」には ghostpace の PR を書く

### テスト（PR ごと）
- PR を出す・push すると、GitHub の Mac（`xcode-27`、Xcode 27.0・iPhone 18 Pro）でビルドを1回作り、3つの Mac で同時にテストする。塊1＝ユニットテスト全件＋UI テストの1/3、塊2・3＝UI テストの残り（PR 1本で Mac は最大3台）
- CI のシミュレーターは、この Mac と同じく日本時間・日本語・日本にしてから回す（地域で時刻の表示が12時間制に変わり、テストが落ちるため）
- UI テストは1回だけやり直す。やり直して通ったものは警告に名前を出す（不安定なテストを隠さない）
- docs・.claude・*.md だけの PR では Mac を使わない
- 「CI OK」が通ったら自動でマージする。Claude は報告を focus-app に入れたあと `gh pr merge <番号> --auto --squash --delete-branch` で予約する。main は「CI OK」を必須にしている
- 保存データの形を変える PR は予約せず、オーナーの確認を待つ（ADR-0010 の例外のまま）

### TestFlight（main）
- main にアプリが変わるコミットが入るたび、テスト全件（ユニット＋UI）→ 成功したら TestFlight に送る。docs だけの変更では送らない。続けて入ったときは、走っている1つのあと最新の1つだけ送る
- 署名と送信は App Store Connect の API キーで行う。キーは GitHub の環境「testflight」の秘密の設定に置き、main からしか使えない。PR や他人のフォークからは使えない（他人の PR は、オーナーが承認するまで CI も動かない）
- API キーで自動署名すると、新しい Mac では毎回、開発用の証明書が1枚作られる。上限まで増えないよう、送ったあとにその Mac で作られた証明書だけを取り消す

### この Mac
- `scripts/test.sh`（順番待ち）とフックは残す。使うのは急ぎのとき（失敗したテストを手元で直す、撮影）だけ。ふだんは push して CI で確かめる
- `scripts/testflight.sh` も残す。CI がこれを使って送る。この Mac から送るのは CI が使えないときだけ

## ほかの ADR との関係
- **ADR-0006**（docs を唯一の仕様とする）：変えない。「作業ごとに docs/reports/ へ報告」の置き場が非公開の focus-app になる
- **ADR-0010**（テストが通れば自動マージ）：条件は同じ（テスト成功・docs 更新・報告）。テストの成功を CI の「CI OK」で判定し、マージは GitHub の自動マージが行う。ビルドとユニットテストだけでなく UI テスト全件も条件になる
- **ADR-0011**（TestFlight で配る）：配り方は同じ。送るのは Claude の手作業から CI の自動に変わり、認証は Xcode の Apple ID から API キーに変わる（「API キーは必要になったときだけ」を置き換え）
- **ADR-0020**（Mac 全体の順番待ち）：PR のテストと TestFlight の前のテストは CI に移す。「PR では触った画面の UI テストだけ」は「PR ごとに UI テスト全件」に置き換える。順番待ちの仕組みは、この Mac で回すときのために残す

## 理由
- 公開リポジトリなら無料で、テストの待ちが Mac の混み具合に左右されない。同時5台なので、PR ごとに UI テスト全件を回せる。壊れたものが main に入る前に見つかる
- 履歴を作り直したので、今までの報告・売り方・個人のメールアドレスは公開されない
- API キーで送れば「Failed to Use Accounts」で止まらず、オーナーが Organizer で送る手間もなくなる
- 仕様を公開側に残すことで「同じ PR で docs を直す」が今までどおり守れる。報告と判断の表は、オーナーが読むもので PR のレビューには使っていないので、別の置き場でも困らない

## 影響・トレードオフ
- 報告と open-questions は ghostpace の PR から見えない。オーナーは focus-app の docs/reports を読む
- 公開側の docs から open-questions へのリンクは張れない（番号だけ）
- GitHub の Mac は5台まで。PR が2本と TestFlight が重なると、しばらく待つ
- CI の結果が出るまで20〜30分かかる（測った値は報告に書く）。急ぐときはこの Mac の scripts/test.sh
- API キー（Admin）は強い権限を持つ。漏れたら App Store Connect でキーを取り消し、作り直す
- 公開されたものは、消してもコピーが残りうる。公開側に何を書くかは review-checklist で毎回確かめる
