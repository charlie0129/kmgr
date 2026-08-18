import AppKit

enum YAMLSyntaxTokenKind: Equatable {
    case key
    case string
    case number
    case keyword
    case comment
}

struct YAMLSyntaxToken: Equatable {
    let kind: YAMLSyntaxTokenKind
    let range: NSRange
}

/// A deliberately small YAML lexer for presentation, not validation.
///
/// It recognizes the common block-mapping syntax emitted for Kubernetes
/// objects. Ambiguous or uncommon YAML remains ordinary text instead of
/// pulling a complete parser into the editing path.
enum YAMLSyntaxLexer {
    static func tokens(in source: NSString, range requestedRange: NSRange) -> [YAMLSyntaxToken] {
        var result: [YAMLSyntaxToken] = []
        enumerateTokens(in: source, range: requestedRange) { result.append($0) }
        return result
    }

    static func enumerateTokens(
        in string: NSString,
        range requestedRange: NSRange,
        _ body: (YAMLSyntaxToken) -> Void
    ) {
        guard requestedRange.length > 0, requestedRange.location < string.length else { return }
        let clippedRange = NSRange(
            location: requestedRange.location,
            length: min(requestedRange.length, string.length - requestedRange.location)
        )
        // One bounded bulk copy is much cheaper than crossing into NSString
        // for every character while typing.
        let source = CharacterBuffer(copying: string, range: clippedRange)
        let end = NSMaxRange(clippedRange)
        var lineStart = requestedRange.location

        while lineStart < end {
            var lineEnd = lineStart
            while lineEnd < end {
                let character = source.character(at: lineEnd)
                if character == Self.lineFeed || character == Self.carriageReturn { break }
                lineEnd += 1
            }
            enumerateLine(in: source, start: lineStart, end: lineEnd, body)

            guard lineEnd < end else { break }
            if source.character(at: lineEnd) == carriageReturn,
                lineEnd + 1 < end,
                source.character(at: lineEnd + 1) == lineFeed
            {
                lineStart = lineEnd + 2
            } else {
                lineStart = lineEnd + 1
            }
        }
    }

    private struct Mapping {
        let keyRange: NSRange
        let colon: Int
    }

    private struct CharacterBuffer {
        let baseLocation: Int
        let characters: [unichar]

        init(copying source: NSString, range: NSRange) {
            baseLocation = range.location
            var characters = [unichar](repeating: 0, count: range.length)
            source.getCharacters(&characters, range: range)
            self.characters = characters
        }

        @inline(__always)
        func character(at location: Int) -> unichar {
            characters[location - baseLocation]
        }
    }

    private static let lineFeed: unichar = 0x0A
    private static let carriageReturn: unichar = 0x0D
    private static let tab: unichar = 0x09
    private static let space: unichar = 0x20
    private static let numberSign: unichar = 0x23
    private static let singleQuote: unichar = 0x27
    private static let doubleQuote: unichar = 0x22
    private static let backslash: unichar = 0x5C

    private static func enumerateLine(
        in source: CharacterBuffer,
        start lineStart: Int,
        end lineEnd: Int,
        _ body: (YAMLSyntaxToken) -> Void
    ) {
        var contentStart = lineStart
        while contentStart < lineEnd, isHorizontalSpace(source.character(at: contentStart)) {
            contentStart += 1
        }
        if contentStart + 1 < lineEnd,
            source.character(at: contentStart) == 0x2D,
            isHorizontalSpace(source.character(at: contentStart + 1))
        {
            contentStart += 2
            while contentStart < lineEnd,
                isHorizontalSpace(source.character(at: contentStart))
            {
                contentStart += 1
            }
        }
        guard contentStart < lineEnd else { return }

        if isDocumentMarker(in: source, start: contentStart, end: lineEnd) { return }

        let mapping = mapping(in: source, start: contentStart, end: lineEnd)
        if let mapping {
            body(YAMLSyntaxToken(kind: .key, range: mapping.keyRange))
        }
        enumerateValues(
            in: source,
            start: mapping.map { $0.colon + 1 } ?? contentStart,
            end: lineEnd,
            body
        )
    }

