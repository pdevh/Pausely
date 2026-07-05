import Cocoa
import SwiftUI
import CoreGraphics

class FullScreenOverlayPanel: NSPanel {
    override var canBecomeKey: Bool {
        return true
    }
    
    override var canBecomeMain: Bool {
        return true
    }
}

class OverlayWindowController {
    static let shared = OverlayWindowController()
    
    private var windows: [NSWindow] = []
    private var escapeMonitor: Any?
    private var lastEscapePressTime: Date?
    private var presentationTask: Task<Void, Never>?
    
    func showOverlays(breakManager: BreakManager, isIntermission: Bool = false) {
        closeOverlays(cancelWallpaperRefresh: false)
        
        let screens = NSScreen.screens
        presentationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }

            _ = await RenderedWallpaperProvider.shared.refreshAndWait(for: screens)
            guard !Task.isCancelled else { return }

            self.presentOverlays(on: screens, breakManager: breakManager, isIntermission: isIntermission)
        }
    }

    @MainActor
    private func presentOverlays(on screens: [NSScreen], breakManager: BreakManager, isIntermission: Bool) {
        for screen in screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                continue
            }

            // Create custom fullscreen panel
            let panel = FullScreenOverlayPanel(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.level = .screenSaver // Appears on top of menu bar, dock, and full-screen windows
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.ignoresMouseEvents = false // Intercept mouse to enforce break
            
            let overlayView = BreakOverlayView(
                breakManager: breakManager,
                isIntermission: isIntermission,
                displayID: displayID
            )
            
            panel.contentView = NSHostingView(rootView: overlayView)
            
            // Render on this screen
            panel.setFrame(screen.frame, display: true)
            
            panel.makeKeyAndOrderFront(nil)
            windows.append(panel)
        }

        // Force activate app so windows can receive key focus
        NSApp.activate(ignoringOtherApps: true)

        // Setup local keyboard monitor for Escape key
        setupEscapeKeyMonitor(breakManager: breakManager)
        
        // Hide the cursor warning perfectly seamlessly as the break overlays present
        CursorWarningManager.shared.hide()
    }
    
    func closeOverlays(cancelWallpaperRefresh: Bool = true) {
        presentationTask?.cancel()
        presentationTask = nil

        // Remove keyboard monitor
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
        
        // Close windows
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        if cancelWallpaperRefresh {
            Task { @MainActor in
                RenderedWallpaperProvider.shared.cancelRefresh()
            }
        }
    }
    
    private func setupEscapeKeyMonitor(breakManager: BreakManager) {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Escape key code is 53
            if event.keyCode == 53 {
                let now = Date()
                if let lastPress = self?.lastEscapePressTime, now.timeIntervalSince(lastPress) < 0.5 {
                    // Double press Escape!
                    DispatchQueue.main.async {
                        if breakManager.isInIntermission {
                            breakManager.endIntermission(wasPremature: true)
                        } else {
                            breakManager.skipBreak()
                        }
                    }
                    self?.lastEscapePressTime = nil
                } else {
                    self?.lastEscapePressTime = now
                }
                return nil // Swallow escape keypress
            }
            return event
        }
    }

}
