#!/bin/bash
set -e

# Control Tower - Build and Run Script
# Usage: ./Scripts/compile_and_run.sh [debug|release]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# Configuration
BUILD_CONFIG="${1:-debug}"
APP_NAME="ControlTower"
BUNDLE_ID="com.krishcdbry.controltower"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║           Control Tower - Build and Run                     ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Kill any existing instances
echo "→ Stopping existing instances..."
pkill -x "$APP_NAME" 2>/dev/null || true
pkill -f "$APP_NAME.app" 2>/dev/null || true
sleep 0.5

# Build
echo "→ Building ($BUILD_CONFIG)..."
if [ "$BUILD_CONFIG" = "release" ]; then
    swift build -c release
    BUILD_PATH=".build/release"
else
    swift build
    BUILD_PATH=".build/debug"
fi

# Create app bundle
echo "→ Creating app bundle..."
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
rm -rf "$APP_BUNDLE"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

# Copy executable
cp "$BUILD_PATH/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# Copy Sparkle.framework (use ditto to preserve symlinks)
SPARKLE_FRAMEWORK="$BUILD_PATH/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    ditto "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
fi

# Copy resource bundles (SwiftPM resource bundles)
for bundle in "$BUILD_PATH"/*.bundle; do
    if [ -d "$bundle" ]; then
        echo "→ Copying resource bundle: $(basename "$bundle")"
        cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
    fi
done

# Copy Info.plist
cp "$PROJECT_DIR/Sources/ControlTower/Plist/Info.plist" "$APP_BUNDLE/Contents/"

# Copy app icon
if [ -f "$PROJECT_DIR/AppIcon.icns" ]; then
    echo "→ Copying app icon..."
    cp "$PROJECT_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
fi

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Fix rpath for Sparkle.framework
echo "→ Fixing framework rpaths..."
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true

# Sign ad-hoc
echo "→ Signing (ad-hoc)..."
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

# Launch
echo "→ Launching..."
open -n "$APP_BUNDLE"

# Verify it's running
sleep 1
if pgrep -x "$APP_NAME" > /dev/null; then
    echo ""
    echo "✓ Control Tower is running!"
    echo "  Look for the icon in your menu bar."
else
    echo ""
    echo "✗ Failed to launch Control Tower"
    echo "  Check Console.app for errors"
    exit 1
fi

echo ""
echo "Done!"
