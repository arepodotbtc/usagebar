#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/Scripts/build.sh"

src="$root/dist/UsageBar.app"
dst="/Applications/UsageBar.app"
rm -rf "$dst"
cp -R "$src" "$dst"
echo "installed $dst"
open "$dst"
echo "If macOS asks about Keychain, choose Always Allow for Claude Code-credentials*."
