#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
app_path="$repo_dir/dist/DuckClip.app"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    "$script_dir/build-app.sh" >/dev/null
fi

if [[ ! -d "$app_path" ]]; then
    echo "DuckClip.app was not found. Run ./scripts/build-app.sh first." >&2
    exit 1
fi

version="${APP_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")}"
dmg_path="${DMG_PATH:-$repo_dir/dist/DuckClip-$version.dmg}"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/duckclip-dmg.XXXXXX")"

cleanup() {
    rm -rf "$staging_dir"
}
trap cleanup EXIT

ditto "$app_path" "$staging_dir/DuckClip.app"
ln -s /Applications "$staging_dir/Applications"
mkdir -p "${dmg_path:h}"
hdiutil create \
    -volname "DuckClip" \
    -srcfolder "$staging_dir" \
    -format UDZO \
    -ov \
    "$dmg_path"

shasum -a 256 "$dmg_path"
echo "$dmg_path"
