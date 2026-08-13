#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
configuration="${CONFIGURATION:-release}"
app_dir="$repo_dir/dist/DuckClip.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"

cd "$repo_dir"
swift build -c "$configuration" --product DuckClip
swift build -c "$configuration" --product duckclip-hook

binary_dir="$(swift build -c "$configuration" --show-bin-path)"
mkdir -p "$macos_dir" "$resources_dir/ko.lproj"
cp "$binary_dir/DuckClip" "$macos_dir/DuckClip"
cp "$binary_dir/duckclip-hook" "$macos_dir/duckclip-hook"
cp "$repo_dir/Support/Info.plist" "$contents_dir/Info.plist"
cp "$repo_dir/Support/ko.lproj/Localizable.strings" "$resources_dir/ko.lproj/Localizable.strings"
cp "$repo_dir/Support/Assets/DuckClipMenuBar.png" "$resources_dir/DuckClipMenuBar.png"
cp "$repo_dir/Support/Assets/DuckClipMenuBar@2x.png" "$resources_dir/DuckClipMenuBar@2x.png"
chmod 755 "$macos_dir/DuckClip" "$macos_dir/duckclip-hook"

if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
    codesign --force --deep --options runtime --sign "$CODE_SIGN_IDENTITY" "$app_dir"
else
    codesign --force --deep --sign - "$app_dir"
fi

echo "$app_dir"
