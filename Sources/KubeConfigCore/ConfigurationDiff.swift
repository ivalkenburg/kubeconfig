import Foundation

public struct DiffLine: Identifiable, Equatable {
    public enum Change: String { case unchanged, removed, added }
    public let id: Int
    public let change: Change
    public let text: String
}

public enum ConfigurationDiff {
    /// Redact the parsed documents before generating the diff, including multiline keys and plugin arguments.
    public static func lines(before: String, after: KubeDocument, reveal: Bool = false) throws -> [DiffLine] {
        let old: String
        if reveal { old = before }
        else if let parsed = try? KubeDocument(yaml: before) { old = try parsed.serialized(revealingSecrets: false) }
        else { old = before.isEmpty ? "" : "‹Original file is invalid YAML. Reveal contents to inspect it.›" }
        let new = try reveal ? after.serialized() : after.redactedComparedTo(try? KubeDocument(yaml: before))
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
            if left < lhs.count && removals.contains(left) {
                result.append(DiffLine(id: result.count, change: .removed, text: lhs[left])); left += 1
            } else if right < rhs.count && insertions.contains(right) {
                result.append(DiffLine(id: result.count, change: .added, text: rhs[right])); right += 1
            } else if right < rhs.count {
                result.append(DiffLine(id: result.count, change: .unchanged, text: rhs[right])); left += 1; right += 1
            } else { left += 1 }
        }
        return result
    }
}
