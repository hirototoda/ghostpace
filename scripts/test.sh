#!/bin/zsh
# テストを Mac 全体の順番待ちに並んで実行する。複数のチャットが同時にテストしても CPU が埋まらないようにする。
# 同時に走るのはビルドとテストを合わせて FOCUSAPP_TEST_SLOTS 個まで（既定 2）。UI テストは数件ずつの塊に分けて並ぶので、
# 1つのチャットが長く占有せず、各チャットの塊が順番に流れる。docs/verification/strategy.md「テストの回し方」
#
#   scripts/test.sh                          ビルドとユニットテスト全件
#   scripts/test.sh ui <対象...>             ユニットテスト全件と、指定した UI テスト（例: RecordingFlowUITests/testPauseResumeEnd OpenedTimeUITests）
#   scripts/test.sh all                      ユニットテスト全件と UI テスト全件（TestFlight に送る前。scripts/testflight.sh が呼ぶ）
#   scripts/test.sh tour <対象...>           撮影用の ScreenTourUITests を SCREEN_TOUR=1 で動かす（例: ScreenTourUITests/testSleep）
#   scripts/test.sh status                   いま走っているもの・待っているものを見る
#
# オプション（対象より前に書く）
#   --sim <UDID>   使うシミュレーター。既定は SIM_UDID、なければ .xcodebuildmcp/config.yaml のもの。別の作業場所（worktree）では自分用の複製を指定する
#   --no-build     前回のビルドをそのまま使う
# 待ちが長くなることがあるので、Claude はバックグラウンドで実行する（Bash の run_in_background）。
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$PWD"

queue="${FOCUSAPP_TEST_QUEUE:-/private/tmp/focusapp-test-queue}"
slots="${FOCUSAPP_TEST_SLOTS:-2}"
chunk_size="${FOCUSAPP_UI_CHUNK:-6}"
job_limit="${FOCUSAPP_JOB_TIMEOUT:-1800}"  # 1つの塊がこれ（秒）を超えたら打ち切る。止まったまま枠を塞がないように
mkdir -p "$queue/tickets" "$queue/slots" "$queue/sims"

sim="${SIM_UDID:-$(sed -n 's/^ *simulatorId: *//p' .xcodebuildmcp/config.yaml)}"
build=true
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --sim) sim="$2"; shift 2 ;;
        --no-build) build=false; shift ;;
        *) echo "知らないオプション: $1" >&2; exit 64 ;;
    esac
done
mode="${1:-unit}"; (( $# )) && shift
targets=("$@")

# ---- 順番待ち ----
# 待ち札（tickets/<時刻>-<pid>）を出し、自分より前の札がすべて動けない状態になったら、空いている枠（slots/N）を取る。
# 同じシミュレーターを2つのテストが同時に使わないよう、sims/<UDID> も取る。札と枠の中身は持ち主の pid。持ち主が死んでいたら片付ける。
ticket="" slot="" simlock="" child=""

alive() { [[ -n "$1" ]] && kill -0 "$1" 2>/dev/null }

owner_alive() {  # 書きかけ（空）のファイルは、できて5秒までは生きているとみなす
    local f="$1" pid
    pid=$(cut -d' ' -f1 "$f" 2>/dev/null || true)
    if [[ -z "$pid" ]]; then
        [[ -n $(find "$f" -mtime -5s 2>/dev/null) ]]
    else
        alive "$pid"
    fi
}

sweep() {
    local f
    for f in "$queue"/tickets/*(N) "$queue"/slots/*(N) "$queue"/sims/*(N); do
        owner_alive "$f" || rm -f "$f"
    done
}

memory_ok() {  # macOS のメモリの逼迫度が「通常」（1）か。2 は注意、4 は危険
    [[ "$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)" == 1 ]]
}

take() { ( set -o noclobber; print -r -- "$$" > "$1" ) 2>/dev/null }

release() {
    [[ -n "$slot" ]] && rm -f "$slot"
    [[ -n "$simlock" ]] && rm -f "$simlock"
    [[ -n "$ticket" ]] && rm -f "$ticket"
    slot="" simlock="" ticket=""
}

on_signal() {
    [[ -n "$child" ]] && kill "$child" 2>/dev/null
    release
    exit 130
}
trap release EXIT
trap on_signal INT TERM HUP

acquire() {  # $1: シミュレーターの UDID（ビルドは空）
    local need_sim="$1" t name older_sim ahead i shown="" blocked
    name="$(perl -MTime::HiRes=time -e 'printf "%.6f", time')-$$"
    ticket="$queue/tickets/$name"
    print -r -- "$$ $need_sim" > "$ticket"
    while true; do
        sweep
        ahead=0 blocked=false
        for t in "$queue"/tickets/*(N:t); do
            [[ "$t" == "$name" ]] && break
            older_sim=$(cut -d' ' -f2 "$queue/tickets/$t" 2>/dev/null || true)
            (( ahead += 1 ))
            # 前の札が動ける（ビルド、またはシミュレーターが空いている）なら、そちらが先
            if [[ -z "$older_sim" || ! -e "$queue/sims/$older_sim" ]]; then blocked=true; fi
        done
        if ! $blocked && { [[ -z "$need_sim" ]] || take "$queue/sims/$need_sim"; }; then
            [[ -n "$need_sim" ]] && simlock="$queue/sims/$need_sim"
            for i in {1..$slots}; do
                # 2つ目からは、メモリに余裕があるときだけ使う。シミュレーターはメモリを多く使い、足りないと圧縮と退避で全体が重くなる
                (( i > 1 )) && ! memory_ok && break
                if take "$queue/slots/$i"; then
                    slot="$queue/slots/$i"
                    rm -f "$ticket"; ticket=""
                    return 0
                fi
            done
            [[ -n "$simlock" ]] && { rm -f "$simlock"; simlock=""; }
        fi
        if [[ "$shown" != "$ahead" ]]; then
            echo "  順番待ち（前に ${ahead} 件、枠 ${slots} つ）"
            shown="$ahead"
        fi
        sleep 2
    done
}

status() {
    sweep
    local f
    echo "枠（${slots} つまで。2つ目はメモリに余裕があるときだけ。いまのメモリ: $(memory_ok && echo 余裕あり || echo 逼迫)）:"
    for f in "$queue"/slots/*(N); do echo "  $(basename "$f"): pid $(cat "$f") $(ps -o args= -p "$(cat "$f")" 2>/dev/null | cut -c1-80)"; done
    echo "待ち:"
    for f in "$queue"/tickets/*(N); do echo "  $(cat "$f")"; done
}

# ---- 実行 ----
failed=()
n=0

job() {  # $1: 名前, $2: シミュレーター（ビルドは空）, 残り: xcodebuild の引数
    local label="$1" need_sim="$2"; shift 2
    (( n += 1 ))
    local log="$out/$n-$label.log" start=$SECONDS rc=0
    echo "[$label]"
    acquire "$need_sim"
    echo "  実行中（枠 $(basename "$slot")）"
    nice -n 5 xcodebuild "$@" > "$log" 2>&1 &
    child=$!
    (
        trap 'kill $nap 2>/dev/null; exit 0' TERM
        sleep "$job_limit" & nap=$!
        wait "$nap"
        kill "$child" 2>/dev/null && echo "  ${job_limit}秒を超えたので打ち切った"
    ) &
    local watchdog=$!
    wait "$child" || rc=$?
    kill "$watchdog" 2>/dev/null || true
    child=""
    release
    local took=$(( SECONDS - start ))
    if (( rc == 0 )); then
        echo "  成功（$(( took / 60 ))分$(( took % 60 ))秒） $(grep -E "Executed [0-9]+ tests?|Test run with" "$log" | tail -1 | sed 's/^[[:space:]]*//')"
    else
        failed+=("$label")
        echo "  失敗（$(( took / 60 ))分$(( took % 60 ))秒） ログ: $log"
        grep -E "error:|failed \(|recorded an issue|BUILD FAILED|TEST FAILED" "$log" | sed 's/^/    /' | head -20
    fi
}

ui_tests() { scripts/ui-tests.sh }  # UI テストの一覧（Class/testName）。撮影用の ScreenTourUITests は除く

case "$mode" in
    status) status; exit 0 ;;
    unit|ui|all|tour) ;;
    *) echo "使い方: scripts/test.sh [--sim UDID] [--no-build] [unit | ui <対象...> | all | tour <対象...> | status]" >&2; exit 64 ;;
