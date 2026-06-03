import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuManager.shared.setupMenuBar()
        
        // Startup reconciliation
        StartupService.shared.reconcile()
        
        // Auto-update
        NotificationCenter.default.addObserver(self, selector: #selector(updateAvailable(_:)), name: UpdateService.updateAvailableNotification, object: nil)
        
        if AppSettings.shared.autoUpdateEnabled {
            UpdateService.shared.checkForUpdate()
        }
    }
    
    @objc func updateAvailable(_ notification: Notification) {
        guard let updateInfo = notification.object as? UpdateInfo else { return }
        
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Pausely v\(updateInfo.version) is available. Update now?"
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        
        // Bring app to front
        NSApp.activate(ignoringOtherApps: true)
        
        if alert.runModal() == .alertFirstButtonReturn {
            // Show a simple progress window while downloading
            let progressAlert = NSAlert()
            progressAlert.messageText = "Downloading Update..."
            progressAlert.informativeText = "Please wait while the update is downloading and installing. The app will restart automatically."
            
            // Start the process without blocking
            DispatchQueue.main.async {
                UpdateService.shared.downloadAndApplyUpdate(updateInfo) { success in
                    if !success {
                        // The progress alert should be closed by now, but we show a new error alert
                        let errorAlert = NSAlert()
                        errorAlert.messageText = "Update Failed"
                        errorAlert.informativeText = "Failed to download or apply the update. Please try again later."
                        errorAlert.addButton(withTitle: "OK")
                        errorAlert.runModal()
                    }
                }
            }
            
            // Show non-blocking progress by returning immediately after rendering
            progressAlert.runModal()
        }
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
    
    var text: String {
        get { label.stringValue }
        set {
            guard label.stringValue != newValue else { return }
            label.stringValue = newValue
            label.needsDisplay = true
        }
    }
    
    init(text: String) {
        super.init(frame: .zero)
        label.stringValue = text
        label.font = NSFont.menuFont(ofSize: 0) // system menu font & size
        label.textColor = .secondaryLabelColor
        label.isEditable = false
        label.isBordered = false
        label.backgroundColor = .clear
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
    }
    
    required init?(coder: NSCoder) { fatalError() }
}

class MenuManager: NSObject, NSMenuDelegate {
    static let shared = MenuManager()
    
    private var statusItem: NSStatusItem?
    private let breakManager = BreakManager.shared
    private var statusMenuItemView: StatusMenuItemView?
    
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
        
        let imageName = breakManager.status == .inBreak ? "eye.slash.fill" : "eye.fill"
        button.image = NSImage(systemSymbolName: imageName, accessibilityDescription: "Pausely")
        button.imagePosition = .imageLeading
        
        let titleText: String
        if breakManager.status == .working {
            titleText = timeFormatted(breakManager.timeRemaining)
        } else {
            titleText = "Break!"
        }
        button.title = titleText
        
        // Update the custom view label in the dropdown — this avoids
        // NSMenu layout invalidation that would reset hover highlights
        let statusText = breakManager.status == .inBreak
            ? "Break in progress"
            : "Next break in \(timeFormatted(breakManager.timeRemaining))"
        statusMenuItemView?.text = statusText
    }
    
    func buildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()
        
        // Title Header
        let headerTitle = breakManager.isSyncedSession ? "Pausely (Synced)" : "Pausely"
        let headerItem = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        
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
        
        menu.addItem(NSMenuItem.separator())
        
        // Action: Start Break Now
        let startBreakItem = NSMenuItem(title: "Start Break Now", action: #selector(startBreakClicked), keyEquivalent: "")
        startBreakItem.target = self
        menu.addItem(startBreakItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Collaborative Studying
        let copyCodeItem = NSMenuItem(title: "Copy Session Code", action: #selector(copySessionCodeClicked), keyEquivalent: "")
        copyCodeItem.target = self
        menu.addItem(copyCodeItem)
        
        let joinSessionItem = NSMenuItem(title: "Join Session...", action: #selector(joinSessionClicked), keyEquivalent: "")
        joinSessionItem.target = self
        menu.addItem(joinSessionItem)
        
        if breakManager.isSyncedSession {
            let leaveSessionItem = NSMenuItem(title: "Leave Session", action: #selector(leaveSessionClicked), keyEquivalent: "")
            leaveSessionItem.target = self
            menu.addItem(leaveSessionItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // Work Interval configuration
        let workIntervalSubmenu = NSMenu()
        let workIntervalItem = NSMenuItem(title: "Work Interval", action: nil, keyEquivalent: "")
        workIntervalItem.submenu = workIntervalSubmenu
        workIntervalItem.isEnabled = !breakManager.isSyncedSession
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
        menu.addItem(breakDurationItem)
        
        let currentDuration = breakManager.breakDuration
        addDurationItem(to: breakDurationSubmenu, title: "5 seconds (Test Mode)", value: 5, current: currentDuration)
        addDurationItem(to: breakDurationSubmenu, title: "15 seconds", value: 15, current: currentDuration)
        addDurationItem(to: breakDurationSubmenu, title: "20 seconds (Standard)", value: 20, current: currentDuration)
        addDurationItem(to: breakDurationSubmenu, title: "60 seconds", value: 60, current: currentDuration)
        
        menu.addItem(NSMenuItem.separator())
        
        let autoUpdateItem = NSMenuItem(title: "Auto-Update", action: #selector(autoUpdateSelected(_:)), keyEquivalent: "")
        autoUpdateItem.target = self
        autoUpdateItem.state = AppSettings.shared.autoUpdateEnabled ? .on : .off
        menu.addItem(autoUpdateItem)
        
        let runOnStartupItem = NSMenuItem(title: "Run on Startup", action: #selector(runOnStartupSelected(_:)), keyEquivalent: "")
        runOnStartupItem.target = self
        runOnStartupItem.state = AppSettings.shared.runOnStartup ? .on : .off
        menu.addItem(runOnStartupItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit action
        let quitItem = NSMenuItem(title: "Quit Pausely", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
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
    
    @objc private func joinSessionClicked() {
        // Run on main thread but delay slightly if menu is closing
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Join Collaborative Session"
            alert.informativeText = "Paste the session code below:"
            alert.addButton(withTitle: "Join")
            alert.addButton(withTitle: "Cancel")
            
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
            alert.accessoryView = input
            
            // Bring app to foreground to show alert properly
            NSApp.activate(ignoringOtherApps: true)
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let code = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !code.isEmpty {
                    self.breakManager.joinSession(code: code)
                }
            }
        }
    }
    
    @objc private func leaveSessionClicked() {
        breakManager.leaveSession()
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
        let newValue = !AppSettings.shared.autoUpdateEnabled
        AppSettings.shared.autoUpdateEnabled = newValue
        sender.state = newValue ? .on : .off
        
        if newValue {
            UpdateService.shared.checkForUpdate()
        }
    }
    
    @objc private func runOnStartupSelected(_ sender: NSMenuItem) {
        let newValue = !AppSettings.shared.runOnStartup
        AppSettings.shared.runOnStartup = newValue
        sender.state = newValue ? .on : .off
        
        StartupService.shared.reconcile()
    }
    
    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }
    
    private func timeFormatted(_ totalSeconds: Int) -> String {
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    // MARK: - NSMenuDelegate
    
    func menuWillOpen(_ menu: NSMenu) {
        buildMenu()
    }
    
    func menuDidClose(_ menu: NSMenu) {
        // The custom view will be recreated on next open via buildMenu
        statusMenuItemView = nil
    }
}