    private static func mapping(in source: CharacterBuffer, start: Int, end: Int) -> Mapping? {
        var index = start
        var quote: unichar?

        while index < end {
            let character = source.character(at: index)
            if let activeQuote = quote {
                if activeQuote == doubleQuote, character == backslash {
                    index = min(end, index + 2)
                    continue
                }
                if character == activeQuote {
                    if activeQuote == singleQuote,
                        index + 1 < end,
                        source.character(at: index + 1) == singleQuote
                    {
                        index += 2
                        continue
                    }
                    quote = nil
                }
                index += 1
                continue
            }

            if character == singleQuote || character == doubleQuote {
                quote = character
                index += 1
                continue
            }
            if character == numberSign, isCommentStart(in: source, at: index, lineStart: start) {
                return nil
            }
            if character == 0x3A, isMappingSeparator(in: source, after: index, end: end) {
                var keyEnd = index
                while keyEnd > start, isHorizontalSpace(source.character(at: keyEnd - 1)) {
                    keyEnd -= 1
                }
                guard keyEnd > start else { return nil }
                return Mapping(
                    keyRange: NSRange(location: start, length: keyEnd - start),
                    colon: index
                )
            }
            index += 1
        }
        return nil
    }

    private static func enumerateValues(
        in source: CharacterBuffer,
        start: Int,
        end: Int,
        _ body: (YAMLSyntaxToken) -> Void
    ) {
        var index = start
        while index < end {
            let character = source.character(at: index)
            if isHorizontalSpace(character) || isFlowPunctuation(character) {
                index += 1
                continue
            }
            if character == numberSign, isCommentStart(in: source, at: index, lineStart: start) {
                body(YAMLSyntaxToken(
                    kind: .comment,
                    range: NSRange(location: index, length: end - index)
                ))
                return
            }
            if character == singleQuote || character == doubleQuote {
                let tokenEnd = quotedScalarEnd(
                    in: source,
                    start: index,
                    end: end,
                    quote: character
                )
                body(YAMLSyntaxToken(
                    kind: .string,
                    range: NSRange(location: index, length: tokenEnd - index)
                ))
                index = tokenEnd
                continue
            }

            let tokenStart = index
            while index < end {
                let scalarCharacter = source.character(at: index)
                if isHorizontalSpace(scalarCharacter) || isFlowPunctuation(scalarCharacter) {
                    break
                }
                index += 1
            }
            guard index > tokenStart else {
                index += 1
                continue
            }
            let range = NSRange(location: tokenStart, length: index - tokenStart)
            body(YAMLSyntaxToken(kind: scalarKind(in: source, range: range), range: range))
        }
    }

    private static func quotedScalarEnd(
        in source: CharacterBuffer,
        start: Int,
        end: Int,
        quote: unichar
    ) -> Int {
        var index = start + 1
        while index < end {
            let character = source.character(at: index)
            if quote == doubleQuote, character == backslash {
                index = min(end, index + 2)
                continue
            }
            if character == quote {
                if quote == singleQuote,
                    index + 1 < end,
                    source.character(at: index + 1) == singleQuote
                {
                    index += 2
                    continue
                }
                return index + 1
            }
            index += 1
        }
        return end
    }

    private static func scalarKind(
        in source: CharacterBuffer,
        range: NSRange
    ) -> YAMLSyntaxTokenKind {
        if isKeyword(in: source, range: range) { return .keyword }
        return isNumber(in: source, range: range) ? .number : .string
    }

    private static func isKeyword(in source: CharacterBuffer, range: NSRange) -> Bool {
        if range.length == 1 { return source.character(at: range.location) == 0x7E }
        let start = range.location
        switch range.length {
        case 4:
            let first = lowercaseASCII(source.character(at: start))
            let second = lowercaseASCII(source.character(at: start + 1))
            let third = lowercaseASCII(source.character(at: start + 2))
            let fourth = lowercaseASCII(source.character(at: start + 3))
            return (first == 0x74 && second == 0x72 && third == 0x75 && fourth == 0x65)
                || (first == 0x6E && second == 0x75 && third == 0x6C && fourth == 0x6C)
        case 5:
            return lowercaseASCII(source.character(at: start)) == 0x66
                && lowercaseASCII(source.character(at: start + 1)) == 0x61
                && lowercaseASCII(source.character(at: start + 2)) == 0x6C
                && lowercaseASCII(source.character(at: start + 3)) == 0x73
                && lowercaseASCII(source.character(at: start + 4)) == 0x65
        default:
            return false
        }
    }

