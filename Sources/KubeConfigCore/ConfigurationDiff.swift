import Foundation

public struct DiffLine: Identifiable, Equatable {
    public enum Change { case unchanged, removed, added }
    public let id: Int
    public let change: Change
    public let text: String
}

public enum ConfigurationDiff {
    /// Compares serialized documents, so formatting alone doesn't bury the real changes.
    public static func lines(before: String, after: KubeDocument) throws -> [DiffLine] {
        let old = try (try? KubeDocument(yaml: before))?.serialized() ?? before
        let new = try after.serialized()
        let lhs = old.components(separatedBy: "\n")
        let rhs = new.components(separatedBy: "\n")
        let difference = rhs.difference(from: lhs)
        var removals = Set<Int>(), insertions = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }
        var result: [DiffLine] = [], left = 0, right = 0
        while left < lhs.count || right < rhs.count {
            if removals.contains(left) {
                result.append(DiffLine(id: result.count, change: .removed, text: lhs[left])); left += 1
            } else if insertions.contains(right) {
                result.append(DiffLine(id: result.count, change: .added, text: rhs[right])); right += 1
            } else {
                result.append(DiffLine(id: result.count, change: .unchanged, text: rhs[right])); left += 1; right += 1
            }
        }
        return result
    }

    /// How many changes Review steps through, so Apply can name the same number.
    public static func changeCount(before: String, after: KubeDocument) throws -> Int {
        changes(in: try lines(before: before, after: after)).count
    }

    /// Runs of changed lines, as offsets into `lines`.
    public static func changes(in lines: [DiffLine]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for (index, line) in lines.enumerated() {
            if line.change == .unchanged {
                if let open = start { runs.append(open..<index); start = nil }
            } else if start == nil { start = index }
        }
        if let open = start { runs.append(open..<lines.count) }
        return runs
    }
}
