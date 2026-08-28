import XCTest
@testable import UsageBarCore

final class ParserTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: "json")
        guard let url else {
            throw URLError(.fileDoesNotExist)
        }
        return try Data(contentsOf: url)
    }

    func testClaudeWindows() throws {
        let snapshot = try Claude.parse(try fixture("claude"))
        XCTAssertEqual(snapshot.id, .claude)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].label, "5h session")
        XCTAssertEqual(snapshot.windows[0].usedPercent, 2)
        XCTAssertEqual(snapshot.windows[1].label, "Weekly")
        XCTAssertEqual(snapshot.windows[1].usedPercent, 16)
        XCTAssertEqual(snapshot.headlineUsedPercent, 16)
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
    }

    func testCodexWindows() throws {
        let snapshot = try Codex.parse(try fixture("codex"))
        XCTAssertEqual(snapshot.plan, "prolite")
        XCTAssertEqual(snapshot.windows[0].label, "Weekly")
        XCTAssertEqual(snapshot.windows[0].usedPercent, 8)
        XCTAssertEqual(snapshot.windows.count, 1, "per-model additional_rate_limits are ignored")
        XCTAssertEqual(snapshot.headlineUsedPercent, 8)
    }

    func testGrokWeekly() throws {
        let snapshot = try Grok.parse(try fixture("grok"))
        XCTAssertEqual(snapshot.windows[0].label, "Weekly")
        XCTAssertEqual(snapshot.windows[0].usedPercent, 25)
        XCTAssertEqual(snapshot.headlineUsedPercent, 25)
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
        XCTAssertEqual(snapshot.windows.count, 1, "identical Build share is omitted")
    }

    func testSeverity() {
        XCTAssertEqual(UsageSeverity.from(usedPercent: 2), .ok)
        XCTAssertEqual(UsageSeverity.from(usedPercent: 50), .warning)
        XCTAssertEqual(UsageSeverity.from(usedPercent: 80), .critical)
        XCTAssertEqual(UsageSeverity.from(usedPercent: nil), .missing)
    }
}
