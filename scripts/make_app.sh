#!/bin/bash
# Build PracticePad as an installable macOS .app bundle.
#
# Produces dist/PracticePad.app from a release build, with an Info.plist and an
# ad-hoc code signature so it launches from Finder / Applications.
#
# Requires the Rubber Band library (brew install rubberband). The built binary
# links it from the Homebrew prefix by absolute path, so the bundle runs only
# on machines where Homebrew's rubberband is installed. Redistributing to other
# Macs would require bundling the dylib and rewriting its install name (e.g.
# with install_name_tool) plus honoring Rubber Band's GPL / commercial license.
set -euo pipefail

APP_NAME="PracticePad"
BUNDLE_ID="com.shawndaley.PracticePad"
VERSION="1.0"
BUILD="1"

# Resolve repo root (parent of this script's directory).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "Building release binary..."
swift build -c release --product "$APP_NAME"
BIN_PATH="$(swift build -c release --product "$APP_NAME" --show-bin-path)/$APP_NAME"

APP="dist/$APP_NAME.app"
echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH" "$APP/Contents/MacOS/$APP_NAME"

# Generate an .icns from assets/icon.png (1024x1024), if present.
ICON_SRC="assets/icon.png"
ICON_PLIST=""
if [[ -f "$ICON_SRC" ]]; then
    echo "Generating app icon..."
    ICONSET="$(mktemp -d)/$APP_NAME.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size"           "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png"    >/dev/null
        sips -z $((size * 2)) $((size * 2)) "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/$APP_NAME.icns"
    ICON_PLIST="    <key>CFBundleIconFile</key><string>$APP_NAME</string>"
else
    echo "No $ICON_SRC found; skipping app icon."
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
$ICON_PLIST
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Ad-hoc signing..."
codesign --force --sign - "$APP"

echo "Done: $ROOT/$APP"
echo "Install by dragging it into /Applications (or run: cp -R \"$APP\" /Applications/)."
