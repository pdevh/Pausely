import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuManager.shared.setupMenuBar()

        ScreenCapturePermissionManager.shared.prepareAtLaunch()
        
        // Startup reconciliation
        StartupService.shared.reconcile()
        
        // Start Sparkle and perform an immediate quiet check when enabled.
        _ = UpdateService.shared
        UpdateService.shared.checkForUpdatesInBackground()
    }
}

@main
struct PauselyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/// A lightweight NSView used as the `view` of the status NSMenuItem.
/// Updating its label does NOT trigger NSMenu layout invalidation,
/// so neighbouring items keep their native hover highlight intact.
class StatusMenuItemView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    
    var text: String {
        get { label.stringValue }
        set {
            guard label.stringValue != newValue else { return }
            label.stringValue = newValue
            label.needsDisplay = true
        }
    }
    
    var progress: Double {
        get { progressIndicator.doubleValue }
        set { progressIndicator.doubleValue = newValue }
    }
    
    init(text: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 32))
        
        progressIndicator.style = .spinning
        progressIndicator.isDisplayedWhenStopped = true
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.controlSize = .small
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        
        label.stringValue = text
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.textColor = .labelColor
        label.isEditable = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.translatesAutoresizingMaskIntoConstraints = false
        
        addSubview(progressIndicator)
        addSubview(label)
        
        NSLayoutConstraint.activate([
            progressIndicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            progressIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            
            label.leadingAnchor.constraint(equalTo: progressIndicator.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    
    required init?(coder: NSCoder) { fatalError() }
}

class PrimaryButtonMenuItemView: NSView {
    private let button = NSButton()
    private weak var target: AnyObject?
    private var action: Selector?
    
    var title: String {
        get { button.title }
        set { button.title = newValue }
    }
    
    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 40))
        self.target = target
        self.action = action
        
        button.title = title
        button.target = self
        button.action = #selector(buttonClicked)
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r" // Makes it the primary button (accent colored)
        if #available(macOS 11.0, *) {
            button.controlSize = .large
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.heightAnchor.constraint(equalToConstant: 32)
        ])
    }
    
    @objc private func buttonClicked() {
        if let menu = enclosingMenuItem?.menu {
            menu.cancelTracking()
        }
        if let target = target as? NSObject, let action = action {
            target.perform(action, with: self)
        }
    }
    
    required init?(coder: NSCoder) { fatalError() }
}

class MenuManager: NSObject, NSMenuDelegate {
    static let shared = MenuManager()
    
