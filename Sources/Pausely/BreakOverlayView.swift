import SwiftUI
import CoreGraphics
import CoreText
import AppKit
import Foundation

// MARK: - Visual Effect Background

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .fullScreenUI
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - TextShape (CoreText → SwiftUI Shape)

/// Converts a string rendered in a given `NSFont` into a SwiftUI `Shape`
/// by extracting each glyph's `CGPath` via CoreText and assembling them
/// into a single path, centered in the proposed rect with a Y-axis flip
/// for SwiftUI's top-left-origin coordinate space.
struct TextShape: Shape, @unchecked Sendable {
    let text: String
    let font: NSFont

    func path(in rect: CGRect) -> Path {
        let ctFont = font as CTFont
        let attrString = NSAttributedString(
            string: text,
            attributes: [.font: font]
        )
        let line = CTLineCreateWithAttributedString(attrString)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]

        let combinedPath = CGMutablePath()

        for run in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            CTRunGetGlyphs(run, CFRangeMake(0, glyphCount), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, glyphCount), &positions)

            for i in 0..<glyphCount {
                guard let glyphPath = CTFontCreatePathForGlyph(ctFont, glyphs[i], nil) else {
                    continue
                }
                let transform = CGAffineTransform(translationX: positions[i].x, y: positions[i].y)
                combinedPath.addPath(glyphPath, transform: transform)
            }
        }

        // Get typographic bounds
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let advanceWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

        // Verify we have a path to draw
        let glyphBounds = combinedPath.boundingBox
        guard !glyphBounds.isEmpty else { return Path() }

        // Center the typographic cell in the proposed rect and flip Y for SwiftUI
        let scaleX: CGFloat = 1
        let scaleY: CGFloat = -1
        let offsetX = rect.midX - CGFloat(advanceWidth) / 2
        let offsetY = (text == ":") ? (rect.midY + glyphBounds.midY) : (rect.midY + (ascent - descent) / 2)

        var finalTransform = CGAffineTransform(scaleX: scaleX, y: scaleY)
            .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))

        let finalPath = combinedPath.copy(using: &finalTransform) ?? combinedPath
        return Path(finalPath)
    }
}

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

// MARK: Native Liquid Glass (macOS 26+)

/// On macOS 26+, renders each character of the time string with the native
/// `.glassEffect(.clear, in: TextShape(...))` modifier for an authentic
/// liquid glass look. Characters are laid out in an HStack with fixed-width
/// frames for stable monospaced alignment, and digit changes animate with
/// a top-push transition.
@available(macOS 26, *)
struct NativeGlassTimerText: View {
    let text: String

    private let fontSize: CGFloat = 84

    /// System rounded bold font configured with **tabular (monospaced) digits**
    /// so that every digit `0`–`9` occupies the same typographic width,
    /// while the colon `:` keeps its natural narrow width.
    private var nsFont: NSFont {
        let systemFont = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        guard let roundedDesc = systemFont.fontDescriptor.withDesign(.rounded) else {
            return systemFont
        }
        // Add tabular-figures CoreText feature
        let tabularFeature: [NSFontDescriptor.FeatureKey: Any] = [
            .typeIdentifier: kNumberSpacingType,
            .selectorIdentifier: kMonospacedNumbersSelector
        ]
        let tabularDesc = roundedDesc.addingAttributes([
            .featureSettings: [tabularFeature]
        ])
        return NSFont(descriptor: tabularDesc, size: fontSize) ?? systemFont
    }

    /// Measures the native typographic width of a single character in `nsFont`.
    /// Because the font uses tabular figures, all digits return the same width;
    /// the colon naturally returns a narrower value.
    private func charWidth(_ char: String) -> CGFloat {
        let attrStr = NSAttributedString(
            string: char,
            attributes: [.font: nsFont]
        )
        return ceil(attrStr.size().width)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { index, char in
                let charStr = String(char)
                let width = charWidth(charStr)
                let height = fontSize * 1.3

                ZStack {
                    TextShape(text: charStr, font: nsFont)
                        .glassEffect(.clear, in: TextShape(text: charStr, font: nsFont))
                        .id("\(index)-\(charStr)")
                        .transition(.push(from: .bottom))
                }
                .frame(width: width, height: height)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .white, location: 0.15),
                            .init(color: .white, location: 0.85),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 6)
    }
}

