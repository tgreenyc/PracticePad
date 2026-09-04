#!/bin/bash
# Build PracticePad as an installable macOS .app bundle.
#
# Produces dist/PracticePad.app from a release build, with an Info.plist and an
# ad-hoc code signature so it launches from Finder / Applications.
#
# Building requires the Rubber Band library (brew install rubberband). The
# script then bundles Rubber Band and its non-system dependencies into
# Contents/Frameworks and rewrites their load paths to @rpath, so the finished
# .app is self-contained and runs on Macs without Homebrew installed.
#
# Note: Rubber Band is GPL. Redistributing a build that bundles it must comply
# with the GPL (or use a commercial Rubber Band license).
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

# ---------------------------------------------------------------------------
# Bundle third-party dylibs (Rubber Band + its dependencies) so the app is
# self-contained and doesn't require Homebrew at runtime.
#
# The built binary links librubberband by its absolute Homebrew path; that (and
# everything it transitively pulls in, minus system libraries) is copied into
# Contents/Frameworks and every load command / install name is rewritten to
# @rpath. An LC_RPATH of @executable_path/../Frameworks is added to the binary
# so the loader finds them inside the bundle.
# ---------------------------------------------------------------------------
BIN="$APP/Contents/MacOS/$APP_NAME"
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"

# A dylib path is "system" (left untouched) if it lives under /usr/lib or
# /System. Everything else (Homebrew, /opt, /usr/local, ...) gets bundled.
is_system_lib() {
    case "$1" in
        /usr/lib/*|/System/*) return 0 ;;
        *) return 1 ;;
    esac
}

# Resolve symlinks to the real file (macOS /bin/bash lacks `realpath`).
real_path() {
    /usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

# List a Mach-O file's linked dylibs, skipping its own id (line 1).
linked_dylibs() {
    otool -L "$1" | tail -n +2 | awk '{print $1}'
}

# Recursively collect the set of non-system dylibs reachable from a Mach-O
# file into the newline-separated global COLLECTED (real paths, de-duplicated).
# Uses plain string membership tests so it works on bash 3.2 (no assoc arrays).
COLLECTED=""
collect_deps() {
    local target="$1" dep real
    while read -r dep; do
        [[ -z "$dep" ]] && continue
        is_system_lib "$dep" && continue
        real="$(real_path "$dep" 2>/dev/null || echo "$dep")"
        [[ -f "$real" ]] || continue
        # Skip if already collected.
        case "
$COLLECTED
" in
            *"
$real
"*) continue ;;
        esac
        COLLECTED="$COLLECTED$real
"
        collect_deps "$real"
    done < <(linked_dylibs "$target")
}

echo "Collecting bundled libraries..."
collect_deps "$BIN"

if [[ -z "${COLLECTED//[[:space:]]/}" ]]; then
    echo "No third-party dylibs to bundle (binary already self-contained)."
else
    # Copy each library into Frameworks and set its own id to @rpath/<name>.
    while IFS= read -r real; do
        [[ -z "$real" ]] && continue
        base="$(basename "$real")"
        echo "  bundling $base"
        cp "$real" "$FRAMEWORKS/$base"
        chmod u+w "$FRAMEWORKS/$base"
        install_name_tool -id "@rpath/$base" "$FRAMEWORKS/$base"
    done <<< "$COLLECTED"

    # Rewrite the main binary's references to @rpath and add an rpath that
    # resolves to the bundle's Frameworks directory. The binary may reference a
    # library by its real path, a symlinked path, or a Homebrew "opt" path, so
    # rewrite whatever it actually records for any bundled basename.
    while read -r ref; do
        [[ "$ref" == "@rpath/"* ]] && continue
        is_system_lib "$ref" && continue
        refreal="$(real_path "$ref" 2>/dev/null || echo "$ref")"
        while IFS= read -r real; do
            [[ -z "$real" ]] && continue
            if [[ "$real" == "$refreal" ]]; then
                install_name_tool -change "$ref" "@rpath/$(basename "$real")" "$BIN"
            fi
        done <<< "$COLLECTED"
    done < <(linked_dylibs "$BIN")
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN" 2>/dev/null || true

    # Fix up cross-references *between* the bundled libraries (e.g. rubberband
    # -> libsamplerate) so those also resolve inside the bundle. A reference may
    # use a symlinked "opt" path (e.g. libsamplerate.0.dylib) whose basename
    # differs from the real versioned file we bundled (libsamplerate.0.2.2.dylib),
    # so match by resolving each reference to its real path.
    while IFS= read -r real; do
        [[ -z "$real" ]] && continue
        lib="$FRAMEWORKS/$(basename "$real")"
        while read -r ref; do
            [[ "$ref" == "@rpath/"* ]] && continue
            is_system_lib "$ref" && continue
            refreal="$(real_path "$ref" 2>/dev/null || echo "$ref")"
            while IFS= read -r other; do
                [[ -z "$other" ]] && continue
                if [[ "$other" == "$refreal" ]]; then
                    install_name_tool -change "$ref" "@rpath/$(basename "$other")" "$lib"
                fi
            done <<< "$COLLECTED"
        done < <(linked_dylibs "$lib")
    done <<< "$COLLECTED"
fi

# Ad-hoc sign. Signatures must be applied to the bundled dylibs *before* the
# app, since editing load commands invalidated any existing signature and the
# outer signature seals the nested code.
echo "Ad-hoc signing..."
if [[ -d "$FRAMEWORKS" ]]; then
    for lib in "$FRAMEWORKS"/*.dylib; do
        [[ -e "$lib" ]] || continue
        codesign --force --sign - "$lib"
    done
fi
codesign --force --sign - "$BIN"
codesign --force --sign - "$APP"

echo "Verifying bundle is self-contained (no /opt or /usr/local references)..."
LEAKS="$( { otool -L "$BIN"; for lib in "$FRAMEWORKS"/*.dylib; do [[ -e "$lib" ]] && otool -L "$lib"; done; } \
    | awk '{print $1}' | grep -E '^(/opt/|/usr/local/)' || true )"
if [[ -n "$LEAKS" ]]; then
    echo "WARNING: bundle still references non-system paths:" >&2
    echo "$LEAKS" >&2
else
    echo "OK: no Homebrew/local paths remain."
fi

echo "Done: $ROOT/$APP"
echo "Install by dragging it into /Applications (or run: cp -R \"$APP\" /Applications/)."
