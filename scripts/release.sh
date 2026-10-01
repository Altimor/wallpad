#!/bin/bash
# Packages and publishes a GitHub release; every installed Mac updates itself within 15 minutes.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/package.sh
V=$(cat dist/version.txt)
gh release create "v$V" dist/Wallpad.zip dist/install.sh dist/version.txt --repo "${WALLPAD_REPO:-Altimor/wallpad}" --title "Wallpad $V" --notes "${1:-}"
