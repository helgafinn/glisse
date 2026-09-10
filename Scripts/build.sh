#!/bin/bash
# Concise wrapper around `swift build` / `swift test`.
#
# SwiftPM on macOS 27 echoes the entire clang invocation on failure, which
# drowns the actual diagnostics. This filters to just the useful lines.
#
# usage: Scripts/build.sh [build|test] [extra swift args...]

set -uo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-build}"
shift || true

if [ "$MODE" = "test" ]; then
  CMD=(swift test "$@")
else
  CMD=(swift build "$@")
fi

OUT="$(mktemp)"
"${CMD[@]}" >"$OUT" 2>&1
STATUS=$?

grep -E \
  -e '(error|warning):' \
  -e '^error:' \
  -e '^\s+[0-9]+ \|' \
  -e '^Build complete' \
  -e '^Compiling' \
  -e '^Test Suite' \
  -e '^Test Case' \
  -e '^\s*Executed [0-9]+ test' \
  -e 'failed|passed' \
  "$OUT" \
  | grep -v -e 'clang -cc1' -e 'CompileC ' -e 'Failed frontend' -e '\-target-feature' \
  | head -120

if [ $STATUS -ne 0 ]; then
  echo "--- exit status: $STATUS"
fi
exit $STATUS
