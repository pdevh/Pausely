import Foundation

public struct SessionSchedule: Equatable {
    public let work: Int
    public let rest: Int
    public let anchor: TimeInterval
}

public enum SessionCode {
    public static let workPresets = [15, 600, 1200, 1800]
    public static let breakPresets = [5, 15, 20, 60]
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    private static let window: Int64 = 4_194_304
    private static let radix: Int64 = 86_400

    public static func encode(work: Int, rest: Int, anchor: TimeInterval) -> String {
        precondition(DurationValue.isValid(Double(work)) && DurationValue.isValid(Double(rest)))
        precondition(anchor.isFinite && anchor >= 0 && anchor < 253_402_300_800)
        let timestamp = Int64(anchor) % window
        let value: Int64
        let length: Int
        if let w = workPresets.firstIndex(of: work), let b = breakPresets.firstIndex(of: rest) {
            // Preserve the original six-character wire format byte for byte.
            value = (Int64(w) << 26) | (Int64(b) << 22) | timestamp
            length = 6
        } else {
            value = ((Int64(work - 1) * radix + Int64(rest - 1)) << 22) | timestamp
            length = 11
        }
        var remaining = value
        var result = ""
        for _ in 0..<length {
            result.insert(alphabet[Int(remaining & 31)], at: result.startIndex)
            remaining >>= 5
        }
        return result
    }

    public static func decode(_ text: String, now: TimeInterval) -> SessionSchedule? {
        guard now.isFinite, now >= 0, now < 253_402_300_800 else { return nil }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = raw.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        if code.count == 6 || code.count == 11 {
            var value: Int64 = 0
            for character in code {
                guard let index = alphabet.firstIndex(of: character) else { return nil }
                value = (value << 5) | Int64(index)
            }
            let work: Int
            let rest: Int
            if code.count == 6 {
                let w = Int((value >> 26) & 15)
                let b = Int((value >> 22) & 15)
                guard w < workPresets.count, b < breakPresets.count else { return nil }
                work = workPresets[w]
                rest = breakPresets[b]
            } else {
                let settings = value >> 22
                guard settings < radix * radix else { return nil }
                work = Int(settings / radix) + 1
                rest = Int(settings % radix) + 1
            }
            let current = Int64(now)
            var difference = (value & (window - 1)) - current % window
            if difference > window / 2 { difference -= window }
            else if difference < -window / 2 { difference += window }
            return SessionSchedule(work: work, rest: rest, anchor: Double(current + difference))
        }

        // Retain the original, pre-compact Base64 import path.
        guard let data = Data(base64Encoded: raw), let payload = String(data: data, encoding: .utf8) else { return nil }
        let parts = payload.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let work = Double(parts[0]), DurationValue.isValid(work),
              let rest = Double(parts[1]), DurationValue.isValid(rest),
              let anchor = Double(parts[2]), anchor.isFinite,
              anchor >= 0, anchor < 253_402_300_800 else { return nil }
        return SessionSchedule(work: Int(work), rest: Int(rest), anchor: anchor)
    }

    public static func display(_ code: String) -> String {
        code.count == 11 ? String(code.prefix(5)) + "-" + String(code.suffix(6)) : code
    }
}
