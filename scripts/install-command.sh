#!/bin/bash
# Copies a TV's install command to the clipboard. It carries a one-time enrollment code (1 hour, single
# use), never the admin key, so nothing reusable lands in that Mac's shell history.
#   scripts/install-command.sh "Lobby TV"
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="${1:?usage: install-command.sh \"TV name\"}"
R="${WALLPAD_ROUTER:-$(cat .router)}"
KEY=$(tr -d '\n' < "$HOME/Library/Application Support/Wallpad/admin-key")
CODE=$(curl -fsS -X POST -H @- "$R/api/enroll" <<<"Authorization: Bearer $KEY" | sed -n 's/.*"code":"\([0-9a-f]*\)".*/\1/p')
[ -n "$CODE" ] || { echo "couldn't get an enrollment code from $R"; exit 1; }
printf 'curl -fsSL %s/install.sh | bash -s -- %q %s' "$R" "$NAME" "$CODE" | pbcopy
echo "Copied the install command for \"$NAME\" (valid for 1 hour, once). Paste it into Terminal on that TV's Mac."