// MARK: Fallback Faked Glass (macOS 13+)

/// Pre-macOS 26 implementation that fakes the glass look using layered
/// materials, specular highlights, inner shadows, and blend modes.
struct FallbackGlassTimerText: View {
    let text: String

    var body: some View {
        let fontSize: CGFloat = 84
        let font: Font = .system(size: fontSize, weight: .bold, design: .rounded)

        ZStack {
            // ── Layer 1: Glass body ──────────────────────────────────────
            // Ultra-thin material masked to the text shape at low opacity.
            // This gives the subtle "refraction" blur through the text
            // without making it look like solid frosted plastic.
            Text(text).font(font).monospacedDigit()
                .foregroundColor(.clear)
                .background(.ultraThinMaterial)
                .mask(Text(text).font(font).monospacedDigit())
                .opacity(0.35)

            // ── Layer 2: Specular highlight (top-left edge) ─────────────
            // Draw white text, then cut out a copy shifted down-right.
            // Only the top-left edge pixels survive — the "light catching
            // the bevel" effect seen on the iOS lock screen.
            Text(text).font(font).monospacedDigit()
                .foregroundColor(.clear)
                .overlay(
                    ZStack {
                        Text(text).font(font).monospacedDigit()
                            .foregroundColor(.white.opacity(0.8))
                        Text(text).font(font).monospacedDigit()
                            .foregroundColor(.black)
                            .offset(x: 1.5, y: 1.5)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                )
                .mask(Text(text).font(font).monospacedDigit())

            // ── Layer 3: Inner shadow (bottom-right edge) ───────────────
            // Same technique, opposite direction — dark edge on the
            // bottom-right to create depth and the 3D embossed look.
            Text(text).font(font).monospacedDigit()
                .foregroundColor(.clear)
                .overlay(
                    ZStack {
                        Text(text).font(font).monospacedDigit()
                            .foregroundColor(.black.opacity(0.3))
                        Text(text).font(font).monospacedDigit()
                            .foregroundColor(.black)
                            .offset(x: -1.5, y: -1.5)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                )
                .mask(Text(text).font(font).monospacedDigit())

            // ── Layer 4: Subtle luminosity fill ─────────────────────────
            // A barely-visible white fill so the text shape isn't
            // completely invisible on very dark backgrounds.
            Text(text).font(font).monospacedDigit()
                .foregroundColor(.white.opacity(0.08))
        }
        .compositingGroup()
        .contentTransition(.numericText(countsDown: true))
        // Soft drop shadow to lift the glass from the background
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 6)
    }
}

// MARK: Public entry point — dispatches based on OS version

struct GlassTimerText: View {
    let text: String

    var body: some View {
        if #available(macOS 26, *) {
            NativeGlassTimerText(text: text)
        } else {
            FallbackGlassTimerText(text: text)
        }
    }
}

struct TimerCountdownView: View {
    @ObservedObject var breakManager: BreakManager
    
    var body: some View {
        GlassTimerText(text: timeFormatted(breakManager.timeRemaining))
            .animation(.spring(duration: 0.4, bounce: 0.15, blendDuration: 0.08), value: breakManager.timeRemaining)
    }
    
