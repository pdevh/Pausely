import XCTest
@testable import PauselyCore

final class SessionCodeTests: XCTestCase {
    struct Vector: Decodable {
        let work: Int
        let rest: Int
        let anchor: Double
        let code: String
    }

    func testCrossPlatformGoldenVectors() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "session-codes", withExtension: "json", subdirectory: "Fixtures"))
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
        for vector in vectors {
            XCTAssertEqual(SessionCode.encode(work: vector.work, rest: vector.rest, anchor: vector.anchor), vector.code)
            for now in [vector.anchor, vector.anchor + 123, vector.anchor + 2_097_151] {
                let decoded = try XCTUnwrap(SessionCode.decode(vector.code, now: now))
                XCTAssertEqual(decoded.work, vector.work)
                XCTAssertEqual(decoded.rest, vector.rest)
                XCTAssertEqual(decoded.anchor, vector.anchor)
            }
            XCTAssertNotNil(SessionCode.decode(" \n" + SessionCode.display(vector.code).lowercased() + "\n", now: vector.anchor))
        }
    }

    func testEverySecondForEachCustomField() throws {
        for seconds in 1...DurationValue.maximum {
            for (work, rest) in [(seconds, 37), (37, seconds)] {
                let code = SessionCode.encode(work: work, rest: rest, anchor: 1_788_600_000)
                let decoded = try XCTUnwrap(SessionCode.decode(code, now: 1_788_600_001))
                XCTAssertEqual(decoded.work, work)
                XCTAssertEqual(decoded.rest, rest)
            }
        }
    }

    func testLegacyImportsAndInvalidCodes() {
        func legacy(_ payload: String) -> String { Data(payload.utf8).base64EncodedString() }
        let valid = SessionCode.decode(legacy("37:13:1788600000"), now: 1_788_600_000)
        XCTAssertEqual(valid?.work, 37)
        XCTAssertEqual(valid?.rest, 13)
        XCTAssertEqual(valid?.anchor, 1_788_600_000)
        for code in ["", "ABCDE", "ABCDEFG", "AAAAAAAAAA", "AAAAAAAAAAAA", "AAAAA0", "AAAAA!",
                     "777777", "77777777777", legacy("0:13:1788600000"), legacy("37:NaN:1788600000"),
                     legacy("37:13:Infinity"), legacy("37:13:-1"), legacy("86401:13:1788600000"),
                     legacy("1.5:13:1788600000"), legacy("37:13"), legacy("37:13:1788600000:extra")] {
            XCTAssertNil(SessionCode.decode(code, now: 1_788_600_000), code)
        }
    }
}
