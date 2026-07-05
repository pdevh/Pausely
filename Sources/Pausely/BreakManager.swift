import Foundation
import Combine
import SwiftUI

enum BreakStatus {
    case working
    case inBreak
    case paused
}

class BreakManager: ObservableObject {
    static let shared = BreakManager()
    
    @Published var status: BreakStatus = .working
    @Published var timeRemaining: Int = 1200 // Default to 20 minutes (1200 seconds)
    @Published var snoozesLeft: Int = 4
    
    @Published var isSyncedSession: Bool = false
    @Published var isInIntermission: Bool = false
    @Published var intermissionTimeRemaining: Int = 0
    private var anchorTimestamp: TimeInterval = 0
    private var skippedCycleIndices: Set<Int> = []
    private var isApplyingSync = false
    private var snoozeEndTime: Date? = nil
    @Published var currentBreakPrompt: BreakPrompt?
    @Published var currentIntermissionPrompt: MicrobreakPrompt?
    
    private var lastBreakDisplayedTime: Date = Date()
    private var preBreakActiveApp: NSRunningApplication?
    
    private var previousWorkInterval: TimeInterval = 1200
    private var previousBreakDuration: TimeInterval = 20
    
    var anchorTimeString: String {
        guard isSyncedSession else { return "" }
        let date = Date(timeIntervalSince1970: anchorTimestamp)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    // Configurations
    @Published var workInterval: TimeInterval = AppSettings.shared.workInterval {
        didSet {
            AppSettings.shared.workInterval = workInterval
            if !isApplyingSync {
                isSyncedSession = false
            }
            if status == .working {
                timeRemaining = Int(workInterval)
            }
        }
    }
    @Published var breakDuration: TimeInterval = AppSettings.shared.breakDuration {
        didSet {
            AppSettings.shared.breakDuration = breakDuration
            if !isApplyingSync {
                isSyncedSession = false
            }
            if status == .inBreak {
                timeRemaining = Int(breakDuration)
            }
        }
    }
    
    private var gcdTimer: DispatchSourceTimer?
    private let overlayController = OverlayWindowController.shared
    private var isEnding = false // Guards against repeated endBreak/snooze calls during reverse animation
    private var isScreenLocked = false
    
    /// Direct callback fired at the end of every tick, after all @Published
    /// properties have been set.  Runs on the main queue via GCD — immune to
    /// RunLoop-mode changes (e.g. NSMenu event-tracking).
    var onTick: (() -> Void)?
    
    init() {
        timeRemaining = Int(workInterval)
        startTimer()
        registerScreenLockObservers()
    }
    
    private func registerScreenLockObservers() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self,
                        selector: #selector(screenDidLock),
                        name: NSNotification.Name("com.apple.screenIsLocked"),
                        object: nil)
        dnc.addObserver(self,
                        selector: #selector(screenDidUnlock),
                        name: NSNotification.Name("com.apple.screenIsUnlocked"),
                        object: nil)
    }
    
    @objc private func screenDidLock() {
        isScreenLocked = true
        gcdTimer?.suspend()
        CursorWarningManager.shared.hide()
        // Dismiss any active overlay immediately
        if status == .inBreak {
            isEnding = false // allow closeOverlays to work
            overlayController.closeOverlays()
            // Restore working state so the cycle resumes correctly on unlock
            status = .working
            if !isSyncedSession {
                timeRemaining = Int(workInterval)
            }
            snoozesLeft = 4
        }
        // If paused when screen locks, reset to normal working state —
        // locking the screen is essentially a break already.
        if status == .paused {
            status = .working
            timeRemaining = Int(workInterval)
        }
        if isInIntermission {
            isInIntermission = false
            intermissionTimeRemaining = 0
            overlayController.closeOverlays()
        }
    }
    
    @objc private func screenDidUnlock() {
        guard isScreenLocked else { return }
        isScreenLocked = false
        gcdTimer?.resume()
    }
    
    func startTimer() {
        gcdTimer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 1.0, repeating: 1.0)
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        source.resume()
        gcdTimer = source
    }
    
    private func tick() {
        // Handle intermission countdown independently
        if isInIntermission {
            if intermissionTimeRemaining > 0 {
                intermissionTimeRemaining -= 1
            } else {
                endIntermission()
            }
        }

        guard !isEnding else { return }
        
        if isSyncedSession {
            let cycleDuration = workInterval + breakDuration
            let elapsed = max(0, Date().timeIntervalSince1970 - anchorTimestamp)
            let currentCycleIndex = Int(elapsed / cycleDuration)
            let cyclePosition = elapsed.truncatingRemainder(dividingBy: cycleDuration)
            
            var newStatus: BreakStatus = .working
            var newTimeRemaining: Double = 0
            
            if cyclePosition < workInterval {
                newStatus = .working
                newTimeRemaining = workInterval - cyclePosition
            } else {
                if skippedCycleIndices.contains(currentCycleIndex) {
                    newStatus = .working
                    newTimeRemaining = (cycleDuration - cyclePosition) + workInterval
                } else {
                    newStatus = .inBreak
                    newTimeRemaining = cycleDuration - cyclePosition
                }
            }
            
            // Apply Snooze Override
            if let snoozeEnd = snoozeEndTime {
                if Date() < snoozeEnd {
                    newStatus = .working
                    newTimeRemaining = snoozeEnd.timeIntervalSince(Date())
                } else {
                    snoozeEndTime = nil
                    // Will naturally fall back to math on next tick
                    if newStatus == .inBreak {
                        skippedCycleIndices.insert(currentCycleIndex)
                        newStatus = .working
                        newTimeRemaining = (cycleDuration - cyclePosition) + workInterval
                    }
                }
            }
            
            let oldStatus = self.status
            self.status = newStatus
            self.timeRemaining = Int(ceil(newTimeRemaining))
            
            if oldStatus == .working && newStatus == .inBreak {
                triggerBreak()
            } else if oldStatus == .inBreak && newStatus == .working {
                // If it transitioned naturally to work, we must close overlays
                // We use endBreak to perform the animation gracefully
                endBreak()
            }
            
        } else {
            if status == .paused {
                // Count down the pause; resume automatically when it hits zero
                if timeRemaining > 0 {
                    timeRemaining -= 1
                } else {
                    resumeBreaks()
                }
            } else {
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
        }
        
        // Pre-fetch wallpaper ~30s before break for instant overlay presentation.
        // This replaces the old 24/7 periodic capture with a targeted on-demand fetch.
        if status == .working && timeRemaining == 30 && !isScreenLocked {
            Task { @MainActor in
                RenderedWallpaperProvider.shared.refresh(for: NSScreen.screens)
            }
        }
        
        // Handle cursor warning logic centrally at the end of tick
        if status == .working && timeRemaining <= 10 && timeRemaining > 0 && !isEnding && !isScreenLocked {
            if CursorWarningManager.shared.viewModel.isVisible == false {
                CursorWarningManager.shared.show(timeRemaining: timeRemaining)
            } else {
                CursorWarningManager.shared.update(timeRemaining: timeRemaining)
            }
        } else if status == .working && timeRemaining > 10 {
            if CursorWarningManager.shared.viewModel.isVisible {
                CursorWarningManager.shared.hide()
            }
        }
        
        onTick?()
    }
    
    func triggerBreak() {
        guard !isEnding else { return }
        
        status = .inBreak
        lastBreakDisplayedTime = Date()
        
        if breakDuration >= 60 {
            currentBreakPrompt = BreakPrompts.randomBreak()
        } else {
            let micro = BreakPrompts.randomMicrobreak()
            currentBreakPrompt = BreakPrompt(title: "Take a breather", message: micro.message)
        }
        
        if !isSyncedSession {
            timeRemaining = Int(breakDuration)
        }
        
        // Hide other apps so the moving wallpaper is visible
        preBreakActiveApp = NSWorkspace.shared.frontmostApplication
        AppVisibilityManager.shared.hideOtherApps()
        
        // Show fullscreen overlay panels across all displays
        overlayController.showOverlays(breakManager: self)
        
        // Play gentle chime
        SoundManager.playStartSound()
    }
    
    func endBreak(wasPremature: Bool = false) {
        guard !isEnding else { return }
        isEnding = true
        
        // Post notification so the overlay can play reverse animations
        NotificationCenter.default.post(name: .breakWillEnd, object: nil)
        
        // Wait for the longest reverse animation (background = 0.50s) + small buffer
        let reverseAnimationDuration = 0.55
        DispatchQueue.main.asyncAfter(deadline: .now() + reverseAnimationDuration) { [weak self] in
            guard let self = self else { return }
            self.isEnding = false
            self.status = .working
            
            if !self.isSyncedSession {
                self.timeRemaining = Int(self.workInterval)
            }
            self.snoozesLeft = 4 // Reset snoozes at full break completion
            
            // Close overlays and warnings
            CursorWarningManager.shared.hide()
            self.overlayController.closeOverlays()
            
            // Restore hidden apps
            AppVisibilityManager.shared.restoreApps()
            
            // Restore previously active app
            self.preBreakActiveApp?.activate(options: .activateIgnoringOtherApps)
            self.preBreakActiveApp = nil
            
            // Play clean finish sound
            if !wasPremature {
                SoundManager.playEndSound()
            }
        }
    }
    
    func snoozeBreak() {
        guard snoozesLeft > 0, !isEnding else { return }
        snoozesLeft -= 1
        isEnding = true
        
        // Post notification so the overlay can play reverse animations
        NotificationCenter.default.post(name: .breakWillEnd, object: nil)
        
        let reverseAnimationDuration = 0.55
        DispatchQueue.main.asyncAfter(deadline: .now() + reverseAnimationDuration) { [weak self] in
            guard let self = self else { return }
            self.isEnding = false
            self.status = .working
            
            let snoozeDuration: TimeInterval = self.workInterval <= 15 ? 10 : 300
            
            if self.isSyncedSession {
                self.snoozeEndTime = Date().addingTimeInterval(snoozeDuration)
            } else {
                self.timeRemaining = Int(snoozeDuration)
            }
            
            // Close overlays and warnings
            CursorWarningManager.shared.hide()
            self.overlayController.closeOverlays()
            
            // Restore hidden apps
            AppVisibilityManager.shared.restoreApps()
            
            // Restore previously active app
            self.preBreakActiveApp?.activate(options: .activateIgnoringOtherApps)
            self.preBreakActiveApp = nil
            
            // No sound when snoozing — silence is intentional
        }
    }
    
    // MARK: - Pause Breaks

    /// The suggested pause duration: 2 full work+break cycles, rounded to
    /// the nearest 15 minutes. For very short test intervals the raw value
    /// is used instead so the rounding doesn't collapse it to zero.
    var suggestedPauseDuration: TimeInterval {
        let raw = 2 * (workInterval + breakDuration)
        let fifteenMinutes: TimeInterval = 900
        let rounded = (raw / fifteenMinutes).rounded() * fifteenMinutes
        return rounded > 0 ? rounded : raw
    }

    func pauseBreaks() {
        guard !isSyncedSession, status == .working else { return }
        CursorWarningManager.shared.hide()
        status = .paused
        timeRemaining = Int(suggestedPauseDuration)
    }

    func resumeBreaks() {
        guard status == .paused else { return }
        status = .working
        timeRemaining = Int(workInterval)
    }

    func skipBreak() {
        if isSyncedSession {
            let cycleDuration = workInterval + breakDuration
            let elapsed = max(0, Date().timeIntervalSince1970 - anchorTimestamp)
            let currentCycleIndex = Int(elapsed / cycleDuration)
            skippedCycleIndices.insert(currentCycleIndex)
        }
        endBreak(wasPremature: true)
    }

    func startIntermission() {
        guard !isInIntermission else { return }
        isInIntermission = true
        intermissionTimeRemaining = Int(breakDuration)
        currentIntermissionPrompt = BreakPrompts.randomMicrobreak()
        
        // Hide other apps so the moving wallpaper is visible
        preBreakActiveApp = NSWorkspace.shared.frontmostApplication
        AppVisibilityManager.shared.hideOtherApps()
        
        // Show fullscreen overlay panels across all displays
        overlayController.showOverlays(breakManager: self, isIntermission: true)
        
        SoundManager.playStartSound()
    }
    
    func endIntermission(wasPremature: Bool = false) {
        isInIntermission = false
        intermissionTimeRemaining = 0
        
        // Post notification so the overlay can play reverse animations
        NotificationCenter.default.post(name: .breakWillEnd, object: nil)
        
        let reverseAnimationDuration = 0.55
        DispatchQueue.main.asyncAfter(deadline: .now() + reverseAnimationDuration) { [weak self] in
            self?.overlayController.closeOverlays()
            AppVisibilityManager.shared.restoreApps()
            self?.preBreakActiveApp?.activate(options: .activateIgnoringOtherApps)
            self?.preBreakActiveApp = nil
            if !wasPremature {
                SoundManager.playEndSound()
            }
        }
    }
    
    private let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    
    private func encodeBase32(_ value: Int) -> String {
        var result = ""
        var temp = value
        for _ in 0..<6 {
            let index = temp & 0x1F
            result.insert(base32Alphabet[index], at: result.startIndex)
            temp >>= 5
        }
        return result
    }

    private func decodeBase32(_ string: String) -> Int? {
        guard string.count == 6 else { return nil }
        var result = 0
        let upperString = string.uppercased()
        for char in upperString {
            guard let index = base32Alphabet.firstIndex(of: char) else { return nil }
            result = (result << 5) | index
        }
        return result
    }

    func generateSessionCode() -> String {
        if !isSyncedSession {
            // Backdate the anchor so current timeRemaining is seamless
            if status == .working {
                let elapsed = workInterval - TimeInterval(timeRemaining)
                anchorTimestamp = Date().timeIntervalSince1970 - elapsed
            } else {
                let elapsed = (workInterval + breakDuration) - TimeInterval(timeRemaining)
                anchorTimestamp = Date().timeIntervalSince1970 - elapsed
            }
            isSyncedSession = true
        }
        
        let workIntervals: [TimeInterval] = [15, 600, 1200, 1800]
        let breakDurations: [TimeInterval] = [5, 15, 20, 60]
        
        let wIndex = workIntervals.firstIndex(of: workInterval) ?? 2 // Default to 1200
        let bIndex = breakDurations.firstIndex(of: breakDuration) ?? 2 // Default to 20
        
        let timestampModulo = Int(anchorTimestamp) % 4_194_304 // 22 bits
        let combined: Int = (wIndex << 26) | (bIndex << 22) | timestampModulo
        
        return encodeBase32(combined)
    }
    
    func joinSession(code: String) {
        let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let workIntervals: [TimeInterval] = [15, 600, 1200, 1800]
        let breakDurations: [TimeInterval] = [5, 15, 20, 60]
        
        var w: TimeInterval = 1200
        var b: TimeInterval = 20
        var a: TimeInterval = 0
        
        if cleanCode.count == 6, let combined = decodeBase32(cleanCode) {
            let modulo = combined & 0x3FFFFF
            let wIndex = (combined >> 26) & 0x0F
            let bIndex = (combined >> 22) & 0x0F
            
            w = (wIndex >= 0 && wIndex < workIntervals.count) ? workIntervals[wIndex] : 1200
            b = (bIndex >= 0 && bIndex < breakDurations.count) ? breakDurations[bIndex] : 20
            
            let current = Int(Date().timeIntervalSince1970)
            let window = 4_194_304
            let currentModulo = current % window
            var diff = modulo - currentModulo
            
            if diff > window / 2 {
                diff -= window
            } else if diff < -window / 2 {
                diff += window
            }
            
            a = TimeInterval(current + diff)
        } else if let data = Data(base64Encoded: cleanCode), let payload = String(data: data, encoding: .utf8) {
            // Legacy Base64
            let parts = payload.split(separator: ":")
            guard parts.count == 3,
                  let wLegacy = TimeInterval(parts[0]),
                  let bLegacy = TimeInterval(parts[1]),
                  let aLegacy = TimeInterval(parts[2]) else { return }
            
            w = wLegacy
            b = bLegacy
            a = aLegacy
        } else {
            return // Invalid code
        }
        
        if !isSyncedSession {
            previousWorkInterval = self.workInterval
            previousBreakDuration = self.breakDuration
        }
        
        isApplyingSync = true
        self.workInterval = w
        self.breakDuration = b
        isApplyingSync = false
        
        self.anchorTimestamp = a
        self.isSyncedSession = true
        self.skippedCycleIndices.removeAll()
        self.snoozeEndTime = nil
        self.snoozesLeft = 4
        
        // If they were in break locally but the code puts them in work, ensure overlays close
        if self.status == .inBreak {
            self.overlayController.closeOverlays()
        }
    }
    
    func leaveSession() {
        guard isSyncedSession else { return }
        isSyncedSession = false
        
        isApplyingSync = true
        self.workInterval = previousWorkInterval
        self.breakDuration = previousBreakDuration
        isApplyingSync = false
        
        // Re-anchor based on the last break that was displayed to the user
        let elapsed = Date().timeIntervalSince(lastBreakDisplayedTime)
        if elapsed >= previousWorkInterval {
            // Overdue for a break — trigger immediately
            timeRemaining = 0
        } else {
            timeRemaining = Int(previousWorkInterval - elapsed)
        }
        status = .working
        
        // Clean up sync state
        skippedCycleIndices.removeAll()
        snoozeEndTime = nil
        snoozesLeft = 4
    }
}
