import Foundation

public enum DurationValue {
    public static let maximum = 86_400

    public static func isValid(_ seconds: Double) -> Bool {
        seconds.isFinite && seconds >= 1 && seconds <= Double(maximum) && seconds.rounded() == seconds
    }

    /// Bare numbers are seconds; colon notation is m:ss or h:mm:ss.
    public static func parse(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let number = Int(part), number <= maximum,
                  index == 0 || number < 60 else { return nil }
            total = total * 60 + number
        }
        return (1...maximum).contains(total) ? total : nil
    }

    public static func clock(_ seconds: Int) -> String {
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    public static func label(_ seconds: Int) -> String {
        var parts: [String] = []
        if seconds >= 3600 { parts.append("\(seconds / 3600)h") }
        if seconds / 60 % 60 > 0 { parts.append("\(seconds / 60 % 60)m") }
        if seconds % 60 > 0 { parts.append("\(seconds % 60)s") }
        return parts.joined(separator: " ")
    }
}

/// The editor's only stored value is its text. Invalid drafts have no preview
/// or adjustment value, so an old numeric value can never disagree with the field.
public struct DurationDraft {
    public var text: String
    public var seconds: Int? { DurationValue.parse(text) }

    public init(seconds: Int) { text = String(seconds) }

    public func canAdjust(by delta: Int) -> Bool {
        guard let seconds else { return false }
        return (1...DurationValue.maximum).contains(seconds + delta)
    }

    public mutating func adjust(by delta: Int) {
        guard let seconds, canAdjust(by: delta) else { return }
        text = String(seconds + delta)
    }
}
