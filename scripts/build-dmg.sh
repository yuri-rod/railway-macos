#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
sh scripts/build-app.sh
app="dist/Railway.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :RailwayReleaseVersion' "$app/Contents/Info.plist")
arch=$(uname -m)
suffix=""
[ -z "${CODE_SIGN_IDENTITY:-}" ] || suffix="-signed"
image="$PWD/dist/Railway-$version-$arch$suffix.dmg"
[ ! -e "$image" ] || { printf '%s\n' "DMG already exists: $image" >&2; exit 1; }
stage=$(mktemp -d "${TMPDIR:-/tmp}/railway-dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
codesign --verify --deep --strict "$app"
ditto "$app" "$stage/Railway.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Railway $version" -srcfolder "$stage" -format UDZO "$image"
if [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
    codesign --sign "$CODE_SIGN_IDENTITY" --timestamp "$image"
    codesign --verify --strict "$image"
fi
hdiutil verify "$image"
shasum -a 256 "$image" > "$image.sha256"
printf '%s\n' "$image"
