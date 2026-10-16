#!/bin/sh
# Bundles MathJax into one script (see entry.mjs), from the versions package-lock.json
# pins. Writes ControlFlow/Resources/cf-mathjax.js, or the file given.
#
#   MathJax/build.sh [output.js]
#
# Needs Node 18 or later.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-"$here/../ControlFlow/Resources/cf-mathjax.js"}
cd "$here"
[ -d node_modules/@mathjax/src ] || npm ci --no-audit --no-fund >&2
mkdir -p "$(dirname "$out")"
npx --no-install esbuild entry.mjs --bundle --minify --format=iife --log-level=warning --outfile="$out"