    private static func isNumber(in source: CharacterBuffer, range: NSRange) -> Bool {
        let end = NSMaxRange(range)
        var index = range.location
        if index < end {
            let sign = source.character(at: index)
            if sign == 0x2B || sign == 0x2D { index += 1 }
        }

        var integralDigits = 0
        while index < end, isDigitOrSeparator(source.character(at: index)) {
            if isDigit(source.character(at: index)) { integralDigits += 1 }
            index += 1
        }

        var fractionalDigits = 0
        if index < end, source.character(at: index) == 0x2E {
            index += 1
            while index < end, isDigitOrSeparator(source.character(at: index)) {
                if isDigit(source.character(at: index)) { fractionalDigits += 1 }
                index += 1
            }
        }
        guard integralDigits + fractionalDigits > 0 else { return false }

        if index < end {
            let exponent = source.character(at: index)
            if exponent == 0x45 || exponent == 0x65 {
                index += 1
                if index < end {
                    let sign = source.character(at: index)
                    if sign == 0x2B || sign == 0x2D { index += 1 }
                }
                var exponentDigits = 0
                while index < end, isDigitOrSeparator(source.character(at: index)) {
                    if isDigit(source.character(at: index)) { exponentDigits += 1 }
                    index += 1
                }
                guard exponentDigits > 0 else { return false }
            }
        }
        return index == end
    }

    private static func lowercaseASCII(_ character: unichar) -> unichar {
        character >= 0x41 && character <= 0x5A ? character + 0x20 : character
    }

    private static func isDocumentMarker(
        in source: CharacterBuffer,
        start: Int,
        end: Int
    ) -> Bool {
        guard end - start == 3 else { return false }
        let first = source.character(at: start)
        return (first == 0x2D || first == 0x2E)
            && source.character(at: start + 1) == first
            && source.character(at: start + 2) == first
    }

    private static func isMappingSeparator(
        in source: CharacterBuffer,
        after colon: Int,
        end: Int
    ) -> Bool {
        guard colon + 1 < end else { return true }
        let next = source.character(at: colon + 1)
        return isHorizontalSpace(next) || next == 0x5D || next == 0x7D || next == 0x2C
    }

    private static func isCommentStart(
        in source: CharacterBuffer,
        at index: Int,
        lineStart: Int
    ) -> Bool {
        index == lineStart || isHorizontalSpace(source.character(at: index - 1))
    }

    private static func isHorizontalSpace(_ character: unichar) -> Bool {
        character == space || character == tab
    }

    private static func isFlowPunctuation(_ character: unichar) -> Bool {
        character == 0x5B || character == 0x5D || character == 0x7B
            || character == 0x7D || character == 0x2C
    }

    private static func isDigit(_ character: unichar) -> Bool {
        character >= 0x30 && character <= 0x39
    }

    private static func isDigitOrSeparator(_ character: unichar) -> Bool {
        isDigit(character) || character == 0x5F
    }
}

/// Applies lightweight YAML colors to only the visible document neighborhood.
/// Temporary layout attributes keep syntax presentation out of the YAML bytes,
/// editing notifications, copy/paste, and undo history.
@MainActor
final class YAMLSyntaxHighlighter: NSObject {
    static let maximumHighlightLength = 16 * 1_024
    private static let lookbehindLength = 1_024
    private static let lookaheadLength = 4 * 1_024

    private weak var textView: NSTextView?
    private var refreshScheduled = false
    private var paintedRange: NSRange?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init()

