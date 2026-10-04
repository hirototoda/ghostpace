#!/bin/zsh
# GitHub Actions の Mac で、テスト用のシミュレーターの起動を始め、UDID を出す（起動を待たない。待つのは scripts/ci/run-tests.sh）。docs/decisions/0021
# - 時刻は日本時間にする（シミュレーターは Mac のタイムゾーンを使う。テストは +09:00 の時刻と端末のタイムゾーンで表示を確かめる）
# - 言語と地域（日本語・日本）は、起動を待ったあと scripts/ci/run-tests.sh が端末に書く
# 進み具合は標準エラーに、UDID だけを標準出力に出す。
set -euo pipefail
device="${SIM_DEVICE:-iPhone 18 Pro}"
runtime="${SIM_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-27-0}"

sudo ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
print -u2 "タイムゾーン: $(date +%Z)"
[[ "$(date +%Z)" == JST ]] || print -u2 "::warning::Mac のタイムゾーンを日本時間にできなかった"

# イメージに最初からある端末を使う（なければ作る）
udid=$(xcrun simctl list devices available -j | jq -r --arg rt "$runtime" --arg name "$device" '.devices[$rt][]? | select(.name == $name) | .udid' | head -1)
[[ -n "$udid" ]] || udid=$(xcrun simctl create "CI $device" "$device" "$runtime")
print -u2 "シミュレーター: $device ($udid) の起動を始めた"
xcrun simctl boot "$udid" 2>/dev/null || true
print -r -- "$udid"
