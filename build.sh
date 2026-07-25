#!/bin/bash

# Exit immediately on errors, unset variables, or failed pipelines.
set -euo pipefail

VERSION_INPUT="${PAUSELY_VERSION:-1.0.0}"
CLEAN=false
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
REQUIRE_STABLE_SIGNING="${REQUIRE_STABLE_SIGNING:-false}"
CODE_SIGN_CERTIFICATE_SHA1="${CODE_SIGN_CERTIFICATE_SHA1:-}"
CODE_SIGN_KEYCHAIN="${CODE_SIGN_KEYCHAIN:-}"

for argument in "$@"; do
    if [[ "$argument" == "clean" ]]; then
        CLEAN=true
    else
        VERSION_INPUT="$argument"
    fi
done

VERSION="${VERSION_INPUT#v}"
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "error: version must be MAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH" >&2
    exit 1
fi

echo "=== Building Pausely v$VERSION ==="

if [[ "$REQUIRE_STABLE_SIGNING" == "true" ]]; then
    if [[ "$CODE_SIGN_IDENTITY" == "-" || -z "$CODE_SIGN_CERTIFICATE_SHA1" ]]; then
        echo "error: release builds require a persistent signing identity and certificate fingerprint" >&2
        exit 1
    fi
fi

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
if [[ ! -s Pausely.icns ]]; then
    echo "error: Pausely.icns is missing or empty" >&2
    exit 1
fi
cp Pausely.icns Pausely.app/Contents/Resources/
if ! cmp -s Pausely.icns Pausely.app/Contents/Resources/Pausely.icns; then
    echo "error: bundled macOS icon does not match Pausely.icns" >&2
    exit 1
fi
/usr/bin/ditto "$BIN_DIR/Sparkle.framework" Pausely.app/Contents/Frameworks/Sparkle.framework

echo "Setting bundle version to $VERSION..."
plutil -replace CFBundleShortVersionString -string "$VERSION" Pausely.app/Contents/Info.plist
plutil -replace CFBundleVersion -string "$VERSION" Pausely.app/Contents/Info.plist

# 5. Set executable permissions
chmod +x Pausely.app/Contents/MacOS/Pausely

if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' Pausely.app/Contents/Info.plist)" != "Pausely" ]]; then
    echo "error: CFBundleExecutable must identify Contents/MacOS/Pausely" >&2
    exit 1
fi

# 6. Local builds remain ad-hoc signable, but distributed builds must supply a
# persistent identity. The no-cost release workflow imports the same self-signed
# certificate on every run so the designated requirement remains stable.
if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
    echo "Applying ad-hoc code signature for local development..."
    codesign --force --sign - Pausely.app
else
    echo "Applying stable self-signed release identity $CODE_SIGN_IDENTITY..."
    CODESIGN_ARGS=(--force --sign "$CODE_SIGN_IDENTITY" --timestamp=none)
    if [[ -n "$CODE_SIGN_KEYCHAIN" ]]; then
        CODESIGN_ARGS+=(--keychain "$CODE_SIGN_KEYCHAIN")
    fi
    if [[ -n "$CODE_SIGN_CERTIFICATE_SHA1" ]]; then
        REQUIREMENT="designated => identifier \"com.philipp.Pausely\" and certificate leaf = H\"$CODE_SIGN_CERTIFICATE_SHA1\""
        CODESIGN_ARGS+=(-r="$REQUIREMENT")
    fi
    codesign "${CODESIGN_ARGS[@]}" Pausely.app
fi
codesign --verify --deep --strict Pausely.app

echo "=== Build Succeeded ==="
echo "Pausely.app is ready in the workspace!"
echo "To run the app: open Pausely.app"
