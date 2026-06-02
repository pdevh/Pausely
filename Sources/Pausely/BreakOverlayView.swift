import SwiftUI
import CoreGraphics
import AppKit
import Foundation

// Dynamically load the private macOS screen lock function at runtime to prevent compile-time link errors.
func lockScreen() {
    let path = "/System/Library/PrivateFrameworks/login.framework/Versions/A/login"
    if let handle = dlopen(path, RTLD_NOW) {
        defer { dlclose(handle) }
        if let sym = dlsym(handle, "SACLockScreenImmediate") {
            typealias LockFunc = @convention(c) () -> Void
            let SACLockScreenImmediate = unsafeBitCast(sym, to: LockFunc.self)
            SACLockScreenImmediate()
            return
        }
    }
    
    // Fallback: Trigger CGSession suspend which locks the screen
    let process = Process()
    process.launchPath = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
    process.arguments = ["-suspend"]
    try? process.run()
}

// MARK: - Animation Constants (from spec)

private enum AnimConst {
    static let frameDuration: Double = 0.02 // 50 fps

    // Blur radii
    static let backgroundStrongBlur: CGFloat = 24
    static let textStrongBlur: CGFloat = 12

    // Layout
    static let clockTopPadding: CGFloat = 24
    static let clockOffscreenPadding: CGFloat = 16

    // Phase durations in seconds (frames * frameDuration)
    static let phase0Duration: Double = 25 * frameDuration  // 0.50s background
    static let phase0To1Gap: Double = 2 * frameDuration     // 2-frame gap (frame 53→55)
    static let phase1Duration: Double = 35 * frameDuration  // 0.70s main text
    static let phase2Duration: Double = 25 * frameDuration  // 0.50s secondary text
    static let phase2To3Gap: Double = 5 * frameDuration     // 5-frame gap (frame 115→120)
    static let phase3Duration: Double = 20 * frameDuration  // 0.40s digital clock

    // Delays from onAppear (frame 0)
    static let phase0Delay: Double = 0
    static let phase1Delay: Double = 27 * frameDuration     // 0.54s
    static let phase2Delay: Double = 62 * frameDuration     // 1.24s
    static let phase3Delay: Double = 92 * frameDuration     // 1.84s
}

// MARK: - Glass Button Style

struct GlassButtonStyle: ButtonStyle {
    var isHovered: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(
                ZStack {
                    // Glassmorphic translucent background
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(isHovered ? 0.16 : 0.08))
                        
                    // Thin highlight border
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(isHovered ? 0.25 : 0.15), lineWidth: 1.5)
                }
            )
            .scaleEffect(configuration.isPressed ? 0.97 : (isHovered ? 1.03 : 1.0))
            .shadow(color: Color.black.opacity(isHovered ? 0.25 : 0.15), radius: 10, x: 0, y: 5)
            .animation(.spring(response: 0.35, dampingFraction: 0.65), value: isHovered)
    }
}

// MARK: - Isolated Timer Component
// Timer ticks only re-render this child, never the parent overlay.

struct TimerCountdownView: View {
    @ObservedObject var breakManager: BreakManager
    
    var body: some View {
        Text(timeFormatted(breakManager.timeRemaining))
            .font(.system(size: 84, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundColor(Color(red: 0.72, green: 0.88, blue: 1.0))
            .contentTransition(.numericText(countsDown: true))
            .animation(.easeOut(duration: 0.4), value: breakManager.timeRemaining)
    }
    
    private func timeFormatted(_ totalSeconds: Int) -> String {
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Isolated Controls Component

struct ControlsView: View {
    @ObservedObject var breakManager: BreakManager
    @State private var isSkipHovered = false
    @State private var isLockHovered = false
    
    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                // Skip Break Button
                Button(action: {
                    breakManager.snoozeBreak()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.forward.2")
                        Text("Skip Break")
                    }
                }
                .buttonStyle(GlassButtonStyle(isHovered: isSkipHovered))
                .onHover { hovering in isSkipHovered = hovering }
                .disabled(breakManager.snoozesLeft == 0)
                .opacity(breakManager.snoozesLeft == 0 ? 0.5 : 1.0)
                
                // Lock Screen Button
                Button(action: {
                    lockScreen()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "lock")
                        Text("Lock Screen")
                    }
                }
                .buttonStyle(GlassButtonStyle(isHovered: isLockHovered))
                .onHover { hovering in isLockHovered = hovering }
            }
            
            VStack(spacing: 8) {
                // Snoozes Left Sub-label
                Text("\(breakManager.snoozesLeft) snoozes available")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                
                // Keyboard shortcut hint
                Text("Press Esc twice to skip the break")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(6)
            }
        }
    }
}

