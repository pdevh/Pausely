# Pausely

Pausely is a cross-platform break reminder for macOS and Windows. It runs from
the menu bar or system tray and presents a full-screen, multi-monitor break
overlay without adding a permanent application window.

Both apps provide the same core workflow:

- Work intervals and break durations adjustable to the second, plus a manual break action
- A pointer-following warning during the final 10 seconds before a break
- Animated overlays based on the current desktop wallpaper
- Randomized break guidance, snooze controls, a lock-screen action, and sound
  cues
- Pause and resume for temporarily suspending the normal schedule
- Compact session codes that align schedules across macOS and Windows
- Optional launch at sign-in and update checks

Session codes contain the selected schedule and timing anchor. They can be
shared directly and do not require an account or a Pausely synchronization
server.

## Custom intervals and durations

In **Work Interval** or **Break Duration**, choose **Custom…** beneath the presets.
Enter seconds (`37`), minutes and seconds (`2:37`), or hours, minutes and seconds
(`1:02:37`). Each setting supports whole seconds from **1 second to 24 hours**.
The editable clock and **Hours / Minutes / Seconds** adjustment buttons share one value.
Choose **Save** to apply it; **Cancel** or Escape keeps the previous setting.
Custom values remain selected in the menu and are saved across app restarts.
The same controls are available on macOS and Windows.

Sessions using presets keep the existing **six-character codes**. A session
with either value customized uses **eleven characters**; both participants need
a version of Pausely supporting custom schedules. Join accepts pasted or typed
codes (including lowercase, spaces, and grouping hyphens) and previews the work
and break durations before joining. Earlier Base64 invites can still be imported.
Settings remain locked during a session; leaving restores your personal values.

The compact encoding and its compatibility limits are documented in
[the session format](docs/session-format.md).

## Download

Prebuilt macOS and Windows packages are published on the repository's
[Releases](https://github.com/pdevh/Pausely/releases) page.

| Download | Platform | Role |
|---|---|---|
| `Pausely-macOS.dmg` | macOS | Recommended installation: drag Pausely to Applications |
| `Pausely-macOS.zip` | macOS | Sparkle update archive; keep it for automatic updates rather than manual installation |
| `Pausely-Windows-Setup.exe` | Windows | Recommended installation: per-user setup wizard |
| `Pausely-Windows.exe` | Windows | Secondary portable download: run directly without installing |

No separate checksum files are published. The applications' update mechanisms
verify update metadata and cryptographic signatures automatically.

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
2. If SmartScreen shows **Windows protected your PC**, select **More info**,
   verify that the file is named `Pausely-Windows-Setup.exe`, then select
   **Run anyway** only if you downloaded it from this repository's Releases
   page. If Windows instead shows an **Unknown publisher** confirmation, review
   the same source and filename before continuing.
3. Follow the installation wizard. Pausely is installed for the current user,
   adds a Start-menu shortcut, and can optionally add a desktop shortcut.

`Pausely-Windows.exe` is available as a secondary portable option. It uses the
same self-contained x64 application payload but does not create an installed
app, Start-menu entry, desktop shortcut, or uninstaller.

The application, installer, and uninstaller are Authenticode signed and
timestamped with Pausely's stable Windows release identity. This identity is
self-signed so releases can be produced without a paid signing service.
Windows does not publicly trust it, so SmartScreen or the installer may still
show **Unknown publisher**. The signature provides tamper detection and signer
continuity for Pausely's updater; it does not make Microsoft publicly trust the
publisher or suppress reputation warnings.

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

## Build from source

### macOS

Install Xcode Command Line Tools with Swift 5.7 or newer, then run from the
repository root:

```bash
./build.sh 1.0.0
open Pausely.app
```

`build.sh` also accepts a strict release tag such as `v1.0.6` and writes the
normalized `1.0.6` version to both macOS bundle-version fields.

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

## Tests

```bash
swift test
```

This runs duration, editor, timer-boundary, and session tests on macOS or Linux.
On macOS it also tests settings persistence and renders the native dialogs in
light and dark appearances. Windows tests include settings persistence and the
existing release-signature policy tests:

```powershell
dotnet run --project PauselyWindows.Tests/PauselyWindows.Tests.csproj -c Release
```

Both suites consume the same encoding fixtures and round-trip all 86,400 values
for each custom field. Native macOS and Windows builds and tests run in the
existing PR release-validation workflow; PRs do not publish a release.

## Maintainer release setup

Pull requests and pushes to `main` compile and smoke-test both platforms without
publishing or using release-signing secrets. A manual candidate run exercises
the persistent signing identities and uploads private candidate artifacts and
diagnostics, but does not create a public release.

Public releases run only for tags matching `vMAJOR.MINOR.PATCH`. The tag supplies
the application, installer, DMG, appcast, and release version. Publication is
atomic: the release contains `Pausely-macOS.dmg`, `Pausely-macOS.zip`,
`appcast.xml`, `Pausely-Windows-Setup.exe`, and `Pausely-Windows.exe`, or no
public release is created.

The macOS build remains a universal Intel/Apple Silicon app distributed in a
drag-to-Applications DMG, with its ZIP retained for Sparkle updates. The Windows
build provides a signed per-user installer and a signed portable copy of the
same self-contained x64 executable. Native Windows x86 and Arm64 payloads are
intentionally not produced: x64 covers supported conventional PCs and Windows
11 on Arm through built-in emulation, without splitting the update channel.

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
uninstaller. A shared verifier checks intact Authenticode content, the exact
certificate SHA-256, code-signing EKU, a valid RFC 3161 timestamp, and permits
only the expected self-signed `CERT_E_UNTRUSTEDROOT` policy result. Candidate
and release lifecycle tests cover installation, installed signatures, in-place
update and relaunch, tamper and wrong-signer rejection, and uninstallation.

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
caused by this self-signed leaf; every other chain, digest, expiry, usage,
timestamp, or policy failure is rejected. Neither CI nor Pausely adds the
certificate to Windows `Root` or `TrustedPublisher`.

This provides cryptographic release and update continuity, but it cannot remove
Windows' **Unknown publisher** or SmartScreen warnings; Microsoft treats this
self-signed identity like an unsigned publisher for those purposes. Microsoft
Store distribution is the only route that reliably avoids the prompt, and
Pausely does not require a Store fee, paid certificate, or managed signing
service. A publicly trusted publisher identity remains an optional future swap.
If the certificate is ever rotated, first ship a transition updater that trusts
both old and new pins; replacing it directly would strand installed clients.

Windows-specific implementation notes are in
[`PauselyWindows/README.md`](PauselyWindows/README.md).
