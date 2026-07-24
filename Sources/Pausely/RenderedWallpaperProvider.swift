import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ScreenCaptureKit
import ImageIO

struct RenderedWallpaperSnapshot {
    let displayID: CGDirectDisplayID
    let crisp: NSImage
    let blurred: NSImage
}

struct CurrentWallpaperImage {
    let displayID: CGDirectDisplayID
    let image: NSImage
}

enum CurrentWallpaperCapture {
    @MainActor
    static func capture(for screen: NSScreen) async throws -> CurrentWallpaperImage {
        guard let target = WallpaperCaptureTarget(screen: screen) else {
            throw RenderedWallpaperCaptureError.missingScreenDisplayID
        }

        let snapshot = try await RenderedWallpaperCapturer.capture(targets: [target], cachedSnapshots: [:]).first
        guard let snapshot else {
            throw RenderedWallpaperCaptureError.emptyCapture(target.displayID)
        }

        return CurrentWallpaperImage(displayID: snapshot.displayID, image: snapshot.crisp)
    }

    @MainActor
    static func captureAll(for screens: [NSScreen] = NSScreen.screens) async throws -> [CurrentWallpaperImage] {
        let targets = screens.compactMap(WallpaperCaptureTarget.init(screen:))
        guard !targets.isEmpty else {
            throw RenderedWallpaperCaptureError.missingScreenDisplayID
        }

        return try await RenderedWallpaperCapturer.capture(targets: targets, cachedSnapshots: [:]).map {
            CurrentWallpaperImage(displayID: $0.displayID, image: $0.crisp)
        }
    }
}

@MainActor
final class RenderedWallpaperProvider: ObservableObject {
    static let shared = RenderedWallpaperProvider()

    @Published private(set) var snapshots: [CGDirectDisplayID: RenderedWallpaperSnapshot] = [:]
    @Published private(set) var lastError: String?

    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var cachedSnapshots: [CGDirectDisplayID: RenderedWallpaperSnapshot] = [:]

    private init() {}
    


    func snapshot(for displayID: CGDirectDisplayID) -> RenderedWallpaperSnapshot? {
        snapshots[displayID]
    }

    func refresh(for screens: [NSScreen]) {
        let targets = screens.compactMap(WallpaperCaptureTarget.init(screen:))

        guard !targets.isEmpty else { return }

        refreshGeneration += 1
        let generation = refreshGeneration
        snapshots = [:]
        lastError = nil

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do {
                let cache = self?.cachedSnapshots ?? [:]
                let newSnapshots = try await RenderedWallpaperCapturer.capture(targets: targets, cachedSnapshots: cache)
                guard !Task.isCancelled, self?.refreshGeneration == generation else { return }
                
                self?.snapshots = Dictionary(uniqueKeysWithValues: newSnapshots.map { ($0.displayID, $0) })
                self?.lastError = nil
                
                for snapshot in newSnapshots {
                    self?.cachedSnapshots[snapshot.displayID] = snapshot
                }
            } catch {
                guard !Task.isCancelled, self?.refreshGeneration == generation else { return }
                self?.snapshots = [:]
                self?.lastError = error.localizedDescription
            }
        }
    }

    func refreshAndWait(for screens: [NSScreen], timeout: TimeInterval = 1.5) async -> Bool {
        let targets = screens.compactMap(WallpaperCaptureTarget.init(screen:))

        guard !targets.isEmpty else { return false }

        refreshGeneration += 1
        let generation = refreshGeneration
        snapshots = [:]
        lastError = nil
        refreshTask?.cancel()
        refreshTask = nil

        do {
            let newSnapshots = try await captureWithTimeout(targets: targets, timeout: timeout)
            guard !Task.isCancelled, refreshGeneration == generation else { return false }
            
            self.snapshots = Dictionary(uniqueKeysWithValues: newSnapshots.map { ($0.displayID, $0) })
            self.lastError = nil
            
            for snapshot in newSnapshots {
                self.cachedSnapshots[snapshot.displayID] = snapshot
            }
            return true
        } catch {
            guard !Task.isCancelled, refreshGeneration == generation else { return false }
            self.snapshots = [:]
            self.lastError = error.localizedDescription
            return false
        }
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func captureWithTimeout(targets: [WallpaperCaptureTarget], timeout: TimeInterval) async throws -> [RenderedWallpaperSnapshot] {
        let cache = self.cachedSnapshots
        return try await withThrowingTaskGroup(of: [RenderedWallpaperSnapshot]?.self) { group in
            group.addTask {
                try await RenderedWallpaperCapturer.capture(targets: targets, cachedSnapshots: cache)
            }
            group.addTask {
                let nanoseconds = UInt64(max(0.1, timeout) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                return nil
            }

            guard let result = try await group.next() else {
                group.cancelAll()
                throw RenderedWallpaperCaptureError.timedOut
            }
            group.cancelAll()

            guard let snapshots = result else {
                throw RenderedWallpaperCaptureError.timedOut
            }
            return snapshots
        }
    }
}

private struct WallpaperCaptureTarget {
    let displayID: CGDirectDisplayID
    let displayFrame: CGRect
    let pointSize: NSSize
    let screen: NSScreen

    init?(screen: NSScreen) {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }

        self.displayID = displayID
        self.displayFrame = screen.frame
        self.pointSize = screen.frame.size
        self.screen = screen
    }
}

