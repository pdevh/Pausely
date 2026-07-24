# Pausely

Pausely is a cross-platform break reminder for macOS and Windows. It runs from
the menu bar or system tray and presents a full-screen, multi-monitor break
overlay without adding a permanent application window.

Both apps provide the same core workflow:

- Configurable work intervals and break durations, plus a manual break action
- A pointer-following warning during the final 10 seconds before a break
- Animated overlays based on the current desktop wallpaper
- Randomized break guidance, snooze controls, a lock-screen action, and sound
  cues
- Pause and resume for temporarily suspending the normal schedule
- Six-character session codes that align schedules across macOS and Windows
- Optional launch at sign-in and update checks

Session codes contain the selected schedule and timing anchor. They can be
shared directly and do not require an account or a Pausely synchronization
server.

## Download

Prebuilt macOS and Windows packages are published on the repository's
[Releases](https://github.com/pdevh/Pausely/releases) page.

### macOS

Requirements: macOS 13 or newer on Apple Silicon or Intel.

1. Download and open `Pausely-macOS.dmg`.
2. Drag `Pausely` onto the **Applications** shortcut in the disk-image window.
3. Eject the Pausely disk image and delete older copies from Downloads,
   Desktop, and other folders.
4. Control-click `/Applications/Pausely.app`, choose **Open**, then confirm
   **Open**. If macOS does not offer that option, use **System Settings →
   Privacy & Security → Open Anyway**.

Pausely does not have a paid Apple Developer membership. GitHub releases are
therefore not notarized or trusted by Gatekeeper and macOS will identify the
developer as unidentified. Only override Gatekeeper when the package came from
this repository.

Releases are signed with Pausely's persistent self-signed identity. This does
not remove the warning or make Apple trust the app; it provides a consistent
cryptographic identity across releases so updates and privacy grants have the
best continuity possible without Developer ID.

### Windows

Requirements: 64-bit Windows 10 or Windows 11, including Windows 11 on Arm
through its built-in x64 application support. The release is self-contained, so
installing the .NET runtime separately is not required.

1. Download and run `Pausely-Windows-Setup.exe`.
2. Follow the installation wizard. Pausely is installed for the current user,
   adds a Start-menu shortcut, and can optionally add a desktop shortcut.

The application, installer, and uninstaller are Authenticode signed and
timestamped with Pausely's stable Windows release identity. This identity is
self-signed so releases can be produced without a paid signing service.
Windows does not publicly trust it, so SmartScreen or the installer may still
show **Unknown publisher**. Download installers only from this repository.

## macOS screen-recording permission

Pausely requests Screen Recording access so it can capture the rendered desktop
wallpaper for its break overlay. The image is processed locally and is not
uploaded. Windows reads the configured wallpaper file and does not require an
equivalent privacy permission.

On macOS, grant access under **System Settings → Privacy & Security → Screen &
System Audio Recording** (called **Screen Recording** on some macOS versions),
then quit and reopen Pausely if macOS asks you to do so.

Keep exactly one installed copy at `/Applications/Pausely.app`. macOS privacy
grants are associated with an app's signed identity. Current releases share a
certificate-pinned identity across updates, but an older ad-hoc-signed build or a
second app copy can leave a stale Pausely row or make an existing toggle refer
to the wrong copy. Pausely checks for duplicate installations and warns when it
finds them. Because this is not Developer ID, permission continuity is a
best-effort compatibility measure rather than an Apple-supported distribution
guarantee. If capture access is still unavailable after an update:

1. Quit every running Pausely process and delete all copies except
   `/Applications/Pausely.app`.
2. In the Screen Recording privacy list, remove obsolete Pausely entries or
   toggle Pausely off and back on.
3. Reopen `/Applications/Pausely.app` and approve the prompt once if requested.

## Updates

macOS uses [Sparkle](https://sparkle-project.org/) for manual and automatic
checks. Update archives and the appcast are verified with Pausely's embedded
EdDSA public key before installation. Use **Settings → Check for Updates…** or
change **Automatically Check for Updates** from the menu-bar menu.

On Windows, use **Settings → Check for Updates…** or enable **Auto-Update** in
the tray menu. The Windows updater downloads the latest signed
`Pausely-Windows-Setup.exe`, verifies both its GitHub-provided SHA-256 metadata
and its Authenticode signature against Pausely's embedded certificate pin, then
runs the installer silently. A missing digest, damaged signature, certificate
mismatch, or installer-launch failure aborts the update without shutting down
the running app.

`Pausely-Windows.zip` remains attached to releases only as a compatibility
bridge for older portable versions whose updater hardcodes that filename. New
installations should use the setup wizard.

## Build from source

### macOS

Install Xcode Command Line Tools with Swift 5.7 or newer, then run from the
repository root:

```bash
./build.sh 1.0.0
open Pausely.app
```

Pass `clean` after the version to clear Swift Package Manager's build cache:

```bash
./build.sh 1.0.0 clean
```

`swift build` compiles the executable target but does not assemble the complete
application bundle and its resources; use `build.sh` when testing the app. Local
builds are ad-hoc signed unless `CODE_SIGN_IDENTITY` names an installed signing
identity.

### Windows

Install the .NET 10 SDK on Windows. From the repository root:

```powershell
dotnet build PauselyWindows/PauselyWindows.csproj
dotnet run --project PauselyWindows/PauselyWindows.csproj
```

To reproduce the self-contained x64 application payload:

```powershell
dotnet publish PauselyWindows/PauselyWindows.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -p:DebugSymbols=false -o out
```

## Maintainer release setup

Every push to `main` builds both platforms and publishes a versioned GitHub
release after both builds succeed. The macOS artifact is a universal Intel/Apple
Silicon app distributed in a drag-to-Applications DMG. The Windows artifact is a
signed per-user installer containing a self-contained x64 executable. Native
Windows x86 and Arm64 payloads are intentionally not produced: x64 covers the
supported conventional PCs and Windows 11 on Arm through built-in emulation,
without splitting the update channel.

`PauselyIcon.icon/` is the editable icon source. `Pausely.icns` and
`PauselyWindows/Pausely.ico` are the generated platform assets consumed by the
two release builds.

The no-cost macOS release workflow uses one long-lived self-signed code-signing
certificate. The app's designated requirement is pinned to the public
certificate in `.github/signing/Pausely-Release-Certificate.pem`. This keeps
the identity stable across releases, but does not make the app Apple-trusted.

Create the identity once and upload its password-protected CI copy to GitHub
Actions:

```bash
scripts/setup-macos-self-signing.sh
```

The script keeps the encrypted private key and certificate passwords under
`~/.config/pausely/release-signing/`. Store that directory in at least two
secure offline backups. The private key must never be committed or uploaded
directly to GitHub. Running the script again preserves the identity and refreshes
the password-protected `.p12` and GitHub secrets:

```bash
scripts/setup-macos-self-signing.sh
```

The macOS release job requires these GitHub Actions secrets:

- `MACOS_SIGNING_CERTIFICATE`: base64-encoded password-protected `.p12`
- `MACOS_SIGNING_CERTIFICATE_PASSWORD`: password for that `.p12`
- `SPARKLE_PRIVATE_KEY`: private EdDSA update-signing key

CI imports the identity into an ephemeral keychain, verifies its fingerprint
against the committed public certificate, embeds the exact certificate-pinned
designated requirement, and rejects ad-hoc signatures or identity drift. It
deliberately does not attempt Apple notarization.

The Sparkle public key is in `Info.plist`. Keep an offline backup of the private
key, because losing it prevents installed copies from trusting future macOS
updates. On the Mac where the key was generated, export it with:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account pausely \
  -x /path/to/secure/offline/pausely-sparkle-private-key
```

Never commit the exported key or attach it to a release. The stable Sparkle feed
is:

```text
https://github.com/pdevh/Pausely/releases/latest/download/appcast.xml
```

Do not change the public key after distributing a release unless following
Sparkle's documented key-rotation procedure.

### Windows release signing

Windows releases use a dedicated long-lived self-signed RSA code-signing
certificate, with no Azure subscription or paid developer account. The workflow
signs and RFC 3161 timestamps the app, Inno Setup installer, and embedded
uninstaller. It verifies the exact certificate SHA-256, code-signing EKU,
timestamp, installation, installed signatures, update relaunch, portable
migration, tamper rejection, and uninstallation before allowing a release.

The committed public certificate is
`.github/signing/Pausely-Windows-Release-Certificate.pem`; its DER SHA-256 is:

```text
75A3947C8623E4EAD6C840D11A64B9A303AA8929548B30F7B14AAED37018A1C7
```

The matching private identity is stored in these GitHub Actions secrets:

- `WINDOWS_SIGNING_CERTIFICATE`, containing the base64 PKCS#12 file
- `WINDOWS_SIGNING_CERTIFICATE_PASSWORD`

This Windows identity is deliberately separate from
`MACOS_SIGNING_CERTIFICATE` and `SPARKLE_PRIVATE_KEY`; never reuse, replace, or
cross-load those secrets.

The updater embeds the certificate SHA-256 and accepts an installer only when
Windows verifies that its Authenticode content is intact and the actual signer
matches that pin. It deliberately permits the precise “untrusted root” result
caused by this self-signed leaf; every other trust, digest, expiry, usage, or
policy failure is rejected. The certificate is never added to an end user's
Windows trust store.

This provides cryptographic release and update continuity, but it cannot remove
Windows' **Unknown publisher** or SmartScreen warnings. Only a publicly trusted
commercial certificate or managed signing service can do that. If the
certificate is ever rotated, first ship a transition updater that trusts both
old and new pins; replacing it directly would strand installed clients.

Windows-specific implementation notes are in
[`PauselyWindows/README.md`](PauselyWindows/README.md).
