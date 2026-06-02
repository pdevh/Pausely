import Foundation
import Combine
import SwiftUI

enum BreakStatus {
    case working
    case inBreak
}

class BreakManager: ObservableObject {
    static let shared = BreakManager()
    
    @Published var status: BreakStatus = .working
    @Published var timeRemaining: Int = 1200 // Default to 20 minutes (1200 seconds)
    @Published var snoozesLeft: Int = 4
    
    // Configurations
    @Published var workInterval: TimeInterval = 1200 { // 20 minutes
        didSet {
            if status == .working {
                timeRemaining = Int(workInterval)
            }
        }
    }
    @Published var breakDuration: TimeInterval = 20 { // 20 seconds
        didSet {
            if status == .inBreak {
                timeRemaining = Int(breakDuration)
            }
        }
    }
    
    private var timer: AnyCancellable?
    private let overlayController = OverlayWindowController.shared
    private var isEnding = false // Guards against repeated endBreak/snooze calls during reverse animation
    
    init() {
        timeRemaining = Int(workInterval)
        startTimer()
    }
    
    func startTimer() {
        timer?.cancel()
        timer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }
    
    private func tick() {
        guard !isEnding else { return }
        if timeRemaining > 0 {
            timeRemaining -= 1
        } else {
            if status == .working {
                triggerBreak()
            } else {
                endBreak()
            }
        }
    }
    
    func triggerBreak() {
        status = .inBreak
        timeRemaining = Int(breakDuration)
        
        // Show fullscreen overlay panels across all displays
        overlayController.showOverlays(breakManager: self)
        
        // Play gentle chime
        SoundManager.playStartSound()
    }
    
    func endBreak() {
        guard !isEnding else { return }
        isEnding = true
        
        // Post notification so the overlay can play reverse animations
        NotificationCenter.default.post(name: .breakWillEnd, object: nil)
        
        // Wait for the longest reverse animation (background = 1.06s) + small buffer
        let reverseAnimationDuration = 1.15
        DispatchQueue.main.asyncAfter(deadline: .now() + reverseAnimationDuration) { [weak self] in
            guard let self = self else { return }
            self.isEnding = false
            self.status = .working
            self.timeRemaining = Int(self.workInterval)
            self.snoozesLeft = 4 // Reset snoozes at full break completion
            
            // Close overlays
            self.overlayController.closeOverlays()
            
            // Play clean finish sound
            SoundManager.playEndSound()
        }
    }
    
    func snoozeBreak() {
        guard snoozesLeft > 0, !isEnding else { return }
        snoozesLeft -= 1
        isEnding = true
        
        // Post notification so the overlay can play reverse animations
        NotificationCenter.default.post(name: .breakWillEnd, object: nil)
        
        let reverseAnimationDuration = 1.15
        DispatchQueue.main.asyncAfter(deadline: .now() + reverseAnimationDuration) { [weak self] in
            guard let self = self else { return }
            self.isEnding = false
            self.status = .working
            
            // Snooze duration is 5 minutes (300 seconds). 
            // If testing on very short workInterval (e.g. 15s), snooze is 10s.
            if self.workInterval <= 15 {
                self.timeRemaining = 10
            } else {
                self.timeRemaining = 300
            }
            
            // Close overlays
            self.overlayController.closeOverlays()
            
            // Play finish sound
            SoundManager.playEndSound()
        }
    }
    
    func skipBreak() {
        endBreak()
    }
}
