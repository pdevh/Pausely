# Pausely for Windows

This directory contains the Windows WPF implementation of Pausely. It targets
64-bit Windows 10 and Windows 11 and currently builds with the .NET 10 SDK.

The Windows app mirrors the macOS timer and session behavior: it runs in the
system tray, supports the same interval and break-duration presets, warns beside
the pointer before a break, and displays animated break overlays on every active
monitor. The overlay uses the configured desktop wallpaper when it is available
and includes randomized break guidance, snooze, lock-screen, audio, and
double-Escape controls. The schedule can also be paused and resumed from the
tray menu.

Settings are stored in `%APPDATA%\Pausely\settings.json`. The optional
launch-at-sign-in setting uses the current user's `Run` registry key. Session
codes use the same six-character format as macOS and do not contact a
synchronization server.

## Install a release

Download `Pausely-Windows-Setup.exe` from the repository's
[Releases](https://github.com/pdevh/Pausely/releases) page and follow the
wizard. It performs a per-user installation under
`%LOCALAPPDATA%\Programs\Pausely`, creates a Start-menu entry and uninstaller,
and offers an optional desktop shortcut. The application is self-contained, so
users do not need to install .NET.

The application, installer, and uninstaller are Authenticode signed and RFC
3161 timestamped with Pausely's stable self-signed Windows release identity.
Windows does not publicly trust this no-cost certificate, so SmartScreen or the
installer can show **Unknown publisher**. Download it only from this repository.
The installer contains one x64 application payload, which runs natively on x64
Windows and through built-in x64 emulation on Windows 11 on Arm. Separate x86
and Arm64 payloads are not currently required for majority compatibility.

## Build and run

Building requires Windows and the .NET 10 SDK. From the repository root:

```powershell
dotnet build PauselyWindows/PauselyWindows.csproj
dotnet run --project PauselyWindows/PauselyWindows.csproj
```

Create the same self-contained, single-file layout used by the release workflow:

```powershell
dotnet publish PauselyWindows/PauselyWindows.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -p:DebugSymbols=false -o out
```

## Updates

Use **Settings → Check for Updates…** for a manual check, or enable
**Auto-Update** for a check shortly after startup. When a release is available,
Pausely downloads `Pausely-Windows-Setup.exe`, validates its size and
GitHub-provided SHA-256 digest, verifies that its Authenticode content is intact,
then checks the actual signer against Pausely's embedded certificate SHA-256
before starting the installer silently. The installer uses Windows Restart
Manager to close Pausely only when installation is ready to proceed, updates
the per-user installation, and relaunches the app. Failed downloads, damaged or
mismatched signatures, and installer launch failures leave the running app open.

Older portable releases only know the asset name `Pausely-Windows.zip`.
Releases continue to include that signed bridge payload so dormant installations
can obtain the installer-aware updater. Once the bridge app restarts, it offers
to finish installation through the signed wizard even when the release version
has not changed.

## Installer source

The Inno Setup definition is in `installer/Pausely.iss`. The release workflow
uses a stable `AppId`, a non-administrative per-user installation, signed setup
and uninstall executables, Start-menu integration, optional desktop shortcut,
silent install/uninstall smoke tests, and the same signed app payload retained
inside the legacy compatibility ZIP.
