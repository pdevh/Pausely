# Pausely

Pausely is a macOS menu-bar break timer. A Windows port is available in
[`PauselyWindows/`](PauselyWindows/).

## macOS requirements

- macOS 13 or newer
- Apple Silicon or Intel Mac. Published releases contain a universal binary.

The project does not currently use a paid Apple Developer account. Release
builds are therefore not Developer ID signed or notarized. macOS may warn that
the developer cannot be verified when opening the app.

## Run a downloaded macOS release

1. Download `Pausely-macOS.zip` from the repository's **Releases** page.
2. Unzip it and move `Pausely.app` to `Applications`.
3. The first time you open it, Control-click `Pausely.app`, choose **Open**,
   and confirm **Open** in the macOS dialog.
4. If macOS still blocks it, open **System Settings → Privacy & Security**,
   find the message that Pausely was blocked, and choose **Open Anyway**.

Only use a release downloaded from this repository. Do not bypass Gatekeeper
for an untrusted copy.

## Build and run from source

Requirements:

- macOS 13 or newer
- Xcode Command Line Tools, including Swift 5.7 or newer

From the repository root:

```bash
./build.sh 1.0.0
open Pausely.app
```

For a direct development build:

```bash
swift build -c release
```

The first launch may request screen-recording permission. Pausely uses this
permission to capture the current desktop wallpaper for the break overlay.

## Updates

Pausely uses [Sparkle](https://sparkle-project.org/) to check the latest public
GitHub release. No GitHub access token is included in the app or required by
users.

When a newer version is available, Sparkle shows its standard update window
with release notes and options to install, be reminded later, or skip that
version. Update archives are verified with Pausely's EdDSA key before they are
extracted. Automatic checks can be changed under **Settings → Automatically
Check for Updates**, and **Check for Updates…** starts a manual check.

Because releases are not Developer ID signed or notarized yet, macOS may still
show the first-launch warning described above. The Sparkle signature protects
the update archive but does not replace Apple's Gatekeeper or notarization.

## Maintainer release setup

Sparkle's private EdDSA key is stored in the repository Actions secret named
`SPARKLE_PRIVATE_KEY`. Its public half is committed in `Info.plist`. Keep an
offline backup of the private key: losing it prevents installed copies from
trusting future updates.

On the Mac where the key was generated, export that backup with:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account pausely \
  -x /path/to/secure/offline/pausely-sparkle-private-key
```

Never commit the exported file or attach it to a GitHub release.

The release workflow builds a universal macOS app, applies an ad-hoc code
signature, packages it with `ditto`, generates a signed `appcast.xml`, and
publishes both files in the GitHub release. The stable feed URL is:

```text
https://github.com/pdevh/Pausely/releases/latest/download/appcast.xml
```

Do not change the public key after distributing a release unless following
Sparkle's documented key-rotation procedure.

## Windows

See [`PauselyWindows/README.md`](PauselyWindows/README.md) for Windows build,
publish, and run instructions.
