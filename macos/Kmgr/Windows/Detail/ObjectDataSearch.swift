import Foundation
import KmgrCore

/// Bounded, transient text matching for the ConfigMap/Secret Data surface.
/// Callers decide whether Secret bytes are authorized before passing them in.
/// Matches and snippets must remain inside the active Data controller.
struct ObjectDataTextSearchMatch: Equatable, Sendable {
    var snippet: String
}

enum ObjectDataTextSearch {
    static let maximumQueryCharacters = 1_024
    static let maximumQueryUTF8Bytes = 4_096
    private static let leadingContextCharacters = 48
    private static let trailingContextCharacters = 96

    static func normalizedQuery(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var result = String()
        result.reserveCapacity(min(trimmed.utf8.count, maximumQueryUTF8Bytes))
        var characterCount = 0
        var byteCount = 0
        for character in trimmed {
            let characterBytes = character.utf8.count
            guard characterCount < maximumQueryCharacters,
                byteCount + characterBytes <= maximumQueryUTF8Bytes
            else { break }
            result.append(character)
            characterCount += 1
            byteCount += characterBytes
        }
        return result
    }

    static func contains(_ value: String, query: String) -> Bool {
        value.range(of: query, options: searchOptions) != nil
    }

    static func match(in value: Data, query: String) -> ObjectDataTextSearchMatch? {
        guard let text = String(data: value, encoding: .utf8), !text.contains("\0") else {
            return nil
        }
        return match(in: text, query: query)
    }

    static func match(in text: String, query: String) -> ObjectDataTextSearchMatch? {
        guard !query.isEmpty,
            let match = text.range(of: query, options: searchOptions)
        else { return nil }

        let start = text.index(
            match.lowerBound,
            offsetBy: -leadingContextCharacters,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        let end = text.index(
            match.upperBound,
            offsetBy: trailingContextCharacters,
            limitedBy: text.endIndex
        ) ?? text.endIndex

        var snippet = String()
        if start != text.startIndex { snippet.append("…") }
        snippet.append(contentsOf: text[start..<end])
        if end != text.endIndex { snippet.append("…") }

        // Reuse the table preview's normalization and two-dimensional bounds.
        // This prevents a match beside a huge line or combining-mark cluster
        // from producing an unbounded AppKit cell or accessibility value.
        let presentation = DataValuePreviewPresentation(
            kind: .text,
            value: Data(snippet.utf8),
            secret: false
        )
        return ObjectDataTextSearchMatch(snippet: presentation.displayText)
    }

    private static let searchOptions: String.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive, .widthInsensitive,
    ]
}
