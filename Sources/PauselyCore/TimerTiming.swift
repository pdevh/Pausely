import Foundation

public enum TimerTiming {
    /// The transition happens on the tick that reaches zero, not one tick later.
    public static func countdown(_ remaining: Int) -> Int { max(0, remaining - 1) }

    public struct Position {
        public let cycle: Int
        public let isBreak: Bool
        public let remaining: Int
    }

    public static func position(work: Double, rest: Double, anchor: Double, now: Double) -> Position {
        let duration = work + rest
        let elapsed = max(0, now - anchor)
        let position = elapsed.truncatingRemainder(dividingBy: duration)
        return Position(cycle: Int(elapsed / duration), isBreak: position >= work,
                        remaining: Int(ceil(position < work ? work - position : duration - position)))
    }
}
