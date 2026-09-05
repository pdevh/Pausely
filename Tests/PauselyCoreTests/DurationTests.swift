import XCTest
@testable import PauselyCore

final class DurationTests: XCTestCase {
    func testInputAndFormatting() {
        for (text, seconds) in [("37", 37), (" 37\n", 37), ("2:37", 157), ("1:02:37", 3757),
                                ("00:01", 1), ("86400", 86400), ("24:00:00", 86400), ("1440:00", 86400)] {
            XCTAssertEqual(DurationValue.parse(text), seconds, text)
            XCTAssertEqual(DurationValue.parse(DurationValue.clock(seconds)), seconds)
        }
        XCTAssertEqual(DurationValue.label(37), "37s")
        XCTAssertEqual(DurationValue.label(157), "2m 37s")
        XCTAssertEqual(DurationValue.label(3757), "1h 2m 37s")
        XCTAssertEqual(DurationValue.clock(86400), "24:00:00")
    }

    func testRejectsInvalidDrafts() {
        for text in ["", " ", "0", "-1", "+37", "1.5", "NaN", "Infinity", "1e2", "86401", "24:00:01",
                     "1:60", "1:00:60", ":37", "1:", "1:2:3:4", "1 :20", "٣٧", String(repeating: "9", count: 100)] {
            XCTAssertNil(DurationValue.parse(text), text)
        }
        for value in [0.0, -1, 0.5, 86401, .nan, .infinity, -.infinity] {
            XCTAssertFalse(DurationValue.isValid(value))
        }
    }

    func testTypingAndAdjustmentsShareOneValue() {
        var draft = DurationDraft(seconds: 20)
        draft.text = "0:37"
        XCTAssertEqual(draft.seconds, 37)
        draft.adjust(by: 60)
        XCTAssertEqual(draft.text, "1:37")
        XCTAssertEqual(draft.seconds, 97)
        draft.adjust(by: -1)
        XCTAssertEqual(draft.seconds, 96)
        draft.text = ""
        XCTAssertNil(draft.seconds)
        XCTAssertFalse(draft.canAdjust(by: 1))
        draft.adjust(by: 60)
        XCTAssertEqual(draft.text, "")
        draft.text = "1"
        draft.adjust(by: -1)
        XCTAssertEqual(draft.seconds, 1)
        draft.text = "86400"
        draft.adjust(by: 1)
        XCTAssertEqual(draft.seconds, 86400)
    }

    func testEditableClockAndHourAdjustments() {
        var draft = DurationDraft(seconds: 3757)
        XCTAssertEqual(draft.text, "1:02:37")
        draft.text = "3599"
        draft.normalize()
        XCTAssertEqual(draft.text, "59:59")
        draft.adjust(by: 1)
        XCTAssertEqual(draft.text, "1:00:00")
        draft.adjust(by: 3600)
        XCTAssertEqual(draft.text, "2:00:00")
        draft.adjust(by: -3600)
        XCTAssertEqual(draft.seconds, 3600)
        draft.text = "1:60"
        draft.normalize()
        XCTAssertEqual(draft.text, "1:60")
        XCTAssertFalse(draft.canAdjust(by: 3600))
        draft.text = "24:00:00"
        XCTAssertFalse(draft.canAdjust(by: 1))
        XCTAssertFalse(draft.canAdjust(by: 60))
        XCTAssertFalse(draft.canAdjust(by: 3600))
        draft.adjust(by: -1)
        XCTAssertEqual(draft.text, "23:59:59")
    }

    func testSecondAccurateCountdownAndCycleBoundaries() {
        var remaining = 37
        for _ in 0..<36 { remaining = TimerTiming.countdown(remaining) }
        XCTAssertEqual(remaining, 1)
        XCTAssertEqual(TimerTiming.countdown(remaining), 0)
        XCTAssertEqual(TimerTiming.countdown(0), 0)
        for (offset, cycle, isBreak, remaining) in [(0.0, 0, false, 37), (36.25, 0, false, 1),
            (37.0, 0, true, 13), (49.5, 0, true, 1), (50.0, 1, false, 37), (87.0, 1, true, 13)] {
            let position = TimerTiming.position(work: 37, rest: 13, anchor: 2000, now: 2000 + offset)
            XCTAssertEqual(position.cycle, cycle)
            XCTAssertEqual(position.isBreak, isBreak)
            XCTAssertEqual(position.remaining, remaining)
        }
        XCTAssertTrue(TimerTiming.position(work: 1, rest: 1, anchor: 0, now: 1).isBreak)
        XCTAssertFalse(TimerTiming.position(work: 1, rest: 1, anchor: 0, now: 2).isBreak)
    }
}
