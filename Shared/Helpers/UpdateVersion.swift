import Foundation

/// Pure dotted-version comparison for release tags ("v5.9.0") against the
/// bundle's short version ("5.8.0"). No I/O.
enum UpdateVersion {
    /// Numeric per-component parse: strips one leading "v"/"V", splits on "."
    /// and reads each component's leading digits ("9-rc1" -> 9, "abc" -> 0).
    static func components(_ version: String) -> [Int] {
        normalized(version)
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    /// True when `candidate` is strictly newer than `current`. Missing
    /// components count as 0, so "5.9" equals "5.9.0".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        var lhs = components(candidate)
        var rhs = components(current)
        let width = max(lhs.count, rhs.count)
        lhs.append(contentsOf: repeatElement(0, count: width - lhs.count))
        rhs.append(contentsOf: repeatElement(0, count: width - rhs.count))
        for (l, r) in zip(lhs, rhs) where l != r {
            return l > r
        }
        return false
    }

    /// Display form: whitespace-trimmed, a single leading "v"/"V" stripped.
    static func normalized(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }
}
