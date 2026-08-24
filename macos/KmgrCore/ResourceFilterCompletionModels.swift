import Foundation

/// A bounded, UI-only completion catalog for the visible resource query.
///
/// Completion intentionally knows only about query syntax and the currently
/// projected column IDs. It never inspects rows or contacts the engine. The
/// backend remains the authority for parsing and validating the completed
/// expression.
public enum ResourceFilterCompletionCatalog {
    /// Keep the completion panel useful even when a view has many columns or
    /// a pasted query is unusually long.
    public static let maximumResults = 64
    public static let maximumExpressionUTF16Length = 65_536
    /// These mirror the bounded column projection limits. The completion
    /// catalog keeps its own nonisolated constants so it can run directly from
    /// AppKit's delegate callback and from pure model tests.
    private static let maximumColumnCount = 64
    private static let maximumColumnIDUTF8Bytes = 128

    /// The order is also the order shown by AppKit when several prefixes match
    /// the same partial text.
    public static let reservedPrefixes: [String] = [
        "namespace:", "name:", "ns:", "status:", "label:", "field:",
        "labelSelector:", "fieldSelector:", "column:",
    ]

    private enum CandidateKind {
        case reserved
        case shorthandColumn
        case explicitColumn
    }

    private struct Candidate {
        var token: String
        var kind: CandidateKind
    }

    private struct TokenSpan {
        var range: Range<String.Index>
        var text: String
        var malformed: Bool
    }

    private struct CompletionContext {
        var token: TokenSpan
        var tokenRelativePartialStart: Int
        var typedPrefix: String
    }

    /// Returns replacement strings for AppKit's
    /// `control(_:textView:completions:forPartialWordRange:indexOfSelectedItem:)`
    /// delegate method. Each returned string replaces only `partialWordRange`;
    /// text before and after that range is left untouched by AppKit.
    public static func completions(
        in expression: String,
        partialWordRange: NSRange,
        columnIDs: [String] = []
    ) -> [String] {
        guard expression.utf16.count <= maximumExpressionUTF16Length,
            let context = completionContext(
                in: expression,
                partialWordRange: partialWordRange
            )
        else { return [] }

        let candidates = candidates(
            for: context,
            columnIDs: columnIDs
        )
        var result: [String] = []
        result.reserveCapacity(min(candidates.count, maximumResults))
        var seen: Set<String> = []
        for candidate in candidates {
            guard matches(candidate, context: context),
                let replacement = replacement(
                    for: candidate,
                    context: context
                ),
                !replacement.isEmpty,
                seen.insert(replacement).inserted
            else { continue }
            result.append(replacement)
            if result.count == maximumResults { break }
        }
        return result
    }

    private static func candidates(
        for context: CompletionContext,
        columnIDs: [String]
    ) -> [Candidate] {
        let token = context.token.text
        let typedPrefix = context.typedPrefix

        // Native selector bodies are deliberately opaque. Prefixes themselves
        // remain completable until the trailing colon is present, but values
        // inside `labelSelector:` and `fieldSelector:` are never suggested.
        if let nativePrefixEnd = nativeSelectorPrefixEnd(in: token),
            typedPrefix.utf16.count > nativePrefixEnd
        {
            return []
        }

        let uniqueColumnIDs = uniqueSafeColumnIDs(columnIDs)
        let firstColon = token.firstIndex(of: ":")
        if let firstColon {
            let prefix = String(token[..<firstColon])
            let lowerPrefix = prefix.lowercased()

            if lowerPrefix == "column" {
                // `column:<id>:` is the unambiguous spelling and is the only
                // way to address IDs that collide with reserved prefixes.
                // Values after the completed ID are intentionally not offered.
                guard !isCompletedExplicitColumnToken(token, columnIDs: uniqueColumnIDs)
                else { return [] }
                return uniqueColumnIDs.map {
                    Candidate(token: "column:\($0):", kind: .explicitColumn)
                }
            }

            if isReservedPrefix(lowerPrefix) {
                // Local selector values are deliberately outside this first
                // completion pass. In particular, do not offer text after
                // name:, field:, or labelSelector:.
                return []
            }

            guard !isCompletedShorthandColumnToken(
                token,
                columnIDs: uniqueColumnIDs
            ) else { return [] }

            // A colon can be part of a custom column ID. Offer shorthand IDs
            // only while the user is still completing that ID; once the exact
            // ID and its delimiter are present, the following text is a value.
            return uniqueColumnIDs
                .filter { isShorthandColumnID($0) }
                .map { Candidate(token: "\($0):", kind: .shorthandColumn) }
        }

        // Without a colon, complete reserved prefixes and shorthand column
        // IDs. Explicit `column:<id>:` candidates are intentionally deferred
        // until the user has typed `column:` so a bare `c` stays readable.
        let reserved = reservedPrefixes.map {
            Candidate(token: $0, kind: .reserved)
        }
        let shorthand = uniqueColumnIDs
            .filter { isShorthandColumnID($0) }
            .map { Candidate(token: "\($0):", kind: .shorthandColumn) }
        return reserved + shorthand
    }

