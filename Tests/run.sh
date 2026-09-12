#!/bin/bash
# Runs every StudyBlock test suite. From the repo root: ./Tests/run.sh
#
# There is no test target — the app is built by `swiftc` over globbed sources
# — so each suite is its own @main binary compiled against the sources it
# needs. Suites that touch a real TaskStore run with CFFIXED_USER_HOME
# pointed at a scratch directory, because JSONStore writes to
# ~/Library/Application Support/StudyBlock and must never touch a real board.
# Each of those also refuses to run if that redirect didn't take.
set -uo pipefail
cd "$(dirname "$0")/.."

SDK=$(xcrun --show-sdk-path)
TARGET=arm64-apple-macos13.0
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
FAILED=0

# Every app source except the @main entry point, for suites needing the store.
APP_SRC=$(ls Shared/*.swift StudyBlock/*.swift StudyBlock/*/*.swift | grep -v StudyBlockApp.swift | tr '\n' ' ')
CANVAS_SRC="StudyBlock/Canvas/ICSParser.swift StudyBlock/Canvas/CanvasItem.swift"

build() {  # build <name> <sources...>
    local name=$1; shift
    if ! swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" -o "$OUT/$name" "$@" 2>"$OUT/$name.log"; then
        echo "=== $name: COMPILE FAILED ==="; cat "$OUT/$name.log"; FAILED=1; return 1
    fi
}

run() {    # run <name> [sandbox-dir-name]
    local name=$1 sandbox=${2:-}
    echo "=== $name ==="
    if [ -n "$sandbox" ]; then
        rm -rf "$OUT/$sandbox"; mkdir -p "$OUT/$sandbox"
        CFFIXED_USER_HOME="$OUT/$sandbox" HOME="$OUT/$sandbox" "$OUT/$name" || FAILED=1
    else
        "$OUT/$name" || FAILED=1
    fi
    echo
}

build canvas       $CANVAS_SRC Tests/CanvasTests.swift          && run canvas
build credentials  StudyBlock/Canvas/CanvasFeed.swift Tests/CanvasCredentialTests.swift && run credentials
build canvasmerge  ${APP_SRC} Tests/CanvasMergeTests.swift      && run canvasmerge canvas-merge-sandbox
build taskmerge    ${APP_SRC} Tests/TaskMergeTests.swift        && run taskmerge mp-sandbox
build stats        ${APP_SRC} Tests/StatsTests.swift            && run stats stats-sandbox
build focus        ${APP_SRC} Tests/FocusSessionTests.swift     && run focus focus-sandbox
build board        ${APP_SRC} Tests/BoardTests.swift            && run board board-sandbox

if [ "$FAILED" -eq 0 ]; then echo "all suites passed"; else echo "SOME SUITES FAILED"; fi
exit $FAILED
