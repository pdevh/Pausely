import AppKit
import CoreGraphics
import Foundation
import ImageIO
import os

// MARK: - Dynamic Wallpaper Resolver

/// Resolves macOS dynamic HEIC wallpapers to the correct sub-image for the current
/// time of day (solar wallpapers) or system appearance (light/dark wallpapers).
///
/// macOS dynamic wallpapers are multi-image HEIC containers with XMP metadata:
/// - `apple_desktop:solar` — 16 images keyed by sun altitude/azimuth
/// - `apple_desktop:apr`   — 2 images keyed by light/dark appearance
/// - `apple_desktop:h24`   — 16 images keyed by time of day (hour-based)
///
/// `NSImage(contentsOf:)` always loads index 0, which is typically the nighttime image.
/// This resolver picks the correct index based on current conditions.
struct DynamicWallpaperResolver {
    
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.pausely", category: "DynamicWallpaper")

    /// Returns the correct NSImage for the currently-active variant of a wallpaper.
    /// For static images, loads normally. For dynamic HEIC, selects the correct sub-image.
    static func resolveCurrentImage(for url: URL) -> NSImage? {
        logger.debug("Resolving image for URL: \(url.path)")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            logger.error("Failed to create CGImageSource for URL: \(url.path)")
            return NSImage(contentsOf: url)
        }

        let imageCount = CGImageSourceGetCount(source)
        logger.debug("Image count: \(imageCount)")

        // Single-image file — not dynamic
        guard imageCount > 1 else {
            logger.debug("Single image file, skipping dynamic resolution")
            return NSImage(contentsOf: url)
        }

