#!/bin/zsh
# シミュレーターでアプリを起動し直してスクリーンショットを撮る。
#   scripts/sim-shot.sh <出力.png> [起動引数...]
#   例: scripts/sim-shot.sh /tmp/day.png -fixedNow 2026-10-19T11:20 -ghost
# 時刻の表示を合わせるには先に: xcrun simctl status_bar <UDID> override --time "11:20"
set -euo pipefail
udid="${SIM_UDID:-F4A3F7ED-3C28-4850-A297-71E0BD3E971D}"  # iPhone 18 Pro（.xcodebuildmcp/config.yaml）
out="$1"; shift
xcrun simctl launch --terminate-running-process "$udid" com.hirototoda.focusapp "$@" >/dev/null
perl -e 'select(undef, undef, undef, 2.5)'  # 画面が落ち着くまで待つ
xcrun simctl io "$udid" screenshot "$out" >/dev/null 2>&1
echo "$out"
