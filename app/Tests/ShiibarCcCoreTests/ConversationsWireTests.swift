import XCTest
@testable import ShiibarCcCore

final class ConversationsWireTests: XCTestCase {
    func testDecodeSearchResultWithNullTitleAndCwd() {
        let line = """
        {"conversations":[{"session_id":"abc","cwd":"/Users/example/blog","title":"Intro draft","updated_at":1700000000,"live":false},{"session_id":"def","cwd":null,"title":null,"updated_at":1700000100,"live":true}]}
        """
        let result = ConversationSearchResult.decode(line)
        XCTAssertEqual(result?.conversations.count, 2)
        XCTAssertEqual(result?.conversations[0].sessionID, "abc")
        XCTAssertEqual(result?.conversations[0].cwd, "/Users/example/blog")
        XCTAssertEqual(result?.conversations[0].title, "Intro draft")
        XCTAssertEqual(result?.conversations[0].updatedAt, 1_700_000_000)
        XCTAssertEqual(result?.conversations[0].live, false)
        XCTAssertNil(result?.conversations[1].cwd)
        XCTAssertNil(result?.conversations[1].title)
        XCTAssertEqual(result?.conversations[1].live, true)
    }

    func testDecodeSearchIgnoresUnknownFields() {
        // §4.2 forward-compat: unknown fields are ignored.
        let line = """
        {"conversations":[{"session_id":"abc","cwd":null,"title":null,"updated_at":1,"live":false,"future_field":42}],"extra":true}
        """
        let result = ConversationSearchResult.decode(line)
        XCTAssertEqual(result?.conversations.first?.sessionID, "abc")
    }

    func testDecodeMalformedSearchLineReturnsNil() {
        XCTAssertNil(ConversationSearchResult.decode("not json"))
        XCTAssertNil(ConversationSearchResult.decode(""))
    }

    func testDecodeShowResult() {
        let line = """
        {"session_id":"abc","cwd":"/Users/example/blog","title":"T","messages":[{"seq":0,"role":"user","text":"hi"},{"seq":1,"role":"assistant","text":"hello"}]}
        """
        let detail = ConversationDetail.decode(line)
        XCTAssertEqual(detail?.sessionID, "abc")
        XCTAssertEqual(detail?.messages.count, 2)
        XCTAssertEqual(detail?.messages[0].role, "user")
        XCTAssertEqual(detail?.messages[1].text, "hello")
        XCTAssertEqual(detail?.messages[1].seq, 1)
    }

    func testDecodeIndexProgressEvents() {
        XCTAssertEqual(IndexProgressEvent.decode("{\"event\":\"start\",\"total\":4200}"), .start(total: 4200))
        XCTAssertEqual(
            IndexProgressEvent.decode("{\"event\":\"progress\",\"done\":340,\"total\":4200}"),
            .progress(done: 340, total: 4200)
        )
        XCTAssertEqual(
            IndexProgressEvent.decode("{\"event\":\"done\",\"indexed\":10,\"removed\":2}"),
            .done(indexed: 10, removed: 2)
        )
        XCTAssertEqual(
            IndexProgressEvent.decode("{\"event\":\"error\",\"message\":\"boom\"}"),
            .error(message: "boom")
        )
    }

    func testDecodeIndexProgressSkipsBlankAndUnknown() {
        XCTAssertNil(IndexProgressEvent.decode(""))
        XCTAssertNil(IndexProgressEvent.decode("   "))
        XCTAssertNil(IndexProgressEvent.decode("{\"event\":\"future\"}"))
        XCTAssertNil(IndexProgressEvent.decode("garbage"))
    }
}
