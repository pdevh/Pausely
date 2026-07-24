import AppKit
import CoreGraphics
import Foundation

/// Owns Pausely's Screen Recording permission flow.
///
/// macOS associates privacy grants with the app's code-signing requirement, not
/// only its display name. Release builds must therefore keep a stable signing
/// requirement. This type prevents a denied/stale grant from turning into a
/// prompt on every launch and gives the user a deliberate recovery path.
final class ScreenCapturePermissionManager: @unchecked Sendable {
    static let shared = ScreenCapturePermissionManager()

    private enum DefaultsKey {
        static let automaticRequestAttempted = "screenCapturePermission.automaticRequestAttempted"
        static let duplicateWarningFingerprint = "screenCapturePermission.duplicateWarningFingerprint"
    }

    private(set) var knownInstallLocations: [URL] = []

    private init() {}

    var isAuthorized: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Requests access at most once automatically for this installation's
    /// preferences. Further attempts must come from an explicit menu action.
    @discardableResult
    func requestOnceIfNeeded() -> Bool {
        if isAuthorized {
            UserDefaults.standard.set(true, forKey: DefaultsKey.automaticRequestAttempted)
            return true
        }

        guard !UserDefaults.standard.bool(forKey: DefaultsKey.automaticRequestAttempted) else {
            return false
        }

        // Persist before asking so a crash, denial, or settings detour cannot
        // cause another automatic prompt on the next launch.
        UserDefaults.standard.set(true, forKey: DefaultsKey.automaticRequestAttempted)
        return CGRequestScreenCaptureAccess()
    }

    /// Re-checks installed copies without blocking application launch. Multiple
    /// physical app bundles can create visually indistinguishable rows in
    /// System Settings, especially across old ad-hoc-signed releases. Pausely
    /// deliberately does not request a new grant until duplicate copies have
    /// been resolved.
    func prepareAtLaunch() {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.philipp.Pausely"
        let currentAppURL = Bundle.main.bundleURL

        Task.detached(priority: .utility) {
            let locations = PauselyInstallLocator.findApplications(
                bundleIdentifier: bundleIdentifier,
                including: currentAppURL
            )

            await MainActor.run {
                self.knownInstallLocations = locations
                guard locations.count > 1 else {
                    UserDefaults.standard.removeObject(forKey: DefaultsKey.duplicateWarningFingerprint)
                    self.requestOnceIfNeeded()
                    return
                }

                let fingerprint = locations.map(\.path).joined(separator: "\n")
                guard UserDefaults.standard.string(forKey: DefaultsKey.duplicateWarningFingerprint) != fingerprint else {
                    return
                }

                // Keep this separate from the initial system permission sheet.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    UserDefaults.standard.set(fingerprint, forKey: DefaultsKey.duplicateWarningFingerprint)
                    self.showDuplicateInstallWarning(locations: locations)
                }
            }
        }
    }

    func showPermissionHelp() {
        let authorized = isAuthorized
        let duplicateLocations = knownInstallLocations.filter { !Self.isCurrentApplication($0) }

        let alert = NSAlert()
        alert.alertStyle = authorized && duplicateLocations.isEmpty ? .informational : .warning
        alert.messageText = authorized ? "Screen Recording is allowed" : "Screen Recording needs attention"

        var details: [String] = []
        if authorized {
            details.append("Pausely can capture your rendered wallpaper for the break overlay.")
        } else {
            details.append("Pausely cannot currently capture the rendered wallpaper. You can request access again below or review Screen Recording in System Settings.")
            details.append("If System Settings shows Pausely as enabled but access still fails, quit Pausely, delete or compress old Pausely copies, remove stale Pausely rows from Screen Recording when macOS offers that option, then reopen the copy in Applications and grant access once.")
        }

        if !duplicateLocations.isEmpty {
            let copyWord = duplicateLocations.count == 1 ? "copy" : "copies"
            details.append("Found \(duplicateLocations.count) additional Pausely app \(copyWord). Keep one installed copy—preferably /Applications/Pausely.app—to avoid ambiguous privacy entries.")
        }

        details.append("Running from: \(Bundle.main.bundleURL.path)")
        alert.informativeText = details.joined(separator: "\n\n")

        if authorized {
            alert.addButton(withTitle: "Open System Settings")
        } else {
            alert.addButton(withTitle: "Request Access")
            alert.addButton(withTitle: "Open System Settings")
        }

        if !duplicateLocations.isEmpty {
            alert.addButton(withTitle: "Reveal Other Copy")
        } else {
            alert.addButton(withTitle: "Done")
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if authorized {
            if response == .alertFirstButtonReturn {
                openScreenRecordingSettings()
            } else if response == .alertSecondButtonReturn, let duplicate = duplicateLocations.first {
                NSWorkspace.shared.activateFileViewerSelecting([duplicate])
            }
            return
        }

        switch response {
        case .alertFirstButtonReturn:
            _ = CGRequestScreenCaptureAccess()
        case .alertSecondButtonReturn:
            openScreenRecordingSettings()
        case .alertThirdButtonReturn:
            if let duplicate = duplicateLocations.first {
                NSWorkspace.shared.activateFileViewerSelecting([duplicate])
            }
        default:
            break
        }
    }

    private func showDuplicateInstallWarning(locations: [URL]) {
        let otherLocations = locations.filter { !Self.isCurrentApplication($0) }
        guard !otherLocations.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Multiple Pausely apps found"
        let otherPaths = otherLocations.map(\.path).joined(separator: "\n")
        alert.informativeText = "macOS privacy permissions are tied to a signed app identity. Multiple or older Pausely copies can leave ambiguous Screen Recording entries.\n\nKeep one installed copy—preferably /Applications/Pausely.app—and delete or compress the others before granting permission again.\n\nRunning from: \(Bundle.main.bundleURL.path)\n\nOther copies:\n\(otherPaths)"
        alert.addButton(withTitle: "Reveal Other Copy")
        alert.addButton(withTitle: "Review Permission")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.activateFileViewerSelecting([otherLocations[0]])
        case .alertSecondButtonReturn:
            showPermissionHelp()
        default:
            break
        }
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func isCurrentApplication(_ url: URL) -> Bool {
        canonicalURL(url) == canonicalURL(Bundle.main.bundleURL)
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

private enum PauselyInstallLocator {
    static func findApplications(bundleIdentifier: String, including currentAppURL: URL) -> [URL] {
        var candidates = Set<URL>()
        candidates.insert(canonicalURL(currentAppURL))

        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        task.arguments = ["kMDItemCFBundleIdentifier == '\(bundleIdentifier)'c"]
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice

        if (try? task.run()) != nil {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            if let result = String(data: data, encoding: .utf8) {
                for path in result.split(whereSeparator: \.isNewline).map(String.init) {
                    let url = canonicalURL(URL(fileURLWithPath: path))
                    guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
                          Bundle(url: url)?.bundleIdentifier == bundleIdentifier else {
                        continue
                    }
                    candidates.insert(url)
                }
            }
        }

        return candidates.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