// MARK: - Main Break Overlay View

struct BreakOverlayView: View {
    var crispWallpaper: NSImage?
    var blurredWallpaper: NSImage?
    
    // NOT @ObservedObject — timer ticks must not re-render this view.
    let breakManager: BreakManager
    
    // --- Animation state ---
    // Phase 0: Background wallpaper transition
    @State private var wallpaperOpacity: Double = 0
    @State private var wallpaperBlur: CGFloat = 0
    
    // Phase 1: Main text (title)
    @State private var mainTextBlur: CGFloat = AnimConst.textStrongBlur
    @State private var mainTextOffsetY: CGFloat = 0 // Will be set in onAppear based on measured height
    @State private var mainTextOpacity: Double = 0
    
    // Phase 2: Secondary text (subtitle) — blur only, no position animation
    @State private var secondaryTextBlur: CGFloat = AnimConst.textStrongBlur
    @State private var secondaryTextOpacity: Double = 0
    
    // Phase 3: Digital clock — slides from above screen
    @State private var clockOffsetY: CGFloat = -100 // Initial: above screen, refined in GeometryReader
    @State private var clockAtRest: Bool = false
    @State private var clockOpacity: Double = 0
    
    // Controls fade in with the secondary text
    @State private var controlsBlur: CGFloat = AnimConst.textStrongBlur
    @State private var controlsOpacity: Double = 0
    
    // Estimated main text height for offset calculation
    private let estimatedMainTextHeight: CGFloat = 62 // ~52pt font line height
    
    var body: some View {
        GeometryReader { geo in
            let safeTop = geo.safeAreaInsets.top
            let clockFinalY = safeTop + AnimConst.clockTopPadding
            let clockStartY = -(60 + AnimConst.clockOffscreenPadding) // clock height ~60pt
            
            ZStack {
                // ──────────────────────────────────────────────
                // Layer 1: Background wallpaper
                // ──────────────────────────────────────────────
                if let crisp = crispWallpaper {
                    Image(nsImage: crisp)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: wallpaperBlur)
                        .scaleEffect(1.05) // Prevent blur edge artifacts
                        .opacity(wallpaperOpacity)
                        .edgesIgnoringSafeArea(.all)
                } else {
                    Color.black
                        .opacity(wallpaperOpacity)
                        .edgesIgnoringSafeArea(.all)
                }
                
                // ──────────────────────────────────────────────
                // Layer 2: Digital clock (top of screen, slides in from above)
                // ──────────────────────────────────────────────
                VStack {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 12))
                        CurrentTimeView()
                    }
                    .foregroundColor(.white.opacity(0.6))
                    .offset(y: clockAtRest ? 0 : (clockStartY - clockFinalY))
                    .opacity(clockOpacity)
                    .padding(.top, clockFinalY)
                    
