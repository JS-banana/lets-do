import XCTest
@testable import TodoM0

final class NoteFormattingTests: XCTestCase {
    func testUTF16RangesKeepEmojiAndMergeAdjacentBold() throws {
        let body = "标题🙂重点"
        let style = NoteFormatting(bold: [.init(location: 0, length: 2), .init(location: 2, length: 2)])
        XCTAssertEqual(try style.validated(for: body), NoteFormatting(bold: [.init(location: 0, length: 4)]))
        let json = try style.encoded(for: body)
        XCTAssertEqual(try NoteFormatting.decode(json, body: body), try style.validated(for: body))
        XCTAssertNil(try NoteFormatting(bold: []).validated(for: body))
        XCTAssertThrowsError(try NoteFormatting(bold: [.init(location: 2, length: 1)]).validated(for: body))
    }

    func testInvalidRangesAndUnknownDataAreRejected() throws {
        for span in [NoteFormatting.Span(location: -1, length: 1), .init(location: 0, length: 0), .init(location: Int.max, length: 1), .init(location: 1, length: Int.max)] {
            XCTAssertThrowsError(try NoteFormatting(bold: [span]).validated(for: "body"))
        }
        XCTAssertThrowsError(try NoteFormatting(bold: [.init(location: 0, length: 3), .init(location: 2, length: 2)]).validated(for: "body"))
        XCTAssertThrowsError(try NoteFormatting.decode("not JSON", body: "body"))
        XCTAssertThrowsError(try NoteFormatting.decode(String(repeating: " ", count: 256_001), body: ""))
    }
}
