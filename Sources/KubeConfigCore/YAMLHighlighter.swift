import Foundation

/// A display-only tokenizer. It never decides what the YAML means; KubeDocument does that.
public enum YAMLHighlighter {
    public enum Kind { case key, punctuation, string, number, keyword, comment }

    public struct Token: Equatable {
        public let kind: Kind
        /// UTF-16 offsets, matching NSString ranges.
        public let range: Range<Int>
    }

    public static func tokens(in text: String) -> [Token] {
        var scanner = Scanner(units: Array(text.utf16))
        scanner.run()
        return scanner.tokens
    }

    private static let space = UInt16(UInt8(ascii: " ")), tab = UInt16(UInt8(ascii: "\t")), newline = UInt16(UInt8(ascii: "\n")), cr = UInt16(UInt8(ascii: "\r"))
    private static let hash = UInt16(UInt8(ascii: "#")), colon = UInt16(UInt8(ascii: ":")), dash = UInt16(UInt8(ascii: "-")), dot = UInt16(UInt8(ascii: "."))
    private static let single = UInt16(UInt8(ascii: "'")), double = UInt16(UInt8(ascii: "\"")), backslash = UInt16(UInt8(ascii: "\\"))
    private static let pipe = UInt16(UInt8(ascii: "|")), greater = UInt16(UInt8(ascii: ">"))
    private static let flowMarks = Set("{}[],".utf16)
    private static let keywords: Set = ["true", "false", "null", "yes", "no", "on", "off", "~"]

    private struct Scanner {
        let units: [UInt16]
        var tokens: [Token] = []
        /// Lines indented past this belong to a `|` or `>` block scalar.
        var blockIndent: Int?

        mutating func run() {
            var start = 0
            while start < units.count {
                var end = start
                while end < units.count, units[end] != newline { end += 1 }
                scanLine(start, end > start && units[end - 1] == cr ? end - 1 : end)
                start = end + 1
            }
        }

        private func isBlank(_ index: Int) -> Bool { units[index] == space || units[index] == tab }

        private func skipBlanks(_ index: Int, _ end: Int) -> Int {
            var index = index
            while index < end, isBlank(index) { index += 1 }
            return index
        }

        private mutating func add(_ kind: Kind, _ range: Range<Int>) {
            if !range.isEmpty { tokens.append(Token(kind: kind, range: range)) }
        }

        private mutating func scanLine(_ start: Int, _ end: Int) {
            var index = skipBlanks(start, end)
            if index == end { return }
            if let indent = blockIndent {
                if index - start > indent { add(.string, index..<end); return }
                blockIndent = nil
            }
            if units[index] == hash { add(.comment, index..<end); return }
            var indent = index - start
            if index == start, isDocumentMarker(index, end) {
                add(.punctuation, index..<index + 3)
                index = skipBlanks(index + 3, end)
            }
            while index < end, units[index] == dash, index + 1 == end || isBlank(index + 1) {
                add(.punctuation, index..<index + 1)
                indent = index - start
                index = skipBlanks(index + 1, end)
            }
            if index == end { return }
            if let keyEnd = keyEnd(index, end) {
                indent = index - start
                add(.key, index..<keyEnd)
                add(.punctuation, keyEnd..<keyEnd + 1)
                index = skipBlanks(keyEnd + 1, end)
            }
            scanValue(index, end, indent: indent)
        }

        private func isDocumentMarker(_ index: Int, _ end: Int) -> Bool {
            guard end - index >= 3, index + 3 == end || isBlank(index + 3) else { return false }
            let marker = units[index..<index + 3]
            return marker.elementsEqual("---".utf16) || marker.elementsEqual("...".utf16)
        }

        /// The offset of the colon ending a key on this line, if there is one.
        private func keyEnd(_ start: Int, _ end: Int) -> Int? {
            var index = start
            if units[index] == single || units[index] == double {
                index = closingQuote(index, end)
                index = skipBlanks(index, end)
                return index < end && units[index] == colon ? index : nil
            }
            if flowMarks.contains(units[index]) { return nil }
            while index < end {
                if units[index] == colon, index + 1 == end || isBlank(index + 1) { return index }
                if units[index] == hash, index == start || isBlank(index - 1) { return nil }
                index += 1
            }
            return nil
        }

        /// The offset just past a quoted scalar's closing quote, or `end` when it stays open.
        private func closingQuote(_ start: Int, _ end: Int) -> Int {
            let quote = units[start]
            var index = start + 1
            while index < end {
                if quote == double, units[index] == backslash { index += 2; continue }
                if units[index] == quote {
                    if quote == single, index + 1 < end, units[index + 1] == single { index += 2; continue }
                    return index + 1
                }
                index += 1
            }
            return end
        }

        private mutating func scanValue(_ start: Int, _ end: Int, indent: Int) {
            guard start < end else { return }
            if units[start] == hash { add(.comment, start..<end); return }
            if units[start] == pipe || units[start] == greater {
                add(.punctuation, start..<start + 1)
                blockIndent = indent
                return
            }
            var index = start
            if units[index] == single || units[index] == double {
                index = closingQuote(index, end)
                add(.string, start..<index)
            } else if flowMarks.contains(units[index]) {
                scanFlow(index, end)
                return
            } else {
                while index < end, !(units[index] == hash && isBlank(index - 1)) { index += 1 }
                var trimmed = index
                while trimmed > start, isBlank(trimmed - 1) { trimmed -= 1 }
                addPlain(start..<trimmed)
            }
            index = skipBlanks(index, end)
            if index < end, units[index] == hash { add(.comment, index..<end) }
        }

        private mutating func scanFlow(_ start: Int, _ end: Int) {
            var index = start
            while index < end {
                let unit = units[index]
                if isBlank(index) { index += 1 }
                else if flowMarks.contains(unit) || unit == colon { add(.punctuation, index..<index + 1); index += 1 }
                else if unit == hash, index > start, isBlank(index - 1) { add(.comment, index..<end); return }
                else {
                    let quoted = unit == single || unit == double
                    var wordEnd = quoted ? closingQuote(index, end) : index
                    if !quoted {
                        while wordEnd < end, !flowMarks.contains(units[wordEnd]), !(units[wordEnd] == colon && (wordEnd + 1 == end || isBlank(wordEnd + 1))) { wordEnd += 1 }
                        while wordEnd > index, isBlank(wordEnd - 1) { wordEnd -= 1 }
                    }
                    let next = skipBlanks(wordEnd, end)
                    if next < end, units[next] == colon { add(.key, index..<wordEnd) }
                    else if quoted { add(.string, index..<wordEnd) }
                    else { addPlain(index..<wordEnd) }
                    index = max(wordEnd, index + 1)
                }
            }
        }

        private mutating func addPlain(_ range: Range<Int>) {
            let word = String(decoding: units[range], as: UTF16.self)
            if keywords.contains(word.lowercased()) { add(.keyword, range) }
            else if Double(word)?.isFinite == true { add(.number, range) }
        }
    }
}