private enum RenderedWallpaperCaptureError: LocalizedError {
    case unsupportedOS
    case missingScreenDisplayID
    case missingDisplay(CGDirectDisplayID)
    case emptyCapture(CGDirectDisplayID)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Rendered wallpaper capture requires macOS 14 or later."
        case .missingScreenDisplayID:
            return "Could not resolve a CoreGraphics display ID for the requested screen."
        case .missingDisplay(let displayID):
            return "ScreenCaptureKit could not find display \(displayID)."
        case .emptyCapture(let displayID):
            return "ScreenCaptureKit returned no image for display \(displayID)."
        case .timedOut:
            return "ScreenCaptureKit wallpaper capture timed out."
        }
    }
}

private enum RenderedWallpaperCapturer {
    private static let sharedCIContext = CIContext(options: [.priorityRequestLow: true])

    // MARK: - Disk Caching Helpers
    
    private static func cacheDirectoryURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Pausely/wallpapers", isDirectory: true)
    }

    private static func blurredWallpaperCacheURL(for displayID: CGDirectDisplayID) -> URL {
        cacheDirectoryURL().appendingPathComponent("wallpaper_blurred_\(displayID).png", isDirectory: false)
    }

    private static func saveBlurredImage(_ cgImage: CGImage, for displayID: CGDirectDisplayID) {
        let url = blurredWallpaperCacheURL(for: displayID)
        let dir = cacheDirectoryURL()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                return
            }
            CGImageDestinationAddImage(destination, cgImage, nil)
            CGImageDestinationFinalize(destination)
        } catch {
            // Ignore cache save failures
        }
    }

    private static func loadBlurredImage(for displayID: CGDirectDisplayID, pointSize: NSSize) -> NSImage? {
        let url = blurredWallpaperCacheURL(for: displayID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              let nsImage = NSImage(data: data) else {
            return nil
        }
        nsImage.size = pointSize
        print("💾 Loaded blurred wallpaper from disk cache for display \(displayID)")
        return nsImage
    }

    static func capture(targets: [WallpaperCaptureTarget], cachedSnapshots: [CGDirectDisplayID: RenderedWallpaperSnapshot]) async throws -> [RenderedWallpaperSnapshot] {
        guard #available(macOS 14.0, *) else {
            throw RenderedWallpaperCaptureError.unsupportedOS
        }

        // Do not let ScreenCaptureKit become a second, implicit permission
        // request path. The permission manager owns prompting so denied or
        // duplicate-install states cannot produce another system dialog when
        // the pre-break wallpaper refresh runs.
        let content = CGPreflightScreenCaptureAccess()
            ? try? await shareableContentExcludingDesktopWindows()
            : nil

        return try await withThrowingTaskGroup(of: RenderedWallpaperSnapshot.self) { group in
            for target in targets {
                group.addTask {
                    if let content = content,
                       let display = content.displays.first(where: { $0.displayID == target.displayID }) {
                        do {
                            return try await captureDisplay(display, target: target, excludingWindows: content.windows, cachedSnapshot: cachedSnapshots[target.displayID])
                        } catch {
                            if let cached = cachedSnapshots[target.displayID] { return cached }
                            if let diskCachedBlurred = loadBlurredImage(for: target.displayID, pointSize: target.pointSize) {
                                return RenderedWallpaperSnapshot(displayID: target.displayID, crisp: diskCachedBlurred, blurred: diskCachedBlurred)
                            }
                            if let fileFallback = loadFileWallpaper(for: target) { return fileFallback }
                            throw error
                        }
                    } else {
                        if let cached = cachedSnapshots[target.displayID] { return cached }
                        if let diskCachedBlurred = loadBlurredImage(for: target.displayID, pointSize: target.pointSize) {
                            return RenderedWallpaperSnapshot(displayID: target.displayID, crisp: diskCachedBlurred, blurred: diskCachedBlurred)
                        }
                        if let fileFallback = loadFileWallpaper(for: target) { return fileFallback }
                        throw RenderedWallpaperCaptureError.missingDisplay(target.displayID)
                    }
                }
            }

            var snapshots: [RenderedWallpaperSnapshot] = []
            for try await snapshot in group {
                snapshots.append(snapshot)
            }
            return snapshots
        }
    }

    @available(macOS 14.0, *)
    private static func shareableContentExcludingDesktopWindows() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            // excludingDesktopWindows: true  →  content.windows contains only
            // regular app windows, NOT the special desktop/wallpaper windows.
            // We then exclude these app windows from the capture, leaving
            // only the wallpaper layer visible.
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(throwing: RenderedWallpaperCaptureError.emptyCapture(CGMainDisplayID()))
                }
            }
        }
    }

    @available(macOS 14.0, *)
    private static func captureDisplay(
        _ display: SCDisplay,
        target: WallpaperCaptureTarget,
        excludingWindows windows: [SCWindow],
        cachedSnapshot: RenderedWallpaperSnapshot?
    ) async throws -> RenderedWallpaperSnapshot {
        // Use excludingWindows (not excludingApplications) to preserve the
        // wallpaper base compositing layer. Excluding all *applications*
        // also removes the Dock process that renders the desktop wallpaper,
        // resulting in a black image.
        let filter = SCContentFilter(display: display, excludingWindows: windows)
        if #available(macOS 14.2, *) {
            filter.includeMenuBar = false
        }

        let scale = displayScale(for: target.displayID)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(target.pointSize.width * scale))
        configuration.height = max(1, Int(target.pointSize.height * scale))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let crisp = NSImage(cgImage: image, size: target.pointSize)
        
        if isImageBlack(crisp) {
            if let cached = cachedSnapshot { return cached }
            if let diskCachedBlurred = loadBlurredImage(for: target.displayID, pointSize: target.pointSize) {
                return RenderedWallpaperSnapshot(displayID: target.displayID, crisp: diskCachedBlurred, blurred: diskCachedBlurred)
            }
            if let fileFallback = loadFileWallpaper(for: target) { return fileFallback }
        }

        let blurredImage = makeBlurredImage(from: image, pointSize: target.pointSize)
        let blurred = NSImage(cgImage: blurredImage, size: target.pointSize)

        let displayID = target.displayID
        Task {
            saveBlurredImage(blurredImage, for: displayID)
        }

        return RenderedWallpaperSnapshot(displayID: target.displayID, crisp: crisp, blurred: blurred)
    }

    private static func displayScale(for displayID: CGDirectDisplayID) -> CGFloat {
        NSScreen.screens.first { screen in
            guard let screenDisplayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return screenDisplayID == displayID
        }?.backingScaleFactor ?? 1
    }

    private static func makeBlurredImage(from image: CGImage, pointSize: NSSize) -> CGImage {
        let maxDimension: CGFloat = 420
        let largestSide = CGFloat(max(image.width, image.height))
        let downsampleScale = min(1, maxDimension / largestSide)
        let downsampledSize = CGSize(
            width: max(1, CGFloat(image.width) * downsampleScale),
            height: max(1, CGFloat(image.height) * downsampleScale)
        )

        let ciImage = CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(scaleX: downsampleScale, y: downsampleScale))
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 11])
            .cropped(to: CGRect(origin: .zero, size: downsampledSize))

        return sharedCIContext.createCGImage(ciImage, from: CGRect(origin: .zero, size: downsampledSize)) ?? image
    }
    
    // MARK: - Fallback Helpers
    
    private static func isImageBlack(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return true
        }
        let ciImage = CIImage(cgImage: cgImage)
        let extent = ciImage.extent
        guard extent.width > 0 && extent.height > 0 else { return true }
        
        guard let avgFilter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: CIVector(cgRect: extent)
        ]), let outputImage = avgFilter.outputImage else { return true }
        
        var pixel = [UInt8](repeating: 0, count: 4)
        sharedCIContext.render(outputImage, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let maxChannel = max(pixel[0], pixel[1], pixel[2])
        return CGFloat(maxChannel) / 255.0 < 0.02
    }
    
    private static func loadFileWallpaper(for target: WallpaperCaptureTarget) -> RenderedWallpaperSnapshot? {
        print("📁 Falling back to loadFileWallpaper for display \(target.displayID)")
        var resolvedImage: NSImage? = nil

        // 1. Try NSWorkspace desktopImageURL
        if let url = NSWorkspace.shared.desktopImageURL(for: target.screen) {
            resolvedImage = DynamicWallpaperResolver.resolveCurrentImage(for: url)
            if resolvedImage == nil {
                resolvedImage = NSImage(contentsOf: url)
            }
        }

        // 2. Fall back to default desktop HEIC
        if resolvedImage == nil {
            let defaultURL = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")
            resolvedImage = DynamicWallpaperResolver.resolveCurrentImage(for: defaultURL)
            if resolvedImage == nil {
                resolvedImage = NSImage(contentsOf: defaultURL)
            }
        }

        // 3. Fall back to any image in /System/Library/Desktop Pictures/
        if resolvedImage == nil {
            let desktopPicturesURL = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
            if let files = try? FileManager.default.contentsOfDirectory(at: desktopPicturesURL, includingPropertiesForKeys: nil) {
                let imageFiles = files.filter { ["heic", "heif", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
                for fileURL in imageFiles {
                    if let img = DynamicWallpaperResolver.resolveCurrentImage(for: fileURL) ?? NSImage(contentsOf: fileURL) {
                        resolvedImage = img
                        break
                    }
                }
            }
        }

        // 4. Final fallback to a generated gradient image if all else fails
        guard let baseImage = resolvedImage else {
            let size = target.pointSize
            let img = NSImage(size: size)
            img.lockFocus()
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let colors = [
                NSColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1.0).cgColor,
                NSColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
                let context = NSGraphicsContext.current?.cgContext
                context?.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
            }
            img.unlockFocus()
            
            guard let cgImg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return nil
            }
            let blurredCG = makeBlurredImage(from: cgImg, pointSize: size)
            let blurred = NSImage(cgImage: blurredCG, size: size)
            
            let displayID = target.displayID
            Task {
                saveBlurredImage(blurredCG, for: displayID)
            }
            
            return RenderedWallpaperSnapshot(displayID: target.displayID, crisp: img, blurred: blurred)
        }

        guard let cgImg = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let crisp = NSImage(cgImage: cgImg, size: target.pointSize)
        let blurredCG = makeBlurredImage(from: cgImg, pointSize: target.pointSize)
        let blurred = NSImage(cgImage: blurredCG, size: target.pointSize)

        let displayID = target.displayID
        Task {
            saveBlurredImage(blurredCG, for: displayID)
        }

        return RenderedWallpaperSnapshot(displayID: target.displayID, crisp: crisp, blurred: blurred)
    }
}
