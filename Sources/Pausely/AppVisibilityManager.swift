import AppKit
import Foundation

class AppVisibilityManager {
    static let shared = AppVisibilityManager()
    
    private var hiddenApps: [NSRunningApplication] = []
    
    private var wasDockAutohidden: Bool = false
    private var wasDesktopHidden: Bool = false
    private var wereWidgetsHidden: Bool = false
    
    private init() {}
    
    // MARK: - Shell Helpers
    
    /// Reads a defaults value synchronously. Returns trimmed stdout.
    private func readDefault(_ command: String) -> String? {
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", command]
        try? task.run()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Runs a shell command synchronously (blocks until complete).
    private func runShellSync(_ command: String) {
        let task = Process()
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", command]
        try? task.run()
        task.waitUntilExit()
    }
    
    /// Runs an AppleScript synchronously.
    private func runAppleScript(_ source: String) {
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            script.executeAndReturnError(&error)
        }
    }
    
    // MARK: - Public API
    
    func hideOtherApps() {
        // 1. Snapshot which apps are currently visible so we can restore them later.
        //    We use NSRunningApplication for tracking only — NOT for hiding.
        hiddenApps = NSWorkspace.shared.runningApplications.filter {
            $0 != NSRunningApplication.current &&
            $0.activationPolicy == .regular &&
            !$0.isHidden
        }
        
        // 2. Read current system state before modifying anything.
        wasDockAutohidden = (readDefault("defaults read com.apple.dock autohide") == "1")
        wasDesktopHidden = (readDefault("defaults read com.apple.WindowManager StandardHideDesktopIcons") == "1")
        wereWidgetsHidden = (readDefault("defaults read com.apple.WindowManager StandardHideWidgets") == "1")
        
        // 3. Write desktop/widget defaults and restart WindowManager SYNCHRONOUSLY.
        //    This MUST happen BEFORE hiding apps via AppleScript, because killall
        //    WindowManager resets Finder's visibility state. By doing it first and
        //    waiting for completion, the subsequent AppleScript hide will stick.
        if !wasDesktopHidden || !wereWidgetsHidden {
            runShellSync("defaults write com.apple.WindowManager StandardHideDesktopIcons -int 1 && defaults write com.apple.WindowManager StandardHideWidgets -int 1 && killall WindowManager")
            // Give WindowManager time to fully restart and stabilize
            Thread.sleep(forTimeInterval: 0.3)
        }
        
        // 4. Single AppleScript to hide ALL visible apps and the dock.
        //    Uses System Events (accessibility layer), which works from an
        //    LSUIElement agent — unlike NSRunningApplication.hide() which
        //    cannot hide the frontmost app from an agent.
        //    Done AFTER WindowManager restart so Finder visibility sticks.
        runAppleScript("""
        tell application "System Events"
            set visible of every process whose visible is true and name is not "Pausely" and name is not "SystemUIServer" and name is not "WindowServer" to false
            tell dock preferences
                set autohide to true
            end tell
        end tell
        """)
    }
    
    func restoreApps() {
        // 1. Restore regular apps via NSRunningApplication.unhide()
        //    (unhiding is permissive and works fine from an LSUIElement)
        for app in hiddenApps {
            app.unhide()
        }
        hiddenApps.removeAll()
        
        // 2. Restore Finder visibility and dock via AppleScript
        var restoreLines = "set visible of process \"Finder\" to true"
        if !wasDockAutohidden {
            restoreLines += "\ntell dock preferences\nset autohide to false\nend tell"
        }
        runAppleScript("""
        tell application "System Events"
            \(restoreLines)
        end tell
        """)
        
        // 3. Restore desktop icons and widgets if we changed them
        if !wasDesktopHidden || !wereWidgetsHidden {
            let desktopVal = wasDesktopHidden ? 1 : 0
            let widgetsVal = wereWidgetsHidden ? 1 : 0
            runShellSync("defaults write com.apple.WindowManager StandardHideDesktopIcons -int \(desktopVal) && defaults write com.apple.WindowManager StandardHideWidgets -int \(widgetsVal) && killall WindowManager")
        }
    }
}
