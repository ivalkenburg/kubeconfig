import XCTest
@testable import KubeConfigCore

final class DraftTests: XCTestCase {
    func testDuplicateClonesUnfamiliarFieldsAndPicksAFreeName() throws {
        var doc = try Fixtures.document()
        XCTAssertEqual(try doc.duplicate(.users, name: "developer"), "developer-copy")
        XCTAssertEqual(try doc.duplicate(.users, name: "developer"), "developer-copy-2")
        let copy = try XCTUnwrap(doc.entry(.users, named: "developer-copy"))
        XCTAssertEqual(copy.value("vendor-field"), "retained")
        XCTAssertEqual(copy.value("token"), "fixture-secret-token")
        XCTAssertEqual(copy.fields, doc.entry(.users, named: "developer")?.fields)
        XCTAssertThrowsError(try doc.duplicate(.users, name: "nobody"))
    }

    func testChangesCompareEntriesWithDisk() throws {
        let disk = try Fixtures.document()
        var draft = disk
        XCTAssertEqual(draft.changes(from: disk).count, 0)
        try draft.update(.contexts, originalName: "development", name: "development", fields: ["namespace": "staging"])
        XCTAssertTrue(draft.changes(from: disk).contains(.contexts, name: "development"))
        XCTAssertEqual(draft.changes(from: disk).count, 1)
        try draft.update(.contexts, originalName: "development", name: "development", fields: ["namespace": "default"])
        XCTAssertEqual(draft.changes(from: disk).count, 0, "Changing a value back leaves nothing to apply")
    }

    func testClearingAFieldAndTypingItBackLeavesNothingToApply() throws {
        let disk = try Fixtures.document()
        var draft = disk
        try draft.update(.contexts, originalName: "development", name: "development", fields: ["namespace": ""])
        try draft.update(.contexts, originalName: "development", name: "development", fields: ["namespace": "default"])
        XCTAssertEqual(draft.changes(from: disk).count, 0)
        XCTAssertTrue(draft.isEquivalent(to: disk))
    }

    func testValuesThatDifferByTypeStillCountAsChanges() throws {
        let number = try KubeDocument(yaml: "vendor: {port: 1}\n")
        let text = try KubeDocument(yaml: "vendor: {port: '1'}\n")
        XCTAssertFalse(number.isEquivalent(to: text))
    }

    func testRenamingTheActiveContextAlsoCountsTheActiveChange() throws {
        let disk = try Fixtures.document()
        var draft = disk
        try draft.update(.contexts, originalName: "development", name: "renamed", fields: [:])
        XCTAssertEqual(draft.currentContext, "renamed")
        XCTAssertEqual(draft.changes(from: disk).count, 2)
    }

    func testEmptyListsAndAnEmptyActiveContextMatchTheirAbsence() throws {
        let disk = try KubeDocument(yaml: "apiVersion: v1\nkind: Config\nclusters:\n- name: c\n  cluster: {server: 'https://c.invalid'}\n")
        var draft = disk
        try draft.update(.users, originalName: nil, name: "u", fields: [:])
        XCTAssertFalse(draft.isEquivalent(to: disk))
        try draft.delete(.users, name: "u")
        try draft.setCurrentContext("")
        XCTAssertNotEqual(draft, disk)
        XCTAssertTrue(draft.isEquivalent(to: disk))
        try draft.delete(.clusters, name: "c")
        XCTAssertFalse(draft.isEquivalent(to: disk))
    }

    func testRenameCountsOnceAndActiveContextCountsOnce() throws {
        let disk = try Fixtures.document()
        var draft = disk
        try draft.update(.clusters, originalName: "dev", name: "renamed", fields: [:])
        let changes = draft.changes(from: disk)
        XCTAssertEqual(changes.count(.clusters), 1)
        XCTAssertTrue(changes.contains(.contexts, name: "development"), "The context referencing a renamed cluster also changed")
        XCTAssertTrue(changes.activeContextChanged == false)
        try draft.setCurrentContext("")
        XCTAssertEqual(draft.changes(from: disk).count, 3)
    }

