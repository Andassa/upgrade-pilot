#!/usr/bin/env bash
# Reproducible demo: a real `plan` on the Flutter 3.24-era fixture, then the
# Markdown report. The output is written to build/demo/ and is the source of
# the excerpts shown in the README.
#
# Requirements: Flutter on the PATH, an Android SDK, network access.
# Usage: bash doc/demo.sh [target-version]
set -euo pipefail

cd "$(dirname "$0")/.."
TARGET="${1:-$(flutter --version --machine | sed -n 's/.*"frameworkVersion": *"\([^"]*\)".*/\1/p')}"
OUT=build/demo
BIN=build/upgrade-pilot
mkdir -p "$OUT"

[ -x "$BIN" ] || dart compile exe bin/upgrade_pilot.dart -o "$BIN"

echo "upgrade-pilot demo: test/fixtures/legacy_toolchain -> Flutter $TARGET"
set +e
"$BIN" --ci doctor | tee "$OUT/doctor.txt"
"$BIN" --ci plan --path test/fixtures/legacy_toolchain --to "$TARGET" \
  --platforms android --timeout 40m | tee "$OUT/plan.txt"
status=${PIPESTATUS[0]}
"$BIN" report --path test/fixtures/legacy_toolchain --format md > "$OUT/report.md"
"$BIN" report --path test/fixtures/legacy_toolchain --format html \
  -o "$OUT/report.html" > /dev/null
"$BIN" --ci plan --path test/fixtures/blocked_dependency --to "$TARGET" \
  | tee "$OUT/blocked.txt"
set -e
echo "plan exit code: $status (outputs in $OUT/)"
