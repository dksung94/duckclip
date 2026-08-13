#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
repo_dir="${script_dir:h}"
app_path="$repo_dir/dist/DuckClip.app"
archive_path="$repo_dir/dist/DuckClip.zip"

if [[ ! -d "$app_path" ]]; then
    echo "Build DuckClip.app first with ./scripts/build-app.sh" >&2
    exit 1
fi

if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    echo "Set NOTARY_PROFILE to a notarytool keychain profile name." >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
ditto -c -k --keepParent "$app_path" "$archive_path"
xcrun notarytool submit "$archive_path" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"

echo "$app_path"