        scrollView.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(documentDidChange(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: textView.textStorage
        )
        center.addObserver(
            self,
            selector: #selector(visibleBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        invalidate()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func invalidate() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.highlightVisibleText()
        }
    }

    @discardableResult
    func highlight(characterRange visibleRange: NSRange) -> NSRange {
        guard let textView,
            let textStorage = textView.textStorage,
            let layoutManager = textView.layoutManager
        else { return NSRange(location: 0, length: 0) }

        // `mutableString` exposes the existing TextKit backing store. Bridging
        // through `textView.string` here would snapshot the entire document on
        // every edit, which is exactly the large-file cost this path avoids.
        let source: NSString = textStorage.mutableString
        let target = Self.boundedHighlightRange(around: visibleRange, in: source)

        if let paintedRange {
            clearTemporaryColor(in: paintedRange, documentLength: source.length, layoutManager: layoutManager)
        }

        YAMLSyntaxLexer.enumerateTokens(in: source, range: target) { token in
            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: Self.color(for: token.kind),
                forCharacterRange: token.range
            )
        }
        paintedRange = target
        return target
    }

    static func boundedHighlightRange(around visibleRange: NSRange, in source: NSString) -> NSRange {
        guard source.length > 0 else { return NSRange(location: 0, length: 0) }
        let visibleStart = min(visibleRange.location, source.length - 1)
        let visibleLength = min(visibleRange.length, source.length - visibleStart)
        let visibleEnd = visibleStart + visibleLength
        let lowerBound = max(0, visibleStart - lookbehindLength)

        var start = visibleStart
        var cursor = visibleStart
        while cursor > lowerBound {
            cursor -= 1
            let character = source.character(at: cursor)
            if character == 0x0A || character == 0x0D {
                start = cursor + 1
                break
            }
            start = cursor
        }

        let hardEnd = min(source.length, start + maximumHighlightLength)
        let suffixStart = min(visibleEnd, hardEnd)
        let suffixEnd = min(hardEnd, suffixStart + lookaheadLength)
        var end = suffixEnd
        cursor = suffixStart
        while cursor < suffixEnd {
            let character = source.character(at: cursor)
            cursor += 1
            if character == 0x0A {
                end = cursor
                break
            }
            if character == 0x0D {
                if cursor < suffixEnd, source.character(at: cursor) == 0x0A { cursor += 1 }
                end = cursor
                break
            }
        }
        if end <= start { end = min(source.length, start + 1) }
        return NSRange(location: start, length: end - start)
    }

    private func highlightVisibleText() {
        guard let textView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer,
            textView.textStorage?.length ?? 0 > 0
        else {
            paintedRange = nil
            return
        }

        let visibleRect = textView.visibleRect
        guard visibleRect.width > 0, visibleRect.height > 0 else {
            let selection = textView.selectedRange()
            _ = highlight(characterRange: NSRange(location: selection.location, length: 1))
            return
        }
        let verticalOverscan = max(visibleRect.height, 300)
        let highlightRect = NSRect(
            x: visibleRect.minX,
            y: max(0, visibleRect.minY - verticalOverscan),
            width: visibleRect.width,
            height: visibleRect.height + verticalOverscan * 2
        )
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: highlightRect,
            in: textContainer
        )
        let characterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange,
            actualGlyphRange: nil
        )
        _ = highlight(characterRange: characterRange)
    }

    private func clearTemporaryColor(
        in range: NSRange,
        documentLength: Int,
        layoutManager: NSLayoutManager
    ) {
        guard range.length > 0, range.location < documentLength else { return }
        let clipped = NSRange(
            location: range.location,
            length: min(range.length, documentLength - range.location)
        )
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: clipped)
    }

    private static func color(for kind: YAMLSyntaxTokenKind) -> NSColor {
        switch kind {
        case .key: .systemPurple
        case .string: .systemRed
        case .number: .systemBlue
        case .keyword: .systemOrange
        case .comment: .secondaryLabelColor
        }
    }

    @objc private func documentDidChange(_ notification: Notification) { invalidate() }

    @objc private func visibleBoundsDidChange(_ notification: Notification) { invalidate() }
}
