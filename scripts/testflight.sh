#!/bin/zsh
# Release ビルドを作って TestFlight（App Store Connect）に送る。docs/decisions/0011-testflight.md
#   scripts/testflight.sh            アップロードまで行う
#   scripts/testflight.sh --no-upload 署名と書き出しだけ確かめる（送らない）
#   scripts/testflight.sh --skip-tests 送る前の全件テストを飛ばす（直したばかりで全件が通っている、などの急ぎのときだけ）
#
# 送る前に scripts/test.sh all でユニットテストと UI テストを全件回し、失敗したら送らない（docs/verification/strategy.md）。
# 順番待ちを含めて20〜40分かかるので、Claude はバックグラウンドで実行する。
#
# 認証は Xcode にサインイン済みの Apple ID を使う。
# App Store Connect API キーを使う場合は ~/.appstoreconnect/ghostpace.env に
#   ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID を書く（リポジトリには置かない）。
set -euo pipefail
cd "$(dirname "$0")/.."

upload=true
run_tests=true
for arg in "$@"; do
    case "$arg" in
        --no-upload) upload=false ;;
        --skip-tests) run_tests=false ;;
        *) echo "知らないオプション: $arg" >&2; exit 64 ;;
    esac
done

if $run_tests; then
    scripts/test.sh all || { echo "テストが失敗したので TestFlight には送らない" >&2; exit 1; }
fi

# ビルド番号は送るたびに増やす必要があるので、日時を使う（例: 202610011530）
build_number=$(date +%Y%m%d%H%M)
out="${TMPDIR:-/tmp}/ghostpace-testflight/$build_number"
mkdir -p "$out"

auth=()
env_file="$HOME/.appstoreconnect/ghostpace.env"
if [[ -f "$env_file" ]]; then
    source "$env_file"
    auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

export_options="scripts/ExportOptions.plist"
if ! $upload; then
    export_options="$out/ExportOptions.plist"
    sed 's#<string>upload</string>#<string>export</string>#' scripts/ExportOptions.plist > "$export_options"
fi

xcodegen generate
xcodebuild archive \
    -project FocusApp.xcodeproj -scheme FocusApp -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$out/FocusApp.xcarchive" \
    -allowProvisioningUpdates "${auth[@]}" \
    CURRENT_PROJECT_VERSION="$build_number" | tail -3
xcodebuild -exportArchive \
    -archivePath "$out/FocusApp.xcarchive" \
    -exportOptionsPlist "$export_options" \
    -exportPath "$out/export" \
    -allowProvisioningUpdates "${auth[@]}" | tail -3

if $upload; then
    echo "TestFlight に送りました（ビルド番号 $build_number）。処理が終わると iPhone の TestFlight に届きます（10〜30分）"
else
    echo "書き出しのみ完了: $out/export"
fi