    private var statusItem: NSStatusItem?
    private let breakManager = BreakManager.shared
    private var statusMenuItemView: StatusMenuItemView?
    private var sessionDialogWindow: NSWindow?
    private lazy var eyeOpenImage = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: "Pausely")
    private lazy var eyeClosedImage = NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: "Pausely")
    private lazy var pauseImage = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pausely")
    private var lastRenderedStatus: BreakStatus?
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
        
        // Initial setup
        buildMenu()
        updateStatusItemLabel()
        
        // Direct callback from the GCD timer — fires on the main queue,
        // so it is immune to RunLoop-mode changes during NSMenu tracking.
        breakManager.onTick = { [weak self] in
            self?.updateStatusItemLabel()
        }
    }
    
    func updateStatusItemLabel() {
        guard let button = statusItem?.button else { return }
        
        // Only recreate image when status actually changes (a few times/hour, not every second)
        if lastRenderedStatus != breakManager.status {
            lastRenderedStatus = breakManager.status
            switch breakManager.status {
            case .inBreak:  button.image = eyeClosedImage
            case .paused:   button.image = pauseImage
            case .working:  button.image = eyeOpenImage
            }
            button.imagePosition = .imageLeading
        }
        
        let titleText: String
        switch breakManager.status {
        case .working:  titleText = timeFormatted(breakManager.timeRemaining)
        case .inBreak:  titleText = "Break!"
        case .paused:   titleText = timeFormatted(breakManager.timeRemaining)
        }
        button.title = titleText
        
        // Update the custom view label in the dropdown — this avoids
        // NSMenu layout invalidation that would reset hover highlights
        let statusText: String
        switch breakManager.status {
        case .working:  statusText = "Next break in \(timeFormatted(breakManager.timeRemaining))"
        case .inBreak:  statusText = "Break in progress"
        case .paused:   statusText = "Breaks paused · \(timeFormatted(breakManager.timeRemaining)) left"
        }
        statusMenuItemView?.text = statusText
        let progress = breakManager.status == .working
            ? 1.0 - (Double(breakManager.timeRemaining) / breakManager.workInterval)
            : 0.0
        statusMenuItemView?.progress = max(0.0, min(1.0, progress))
    }
    
    func buildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()
        
        // Status indicator (time remaining) — uses a custom view so
        // per-second updates don't disturb native hover on other items
        let statusText = breakManager.status == .inBreak
            ? "Break in progress"
            : "Next break in \(timeFormatted(breakManager.timeRemaining))"
        let customView = StatusMenuItemView(text: statusText)
        self.statusMenuItemView = customView
        let statusMenuItem = NSMenuItem()
        statusMenuItem.view = customView
        menu.addItem(statusMenuItem)
        
        // Action: Start Break Now
        let startBreakItem = NSMenuItem()
        let buttonTitle = breakManager.isSyncedSession ? "Start Intermission" : "Start Break Now"
        let primaryButtonView = PrimaryButtonMenuItemView(title: buttonTitle, target: self, action: #selector(startBreakClicked))
        startBreakItem.view = primaryButtonView
        menu.addItem(startBreakItem)
        
        // Pause / Resume Breaks
        if breakManager.status == .paused {
            let resumeItem = NSMenuItem(title: "Resume Breaks", action: #selector(resumeBreaksClicked), keyEquivalent: "")
            resumeItem.target = self
            resumeItem.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
            menu.addItem(resumeItem)
        } else {
            let pauseDuration = breakManager.suggestedPauseDuration
            let pauseTitle = "Pause Breaks (\(formatFriendlyDuration(pauseDuration)))"
            let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(pauseBreaksClicked), keyEquivalent: "")
            pauseItem.target = self
            pauseItem.isEnabled = !breakManager.isSyncedSession && breakManager.status == .working
            pauseItem.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
            menu.addItem(pauseItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // Collaborative Studying
        if breakManager.isSyncedSession {
            let copyCodeItem = NSMenuItem(title: "Copy Invite Code", action: #selector(copySessionCodeClicked), keyEquivalent: "")
            copyCodeItem.target = self
            copyCodeItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            menu.addItem(copyCodeItem)
            
            let leaveSessionItem = NSMenuItem(title: "Leave Session", action: #selector(leaveSessionClicked), keyEquivalent: "")
            leaveSessionItem.target = self
            leaveSessionItem.image = NSImage(systemSymbolName: "person.fill.xmark", accessibilityDescription: nil)
            menu.addItem(leaveSessionItem)
        } else {
            let hostSessionItem = NSMenuItem(title: "Host Session", action: #selector(hostSessionClicked), keyEquivalent: "")
            hostSessionItem.target = self
            hostSessionItem.isEnabled = breakManager.status == .working
            hostSessionItem.image = NSImage(systemSymbolName: "person.2.badge.gearshape", accessibilityDescription: nil)
            hostSessionItem.toolTip = "Starts a session using your current Work Interval and Break Duration."
            menu.addItem(hostSessionItem)
            
            let joinSessionItem = NSMenuItem(title: "Join Session...", action: #selector(joinSessionClicked), keyEquivalent: "")
            joinSessionItem.target = self
            joinSessionItem.image = NSImage(systemSymbolName: "link.badge.plus", accessibilityDescription: nil)
            menu.addItem(joinSessionItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // Work Interval configuration
        let workIntervalSubmenu = NSMenu()
        let workIntervalItem = NSMenuItem(title: "Work Interval", action: nil, keyEquivalent: "")
        workIntervalItem.submenu = workIntervalSubmenu
        workIntervalItem.isEnabled = !breakManager.isSyncedSession
        workIntervalItem.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        menu.addItem(workIntervalItem)
        
        let currentInterval = breakManager.workInterval
        addIntervalItem(to: workIntervalSubmenu, title: "15 seconds (Test Mode)", value: 15, current: currentInterval)
        addIntervalItem(to: workIntervalSubmenu, title: "10 minutes", value: 600, current: currentInterval)
        addIntervalItem(to: workIntervalSubmenu, title: "20 minutes (Standard)", value: 1200, current: currentInterval)
        addIntervalItem(to: workIntervalSubmenu, title: "30 minutes", value: 1800, current: currentInterval)
        
        // Break Duration configuration
        let breakDurationSubmenu = NSMenu()
        let breakDurationItem = NSMenuItem(title: "Break Duration", action: nil, keyEquivalent: "")
        breakDurationItem.submenu = breakDurationSubmenu
        breakDurationItem.isEnabled = !breakManager.isSyncedSession
        breakDurationItem.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil)
        menu.addItem(breakDurationItem)
        
        let currentDuration = breakManager.breakDuration
        addDurationItem(to: breakDurationSubmenu, title: "5 seconds (Test Mode)", value: 5, current: currentDuration)
        addDurationItem(to: breakDurationSubmenu, title: "15 seconds", value: 15, current: currentDuration)
        addDurationItem(to: breakDurationSubmenu, title: "20 seconds (Standard)", value: 20, current: currentDuration)
        addDurationItem(to: breakDurationSubmenu, title: "60 seconds", value: 60, current: currentDuration)
        
        menu.addItem(NSMenuItem.separator())
        
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        let settingsMenu = NSMenu()
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)
        
        let checkForUpdatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesSelected(_:)), keyEquivalent: "")
        checkForUpdatesItem.target = self
        checkForUpdatesItem.isEnabled = UpdateService.shared.canCheckForUpdates
        settingsMenu.addItem(checkForUpdatesItem)

        let autoUpdateItem = NSMenuItem(title: "Automatically Check for Updates", action: #selector(autoUpdateSelected(_:)), keyEquivalent: "")
        autoUpdateItem.target = self
        autoUpdateItem.state = UpdateService.shared.automaticallyChecksForUpdates ? .on : .off
        settingsMenu.addItem(autoUpdateItem)
        
        let runOnStartupItem = NSMenuItem(title: "Run on Startup", action: #selector(runOnStartupSelected(_:)), keyEquivalent: "")
        runOnStartupItem.target = self
        runOnStartupItem.state = AppSettings.shared.runOnStartup ? .on : .off
        settingsMenu.addItem(runOnStartupItem)

        let permissionManager = ScreenCapturePermissionManager.shared
        let hasDuplicateInstalls = permissionManager.knownInstallLocations.count > 1
        let permissionTitle: String
        if hasDuplicateInstalls {
            permissionTitle = "Screen Recording: Duplicate Apps Found…"
        } else if permissionManager.isAuthorized {
            permissionTitle = "Screen Recording: Allowed"
        } else {
            permissionTitle = "Screen Recording: Needs Attention…"
        }
        let screenRecordingItem = NSMenuItem(title: permissionTitle, action: #selector(screenRecordingPermissionSelected(_:)), keyEquivalent: "")
        screenRecordingItem.target = self
        screenRecordingItem.image = NSImage(
            systemSymbolName: permissionManager.isAuthorized && !hasDuplicateInstalls ? "checkmark.shield" : "exclamationmark.shield",
            accessibilityDescription: nil
        )
        settingsMenu.addItem(screenRecordingItem)
        
        settingsMenu.addItem(NSMenuItem.separator())
        
        // Quit action
        let quitItem = NSMenuItem(title: "Quit Pausely", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        settingsMenu.addItem(quitItem)
    }
    
    private func addIntervalItem(to menu: NSMenu, title: String, value: Double, current: Double) {
        let item = NSMenuItem(title: title, action: #selector(workIntervalSelected(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = value
        item.state = (value == current) ? .on : .off
        menu.addItem(item)
    }
    
    private func addDurationItem(to menu: NSMenu, title: String, value: Double, current: Double) {
        let item = NSMenuItem(title: title, action: #selector(breakDurationSelected(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = value
        item.state = (value == current) ? .on : .off
        menu.addItem(item)
    }
    
    @objc private func startBreakClicked() {
        if breakManager.isSyncedSession {
            breakManager.startIntermission()
        } else {
            breakManager.triggerBreak()
        }
    }
    
    @objc private func copySessionCodeClicked() {
        let code = breakManager.generateSessionCode()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
    }
    
    @objc private func hostSessionClicked() {
        let code = breakManager.generateSessionCode()
        
        DispatchQueue.main.async {
            if let existingWindow = self.sessionDialogWindow {
                existingWindow.close()
            }
            
            let view = HostSessionView(
                code: code,
                onDone: { [weak self] in
                    self?.sessionDialogWindow?.close()
                    self?.sessionDialogWindow = nil
                }
            )
            
            let hostingController = NSHostingController(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            
            self.sessionDialogWindow = window
            
            NSApp.activate(ignoringOtherApps: true)
            self.centerWindow(window)
            window.makeKeyAndOrderFront(nil)
        }
    }
    
    @objc private func joinSessionClicked() {
        // Run on main thread but delay slightly if menu is closing
        DispatchQueue.main.async {
            if let existingWindow = self.sessionDialogWindow {
                existingWindow.close()
            }
            
            let view = JoinSessionView(
                onJoin: { [weak self] code in
                    self?.breakManager.joinSession(code: code)
                    self?.sessionDialogWindow?.close()
                    self?.sessionDialogWindow = nil
                },
                onCancel: { [weak self] in
                    self?.sessionDialogWindow?.close()
                    self?.sessionDialogWindow = nil
                }
            )
            
            let hostingController = NSHostingController(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 250),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            
            self.sessionDialogWindow = window
            
            NSApp.activate(ignoringOtherApps: true)
            self.centerWindow(window)
            window.makeKeyAndOrderFront(nil)
        }
    }
    
    @objc private func leaveSessionClicked() {
        breakManager.leaveSession()
    }
    
    private func centerWindow(_ window: NSWindow) {
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let screenRect = screen.visibleFrame
            let windowRect = window.frame
            let newOrigin = NSPoint(
                x: screenRect.minX + (screenRect.width - windowRect.width) / 2,
                y: screenRect.minY + (screenRect.height - windowRect.height) / 2
            )
            window.setFrameOrigin(newOrigin)
        }
    }
    
    @objc private func workIntervalSelected(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double {
            breakManager.workInterval = value
            buildMenu()
        }
    }
    
    @objc private func breakDurationSelected(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Double {
            breakManager.breakDuration = value
            buildMenu()
        }
    }
    
    @objc private func autoUpdateSelected(_ sender: NSMenuItem) {
        let newValue = !UpdateService.shared.automaticallyChecksForUpdates
        UpdateService.shared.automaticallyChecksForUpdates = newValue
        sender.state = newValue ? .on : .off

        if newValue {
            UpdateService.shared.checkForUpdatesInBackground()
        }
    }

    @objc private func checkForUpdatesSelected(_ sender: NSMenuItem) {
        UpdateService.shared.checkForUpdates()
    }
    
    @objc private func runOnStartupSelected(_ sender: NSMenuItem) {
        let newValue = !AppSettings.shared.runOnStartup
        AppSettings.shared.runOnStartup = newValue
        sender.state = newValue ? .on : .off
        
        StartupService.shared.reconcile()
    }

    @objc private func screenRecordingPermissionSelected(_ sender: NSMenuItem) {
        DispatchQueue.main.async { [weak self] in
            ScreenCapturePermissionManager.shared.showPermissionHelp()
            self?.buildMenu()
        }
    }
    
    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }
    
    @objc private func pauseBreaksClicked() {
        breakManager.pauseBreaks()
        buildMenu()
    }
    
    @objc private func resumeBreaksClicked() {
        breakManager.resumeBreaks()
        buildMenu()
    }
    
    /// Formats a duration into a human-friendly string rounded to the nearest 15 minutes.
    /// Examples: 3600 → "1h", 5400 → "1h 30m", 1800 → "30m", 60 → "1m".
    private func formatFriendlyDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds.rounded()) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        
        if hours > 0 && minutes > 0 { return "\(hours)h \(minutes)m" }
        if hours > 0               { return "\(hours)h" }
        if minutes > 0             { return "\(minutes)m" }
        return "\(Int(seconds.rounded()))s"
    }
    
    private func timeFormatted(_ totalSeconds: Int) -> String {
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    // MARK: - NSMenuDelegate
    
    func menuWillOpen(_ menu: NSMenu) {
        buildMenu()
        updateStatusItemLabel()
    }
    
    func menuDidClose(_ menu: NSMenu) {
        // The custom view will be recreated on next open via buildMenu
        statusMenuItemView = nil
    }
}
