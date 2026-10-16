#!/usr/bin/env bash
# Runs the same three checks as CI (.github/workflows/ci.yml), on a Mac.
#
#   scripts/check.sh            core tests, schema check, iPad Simulator build
#   scripts/check.sh core       just one of: core, schema, app
#
# Keep this in step with ci.yml when either changes.
set -euo pipefail
cd "$(dirname "$0")/.."

core() {
  echo "==> ControlFlowCore tests"
  swift test --package-path Packages/ControlFlowCore
}

schema() {
  echo "==> File format schema"
  # A private venv, because Homebrew's Python refuses a global pip install.
  if [ ! -x .venv/bin/python ]; then
    python3 -m venv .venv
    .venv/bin/pip install --quiet "jsonschema>=4.18"
  fi
  .venv/bin/python Schema/validate.py
  echo "==> HTML export player"
  node Schema/test_player.js
}

app() {
  echo "==> App build (iPad Simulator)"
  xcodebuild build \
    -project ControlFlow.xcodeproj \
    -scheme ControlFlow \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO \
    -quiet
  echo "==> MathJax is in the app"
  local app
  app=$(xcodebuild -showBuildSettings \
    -project ControlFlow.xcodeproj \
    -scheme ControlFlow \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO | awk '$1 == "CODESIGNING_FOLDER_PATH" { print $3 }')
  test -f "$app/cf-mathjax.js" || { echo "cf-mathjax.js is not in $app" >&2; exit 1; }
}

if [ $# -eq 0 ]; then
  set -- core schema app
fi
for step in "$@"; do
  case "$step" in
    core|schema|app) "$step" ;;
    *) echo "Unknown step: $step (expected core, schema or app)" >&2; exit 2 ;;
  esac
done
echo "==> All checks passed"
