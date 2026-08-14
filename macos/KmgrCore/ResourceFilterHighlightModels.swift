import Foundation

/// A deliberately narrow visual hint for filters whose matching semantics are
/// obvious from the compact expression. Complex structured filters remain
/// unstyled rather than implying that one displayed substring explains why a
/// row matched.
public struct ResourceFilterHighlight: Hashable, Sendable {
    public var term: String
    /// `nil` means the bare term can be emphasized in any visible cell.
    public var columnID: String?

    public init(term: String, columnID: String?) {
        self.term = term
        self.columnID = columnID
    }

    public func applies(to columnID: String) -> Bool {
        self.columnID == nil || self.columnID == columnID
    }
}

public enum ResourceFilterHighlightParser {
    public static let maximumTermUTF8Bytes = 253

    public static func parse(_ expression: String) -> ResourceFilterHighlight? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            trimmed.utf8.count <= maximumTermUTF8Bytes,
            !trimmed.contains(where: { $0.isWhitespace }),
            !trimmed.contains("\\"),
            !trimmed.contains("\""),
            !trimmed.contains("'"),
            !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }

        guard let separator = trimmed.firstIndex(of: ":") else {
            return ResourceFilterHighlight(term: trimmed, columnID: nil)
        }
        let prefix = trimmed[..<separator].lowercased()
        let value = String(trimmed[trimmed.index(after: separator)...])
        guard prefix == "name", !value.isEmpty, !value.contains("=") else { return nil }
        return ResourceFilterHighlight(term: value, columnID: "name")
    }
}