    private static func matches(
        _ candidate: Candidate,
        context: CompletionContext
    ) -> Bool {
        let typed = context.typedPrefix
        guard !typed.isEmpty else {
            // An empty range is useful immediately after `column:`. It is not
            // useful for the first token because showing every prefix before a
            // character is distracting.
            return candidate.kind == .explicitColumn
                && typedColumnPrefix(in: context.token.text) != nil
        }

        switch candidate.kind {
        case .reserved:
            return candidate.token.lowercased().hasPrefix(typed.lowercased())
        case .shorthandColumn:
            return candidate.token.hasPrefix(typed)
        case .explicitColumn:
            guard let separator = candidate.token.firstIndex(of: ":") else {
                return false
            }
            let typedSeparator = typed.firstIndex(of: ":")
            guard let typedSeparator else {
                return candidate.token.lowercased().hasPrefix(typed.lowercased())
            }
            let typedPrefix = String(typed[..<typedSeparator])
            guard typedPrefix.lowercased() == "column" else { return false }
            let typedID = String(typed[typed.index(after: typedSeparator)...])
            let candidateIDStart = candidate.token.index(after: separator)
            let candidateID = String(candidate.token[candidateIDStart...])
            // The ID is a protocol identity and is case-sensitive. The final
            // delimiter is part of the candidate but not a value completion.
            return candidateID.hasPrefix(typedID)
        }
    }

    private static func replacement(
        for candidate: Candidate,
        context: CompletionContext
    ) -> String? {
        let offset = context.tokenRelativePartialStart
        let candidateUTF16 = candidate.token.utf16
        guard offset <= candidateUTF16.count else { return nil }
        let start = candidateUTF16.index(candidateUTF16.startIndex, offsetBy: offset)
        return String(candidateUTF16[start...])
    }

    private static func completionContext(
        in expression: String,
        partialWordRange: NSRange
    ) -> CompletionContext? {
        let expressionUTF16Count = expression.utf16.count
        guard partialWordRange.location != NSNotFound,
            partialWordRange.location >= 0,
            partialWordRange.length >= 0,
            partialWordRange.location <= expressionUTF16Count,
            partialWordRange.length <= expressionUTF16Count - partialWordRange.location,
            let partialRange = Range(partialWordRange, in: expression),
            String(expression[partialRange]).utf16.count == partialWordRange.length
        else { return nil }

        let spans = tokenize(expression)
        guard let token = spans.first(where: { span in
            let range = NSRange(span.range, in: expression)
            return partialWordRange.location >= range.location
                && NSMaxRange(partialWordRange) <= NSMaxRange(range)
        }), !token.malformed
        else { return nil }

        let tokenRange = NSRange(token.range, in: expression)
        guard String(expression[token.range]).utf16.count == tokenRange.length else {
            return nil
        }
        let relativeStart = partialWordRange.location - tokenRange.location
        if partialWordRange.length == 0,
            !token.text.hasSuffix(":")
        {
            // AppKit normally reports the whole bare word as the partial
            // range. An empty range is meaningful here only immediately after
            // a delimiter, where a column ID may still be completed.
            return nil
        }
        let tokenUTF16 = token.text.utf16
        guard relativeStart >= 0,
            relativeStart <= tokenUTF16.count,
            partialWordRange.length <= tokenUTF16.count - relativeStart,
            let partialStart = token.text.utf16.index(
                token.text.utf16.startIndex,
                offsetBy: relativeStart,
                limitedBy: token.text.utf16.endIndex
            ),
            let partialEnd = token.text.utf16.index(
                partialStart,
                offsetBy: partialWordRange.length,
                limitedBy: token.text.utf16.endIndex
            )
        else { return nil }

        let typedPrefix = String(
            decoding: token.text.utf16[..<partialEnd],
            as: Unicode.UTF16.self
        )
        let partial = String(
            decoding: token.text.utf16[partialStart..<partialEnd],
            as: Unicode.UTF16.self
        )
        let suffix = String(
            decoding: token.text.utf16[partialEnd...],
            as: Unicode.UTF16.self
        )
        guard suffix.isEmpty,
            !typedPrefix.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            !partial.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }

