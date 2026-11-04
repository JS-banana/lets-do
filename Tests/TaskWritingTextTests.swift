import Foundation
import XCTest
@testable import TodoM0

final class TaskWritingTextTests: XCTestCase {
    private typealias Replacement = (range: NSRange, text: String)

    private func utf16Length(_ text: String) -> Int {
        (text as NSString).length
    }

    private func applying(_ text: String, replacements: [Replacement]) -> String {
        let value = NSMutableString(string: text)
        for replacement in replacements.reversed() {
            value.replaceCharacters(in: replacement.range, with: replacement.text)
        }
        return value as String
    }

    func testListToggleExcludesTitleAndAdjustsWholeSelection() {
        let input = "标题\nalpha\nbeta"
        let selection = NSRange(location: 0, length: utf16Length(input))
        let replacements = TaskWritingText.listReplacements(in: input, selection: selection, kind: .bullets)

        XCTAssertEqual(replacements.map { $0.text }, ["• ", "• "])
        XCTAssertEqual(replacements.map { $0.range }, [
            NSRange(location: utf16Length("标题\n"), length: 0),
            NSRange(location: utf16Length("标题\nalpha\n"), length: 0)
        ])

        let result = applying(input, replacements: replacements)
        XCTAssertEqual(result, "标题\n• alpha\n• beta")
        XCTAssertEqual(TaskWritingText.adjustedSelection(selection, replacements: replacements,
                                                         textLength: utf16Length(result)),
                       NSRange(location: 0, length: utf16Length(result)))
    }

    func testMixedListConversionThenRemovalPreservesSelection() {
        let input = "标题\n• alpha\n2. beta\nplain"
        let bodyStart = utf16Length("标题\n")
        let selection = NSRange(location: bodyStart, length: utf16Length(input) - bodyStart)
        let conversion = TaskWritingText.listReplacements(in: input, selection: selection, kind: .numbers)
        let converted = applying(input, replacements: conversion)
        XCTAssertEqual(converted, "标题\n1. alpha\n2. beta\n3. plain")
        let convertedSelection = TaskWritingText.adjustedSelection(selection, replacements: conversion,
                                                                    textLength: utf16Length(converted))
        XCTAssertEqual(convertedSelection,
                       NSRange(location: bodyStart, length: utf16Length(converted) - bodyStart))

        let removal = TaskWritingText.listReplacements(in: converted, selection: convertedSelection, kind: .numbers)
        let removed = applying(converted, replacements: removal)
        XCTAssertEqual(removed, "标题\nalpha\nbeta\nplain")
        XCTAssertEqual(TaskWritingText.adjustedSelection(convertedSelection, replacements: removal,
                                                         textLength: utf16Length(removed)),
                       NSRange(location: bodyStart, length: utf16Length(removed) - bodyStart))
    }

    func testMultiLineSelectionWithTrailingNewlineDoesNotPrefixEmptyLine() {
        let input = "标题\none\ntwo\n"
        let bodyStart = utf16Length("标题\n")
        let selection = NSRange(location: bodyStart, length: utf16Length(input) - bodyStart)
        let replacements = TaskWritingText.listReplacements(in: input, selection: selection, kind: .bullets)

        XCTAssertEqual(replacements.count, 2)
        let result = applying(input, replacements: replacements)
        XCTAssertEqual(result, "标题\n• one\n• two\n")
        XCTAssertEqual(TaskWritingText.adjustedSelection(selection, replacements: replacements,
                                                         textLength: utf16Length(result)),
                       NSRange(location: bodyStart, length: utf16Length(result) - bodyStart))
    }

    func testEmptyListItemNewlineExitsListAndPlacesCaretAfterNewline() throws {
        let input = "标题\n• "
        let location = utf16Length(input)
        let edit = try XCTUnwrap(TaskWritingText.newlineEdit(in: input, at: location))

        XCTAssertEqual(edit.range, NSRange(location: utf16Length("标题\n"), length: utf16Length("• ")))
        XCTAssertEqual(edit.text, "\n")
        let result = applying(input, replacements: [(edit.range, edit.text)])
        XCTAssertEqual(result, "标题\n\n")
        XCTAssertEqual(edit.selection, NSRange(location: utf16Length(result), length: 0))
    }

    func testNumberContinuationKeepsIntMaxWithoutOverflow() throws {
        let input = "标题\n3. item"
        let edit = try XCTUnwrap(TaskWritingText.newlineEdit(in: input, at: utf16Length(input)))
        XCTAssertEqual(edit.text, "\n4. ")
        let result = applying(input, replacements: [(edit.range, edit.text)])
        XCTAssertEqual(result, "标题\n3. item\n4. ")
        XCTAssertEqual(edit.selection, NSRange(location: utf16Length(result), length: 0))

        let maximum = String(Int.max)
        let maxInput = "标题\n\(maximum). item"
        let maxEdit = try XCTUnwrap(TaskWritingText.newlineEdit(in: maxInput, at: utf16Length(maxInput)))
        XCTAssertEqual(maxEdit.text, "\n\(maximum). ")
        let maxResult = applying(maxInput, replacements: [(maxEdit.range, maxEdit.text)])
        XCTAssertEqual(maxResult, "标题\n\(maximum). item\n\(maximum). ")
        XCTAssertEqual(maxEdit.selection, NSRange(location: utf16Length(maxResult), length: 0))
    }

    func testEmojiUsesUTF16SelectionOffsetsWhenTogglingList() {
        let input = "标题\n🙂alpha\nbeta"
        let bodyStart = utf16Length("标题\n")
        let afterEmoji = bodyStart + utf16Length("🙂")
        let selection = NSRange(location: afterEmoji, length: utf16Length(input) - afterEmoji)
        let replacements = TaskWritingText.listReplacements(in: input, selection: selection, kind: .numbers)
        let result = applying(input, replacements: replacements)

        XCTAssertEqual(result, "标题\n1. 🙂alpha\n2. beta")
        XCTAssertEqual(TaskWritingText.adjustedSelection(selection, replacements: replacements,
                                                         textLength: utf16Length(result)),
                       NSRange(location: 8, length: 13))
    }

    func testTitleOnlyListToggleReturnsNoReplacementsAtEndCaret() {
        let input = "仅标题"
        let selection = NSRange(location: utf16Length(input), length: 0)

        XCTAssertTrue(TaskWritingText.listReplacements(in: input, selection: selection, kind: .bullets).isEmpty)
    }
}
