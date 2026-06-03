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
    
    func showOverlays(breakManager: BreakManager, isIntermission: Bool = false) {
        closeOverlays()
        
        let screens = NSScreen.screens
        for screen in screens {
            let images = getWallpaperImages(screen: screen)
            
            // Create custom fullscreen panel
            let panel = FullScreenOverlayPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
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
                crispWallpaper: images?.crisp,
                blurredWallpaper: images?.blurred,
                breakManager: breakManager,
                isIntermission: isIntermission
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
    }
    
    func closeOverlays() {
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
                            breakManager.endIntermission()
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
    
    private func getWallpaperImages(screen: NSScreen) -> (crisp: NSImage, blurred: NSImage)? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let crispImage = DynamicWallpaperResolver.resolveCurrentImage(for: url) else {
            return nil
        }
        
        // For the thumbnail, use the crisp image's CGImage representation directly
        // to avoid re-resolving the dynamic wallpaper index.
        guard let cgRepr = crispImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return (crisp: crispImage, blurred: crispImage)
        }
        
        // Create a tiny thumbnail from the resolved image for the blur layer
        let maxDimension = max(cgRepr.width, cgRepr.height)
        let scale = min(1.0, 300.0 / Double(maxDimension))
        let thumbWidth = Int(Double(cgRepr.width) * scale)
        let thumbHeight = Int(Double(cgRepr.height) * scale)
        
        guard let colorSpace = cgRepr.colorSpace,
              let context = CGContext(data: nil,
                                      width: thumbWidth,
                                      height: thumbHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return (crisp: crispImage, blurred: crispImage)
        }
        
        context.interpolationQuality = .low
        context.draw(cgRepr, in: CGRect(x: 0, y: 0, width: thumbWidth, height: thumbHeight))
        
        guard let cgThumbnail = context.makeImage() else {
            return (crisp: crispImage, blurred: crispImage)
        }
        
        let blurredImage = NSImage(cgImage: cgThumbnail, size: NSSize(width: cgThumbnail.width, height: cgThumbnail.height))
        
        return (crisp: crispImage, blurred: blurredImage)
    }
}
