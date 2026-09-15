import Foundation

/// A model release version such as `"2026.09.10-1"`.
///
/// Versions order numerically per dotted component — `"2026.09.9"` is older than
/// `"2026.09.10"`, which a plain string compare gets backwards — and a trailing
/// `-N` build suffix orders after the bare version (`"2026.09.10"` <
/// `"2026.09.10-1"` < `"2026.09.10-2"`), so a same-day hotfix re-release is
/// recognized as newer. Non-numeric components fall back to lexicographic order
/// rather than failing the comparison.
struct ModelVersion: Codable, Comparable, Hashable, Sendable {
    /// The version exactly as the manifest served it; kept so staged metadata
    /// round-trips byte-identically.
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: ModelVersion, rhs: ModelVersion) -> Bool {
        let left = parse(lhs.rawValue)
        let right = parse(rhs.rawValue)
        for (leftPart, rightPart) in zip(left.parts, right.parts) {
            guard leftPart != rightPart else { continue }
            if let leftNumber = Int(leftPart), let rightNumber = Int(rightPart) {
                return leftNumber < rightNumber
            }
            return leftPart < rightPart
        }
        // A version that is a strict prefix of another is older ("1.2" < "1.2.1").
        guard left.parts.count == right.parts.count else {
            return left.parts.count < right.parts.count
        }
        // A missing build suffix counts as build 0, so the bare version is
        // older than any same-day re-release.
        return (left.build ?? 0) < (right.build ?? 0)
    }

    /// Whether the version is well-formed dotted-numeric with an optional
    /// trailing `-N` build suffix (e.g. `"2026.09.10-1"`) — the only shape
    /// `<` orders predictably. A component counts as numeric exactly when the
    /// `<` implementation treats it numerically (`Int` parses it), so every
    /// version that passes this check compares without the lexicographic
    /// fallback. The service rejects malformed versions at
    /// manifest-validation time; without that gate a typo'd `"2026-09-10"`
    /// or `"v2"` would compare unpredictably against the bundled version
    /// and could pin clients to a staged file the version floor was meant
    /// to reject.
    var isWellFormed: Bool {
        var rest = rawValue[...]
        if let dash = rest.lastIndex(of: "-") {
            let suffix = rest[rest.index(after: dash)...]
            guard Self.isNumericComponent(suffix) else { return false }
            rest = rest[..<dash]
        }
        return rest.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy(Self.isNumericComponent)
    }

    private static func isNumericComponent(_ part: Substring) -> Bool {
        !part.isEmpty && Int(part) != nil
    }

    /// Splits `"2026.09.10-1"` into dotted parts `["2026", "09", "10"]` plus a
    /// build number. Only a trailing `-<digits>` is treated as a build suffix;
    /// anything else stays inside the dotted components it came with.
    private static func parse(_ rawValue: String) -> (parts: [String], build: Int?) {
        var rest = rawValue
        var build: Int?
        if let dash = rest.lastIndex(of: "-") {
            let suffix = rest[rest.index(after: dash)...]
            if let number = Int(suffix) {
                build = number
                rest = String(rest[..<dash])
            }
        }
        return (rest.split(separator: ".").map(String.init), build)
    }
}