    func testOneRemovedEntryExplainsOnlyOneIdenticalNewEntry() throws {
        let disk = try KubeDocument(yaml: "clusters: [{name: a, cluster: {server: 'https://x.invalid'}}]\n")
        let draft = try KubeDocument(yaml: "clusters: [{name: b, cluster: {server: 'https://x.invalid'}}, {name: c, cluster: {server: 'https://x.invalid'}}]\n")
        XCTAssertEqual(draft.changes(from: disk).count(.clusters), 2, "One rename and one addition")
    }

    func testRenamingAndEditingAnEntryStillCountsAsTwo() throws {
        let disk = try Fixtures.document()
        var draft = disk
        try draft.update(.clusters, originalName: "dev", name: "renamed", fields: ["server": "https://other.invalid"])
        XCTAssertEqual(draft.changes(from: disk).count(.clusters), 2)
    }

    func testRemovedEntriesCountWithoutAppearingAsChanged() throws {
        let disk = try Fixtures.document()
        var draft = disk
        try draft.setCurrentContext("")
        try draft.delete(.contexts, name: "development")
        let changes = draft.changes(from: disk)
        XCTAssertEqual(changes.count(.contexts), 1)
        XCTAssertFalse(changes.contains(.contexts, name: "development"))
    }

    func testChangesWithoutAFileOnDiskTreatEveryEntryAsAdded() throws {
        XCTAssertEqual(try Fixtures.document().changes(from: nil).count, 4)
    }

    func testSyntaxErrorsCarryTheirLocationWithoutSourceText() {
        XCTAssertThrowsError(try KubeDocument(yaml: "clusters:\n  - name: 'open\ncontexts: [\n")) { error in
            guard case ConfigError.syntax(let line, _) = error else { return XCTFail("Expected a syntax error, got \(error)") }
            XCTAssertGreaterThan(line, 0)
            XCTAssertFalse(error.localizedDescription.contains("open"))
        }
    }
}

final class YAMLHighlighterTests: XCTestCase {
    private func pieces(_ text: String) -> [String] {
        let units = Array(text.utf16)
        return YAMLHighlighter.tokens(in: text).map { "\($0.kind):\(String(decoding: units[$0.range], as: UTF16.self))" }
    }

    func testKeysValuesAndSequenceMarkers() {
        XCTAssertEqual(pieces("- name: dev\n  retries: 3\n  enabled: true\n"), [
            "punctuation:-", "key:name", "punctuation::",
            "key:retries", "punctuation::", "number:3",
            "key:enabled", "punctuation::", "keyword:true",
        ])
    }

    func testURLsAreValuesNotKeys() {
        XCTAssertEqual(pieces("server: https://dev.invalid:6443\n"), ["key:server", "punctuation::"])
    }

    func testQuotedStringsAndComments() {
        XCTAssertEqual(pieces("# top\nlabel: \"a # b\" # note\n"), [
            "comment:# top", "key:label", "punctuation::", "string:\"a # b\"", "comment:# note",
        ])
    }

    func testBlockScalarContentIsNotReadAsKeys() {
        XCTAssertEqual(pieces("data: |\n  key: value\n  more: text\nnext: 1\n"), [
            "key:data", "punctuation::", "punctuation:|",
            "string:key: value", "string:more: text",
            "key:next", "punctuation::", "number:1",
        ])
    }

    func testBlockScalarAfterASequenceMarkerEndsAtItsSiblingKey() {
        XCTAssertEqual(pieces("- data: |\n    text\n  next: 1\n"), [
            "punctuation:-", "key:data", "punctuation::", "punctuation:|",
            "string:text",
            "key:next", "punctuation::", "number:1",
        ])
    }

