import Foundation

/// One text-bearing part of the visible resource query that can be emphasized
/// in a rendered table cell. A nil column ID means the term is global bare
/// text; otherwise the term applies only to the named projected column.
public struct ResourceFilterHighlight: Hashable, Sendable {
    public var term: String
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
    /// Keep per-cell matching bounded even if a user pastes a very large
    /// expression into the query field. The backend still remains the
    /// authority for query validity and matching semantics.
    public static let maximumTermUTF8Bytes = 253
    public static let maximumHighlightTerms = 32

    private struct Token {
        var text: String
        var isNativeSelector: Bool
    }

    private static let reservedPrefixes: Set<String> = [
        "namespace", "ns", "name", "status", "label", "field",
        "labelselector", "fieldselector", "column",
    ]

    /// Extracts only text-bearing terms from the complete visible query.
    /// Native Kubernetes selector clauses are deliberately skipped: their
    /// syntax constrains rows but is not itself a displayed search string.
    public static func parse(
        _ expression: String,
        columnIDs: [String] = []
    ) -> [ResourceFilterHighlight] {
        guard let tokens = tokenize(expression) else { return [] }
        let uniqueColumnIDs = Array(Set(columnIDs))
        let shorthandColumnIDs = uniqueColumnIDs.filter {
            isShorthandColumnID($0)
        }

        var result: [ResourceFilterHighlight] = []
        result.reserveCapacity(min(tokens.count, maximumHighlightTerms))
        for token in tokens where result.count < maximumHighlightTerms {
            guard !token.isNativeSelector,
                let highlight = highlight(
                    for: token.text,
                    columnIDs: uniqueColumnIDs,
                    shorthandColumnIDs: shorthandColumnIDs
                )
            else { continue }
            guard !result.contains(highlight) else { continue }
            result.append(highlight)
        }
        return result
    }

    private static func highlight(
        for token: String,
        columnIDs: [String],
        shorthandColumnIDs: [String]
    ) -> ResourceFilterHighlight? {
        guard let separator = token.firstIndex(of: ":") else {
            return makeHighlight(term: token, columnID: nil)
        }

        let prefix = String(token[..<separator])
        let body = String(token[token.index(after: separator)...])
        guard !body.isEmpty else { return nil }
        switch prefix.lowercased() {
        case "name":
            return makeHighlight(term: body, columnID: "name")
        case "namespace", "ns":
            return makeHighlight(term: body, columnID: "namespace")
        case "status":
            return makeHighlight(term: body, columnID: "status")
        case "label", "field", "labelselector", "fieldselector":
            // These predicates either address object metadata that may not be
            // rendered in a matching column or contain Kubernetes syntax. A
            // user can target a rendered value explicitly with column:<id>.
            return nil
        case "column":
            guard let match = matchColumnPrefix(body, in: columnIDs) else {
                return nil
            }
            return makeHighlight(term: match.value, columnID: match.id)
        default:
            guard let match = matchColumnPrefix(token, in: shorthandColumnIDs)
            else { return nil }
            return makeHighlight(term: match.value, columnID: match.id)
        }
    }

    private static func makeHighlight(
        term: String,
        columnID: String?
    ) -> ResourceFilterHighlight? {
        guard !term.isEmpty,
            term.utf8.count <= maximumTermUTF8Bytes,
            !term.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            !term.allSatisfy(\.isWhitespace)
        else { return nil }
        return ResourceFilterHighlight(term: term, columnID: columnID)
    }

    private static func matchColumnPrefix(
        _ value: String,
        in columnIDs: [String]
    ) -> (id: String, value: String)? {
        // Longest IDs win so IDs containing ':' remain addressable when a
        // shorter ID shares their prefix. IDs are protocol identities and are
        // therefore matched case-sensitively.
        let ordered = columnIDs.sorted {
            if $0.utf8.count != $1.utf8.count {
                return $0.utf8.count > $1.utf8.count
            }
            return $0 < $1
        }
        for id in ordered {
            let prefix = id + ":"
            guard value.hasPrefix(prefix) else { continue }
            return (id, String(value.dropFirst(prefix.count)))
        }
        return nil
    }

    private static func isShorthandColumnID(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        let firstComponent = id.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? id
        return !reservedPrefixes.contains(firstComponent.lowercased())
    }

    private static func tokenize(_ expression: String) -> [Token]? {
        let characters = Array(expression)
        var tokens: [Token] = []
        var index = 0

        while index < characters.count {
            while index < characters.count && characters[index].isWhitespace {
                index += 1
            }
            guard index < characters.count else { break }

            let nativeSelector = isNativeSelector(
                characters,
                startingAt: index
            )
            var builder = String()
            var quote: Character?

            while index < characters.count {
                let character = characters[index]
                if quote == nil && character.isWhitespace {
                    break
                }

                if nativeSelector {
                    // Preserve Kubernetes' own escapes byte-for-byte. The
                    // token is not highlighted, but retaining its grouping
                    // prevents an escaped quote/space from corrupting the
                    // following keyword token.
                    if character == "\\" {
                        builder.append(character)
                        index += 1
                        guard index < characters.count else { return nil }
                        builder.append(characters[index])
                        index += 1
                        continue
                    }
                    if character == "'" || character == "\"" {
                        if quote == nil {
                            quote = character
                            index += 1
                            continue
                        }
                        if quote == character {
                            quote = nil
                            index += 1
                            continue
                        }
                    }
                    builder.append(character)
                    index += 1
                    continue
                }

                if character == "\\" {
                    index += 1
                    guard index < characters.count else { return nil }
                    builder.append(characters[index])
                    index += 1
                    continue
                }
                if character == "'" || character == "\"" {
                    if quote == nil {
                        quote = character
                        index += 1
                        continue
                    }
                    if quote == character {
                        quote = nil
                        index += 1
                        continue
                    }
                }
                builder.append(character)
                index += 1
            }

            guard quote == nil else { return nil }
            if !builder.isEmpty {
                tokens.append(Token(text: builder, isNativeSelector: nativeSelector))
            }
        }
        return tokens
    }

    private static func isNativeSelector(
        _ characters: [Character],
        startingAt index: Int
    ) -> Bool {
        let remainder = String(characters[index...]).lowercased()
        return remainder.hasPrefix("labelselector:") ||
            remainder.hasPrefix("fieldselector:")
    }
}