        // Try to read the XMP metadata from the primary image properties
        let index = resolveIndex(source: source, imageCount: imageCount)
        logger.debug("Final resolved index: \(index)")
        return extractImage(from: source, at: index)
    }

    // MARK: - Index Resolution

    private static func resolveIndex(source: CGImageSource, imageCount: Int) -> Int {
        // Try solar metadata first, then appearance-based (apr), then time-based (h24)
        if let index = resolveSolarIndex(source: source, imageCount: imageCount) {
            return index
        }
        if let index = resolveAppearanceIndex(source: source, imageCount: imageCount) {
            return index
        }
        if let index = resolveH24Index(source: source, imageCount: imageCount) {
            return index
        }
        // Fallback: index 0
        return 0
    }

    // MARK: - Solar Wallpapers (apple_desktop:solar)

    /// Solar wallpapers contain an `si` (solar-info) array in the XMP metadata.
    /// Each entry maps an image index to a sun altitude/azimuth pair.
    /// We calculate the current solar position and pick the closest match.
    private static func resolveSolarIndex(source: CGImageSource, imageCount: Int) -> Int? {
        guard let metadata = extractBase64Metadata(source: source, key: "solar") else {
            logger.debug("No solar metadata found")
            return nil
        }

        // The solar metadata is a plist with an "si" array of dicts: [{a: altitude, i: index, z: azimuth}]
        guard let plist = try? PropertyListSerialization.propertyList(from: metadata, format: nil),
              let dict = plist as? [String: Any],
              let siArray = dict["si"] as? [[String: Any]] else {
            logger.error("Failed to parse solar metadata plist")
            return nil
        }

        let solar = currentSolarPosition()
        logger.debug("Current solar position: alt=\(solar.altitude), azi=\(solar.azimuth)")

        var bestIndex = 0
        var bestDistance = Double.infinity

        for entry in siArray {
            guard let altitude = entry["a"] as? Double,
                  let azimuth = entry["z"] as? Double,
                  let index = entry["i"] as? Int,
                  index >= 0, index < imageCount else {
                continue
            }

            // Angular distance — weight altitude more heavily since it determines
            // day/night much more than azimuth direction
            let altDiff = solar.altitude - altitude
            let aziDiff = angleDifference(solar.azimuth, azimuth)
            let distance = altDiff * altDiff + 0.25 * aziDiff * aziDiff

            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        logger.debug("Resolved solar index: \(bestIndex)")
        return bestIndex
    }

    // MARK: - Appearance Wallpapers (apple_desktop:apr)

    /// Appearance wallpapers have `l` (light) and `d` (dark) indices.
    private static func resolveAppearanceIndex(source: CGImageSource, imageCount: Int) -> Int? {
        guard let metadata = extractBase64Metadata(source: source, key: "apr") else {
            logger.debug("No apr metadata found")
            return nil
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: metadata, format: nil),
              let dict = plist as? [String: Any] else {
            logger.error("Failed to parse apr metadata plist")
            return nil
        }

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = isDark ? "d" : "l"
        logger.debug("Appearance: isDark=\(isDark), looking for key=\(key)")

        if let index = dict[key] as? Int, index >= 0, index < imageCount {
            logger.debug("Resolved apr index: \(index)")
            return index
        }

        logger.warning("Failed to find index for key \(key) in apr metadata")
        return nil
    }

    // MARK: - Time-of-Day Wallpapers (apple_desktop:h24)

    /// H24 wallpapers map images to time-of-day (0.0–1.0 fraction of 24h).
    private static func resolveH24Index(source: CGImageSource, imageCount: Int) -> Int? {
        guard let metadata = extractBase64Metadata(source: source, key: "h24") else {
            logger.debug("No h24 metadata found")
            return nil
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: metadata, format: nil),
              let dict = plist as? [String: Any],
              let tiArray = dict["ti"] as? [[String: Any]] else {
            logger.error("Failed to parse h24 metadata plist")
            return nil
        }

        // Current time as fraction of day
        let cal = Calendar.current
        let now = Date()
        let hour = Double(cal.component(.hour, from: now))
        let minute = Double(cal.component(.minute, from: now))
        let currentFraction = (hour + minute / 60.0) / 24.0
        logger.debug("Current time fraction: \(currentFraction)")

        var bestIndex = 0
        var bestDistance = Double.infinity

        for entry in tiArray {
            guard let t = entry["t"] as? Double,
                  let index = entry["i"] as? Int,
                  index >= 0, index < imageCount else {
                continue
            }

            // Circular distance on [0, 1)
            var diff = abs(currentFraction - t)
            if diff > 0.5 { diff = 1.0 - diff }

            if diff < bestDistance {
                bestDistance = diff
                bestIndex = index
            }
        }

        logger.debug("Resolved h24 index: \(bestIndex)")
        return bestIndex
    }

    // MARK: - XMP Metadata Extraction

    /// Extracts the base64-encoded plist data from the HEIC's XMP metadata for the given key
    /// (e.g., "solar", "apr", "h24"). The metadata is stored in the image properties under
    /// `{TIFF}` → `ImageDescription` or directly in XMP namespace `apple_desktop:<key>`.
    private static func extractBase64Metadata(source: CGImageSource, key: String) -> Data? {
        // Strategy 1: Check CGImageMetadata at index 0
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] {
            for tag in tags {
                if let prefix = CGImageMetadataTagCopyPrefix(tag) as? String,
                   let name = CGImageMetadataTagCopyName(tag) as? String,
                   let value = CGImageMetadataTagCopyValue(tag) as? String {
                    if prefix == "apple_desktop" && name == key {
                        if let data = Data(base64Encoded: value, options: .ignoreUnknownCharacters) {
                            return data
                        }
                    }
                }
            }
        }

        // Strategy 2: Check image properties at index 0 (legacy)
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            // Look in TIFF ImageDescription (some wallpapers store XMP here)
            if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
               let desc = tiff[kCGImagePropertyTIFFImageDescription as String] as? String,
               let data = extractFromXMP(xmpString: desc, key: key) {
                return data
            }
        }

        // Strategy 3: Check global metadata (legacy)
        if let metadata = CGImageSourceCopyProperties(source, nil) as? [String: Any] {
            if let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
               let desc = tiff[kCGImagePropertyTIFFImageDescription as String] as? String,
               let data = extractFromXMP(xmpString: desc, key: key) {
                return data
            }
        }

        // Strategy 4: Try reading raw XMP data from each image index (fallback)
        for i in 0..<min(CGImageSourceGetCount(source), 2) {
            if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any] {
                // Some formats store it under a custom namespace key
                for (propKey, propValue) in props {
                    if propKey.contains("apple_desktop") || propKey.contains(key) {
                        if let stringValue = propValue as? String,
                           let data = Data(base64Encoded: stringValue) {
                            return data
                        }
                    }
                }
            }
        }

        return nil
    }

    /// Parses an XMP string looking for `apple_desktop:<key>` and extracts its base64 value.
    private static func extractFromXMP(xmpString: String, key: String) -> Data? {
        // Look for pattern: apple_desktop:<key>="<base64>" or apple_desktop:<key>><base64></
        let patterns = [
            "apple_desktop:\(key)=\"",
            "apple_desktop:\(key)>",
        ]

        for pattern in patterns {
            guard let startRange = xmpString.range(of: pattern) else { continue }
            let afterPattern = xmpString[startRange.upperBound...]

            // Find the closing delimiter
            let endChar: Character = pattern.hasSuffix("\"") ? "\"" : "<"
            guard let endIndex = afterPattern.firstIndex(of: endChar) else { continue }

            let base64String = String(afterPattern[afterPattern.startIndex..<endIndex])
            if let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters) {
                return data
            }
        }

        return nil
    }

    // MARK: - Image Extraction

    private static func extractImage(from source: CGImageSource, at index: Int) -> NSImage? {
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else {
            // Fallback to index 0
            if index != 0, let fallback = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return NSImage(cgImage: fallback, size: NSSize(width: fallback.width, height: fallback.height))
            }
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    // MARK: - Solar Position Calculation

    /// Simplified solar position calculation using current date and timezone-estimated coordinates.
    /// Accuracy is sufficient for selecting among ~16 discrete wallpaper images.
    private static func currentSolarPosition() -> (altitude: Double, azimuth: Double) {
        let now = Date()
        let tz = TimeZone.current

        // Estimate longitude from timezone offset
        let offsetSeconds = Double(tz.secondsFromGMT(for: now))
        let longitude = offsetSeconds / 240.0 // 360° / 86400s = 1° per 240s

        // Default latitude: 48°N (reasonable for most populated mid-latitude zones)
        let latitude = 48.0

        return solarPosition(date: now, latitude: latitude, longitude: longitude)
    }

    /// Standard solar position algorithm.
    /// Reference: NOAA Solar Calculator (simplified Meeus approach)
    private static func solarPosition(date: Date, latitude: Double, longitude: Double) -> (altitude: Double, azimuth: Double) {
        let cal = Calendar(identifier: .gregorian)
        let components = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)

        let year = Double(components.year ?? 2025)
        let month = Double(components.month ?? 1)
        let day = Double(components.day ?? 1)
        let hour = Double(components.hour ?? 12)
        let minute = Double(components.minute ?? 0)
        let second = Double(components.second ?? 0)

        // Julian Day Number
        let a = floor((14 - month) / 12)
        let y = year + 4800 - a
        let m = month + 12 * a - 3

        let jdn = day + floor((153 * m + 2) / 5) + 365 * y + floor(y / 4) - floor(y / 100) + floor(y / 400) - 32045
        let jd = jdn + (hour - 12) / 24.0 + minute / 1440.0 + second / 86400.0

        // Julian centuries from J2000.0
        let T = (jd - 2451545.0) / 36525.0

        // Solar coordinates (low-precision, sufficient for wallpaper selection)
        // Mean longitude
        let L0 = (280.46646 + T * (36000.76983 + T * 0.0003032)).truncatingRemainder(dividingBy: 360)

        // Mean anomaly
        let M = (357.52911 + T * (35999.05029 - T * 0.0001537)).truncatingRemainder(dividingBy: 360)
        let Mrad = M * .pi / 180

        // Equation of center
        let C = (1.914602 - T * (0.004817 + T * 0.000014)) * sin(Mrad)
            + (0.019993 - T * 0.000101) * sin(2 * Mrad)
            + 0.000289 * sin(3 * Mrad)

        // Sun's true longitude
        let sunLon = L0 + C

        // Sun's apparent longitude
        let omega = 125.04 - 1934.136 * T
        let lambda = sunLon - 0.00569 - 0.00478 * sin(omega * .pi / 180)
        let lambdaRad = lambda * .pi / 180

        // Obliquity of ecliptic
        let epsilon0 = 23.0 + (26.0 + (21.448 - T * (46.815 + T * (0.00059 - T * 0.001813))) / 60.0) / 60.0
        let epsilon = epsilon0 + 0.00256 * cos(omega * .pi / 180)
        let epsilonRad = epsilon * .pi / 180

        // Declination
        let sinDec = sin(epsilonRad) * sin(lambdaRad)
        let declination = asin(sinDec) // radians

        // Right ascension (for equation of time)
        let tanRA = cos(epsilonRad) * sin(lambdaRad) / cos(lambdaRad)
        var RA = atan(tanRA)
        // Quadrant correction
        if cos(lambdaRad) < 0 { RA += .pi }
        if cos(lambdaRad) >= 0 && sin(lambdaRad) < 0 { RA += 2 * .pi }

        // Equation of time (minutes)
        let L0rad = L0 * .pi / 180
        let eqTime = (L0rad - RA) * 180.0 / .pi * 4.0 // Convert to minutes

        // True solar time
        let utcMinutes = hour * 60 + minute + second / 60.0
        var trueSolarTime = utcMinutes + eqTime + 4.0 * longitude
        trueSolarTime = trueSolarTime.truncatingRemainder(dividingBy: 1440)
        if trueSolarTime < 0 { trueSolarTime += 1440 }

        // Hour angle
        let hourAngle = (trueSolarTime / 4.0 - 180.0) * .pi / 180.0

        // Solar altitude
        let latRad = latitude * .pi / 180
        let sinAlt = sin(latRad) * sin(declination) + cos(latRad) * cos(declination) * cos(hourAngle)
        let altitude = asin(sinAlt) * 180.0 / .pi

        // Solar azimuth
        let cosAzi = (sin(declination) - sin(latRad) * sinAlt) / (cos(latRad) * cos(asin(sinAlt)))
        var azimuth = acos(max(-1, min(1, cosAzi))) * 180.0 / .pi
        if hourAngle > 0 { azimuth = 360 - azimuth }

        return (altitude: altitude, azimuth: azimuth)
    }

    // MARK: - Helpers

    /// Shortest angular difference between two angles in degrees.
    private static func angleDifference(_ a: Double, _ b: Double) -> Double {
        var diff = a - b
        while diff > 180 { diff -= 360 }
        while diff < -180 { diff += 360 }
        return diff
    }
}
