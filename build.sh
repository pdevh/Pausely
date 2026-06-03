#!/bin/bash

# Exit immediately if any command fails
set -e

VERSION=${1:-"1.0.0"}

echo "=== Building Pausely MVP v$VERSION ==="

# 1. Clean previous builds
echo "Cleaning old build files..."
rm -rf .build Pausely.app

# 2. Update Info.plist version
echo "Setting version to $VERSION in Info.plist..."
plutil -replace CFBundleShortVersionString -string "$VERSION" Info.plist
plutil -replace CFBundleVersion -string "$VERSION" Info.plist

# 3. Build the Swift Package in release mode
echo "Compiling swift sources..."
swift build -c release

# 3. Create the .app bundle directory structure
echo "Creating Pausely.app bundle structure..."
mkdir -p Pausely.app/Contents/MacOS
mkdir -p Pausely.app/Contents/Resources

# 4. Copy the compiled binary and Info.plist
echo "Copying binary and Info.plist..."
cp .build/release/Pausely Pausely.app/Contents/MacOS/
cp Info.plist Pausely.app/Contents/

# 5. Set executable permissions
chmod +x Pausely.app/Contents/MacOS/Pausely

echo "=== Build Succeeded ==="
echo "Pausely.app is ready in the workspace!"
echo "To run the app: open Pausely.app"
