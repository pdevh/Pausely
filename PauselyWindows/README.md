# Pausely for Windows

This is the Windows port of Pausely, built with WPF and .NET 8+.

## Features Implemented
- **System Tray Integration**: Uses `Hardcodet.NotifyIcon.Wpf` to sit quietly in the taskbar.
- **State Machine**: Replicates `BreakManager` from the macOS version to handle work intervals and break durations.
- **Multi-Monitor Fullscreen Overlays**: Automatically spans all active monitors.
- **Dynamic Desktop Background**: Automatically grabs the current Windows desktop wallpaper (`SystemParametersInfo` API) and applies it behind the darkened overlay.
- **Audio Prompts**: Uses standard Windows sounds (Exclamation, Asterisk) for break start and end.
- **Animations**: Smooth fade-in and fade-out animations for the overlays.

## How to Build and Run
Because this is a WPF application, it must be built and run on a Windows machine.

### Prerequisites
- Windows OS (Windows 10 or 11)
- .NET 8.0 SDK or later

### Building
1. Open a terminal or Developer Command Prompt in this folder (`PauselyWindows`).
2. Run the following command:
   ```bash
   dotnet build
   ```
3. To run the app:
   ```bash
   dotnet run
   ```

### Packaging
You can publish it as a self-contained single-file executable for easier distribution:
```bash
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true
```