        // Quotes and escapes have semantics owned by the query lexer. This
        // completion pass only edits simple unquoted syntax tokens.
        guard !token.text.contains("\\"),
            !token.text.contains("\""),
            !token.text.contains("'")
        else {
            // Quoted and escaped tokens are intentionally left to the query
            // lexer rather than guessed at by this lightweight completer.
            return nil
        }

        return CompletionContext(
            token: token,
            tokenRelativePartialStart: relativeStart,
            typedPrefix: typedPrefix
        )
    }

    private static func tokenize(_ expression: String) -> [TokenSpan] {
        var result: [TokenSpan] = []
        var index = expression.startIndex
        while index < expression.endIndex {
            while index < expression.endIndex && expression[index].isWhitespace {
                index = expression.index(after: index)
            }
            guard index < expression.endIndex else { break }

            let start = index
            var quote: Character?
            var escaped = false
            var malformed = false
            while index < expression.endIndex {
                let character = expression[index]
                if escaped {
                    escaped = false
                    index = expression.index(after: index)
                    continue
                }
                if character == "\\" {
                    escaped = true
                    index = expression.index(after: index)
                    continue
                }
                if let activeQuote = quote {
                    if character == activeQuote {
                        quote = nil
                    }
                    index = expression.index(after: index)
                    continue
                }
                if character == "\"" || character == "'" {
                    quote = character
                    index = expression.index(after: index)
                    continue
                }
                if character.isWhitespace { break }
                index = expression.index(after: index)
            }
            if quote != nil || escaped { malformed = true }
            let end = index
            result.append(TokenSpan(
                range: start..<end,
                text: String(expression[start..<end]),
                malformed: malformed
            ))
        }
        return result
    }

    private static func nativeSelectorPrefixEnd(in token: String) -> Int? {
        for prefix in ["labelselector:", "fieldselector:"] {
            guard token.count >= prefix.count else { continue }
            let candidate = token.prefix(prefix.count)
            if candidate.lowercased() == prefix {
                return prefix.utf16.count
            }
        }
        return nil
    }

    private static func typedColumnPrefix(in token: String) -> String? {
        guard let separator = token.firstIndex(of: ":"),
            token[..<separator].lowercased() == "column"
        else { return nil }
        return String(token[..<separator])
    }

    private static func isCompletedExplicitColumnToken(
        _ token: String,
        columnIDs: [String]
    ) -> Bool {
        guard let separator = token.firstIndex(of: ":"),
            token[..<separator].lowercased() == "column"
        else { return false }
        let body = token[token.index(after: separator)...]
        return columnIDs.contains { body == "\($0):" }
    }

    private static func isCompletedShorthandColumnToken(
        _ token: String,
        columnIDs: [String]
    ) -> Bool {
        columnIDs.contains { isShorthandColumnID($0) && token == "\($0):" }
    }

    private static func uniqueSafeColumnIDs(_ columnIDs: [String]) -> [String] {
        var result: [String] = []
        result.reserveCapacity(min(columnIDs.count, maximumColumnCount))
        var seen: Set<String> = []
        for id in columnIDs {
            guard seen.insert(id).inserted,
                isSafeColumnID(id)
            else { continue }
            result.append(id)
            if result.count == maximumColumnCount { break }
        }
        return result
    }

    private static func isSafeColumnID(_ id: String) -> Bool {
        guard !id.isEmpty,
            id.utf8.count <= maximumColumnIDUTF8Bytes,
            !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            !id.contains(where: \.isWhitespace)
        else { return false }
        return !id.contains("\\") && !id.contains("\"") && !id.contains("'")
    }

    private static func isReservedPrefix(_ prefix: String) -> Bool {
        let normalized = prefix.lowercased()
        return reservedPrefixes.contains { candidate in
            candidate.dropLast().lowercased() == normalized
        }
    }

    private static func isShorthandColumnID(_ id: String) -> Bool {
        guard let separator = id.firstIndex(of: ":") else {
            return !isReservedPrefix(id)
        }
        let firstComponent = String(id[..<separator])
        return !isReservedPrefix(firstComponent)
    }
}
