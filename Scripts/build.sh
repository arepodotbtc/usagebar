#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift build -c release --product UsageBar

app="$root/dist/UsageBar.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/.build/release/UsageBar" "$app/Contents/MacOS/UsageBar"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
chmod +x "$app/Contents/MacOS/UsageBar"

if command -v codesign >/dev/null; then
  codesign --force --deep -s - "$app"
fi

"$app/Contents/MacOS/UsageBar" --self-test

echo "built $app"
echo "probe:  $app/Contents/MacOS/UsageBar --probe"
echo "open:   open $app"
