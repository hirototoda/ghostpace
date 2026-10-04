#!/bin/zsh
# GitHub Actions の Mac で、テスト用のシミュレーターをこの Mac と同じ条件にして起動し、UDID を出す。docs/decisions/0021
# - 時刻は日本時間（テストは +09:00 の時刻と端末のタイムゾーンで表示を確かめる）
# - 言語と地域は日本語・日本（日付や曜日の表示を確かめるテストがある）
# 進み具合は標準エラーに、UDID だけを標準出力に出す。
set -euo pipefail
device="${SIM_DEVICE:-iPhone 18 Pro}"
runtime="${SIM_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-27-0}"

sudo systemsetup -settimezone Asia/Tokyo >/dev/null 2>&1 || sudo ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
print -u2 "タイムゾーン: $(date +%Z)"

udid=$(xcrun simctl create "CI $device" "$device" "$runtime")
print -u2 "シミュレーター: $device ($udid)"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array ja-JP en-JP
xcrun simctl spawn "$udid" defaults write -g AppleLocale -string ja_JP
# 言語の設定は起動し直すと効く
xcrun simctl shutdown "$udid"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null
print -u2 "言語: $(xcrun simctl spawn "$udid" defaults read -g AppleLocale)"
print -r -- "$udid"
