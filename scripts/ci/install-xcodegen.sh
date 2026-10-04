#!/bin/zsh
# GitHub Actions の Mac に XcodeGen を入れる（イメージに入っていない）。版はこの Mac と同じにそろえる。docs/decisions/0021
set -euo pipefail
version="${XCODEGEN_VERSION:-2.46.0}"
dir="${RUNNER_TEMP:-/tmp}/xcodegen-$version"
if [[ ! -x "$dir/xcodegen/bin/xcodegen" ]]; then
    mkdir -p "$dir"
    curl -fsSL -o "$dir/xcodegen.zip" "https://github.com/yonaskolb/XcodeGen/releases/download/$version/xcodegen.zip"
    unzip -q -o "$dir/xcodegen.zip" -d "$dir"
fi
echo "$dir/xcodegen/bin" >> "${GITHUB_PATH:-/dev/null}"
"$dir/xcodegen/bin/xcodegen" --version