                    Spacer()
                }
                
                // ──────────────────────────────────────────────
                // Layer 3: Centered main content
                // ──────────────────────────────────────────────
                VStack(spacing: 24) {
                    // Main Text (Phase 1: blur + downward movement from above)
                    Text("Eyes to the horizon")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .blur(radius: mainTextBlur)
                        .offset(y: mainTextOffsetY)
                        .opacity(mainTextOpacity)
                    
                    // Secondary Text (Phase 2: blur only, no movement)
                    Text("Set your eyes on something distant until the countdown is over")
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.85))
                        .blur(radius: secondaryTextBlur)
                        .opacity(secondaryTextOpacity)
                    
                    // Elegant divider
                    Rectangle()
                        .frame(width: 80, height: 1.5)
                        .foregroundColor(.white.opacity(0.25))
                        .blur(radius: controlsBlur)
                        .opacity(controlsOpacity)
                    
                    // Countdown timer (isolated — ticks don't touch parent)
                    TimerCountdownView(breakManager: breakManager)
                        .blur(radius: controlsBlur)
                        .opacity(controlsOpacity)
                    
                    // Controls (isolated)
                    ControlsView(breakManager: breakManager)
                        .blur(radius: controlsBlur)
                        .opacity(controlsOpacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .clipped()
            .edgesIgnoringSafeArea(.all)
            .onAppear {
                // Set initial main text offset: starts shifted UP by half its height
                // (negative Y = upward in SwiftUI). Text settles DOWN into place (offset → 0).
                mainTextOffsetY = -(estimatedMainTextHeight * 0.5)
                
                // Schedule forward animation phases
                playForwardAnimation()
                
                // Listen for reverse trigger from BreakManager
                NotificationCenter.default.addObserver(
                    forName: .breakWillEnd,
                    object: nil,
                    queue: .main
                ) { _ in
                    playReverseAnimation()
                }
            }
        }
    }
    
    // MARK: - Forward Animation (staggered per spec)
    
    private func playForwardAnimation() {
        let easeOut = Animation.easeOut(duration: AnimConst.phase0Duration)
        
        // Phase 0: Background transition (frame 0–53, 1.06s)
        withAnimation(easeOut) {
            wallpaperOpacity = 1.0
            wallpaperBlur = AnimConst.backgroundStrongBlur
        }
        
        // Phase 1: Main text intro (frame 55–90, 0.70s)
        withAnimation(
            Animation.easeOut(duration: AnimConst.phase1Duration)
                .delay(AnimConst.phase1Delay)
        ) {
            mainTextBlur = 0
            mainTextOffsetY = 0
            mainTextOpacity = 1
        }
        
        // Phase 2: Secondary text intro (frame 90–115, 0.50s)
        withAnimation(
            Animation.easeOut(duration: AnimConst.phase2Duration)
                .delay(AnimConst.phase2Delay)
        ) {
            secondaryTextBlur = 0
            secondaryTextOpacity = 1
        }
        
        // Phase 3: Digital clock intro (frame 120–140, 0.40s)
        withAnimation(
            Animation.easeOut(duration: AnimConst.phase3Duration)
                .delay(AnimConst.phase3Delay)
        ) {
            clockAtRest = true
            clockOpacity = 1
        }
        
        // Controls: fade in alongside secondary text
        withAnimation(
            Animation.easeOut(duration: AnimConst.phase2Duration)
                .delay(AnimConst.phase2Delay)
        ) {
            controlsBlur = 0
            controlsOpacity = 1
        }
    }
    
    // MARK: - Reverse Animation (all simultaneous per spec)
    
    private func playReverseAnimation() {
        // All reverse animations start at the same moment.
        // Each has its own duration but they all begin together.
        
        // 1. Background wallpaper reverse (1.06s) — this is the longest
        withAnimation(.easeOut(duration: AnimConst.phase0Duration)) {
            wallpaperOpacity = 0
            wallpaperBlur = 0
        }
        
        // 2. Main text reverse (0.70s)
        withAnimation(.easeOut(duration: AnimConst.phase1Duration)) {
            mainTextBlur = AnimConst.textStrongBlur
            mainTextOffsetY = -(estimatedMainTextHeight * 0.5)
            mainTextOpacity = 0
        }
        
        // 3. Secondary text reverse (0.50s)
        withAnimation(.easeOut(duration: AnimConst.phase2Duration)) {
            secondaryTextBlur = AnimConst.textStrongBlur
            secondaryTextOpacity = 0
        }
        
        // 4. Digital clock reverse (0.40s)
        withAnimation(.easeOut(duration: AnimConst.phase3Duration)) {
            clockAtRest = false
            clockOpacity = 0
        }
        
        // 5. Controls reverse
        withAnimation(.easeOut(duration: AnimConst.phase2Duration)) {
            controlsBlur = AnimConst.textStrongBlur
            controlsOpacity = 0
        }
    }
}

// MARK: - Current Time View (updates independently)

private struct CurrentTimeView: View {
    @State private var currentTime: String = ""
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        Text(currentTime)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .onAppear { updateTime() }
            .onReceive(timer) { _ in updateTime() }
    }
    
    private func updateTime() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        currentTime = formatter.string(from: Date())
    }
}

// MARK: - Notification name for reverse animation trigger

extension Notification.Name {
    static let breakWillEnd = Notification.Name("breakWillEnd")
}
