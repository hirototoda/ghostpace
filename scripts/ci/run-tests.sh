#!/bin/zsh
# GitHub Actions で、作り終えたビルドを使ってテストの塊を1つ回す。docs/decisions/0021
#   scripts/ci/run-tests.sh <塊の番号> <塊の数> <シミュレーターの UDID> <ビルドの置き場（DerivedData）> <結果の置き場>
# 1つ目の塊はユニットテスト全件も回す。UI テストは scripts/ui-tests.sh の一覧を、上から順に塊の数で割り振る。
# UI テストは1回だけやり直す（シミュレーターの都合でたまに落ちるもののため）。やり直して通ったものは最後に名前を出す。
set -euo pipefail
cd "$(dirname "$0")/../.."
shard="$1" shards="$2" sim="$3" dd="$4" out="$5"
mkdir -p "$out"

xctestrun=$(ls "$dd"/Build/Products/*.xctestrun | head -1)
common=(test-without-building -xctestrun "$xctestrun" -destination "id=$sim" -collect-test-diagnostics never)

start=$SECONDS
xcrun simctl bootstatus "$sim" -b >/dev/null
echo "シミュレーターの起動を待った（$(( SECONDS - start ))秒）"
# 言語と地域を、この Mac のシミュレーターと同じ日本語・日本にする。時刻の表示（24時間制）が地域で変わり、テストが確かめている。
# xcodebuild の -testLanguage / -testRegion では12時間制のままだった。アプリは起動するたびに読むので、端末の起動し直しは要らない
xcrun simctl spawn "$sim" defaults write -g AppleLanguages -array ja-JP en-JP
xcrun simctl spawn "$sim" defaults write -g AppleLocale -string ja_JP
echo "言語と地域: $(xcrun simctl spawn "$sim" defaults read -g AppleLocale)"
failed=()

run() {  # $1: 名前, 残り: xcodebuild の引数
    local label="$1"; shift
    local log="$out/$label.log" rc=0 start=$SECONDS
    echo "::group::$label"
    xcodebuild "${common[@]}" "$@" -resultBundlePath "$out/$label.xcresult" > "$log" 2>&1 || rc=$?
    grep -E "Test (Case|case) .*(passed|failed)|Executed [0-9]+ tests?|Test run with|error:|recorded an issue" "$log" | tail -200 || true
    echo "::endgroup::"
    local took=$(( SECONDS - start ))
    if (( rc == 0 )); then
        echo "$label: 成功（$(( took / 60 ))分$(( took % 60 ))秒） $(grep -E "Executed [0-9]+ tests?|Test run with" "$log" | tail -1 | sed 's/^[[:space:]]*//')"
    else
        failed+=("$label")
        echo "::error title=$label::テストが失敗した（$(( took / 60 ))分$(( took % 60 ))秒）。詳しくは Artifacts の test-results"
        grep -E "error:|failed \(|recorded an issue|TEST FAILED" "$log" | head -30 || true
    fi
}

if (( shard == 1 )); then
    run unit -only-testing:FocusAppTests
fi

ui=()
i=0
for t in ${(f)"$(scripts/ui-tests.sh)"}; do
    (( i % shards + 1 == shard )) && ui+=("-only-testing:FocusAppUITests/$t")
    (( i += 1 ))
done
echo "UI テスト：全 $i 件のうち ${#ui} 件（塊 $shard / $shards）"
if (( ${#ui} )); then
    run "ui-$shard" "${ui[@]}" -retry-tests-on-failure -test-iterations 2
    # やり直して通ったものを知らせる（不安定なテストを隠さない）
    retried=$(grep -oE "Test [Cc]ase '[^']+' failed" "$out/ui-$shard.log" | sort -u || true)
    if [[ -n "$retried" && ! " ${failed[*]} " == *" ui-$shard "* ]]; then
        echo "::warning title=やり直して通った UI テスト::$(print -r -- "$retried" | tr '\n' ' ')"
    fi
fi

if (( ${#failed} )); then
    echo "失敗: ${failed[*]}"
    exit 1
fi
echo "すべて成功"
