#!/bin/bash

# Exit immediately on errors, unset variables, or failed pipelines.
set -euo pipefail

VERSION="1.0.0"
CLEAN=false

for argument in "$@"; do
    if [[ "$argument" == "clean" ]]; then
        CLEAN=true
    else
        VERSION="$argument"
    fi
done

echo "=== Building Pausely MVP v$VERSION ==="

# 1. Clean previous build artifact
echo "Cleaning Pausely.app..."
rm -rf Pausely.app

# Optional clean of swift build cache
if [[ "$CLEAN" == "true" ]]; then
    echo "Cleaning build cache (.build)..."
    rm -rf .build
fi

# 2. Build a universal Swift Package executable in release mode
echo "Compiling universal macOS binary (Apple Silicon + Intel)..."
swift build -c release --arch arm64 --arch x86_64
BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

# 3. Create the .app bundle directory structure
echo "Creating Pausely.app bundle structure..."
mkdir -p Pausely.app/Contents/MacOS
mkdir -p Pausely.app/Contents/Resources
mkdir -p Pausely.app/Contents/Frameworks

# 4. Copy the compiled binary and Info.plist
echo "Copying binary and Info.plist..."
cp "$BIN_DIR/Pausely" Pausely.app/Contents/MacOS/
cp Info.plist Pausely.app/Contents/
cp Sources/audio/crystal-glass.wav Pausely.app/Contents/Resources/
cp Pausely.icns Pausely.app/Contents/Resources/
/usr/bin/ditto "$BIN_DIR/Sparkle.framework" Pausely.app/Contents/Frameworks/Sparkle.framework

echo "Setting bundle version to $VERSION..."
plutil -replace CFBundleShortVersionString -string "$VERSION" Pausely.app/Contents/Info.plist
plutil -replace CFBundleVersion -string "$VERSION" Pausely.app/Contents/Info.plist

# 5. Set executable permissions
chmod +x Pausely.app/Contents/MacOS/Pausely

# 6. Apply an ad-hoc signature so the app and embedded Sparkle helpers have a
# consistent local identity. Developer ID signing/notarization can replace this
# step later without changing the updater integration.
echo "Applying ad-hoc code signature..."
codesign --force --sign - Pausely.app
codesign --verify --deep --strict Pausely.app

echo "=== Build Succeeded ==="
echo "Pausely.app is ready in the workspace!"
echo "To run the app: open Pausely.app"