esac
if [[ "$mode" == (ui|tour) && ${#targets} -eq 0 ]]; then
    echo "$mode には対象を書く（例: RecordingFlowUITests/testPauseResumeEnd）" >&2; exit 64
fi
[[ -z "$sim" ]] && { echo "シミュレーターが決まらない。--sim <UDID> を付ける" >&2; exit 64 }

name="$(basename "$repo")"
dd="${FOCUSAPP_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/focusapp-test-$name}"
out="$dd/test-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"

echo "作業場所: $repo / シミュレーター: $sim / ログ: $out"
# 全件（all）のときは、始める前に止まっていたシミュレーターを終わったら止め直す。起動したままだと、テストをしていなくても中の処理が CPU を使う。
# 普段の確認（unit・ui・tour）は続けて撮影や再実行をするので止めない（毎回起動し直すほうが重い）。撮り終えたら verify-ios の手順で止める
was_booted=false
xcrun simctl list devices | grep -q "$sim) (Booted)" && was_booted=true
common=(-project FocusApp.xcodeproj -scheme FocusApp -destination "id=$sim" -derivedDataPath "$dd")
# テスト中にアプリが落ちると、xcodebuild は診断（simctl diagnose、最大10分）を集めるあいだ枠を握り続ける。失敗の中身はログと xcresult に残るので集めない
testing=(test-without-building "${common[@]}" -collect-test-diagnostics never)

if $build; then
    xcodegen generate --quiet
    job build "" build-for-testing "${common[@]}"
    if (( ${#failed} )); then echo "ビルドに失敗したのでテストはしない"; exit 1; fi
fi

if [[ "$mode" != tour ]]; then
    job unit "$sim" "${testing[@]}" -only-testing:FocusAppTests -resultBundlePath "$out/unit.xcresult"
fi

ui=()
case "$mode" in
    all) ui=(${(f)"$(ui_tests)"}) ;;
    ui|tour) ui=("${targets[@]}") ;;
esac
if (( ${#ui} )); then
    [[ "$mode" == tour ]] && export TEST_RUNNER_SCREEN_TOUR=1
    total=$(( (${#ui} + chunk_size - 1) / chunk_size ))
    for (( c = 0; c < total; c++ )); do
        only=()
        for t in "${(@)ui[c * chunk_size + 1, (c + 1) * chunk_size]}"; do only+=("-only-testing:FocusAppUITests/$t"); done
        job "ui-$(( c + 1 ))of$total" "$sim" "${testing[@]}" "${only[@]}" -resultBundlePath "$out/ui-$(( c + 1 )).xcresult"
    done
fi

if [[ "$mode" == all ]] && ! $was_booted; then xcrun simctl shutdown "$sim" 2>/dev/null || true; fi

if (( ${#failed} )); then
    echo "失敗: ${failed[*]}（ログと xcresult: $out）"
    exit 1
fi
echo "すべて成功（xcresult: $out）"
