#!/bin/zsh
# Claude Code の PreToolUse フック（.claude/settings.json）。テストを直接実行させず、順番待ちの scripts/test.sh に回す。
# 複数のチャットが同時に UI テストを回して CPU が埋まるのを防ぐため。docs/verification/strategy.md「テストの回し方」
# 例外: 実機で本物の時間を待つテスト（REAL_WAIT=1）はシミュレーターを使わないので通す。
input=$(cat)
tool=$(print -r -- "$input" | jq -r '.tool_name // ""')
msg="テストは順番待ちの scripts/test.sh で実行する（Mac 全体で同時に2つまで）。例: scripts/test.sh ui RecordingFlowUITests/testPauseResumeEnd ／ 全件は scripts/test.sh all ／ 撮影は scripts/test.sh tour ScreenTourUITests/testSleep。待ちが出るので Bash の run_in_background で実行する。"

if [[ "$tool" == mcp__XcodeBuildMCP__test_* ]]; then
    print -u2 -- "$msg"
    exit 2
fi
if [[ "$tool" == Bash ]]; then
    cmd=$(print -r -- "$input" | jq -r '.tool_input.command // ""')
    if [[ "$cmd" =~ 'xcodebuild([^;&|]*[[:space:]])?test(-without-building)?([[:space:]]|$)' && "$cmd" != *REAL_WAIT* ]]; then
        print -u2 -- "$msg"
        exit 2
    fi
fi
exit 0