    func testBlockScalarDirectlyUnderASequenceMarker() {
        XCTAssertEqual(pieces("- |\n  key: value\n- next: 1\n"), [
            "punctuation:-", "punctuation:|",
            "string:key: value",
            "punctuation:-", "key:next", "punctuation::", "number:1",
        ])
        XCTAssertEqual(pieces("- - |\n    text\n  - next: 1\n"), [
            "punctuation:-", "punctuation:-", "punctuation:|",
            "string:text",
            "punctuation:-", "key:next", "punctuation::", "number:1",
        ])
    }

    func testDocumentMarkersStandAloneAtTheFirstColumn() {
        XCTAssertEqual(pieces("--- \nkey: 1\n...\n"), ["punctuation:---", "key:key", "punctuation::", "number:1", "punctuation:..."])
        XCTAssertEqual(pieces("---x: 1\n"), ["key:---x", "punctuation::", "number:1"])
        XCTAssertEqual(pieces("  ---\n"), [])
    }

    func testCommentsAreNotReadAsKeys() {
        XCTAssertEqual(pieces("- # a: b\n"), ["punctuation:-", "comment:# a: b"])
        XCTAssertEqual(pieces("--- # a: b\n"), ["punctuation:---", "comment:# a: b"])
    }

    func testNanAndInfAreWordsWhileRealNumbersStayNumbers() {
        XCTAssertEqual(pieces("a: nan\nb: inf\nc: 1e3\nd: -2.5\n"), [
            "key:a", "punctuation::", "key:b", "punctuation::",
            "key:c", "punctuation::", "number:1e3", "key:d", "punctuation::", "number:-2.5",
        ])
    }

    func testCRLFLinesKeepTheirBreaksOutOfTokens() {
        XCTAssertEqual(pieces("# note\r\nkey: 1\r\n"), ["comment:# note", "key:key", "punctuation::", "number:1"])
    }

    func testFlowMappings() {
        XCTAssertEqual(pieces("cluster: {server: 'x', retries: 2}\n"), [
            "key:cluster", "punctuation::", "punctuation:{",
            "key:server", "punctuation::", "string:'x'", "punctuation:,",
            "key:retries", "punctuation::", "number:2", "punctuation:}",
        ])
    }

    func testOffsetsAreUTF16SoEmojiDoNotShiftLaterTokens() {
        XCTAssertEqual(pieces("note: 👋\nnext: 1\n").last, "number:1")
    }

    func testFlowSequencesAndEscapedQuotes() {
        XCTAssertEqual(pieces("args: [1, 'a', true] # note\n"), [
            "key:args", "punctuation::", "punctuation:[",
            "number:1", "punctuation:,", "string:'a'", "punctuation:,", "keyword:true", "punctuation:]",
            "comment:# note",
        ])
        XCTAssertEqual(pieces("a: \"x\\\"y\" # c\nb: 'it''s'\n"), [
            "key:a", "punctuation::", "string:\"x\\\"y\"", "comment:# c",
            "key:b", "punctuation::", "string:'it''s'",
        ])
    }

    func testTokensStayOrderedAndInBoundsOnArbitraryInput() {
        let pieces = ["a", " ", "  ", "\n", "\r\n", ":", ": ", "- ", "#", " #", "'", "\"", "\\", "|", ">", "{", "}", "[", "]", ",", "---", "...", "1", "true", "é", "😀", "~"]
        var state: UInt64 = 42
        for _ in 0..<2000 {
            var text = ""
            for _ in 0..<40 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                text += pieces[Int((state >> 33) % UInt64(pieces.count))]
            }
            var offset = 0
            for token in YAMLHighlighter.tokens(in: text) {
                XCTAssertFalse(token.range.isEmpty, text)
                XCTAssertGreaterThanOrEqual(token.range.lowerBound, offset, text)
                offset = token.range.upperBound
            }
            XCTAssertLessThanOrEqual(offset, text.utf16.count, text)
        }
    }

    func testUnfinishedInputDoesNotCrash() {
        for text in ["", "\n", "-", "'", "\"open", "a: '", "a: [", "key:", "- - -", "? x", "\r\n", "a: |"] {
            _ = YAMLHighlighter.tokens(in: text)
        }
    }
}
