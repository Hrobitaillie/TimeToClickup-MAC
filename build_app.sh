#!/bin/zsh
set -euo pipefail

APP_NAME="TimeToClickup"
APP_VERSION="${APP_VERSION:-0.0.0-dev}"
APP_BUILD="${APP_BUILD:-1}"
SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

BUILD_DIR=".build/release"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

print -P "%F{cyan}→%f Building release binary (v$APP_VERSION)…"
swift build -c release

print -P "%F{cyan}→%f Assembling .app bundle"
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RES"

cp "$BUILD_DIR/$APP_NAME" "$MACOS/$APP_NAME"

# Embed the app icon if available. We rebuild the .icns from the
# source PNG when present so contributors only need to update one
# file (assets/icon-source.png) for both git history and bundle.
ICON_PNG="assets/icon-source.png"
ICON_ICNS="assets/AppIcon.icns"
if [ -f "$ICON_PNG" ]; then
    print -P "%F{cyan}→%f Generating AppIcon.icns from $ICON_PNG"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for spec in "16:icon_16x16.png" "32:icon_16x16@2x.png" \
                "32:icon_32x32.png" "64:icon_32x32@2x.png" \
                "128:icon_128x128.png" "256:icon_128x128@2x.png" \
                "256:icon_256x256.png" "512:icon_256x256@2x.png" \
                "512:icon_512x512.png" "1024:icon_512x512@2x.png"; do
        size="${spec%%:*}"
        name="${spec##*:}"
        sips -z "$size" "$size" "$ICON_PNG" \
             --out "$ICONSET/$name" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET" -o "$ICON_ICNS" 2>/dev/null
    rm -rf "$(dirname "$ICONSET")"
fi

if [ -f "$ICON_ICNS" ]; then
    cp "$ICON_ICNS" "$RES/AppIcon.icns"
    ICON_KEY='<key>CFBundleIconFile</key><string>AppIcon</string>'
else
    ICON_KEY=''
fi

# Bundle .env as credentials.env so the OAuth client_id / client_secret
# travel with the .app. The file is gitignored — on CI we expect it to
# come from a GitHub secret (handled by the workflow before this runs).
if [ -f ".env" ]; then
    cp .env "$RES/credentials.env"
    print -P "%F{cyan}→%f Bundled .env into Resources/credentials.env"
fi

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>com.local.timetoclickup</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>TimeToClickup</string>
    <key>CFBundleVersion</key><string>$APP_BUILD</string>
    <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    $ICON_KEY
</dict>
</plist>
EOF

# Ad-hoc sign so the binary has a stable identity (no Gatekeeper bypass,
# but avoids "damaged" warnings when downloaded). Skip silently if no
# `codesign` is available.
if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

print -P "%F{green}✓%f App bundle ready: $APP_DIR"
print -P "  Run:    %F{yellow}open '$APP_DIR'%f"
print -P "  Or:     %F{yellow}.build/release/$APP_NAME%f"
