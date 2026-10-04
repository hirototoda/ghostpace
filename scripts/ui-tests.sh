#!/bin/zsh
# UI テストの一覧（Class/testName）を1行ずつ出す。撮影用の ScreenTourUITests は除く。
# scripts/test.sh（この Mac）と scripts/ci/run-tests.sh（GitHub Actions）が使う
cd "$(dirname "$0")/.."
awk '
    match($0, /class [A-Za-z0-9_]+ *: *XCTestCase/) { split(substr($0, RSTART + 6), a, /[ :]/); cls = a[1] }
    match($0, /func test[A-Za-z0-9_]+\(/) && cls != "" && cls != "ScreenTourUITests" { print cls "/" substr($0, RSTART + 5, RLENGTH - 6) }
' FocusAppUITests/*.swift
