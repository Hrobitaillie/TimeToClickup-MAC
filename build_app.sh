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
