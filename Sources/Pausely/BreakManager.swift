import Foundation
import PauselyCore
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
            if !isApplyingSync {
                AppSettings.shared.workInterval = workInterval
                isSyncedSession = false
            }
            if status == .working {
                timeRemaining = Int(workInterval)
            }
        }
    }
    @Published var breakDuration: TimeInterval = AppSettings.shared.breakDuration {
        didSet {
            if !isApplyingSync {
                AppSettings.shared.breakDuration = breakDuration
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
            intermissionTimeRemaining = TimerTiming.countdown(intermissionTimeRemaining)
            if intermissionTimeRemaining == 0 {
                endIntermission()
            }
        }

        guard !isEnding else { return }
        
        if isSyncedSession {
            let position = TimerTiming.position(work: workInterval, rest: breakDuration,
                                                anchor: anchorTimestamp, now: Date().timeIntervalSince1970)
            let currentCycleIndex = position.cycle
            var newStatus: BreakStatus = position.isBreak ? .inBreak : .working
            var newTimeRemaining = Double(position.remaining)
            if position.isBreak && skippedCycleIndices.contains(currentCycleIndex) {
                newStatus = .working
                newTimeRemaining += workInterval
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
                        newTimeRemaining = Double(position.remaining) + workInterval
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
            timeRemaining = TimerTiming.countdown(timeRemaining)
            if timeRemaining == 0 {
                if status == .paused { resumeBreaks() }
                else if status == .working { triggerBreak() }
                else { endBreak() }
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
    
    func generateSessionCode() -> String {
        if !isSyncedSession {
            previousWorkInterval = workInterval
            previousBreakDuration = breakDuration
            // Backdate the anchor so current timeRemaining is seamless
            if status == .working {
                let elapsed = workInterval - TimeInterval(timeRemaining)
                anchorTimestamp = Date().timeIntervalSince1970 - elapsed
            } else {
                let elapsed = (workInterval + breakDuration) - TimeInterval(timeRemaining)
                anchorTimestamp = Date().timeIntervalSince1970 - elapsed
            }
            anchorTimestamp = floor(anchorTimestamp)
            isSyncedSession = true
        }
        
        return SessionCode.encode(work: Int(workInterval), rest: Int(breakDuration), anchor: anchorTimestamp)
    }

    @discardableResult
    func joinSession(code: String) -> Bool {
        guard let schedule = SessionCode.decode(code, now: Date().timeIntervalSince1970) else { return false }

        if !isSyncedSession {
            previousWorkInterval = self.workInterval
            previousBreakDuration = self.breakDuration
        }
        
        isApplyingSync = true
        self.workInterval = Double(schedule.work)
        self.breakDuration = Double(schedule.rest)
        isApplyingSync = false
        
        self.anchorTimestamp = schedule.anchor
        self.isSyncedSession = true
        self.skippedCycleIndices.removeAll()
        self.snoozeEndTime = nil
        self.snoozesLeft = 4
        
        // If they were in break locally but the code puts them in work, ensure overlays close
        if self.status == .inBreak {
            self.overlayController.closeOverlays()
        }
        status = .working
        if !isScreenLocked { tick() }
        return true
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