    private func timeFormatted(_ totalSeconds: Int) -> String {
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct IntermissionTimerView: View {
    @ObservedObject var breakManager: BreakManager
    
    var body: some View {
        GlassTimerText(text: timeFormatted(breakManager.intermissionTimeRemaining))
            .animation(.spring(duration: 0.4, bounce: 0.15, blendDuration: 0.08), value: breakManager.intermissionTimeRemaining)
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
                // Snooze Button
                Button(action: {
                    breakManager.snoozeBreak()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "zzz")
                        Text("Snooze")
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
                Text("Press Esc twice to snooze the break")
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

struct IntermissionControlsView: View {
    @ObservedObject var breakManager: BreakManager
    @State private var isEndHovered = false
    
    var body: some View {
        VStack(spacing: 20) {
            Button(action: {
                breakManager.endIntermission(wasPremature: true)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                    Text("End Early")
                }
            }
            .buttonStyle(GlassButtonStyle(isHovered: isEndHovered))
            .onHover { hovering in isEndHovered = hovering }
            
            Text("Press Esc twice to end early")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundColor(.white.opacity(0.4))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.06))
                .cornerRadius(6)
        }
    }
}

// MARK: - Main Break Overlay View

struct BreakOverlayView: View {
    
    // NOT @ObservedObject — timer ticks must not re-render this view.
    let breakManager: BreakManager
    var isIntermission: Bool = false
    let displayID: CGDirectDisplayID
    @ObservedObject private var wallpaperProvider = RenderedWallpaperProvider.shared
    
    // --- Animation state ---
    // Phase 0: Background wallpaper transition
    @State private var wallpaperOpacity: Double = 0
    @State private var wallpaperBlurOpacity: Double = 0
    
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
                // Layer 1: Captured rendered wallpaper
                // ──────────────────────────────────────────────
                if let wallpaper = wallpaperProvider.snapshot(for: displayID) {
                    Image(nsImage: wallpaper.crisp)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .opacity(wallpaperOpacity)
                        .edgesIgnoringSafeArea(.all)

                    Image(nsImage: wallpaper.blurred)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .scaleEffect(1.05)
                        .opacity(wallpaperBlurOpacity)
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
                    Text(isIntermission ? "Voluntary break" : (breakManager.currentBreakPrompt?.title ?? "Eyes to the horizon"))
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .blur(radius: mainTextBlur)
                        .offset(y: mainTextOffsetY)
                        .opacity(mainTextOpacity)
                    
                    // Secondary Text (Phase 2: blur only, no movement)
                    Text(isIntermission ? (breakManager.currentIntermissionPrompt?.message ?? "Take a moment to rest your eyes") : (breakManager.currentBreakPrompt?.message ?? "Set your eyes on something distant until the countdown is over"))
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .frame(maxWidth: 700)
                        .blur(radius: secondaryTextBlur)
                        .opacity(secondaryTextOpacity)
                    
                    // Elegant divider
                    Rectangle()
                        .frame(width: 80, height: 1.5)
                        .foregroundColor(.white.opacity(0.25))
                        .blur(radius: controlsBlur)
                        .opacity(controlsOpacity)
                    
                    // Countdown timer (isolated — ticks don't touch parent)
                    if isIntermission {
                        IntermissionTimerView(breakManager: breakManager)
                            .blur(radius: controlsBlur)
                            .opacity(controlsOpacity)
                    } else {
                        TimerCountdownView(breakManager: breakManager)
                            .blur(radius: controlsBlur)
                            .opacity(controlsOpacity)
                    }
                    
                    // Controls (isolated)
                    if isIntermission {
                        IntermissionControlsView(breakManager: breakManager)
                            .blur(radius: controlsBlur)
                            .opacity(controlsOpacity)
                    } else {
                        ControlsView(breakManager: breakManager)
                            .blur(radius: controlsBlur)
                            .opacity(controlsOpacity)
                    }
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
            }
            .onReceive(NotificationCenter.default.publisher(for: .breakWillEnd)) { _ in
                playReverseAnimation()
            }
        }
    }
    
    // MARK: - Forward Animation (staggered per spec)
    
    private func playForwardAnimation() {
        // Short custom breaks must show the timer before the break is over.
        if breakManager.breakDuration < 5 {
            wallpaperOpacity = 1
            wallpaperBlurOpacity = 1
            mainTextBlur = 0
            mainTextOffsetY = 0
            mainTextOpacity = 1
            secondaryTextBlur = 0
            secondaryTextOpacity = 1
            clockAtRest = true
            clockOpacity = 1
            controlsBlur = 0
            controlsOpacity = 1
            return
        }
        let easeOut = Animation.easeOut(duration: AnimConst.phase0Duration)
        
        // Phase 0: Background transition (frame 0–53, 1.06s)
        withAnimation(easeOut) {
            wallpaperOpacity = 1.0
            wallpaperBlurOpacity = 1.0
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
            wallpaperBlurOpacity = 0
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
    
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    
    var body: some View {
        Text(currentTime)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .onAppear { updateTime() }
            .onReceive(timer) { _ in updateTime() }
    }
    
    private func updateTime() {
        currentTime = Self.timeFormatter.string(from: Date())
    }
}

// MARK: - Notification name for reverse animation trigger

extension Notification.Name {
    static let breakWillEnd = Notification.Name("breakWillEnd")
}
