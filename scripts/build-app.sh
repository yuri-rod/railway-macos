#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
version=$(cat VERSION)
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$' || { printf '%s\n' 'VERSION must use major.minor.patch-beta.number.' >&2; exit 1; }
swift build -c release
app="dist/Railway.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
bin=$(swift build -c release --show-bin-path)
cp "$bin/RailwayNative" "$app/Contents/MacOS/RailwayNative"
if [ -f Sources/RailwayDesktop/Resources/AppIcon.icns ]; then
    cp Sources/RailwayDesktop/Resources/AppIcon.icns "$app/Contents/Resources/"
fi
for resources in "$bin"/*.bundle; do
    [ ! -d "$resources" ] || cp -R "$resources" "$app/Contents/Resources/"
done
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.railway-native.desktop</string>
<key>CFBundleName</key><string>Railway</string>
<key>CFBundleDisplayName</key><string>Railway</string>
<key>CFBundleExecutable</key><string>RailwayNative</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLSchemes</key><array><string>railway-native</string></array><key>CFBundleURLName</key><string>OAuth callback</string></dict></array>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version%-beta.*}" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${version##*-beta.}" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :RailwayReleaseVersion string $version" "$app/Contents/Info.plist"
if [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$CODE_SIGN_IDENTITY" --options runtime --timestamp "$app"
else
    codesign --force --sign - "$app"
fi
printf '%s\n' "$PWD/$app"
