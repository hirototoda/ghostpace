#!/bin/zsh
# GitHub Actions の Mac で、テスト用のシミュレーターをこの Mac と同じ条件にして起動し、UDID を出す。docs/decisions/0021
# - 時刻は日本時間（テストは +09:00 の時刻と端末のタイムゾーンで表示を確かめる）
# - 言語と地域は日本語・日本（日付や曜日の表示を確かめるテストがある）
# 起動は1回だけにする（新しく作った端末の初回起動と、言語のための再起動で7〜11分かかっていた）。
# 進み具合は標準エラーに、UDID だけを標準出力に出す。
set -euo pipefail
device="${SIM_DEVICE:-iPhone 18 Pro}"
runtime="${SIM_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-27-0}"
start=$SECONDS

# シミュレーターは Mac のタイムゾーンを使う。起動する前に変える
sudo ln -sf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime
print -u2 "タイムゾーン: $(date +%Z)"
[[ "$(date +%Z)" == JST ]] || print -u2 "::warning::Mac のタイムゾーンを日本時間にできなかった"

# イメージに最初からある端末を使う（なければ作る）
udid=$(xcrun simctl list devices available -j | jq -r --arg rt "$runtime" --arg name "$device" '.devices[$rt][]? | select(.name == $name) | .udid' | head -1)
[[ -n "$udid" ]] || udid=$(xcrun simctl create "CI $device" "$device" "$runtime")
xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
print -u2 "シミュレーター: $device ($udid)"

# 言語と地域を、起動する前に端末の設定ファイルへ書く
prefs="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Library/Preferences"
mkdir -p "$prefs"
defaults write "$prefs/.GlobalPreferences" AppleLanguages -array ja-JP en-JP
defaults write "$prefs/.GlobalPreferences" AppleLocale -string ja_JP

xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null
locale=$(xcrun simctl spawn "$udid" defaults read -g AppleLocale 2>/dev/null || true)
if [[ "$locale" != ja_JP ]]; then
    # 起動前の書き込みが効かなかったときは、起動してから書いて起動し直す
    print -u2 "言語の設定を起動し直して入れる（起動前は $locale）"
    xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array ja-JP en-JP
    xcrun simctl spawn "$udid" defaults write -g AppleLocale -string ja_JP
    xcrun simctl shutdown "$udid"
    xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" -b >/dev/null
    locale=$(xcrun simctl spawn "$udid" defaults read -g AppleLocale)
fi
print -u2 "言語: $locale・端末の時刻: $(xcrun simctl spawn "$udid" date +%Z 2>/dev/null || echo 不明)（準備 $(( SECONDS - start ))秒）"
print -r -- "$udid"
