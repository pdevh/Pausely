import SwiftUI
import AppKit
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuManager.shared.setupMenuBar()
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

class MenuManager: NSObject, NSMenuDelegate {
    static let shared = MenuManager()
    
    private var statusItem: NSStatusItem?
    private let breakManager = BreakManager.shared
    private var statusMenuItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
        
        // Initial setup
        buildMenu()
        updateStatusItemLabel()
        
        // Subscribe to changes in BreakManager to update status and labels dynamically
        breakManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // Defer to the next run loop cycle so BreakManager's properties have updated
                DispatchQueue.main.async {
                    self?.updateStatusItemLabel()
                }
            }
            .store(in: &cancellables)
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
        
        // Update the status item in the menu dropdown in-place
        if let statusItem = statusMenuItem {
            let statusText = breakManager.status == .inBreak ? "Break in progress" : "Next break in \(timeFormatted(breakManager.timeRemaining))"
            if statusItem.title != statusText {
                statusItem.title = statusText
            }
        }
    }
    
    func buildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()
        
        // Title Header
        let headerItem = NSMenuItem(title: "Pausely MVP", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        
        // Status indicator (time remaining)
        let statusText = breakManager.status == .inBreak ? "Break in progress" : "Next break in \(timeFormatted(breakManager.timeRemaining))"
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        self.statusMenuItem = statusItem
        menu.addItem(statusItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Action: Start Break Now
        let startBreakItem = NSMenuItem(title: "Start Break Now", action: #selector(startBreakClicked), keyEquivalent: "")
        startBreakItem.target = self
        menu.addItem(startBreakItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Work Interval configuration
        let workIntervalSubmenu = NSMenu()
        let workIntervalItem = NSMenuItem(title: "Work Interval", action: nil, keyEquivalent: "")
        workIntervalItem.submenu = workIntervalSubmenu
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
        menu.addItem(breakDurationItem)
        
        let currentDuration = breakManager.breakDuration
        addDurationItem(to: breakDurationSubmenu, title: "5 seconds (Test Mode)", value: 5, current: currentDuration)
        addDurationItem(to: breakDurationSubmenu, title: "15 seconds", value: 15, current: currentDuration)
        addDurationItem(to: breakDurationSubmenu, title: "20 seconds (Standard)", value: 20, current: currentDuration)
        addDurationItem(to: breakDurationSubmenu, title: "60 seconds", value: 60, current: currentDuration)
        
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
        breakManager.triggerBreak()
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
}
