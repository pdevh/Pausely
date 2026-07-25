#!/bin/bash

set -euo pipefail

run_timed() {
    local timeout_seconds="$1"
    shift
    python3 - "$timeout_seconds" "$@" <<'PY'
import os
import signal
import subprocess
import sys

timeout = int(sys.argv[1])
command = sys.argv[2:]
process = subprocess.Popen(command, start_new_session=True)
try:
    return_code = process.wait(timeout=timeout)
except BaseException:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()
    raise
raise SystemExit(return_code)
PY
}

if [[ $# -ne 2 ]]; then
    echo "usage: $0 VERSION signed|unsigned" >&2
    exit 2
fi

VERSION="$1"
MODE="$2"
SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
if [[ ! "$VERSION" =~ $SEMVER_RE ]]; then
    echo "error: '$VERSION' is not strict MAJOR.MINOR.PATCH SemVer" >&2
    exit 2
fi
if [[ "$MODE" != "signed" && "$MODE" != "unsigned" ]]; then
    echo "error: mode must be signed or unsigned" >&2
    exit 2
fi

SCRIPT_DIR=$(cd "$(run_timed 10 dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ASSET_DIR="$REPO_ROOT/release-assets-macos"
DIAGNOSTICS_DIR="$REPO_ROOT/release-diagnostics-macos"

run_timed 30 rm -rf "$ASSET_DIR" "$DIAGNOSTICS_DIR"
run_timed 30 mkdir -p "$ASSET_DIR" "$DIAGNOSTICS_DIR"

write_build_summary() {
    local status="$1"
    local architectures="${2:-unknown}"
    printf 'version=%s\nmode=%s\nstatus=%s\narchitectures=%s\n' \
        "$VERSION" \
        "$MODE" \
        "$status" \
        "$architectures" > "$DIAGNOSTICS_DIR/build-summary.txt"
}
write_build_summary started

cd "$REPO_ROOT"
if [[ "$MODE" == "signed" ]]; then
    export REQUIRE_STABLE_SIGNING=true
else
    export CODE_SIGN_IDENTITY=-
    export REQUIRE_STABLE_SIGNING=false
fi

run_timed 1800 ./build.sh "$VERSION"

SHORT_VERSION=$(run_timed 30 /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' \
    Pausely.app/Contents/Info.plist)
BUNDLE_VERSION=$(run_timed 30 /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' \
    Pausely.app/Contents/Info.plist)
ICON_FILE=$(run_timed 30 /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleIconFile' \
    Pausely.app/Contents/Info.plist)
[[ "$SHORT_VERSION" == "$VERSION" ]]
[[ "$BUNDLE_VERSION" == "$VERSION" ]]
[[ "$ICON_FILE" == "Pausely.icns" ]]
run_timed 30 cmp -s Pausely.icns Pausely.app/Contents/Resources/Pausely.icns
ARCHS=$(run_timed 30 lipo -archs Pausely.app/Contents/MacOS/Pausely)
[[ "$ARCHS" == "x86_64 arm64" || "$ARCHS" == "arm64 x86_64" ]]
run_timed 120 codesign --verify --deep --strict Pausely.app

if [[ "$MODE" == "signed" ]]; then
    [[ -n "${PAUSELY_SIGNING_CERTIFICATE_SHA1:-}" ]]
    SIGNATURE_DETAILS=$(run_timed 30 codesign -dv --verbose=4 Pausely.app 2>&1)
    IS_ADHOC=false
    HAS_EXPECTED_AUTHORITY=false
    while IFS= read -r signature_line; do
        [[ "$signature_line" == "Signature=adhoc" ]] && IS_ADHOC=true
        [[ "$signature_line" == "Authority=Pausely GitHub Release Signing" ]] &&
            HAS_EXPECTED_AUTHORITY=true
    done <<<"$SIGNATURE_DETAILS"
    [[ "$IS_ADHOC" == "false" ]]
    [[ "$HAS_EXPECTED_AUTHORITY" == "true" ]]
    EXPECTED_REQUIREMENT="identifier \"com.philipp.Pausely\" and certificate leaf = H\"$PAUSELY_SIGNING_CERTIFICATE_SHA1\""
    REQUIREMENT_DETAILS=$(run_timed 30 codesign -d -r- Pausely.app 2>&1)
    ACTUAL_REQUIREMENT=""
    while IFS= read -r requirement_line; do
        if [[ "$requirement_line" == "designated => "* ]]; then
            ACTUAL_REQUIREMENT="${requirement_line#designated => }"
        fi
    done <<<"$REQUIREMENT_DETAILS"
    [[ "$ACTUAL_REQUIREMENT" == "$EXPECTED_REQUIREMENT" ]]
    run_timed 120 codesign --verify --strict --verbose=4 \
        -R="$EXPECTED_REQUIREMENT" \
        Pausely.app
fi

run_timed 300 ditto -c -k --sequesterRsrc --keepParent \
    Pausely.app \
    "$ASSET_DIR/Pausely-macOS.zip"

DMG_ROOT=$(run_timed 30 mktemp -d \
    "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pausely-dmg.XXXXXX")
run_timed 300 /usr/bin/ditto Pausely.app "$DMG_ROOT/Pausely.app"
run_timed 30 ln -s /Applications "$DMG_ROOT/Applications"
run_timed 300 hdiutil create \
    -volname "Pausely" \
    -srcfolder "$DMG_ROOT" \
    -format UDZO \
    -ov \
    -nospotlight \
    "$ASSET_DIR/Pausely-macOS.dmg"
run_timed 300 hdiutil verify "$ASSET_DIR/Pausely-macOS.dmg"

MOUNT_POINT=$(run_timed 30 mktemp -d \
    "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pausely-mount.XXXXXX")
cleanup_mount() {
    run_timed 30 hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
}
trap cleanup_mount EXIT
run_timed 120 hdiutil attach \
    -readonly \
    -nobrowse \
    -noautoopen \
    -mountpoint "$MOUNT_POINT" \
    "$ASSET_DIR/Pausely-macOS.dmg"
[[ -d "$MOUNT_POINT/Pausely.app" ]]
[[ -L "$MOUNT_POINT/Applications" ]]
[[ "$(run_timed 30 readlink "$MOUNT_POINT/Applications")" == "/Applications" ]]
run_timed 120 codesign --verify --deep --strict "$MOUNT_POINT/Pausely.app"
MOUNTED_VERSION=$(run_timed 30 /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' \
    "$MOUNT_POINT/Pausely.app/Contents/Info.plist")
[[ "$MOUNTED_VERSION" == "$VERSION" ]]
run_timed 30 hdiutil detach "$MOUNT_POINT"
trap - EXIT

if [[ "$MODE" == "signed" ]]; then
    [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]
    [[ -n "${GH_TOKEN:-}" ]]
    RELEASE_TAG="v$VERSION"
    SPARKLE_DIR=$(run_timed 30 mktemp -d \
        "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pausely-sparkle.XXXXXX")
    run_timed 30 cp \
        "$ASSET_DIR/Pausely-macOS.zip" \
        "$SPARKLE_DIR/Pausely-macOS.zip"
    LATEST_RELEASE_TAG=$(run_timed 30 gh api \
        "/repos/${GITHUB_REPOSITORY}/releases/latest" \
        --jq .tag_name)
    if [[ "$LATEST_RELEASE_TAG" != v* ||
        ! "${LATEST_RELEASE_TAG#v}" =~ $SEMVER_RE ]]; then
        echo "error: latest release tag '$LATEST_RELEASE_TAG' is not strict SemVer" >&2
        exit 1
    fi
    run_timed 120 gh api \
        "/repos/${GITHUB_REPOSITORY}/compare/${LATEST_RELEASE_TAG}...${GITHUB_SHA}" \
        --jq \
        '.commits | map("- " + (.commit.message | split("\n")[0])) | join("\n")' \
        > "$SPARKLE_DIR/Pausely-macOS.md"
    if [[ ! -s "$SPARKLE_DIR/Pausely-macOS.md" ]]; then
        printf 'Pausely %s\n' "$VERSION" > "$SPARKLE_DIR/Pausely-macOS.md"
    fi

    SPARKLE_KEY_FILE=$(run_timed 30 mktemp \
        "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pausely-sparkle-key.XXXXXX")
    run_timed 30 chmod 600 "$SPARKLE_KEY_FILE"
    printf '%s' "$SPARKLE_PRIVATE_KEY" > "$SPARKLE_KEY_FILE"
    cleanup_sparkle_key() {
        run_timed 30 rm -f "$SPARKLE_KEY_FILE"
    }
    trap cleanup_sparkle_key EXIT
    run_timed 300 .build/artifacts/sparkle/Sparkle/bin/generate_appcast \
            --ed-key-file "$SPARKLE_KEY_FILE" \
            --download-url-prefix "https://github.com/${GITHUB_REPOSITORY}/releases/download/${RELEASE_TAG}/" \
            --link "https://github.com/${GITHUB_REPOSITORY}/releases/tag/${RELEASE_TAG}" \
            --embed-release-notes \
            --maximum-versions 1 \
            --maximum-deltas 0 \
            -o "$ASSET_DIR/appcast.xml" \
            "$SPARKLE_DIR"

    APPCAST_CONTENTS=$(<"$ASSET_DIR/appcast.xml")
    [[ "$APPCAST_CONTENTS" == *"<sparkle:version>$VERSION</sparkle:version>"* ]]
    [[ "$APPCAST_CONTENTS" == *"releases/download/${RELEASE_TAG}/Pausely-macOS.zip"* ]]
    [[ "$APPCAST_CONTENTS" != *"Pausely-macOS.dmg"* ]]
    [[ "$APPCAST_CONTENTS" == *"sparkle:edSignature="* ]]
    [[ "$APPCAST_CONTENTS" == *"sparkle-signatures:"* ]]
    run_timed 120 .build/artifacts/sparkle/Sparkle/bin/sign_update \
            --verify \
            --ed-key-file "$SPARKLE_KEY_FILE" \
            "$ASSET_DIR/appcast.xml"
    run_timed 30 rm -f "$SPARKLE_KEY_FILE"
    trap - EXIT
fi

write_build_summary success "$ARCHS"
