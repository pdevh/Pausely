import Cocoa
import SwiftUI

class CursorWarningManager {
    static let shared = CursorWarningManager()
    
    private var window: NSWindow?
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    let viewModel = CursorWarningViewModel()
    
    init() {}
    
    func show(timeRemaining: Int) {
        viewModel.timeRemaining = timeRemaining
        
        if window == nil {
            let view = CursorWarningView(viewModel: viewModel)
            let hostingController = NSHostingController(rootView: view)
            
            // Give it enough width and height for padding and shadows
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 220, height: 80),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            newWindow.isOpaque = false
            newWindow.backgroundColor = .clear
            newWindow.level = .screenSaver // Appears on top of most things
            newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            newWindow.ignoresMouseEvents = true // Doesn't block clicks
            newWindow.contentViewController = hostingController
            
            self.window = newWindow
        }
        
        window?.orderFront(nil)
        startTrackingCursor()
        updateWindowPosition() // Initial position update
        
        // Delaying setting isVisible ensures the view transitions from hidden to visible, 
        // triggering the scale and opacity animation every time.
        DispatchQueue.main.async {
            self.viewModel.isVisible = true
        }
    }
    
    func update(timeRemaining: Int) {
        viewModel.timeRemaining = timeRemaining
    }
    
    func hide() {
        guard viewModel.isVisible else { return }
        viewModel.isVisible = false
        stopTrackingCursor()
        
        // Wait for the spring fade out animation to run before destroying window.
        // Destroying (not just hiding) kills the repeatForever SwiftUI animations
        // that would otherwise spin the CPU indefinitely.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.window?.orderOut(nil)
            self.window = nil
        }
    }
    
    private func startTrackingCursor() {
        stopTrackingCursor()
        // Event-driven: fires only on actual mouse movement (zero CPU when still)
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            self?.updateWindowPosition()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            self?.updateWindowPosition()
            return event
        }
    }
    
    private func stopTrackingCursor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
    }
    
    private func updateWindowPosition() {
        guard let window = window else { return }
        let mouseLoc = NSEvent.mouseLocation
        
        // Offset to bottom right of the cursor to look connected
        let offsetX: CGFloat = 0
        let offsetY: CGFloat = 0
        
        let newOrigin = NSPoint(
            x: mouseLoc.x + offsetX,
            y: mouseLoc.y - window.frame.height - offsetY
        )
        
        window.setFrameOrigin(newOrigin)
    }
}
