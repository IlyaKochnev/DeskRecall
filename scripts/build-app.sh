#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
configuration="${1:-release}"
if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
    echo "Usage: scripts/build-app.sh [release|debug]" >&2
    exit 2
fi
scripts/swiftw build -c "$configuration" --product DeskRecall
binary_dir="$(scripts/swiftw build -c "$configuration" --show-bin-path)"
app_dir="$project_dir/dist/DeskRecall.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/DeskRecall" "$app_dir/Contents/MacOS/DeskRecall"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
printf 'APPL????' > "$app_dir/Contents/PkgInfo"
# A Developer ID can be supplied for distribution; ad-hoc signing supports local use.
signing_identity="${DESKRECALL_SIGN_IDENTITY:--}"
if [[ "$signing_identity" == "-" ]]; then
    codesign --force --sign - --identifier local.deskrecall.app "$app_dir"
else
    codesign --force --options runtime --timestamp --sign "$signing_identity" "$app_dir"
fi
codesign --verify --strict "$app_dir"
echo "Built: $app_dir"
