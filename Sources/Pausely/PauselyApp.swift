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
            // Start the process without blocking
            DispatchQueue.main.async {
                UpdateService.shared.downloadAndApplyUpdate(updateInfo) { success in
                    if !success {
                        let errorAlert = NSAlert()
                        errorAlert.messageText = "Update Failed"
                        errorAlert.informativeText = "Failed to download or apply the update. Please try again later."
                        errorAlert.addButton(withTitle: "OK")
                        errorAlert.runModal()
                    }
                }
            }
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
        let progress = 1.0 - (Double(breakManager.timeRemaining) / breakManager.workInterval)
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
        
        menu.addItem(NSMenuItem.separator())
        
        // Collaborative Studying
        let copyCodeItem = NSMenuItem(title: "Copy Session Code", action: #selector(copySessionCodeClicked), keyEquivalent: "")
        copyCodeItem.target = self
        copyCodeItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        menu.addItem(copyCodeItem)
        
        let joinSessionItem = NSMenuItem(title: "Join Session...", action: #selector(joinSessionClicked), keyEquivalent: "")
        joinSessionItem.target = self
        joinSessionItem.image = NSImage(systemSymbolName: "link.badge.plus", accessibilityDescription: nil)
        menu.addItem(joinSessionItem)
        
        if breakManager.isSyncedSession {
            let leaveSessionItem = NSMenuItem(title: "Leave Session", action: #selector(leaveSessionClicked), keyEquivalent: "")
            leaveSessionItem.target = self
            leaveSessionItem.image = NSImage(systemSymbolName: "person.fill.xmark", accessibilityDescription: nil)
            menu.addItem(leaveSessionItem)
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
        
        let autoUpdateItem = NSMenuItem(title: "Auto-Update", action: #selector(autoUpdateSelected(_:)), keyEquivalent: "")
        autoUpdateItem.target = self
        autoUpdateItem.state = AppSettings.shared.autoUpdateEnabled ? .on : .off
        settingsMenu.addItem(autoUpdateItem)
        
        let runOnStartupItem = NSMenuItem(title: "Run on Startup", action: #selector(runOnStartupSelected(_:)), keyEquivalent: "")
        runOnStartupItem.target = self
        runOnStartupItem.state = AppSettings.shared.runOnStartup ? .on : .off
        settingsMenu.addItem(runOnStartupItem)
        
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
        updateStatusItemLabel()
    }
    
    func menuDidClose(_ menu: NSMenu) {
        // The custom view will be recreated on next open via buildMenu
        statusMenuItemView = nil
    }
}
