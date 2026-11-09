import XCTest
@testable import ContextWeaveCore

final class SessionTests: XCTestCase {
    func testIdentityDoesNotCollideWhenFieldsContainDelimiters() throws {
        let first = try SessionID(agent: "a:b", externalID: "c")
        let second = try SessionID(agent: "a", externalID: "b:c")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Set([first, second]).count, 2)
    }

    func testEmptyIdentityIsRejected() {
        XCTAssertThrowsError(try SessionID(agent: " \n", externalID: "1"))
        XCTAssertThrowsError(try SessionID(agent: "codex", externalID: ""))
    }

    func testSessionRoundTripKeepsSourceAndTimestamp() throws {
        let session = Session(
            source: SessionSource(id: try SessionID(agent: "codex", externalID: "123"), sourcePath: "/tmp/session"),
            projectID: "project-1",
            messages: [SessionMessage(id: "1", role: .user, content: "hello", timestampMilliseconds: 1_700_000_000_000)]
        )
        let decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.source.id, session.source.id)
        XCTAssertEqual(decoded.projectID, "project-1")
        XCTAssertEqual(decoded.messages.first?.timestampMilliseconds, 1_700_000_000_000)
    }
}
