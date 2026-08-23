import AppKit

enum SyntaxTokenKind: Equatable {
    case key
    case string
    case number
    case keyword
    case comment
}

struct SyntaxToken: Equatable {
    let kind: SyntaxTokenKind
    let range: NSRange
}

/// One bounded UTF-16 copy shared by the lightweight lexers. Reading this
/// buffer in tight loops avoids an Objective-C `NSString` call per character.
private struct SyntaxCharacterBuffer {
    let baseLocation: Int
    let characters: [unichar]

    init(copying source: NSString, range: NSRange) {
        baseLocation = range.location
        var characters = [unichar](repeating: 0, count: range.length)
        source.getCharacters(&characters, range: range)
        self.characters = characters
    }

    var endLocation: Int { baseLocation + characters.count }

    @inline(__always)
    func character(at location: Int) -> unichar {
        characters[location - baseLocation]
    }
}

/// A deliberately small YAML lexer for presentation, not validation.
///
/// It recognizes the common block-mapping syntax emitted for Kubernetes
/// objects. Ambiguous or uncommon YAML remains ordinary text instead of
/// pulling a complete parser into the editing path.
enum YAMLSyntaxLexer {
    static func tokens(in source: NSString, range requestedRange: NSRange) -> [SyntaxToken] {
        var result: [SyntaxToken] = []
        enumerateTokens(in: source, range: requestedRange) { result.append($0) }
        return result
    }

    static func enumerateTokens(
        in string: NSString,
        range requestedRange: NSRange,
        _ body: (SyntaxToken) -> Void
    ) {
        guard requestedRange.length > 0, requestedRange.location < string.length else { return }
        let clippedRange = NSRange(
            location: requestedRange.location,
            length: min(requestedRange.length, string.length - requestedRange.location)
        )
        // One bounded bulk copy is much cheaper than crossing into NSString
        // for every character while typing.
        let source = SyntaxCharacterBuffer(copying: string, range: clippedRange)
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

    private static let lineFeed: unichar = 0x0A
    private static let carriageReturn: unichar = 0x0D
    private static let tab: unichar = 0x09
    private static let space: unichar = 0x20
    private static let numberSign: unichar = 0x23
    private static let singleQuote: unichar = 0x27
    private static let doubleQuote: unichar = 0x22
    private static let backslash: unichar = 0x5C

    private static func enumerateLine(
        in source: SyntaxCharacterBuffer,
        start lineStart: Int,
        end lineEnd: Int,
        _ body: (SyntaxToken) -> Void
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
            body(SyntaxToken(kind: .key, range: mapping.keyRange))
        }
        enumerateValues(
            in: source,
            start: mapping.map { $0.colon + 1 } ?? contentStart,
            end: lineEnd,
            body
        )
    }

    private static func mapping(
        in source: SyntaxCharacterBuffer,
        start: Int,
        end: Int
    ) -> Mapping? {
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
        in source: SyntaxCharacterBuffer,
        start: Int,
        end: Int,
        _ body: (SyntaxToken) -> Void
    ) {
        var index = start
        while index < end {
            let character = source.character(at: index)
            if isHorizontalSpace(character) || isFlowPunctuation(character) {
                index += 1
                continue
            }
            if character == numberSign, isCommentStart(in: source, at: index, lineStart: start) {
                body(SyntaxToken(
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
                body(SyntaxToken(
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
            body(SyntaxToken(kind: scalarKind(in: source, range: range), range: range))
        }
    }

    private static func quotedScalarEnd(
        in source: SyntaxCharacterBuffer,
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
        in source: SyntaxCharacterBuffer,
        range: NSRange
    ) -> SyntaxTokenKind {
        if isKeyword(in: source, range: range) { return .keyword }
        return isNumber(in: source, range: range) ? .number : .string
    }

    private static func isKeyword(in source: SyntaxCharacterBuffer, range: NSRange) -> Bool {
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

    private static func isNumber(in source: SyntaxCharacterBuffer, range: NSRange) -> Bool {
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
        in source: SyntaxCharacterBuffer,
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
        in source: SyntaxCharacterBuffer,
        after colon: Int,
        end: Int
    ) -> Bool {
        guard colon + 1 < end else { return true }
        let next = source.character(at: colon + 1)
        return isHorizontalSpace(next) || next == 0x5D || next == 0x7D || next == 0x2C
    }

    private static func isCommentStart(
        in source: SyntaxCharacterBuffer,
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

/// A deliberately small JSON lexer for presentation, not validation.
///
/// It recognizes strings, object keys, numbers, and JSON literals without
/// building a tree. Punctuation and ambiguous fragments remain ordinary text,
/// which keeps partial edits cheap and useful while the user is typing.
enum JSONSyntaxLexer {
    static func tokens(in source: NSString, range requestedRange: NSRange) -> [SyntaxToken] {
        var result: [SyntaxToken] = []
        enumerateTokens(in: source, range: requestedRange) { result.append($0) }
        return result
    }

    static func enumerateTokens(
        in string: NSString,
        range requestedRange: NSRange,
        _ body: (SyntaxToken) -> Void
    ) {
        guard requestedRange.length > 0, requestedRange.location < string.length else { return }
        let clippedRange = NSRange(
            location: requestedRange.location,
            length: min(requestedRange.length, string.length - requestedRange.location)
        )
        let start = clippedRange.location
        let end = NSMaxRange(clippedRange)
        let copiedEnd = min(string.length, end + maximumTokenLookahead)
        let source = SyntaxCharacterBuffer(
            copying: string,
            range: NSRange(location: start, length: copiedEnd - start)
        )
        var index = start

        while index < end {
            let character = source.character(at: index)
            if isWhitespace(character) || isPunctuation(character) {
                index += 1
                continue
            }

            if character == doubleQuote {
                let tokenStart = index
                let tokenEnd = quotedStringEnd(
                    in: source,
                    start: index,
                    end: source.endLocation
                )
                let kind: SyntaxTokenKind = nextSignificantCharacter(
                    in: source,
                    from: tokenEnd
                ) == colon ? .key : .string
                emit(
                    kind: kind,
                    start: tokenStart,
                    end: tokenEnd,
                    requestedRange: clippedRange,
                    body: body
                )
                index = max(tokenEnd, index + 1)
                continue
            }

            let tokenStart = index
            var tokenEnd = index
            while tokenEnd < source.endLocation {
                let scalar = source.character(at: tokenEnd)
                if isWhitespace(scalar) || isPunctuation(scalar) { break }
                tokenEnd += 1
            }
            guard tokenEnd > tokenStart else {
                index += 1
                continue
            }
            let kind = scalarKind(in: source, start: tokenStart, end: tokenEnd)
            emit(
                kind: kind,
                start: tokenStart,
                end: tokenEnd,
                requestedRange: clippedRange,
                body: body
            )
            index = tokenEnd
        }
    }

    private static let doubleQuote: unichar = 0x22
    private static let backslash: unichar = 0x5C
    private static let colon: unichar = 0x3A
    private static let maximumTokenLookahead = 256

    private static func quotedStringEnd(
        in source: SyntaxCharacterBuffer,
        start: Int,
        end: Int
    ) -> Int {
        var index = start + 1
        while index < end {
            let character = source.character(at: index)
            if character == backslash {
                index = min(end, index + 2)
            } else if character == doubleQuote {
                return index + 1
            } else {
                index += 1
            }
        }
        return end
    }

    private static func scalarKind(
        in source: SyntaxCharacterBuffer,
        start: Int,
        end: Int
    ) -> SyntaxTokenKind {
        if isKeyword(in: source, start: start, end: end) { return .keyword }
        return isNumber(in: source, start: start, end: end) ? .number : .string
    }

    private static func isKeyword(
        in source: SyntaxCharacterBuffer,
        start: Int,
        end: Int
    ) -> Bool {
        switch end - start {
        case 4:
            let first = source.character(at: start)
            return (first == 0x74
                && source.character(at: start + 1) == 0x72
                && source.character(at: start + 2) == 0x75
                && source.character(at: start + 3) == 0x65)
                || (first == 0x6E
                    && source.character(at: start + 1) == 0x75
                    && source.character(at: start + 2) == 0x6C
                    && source.character(at: start + 3) == 0x6C)
        case 5:
            return source.character(at: start) == 0x66
                && source.character(at: start + 1) == 0x61
                && source.character(at: start + 2) == 0x6C
                && source.character(at: start + 3) == 0x73
                && source.character(at: start + 4) == 0x65
        default:
            return false
        }
    }

    private static func isNumber(
        in source: SyntaxCharacterBuffer,
        start: Int,
        end: Int
    ) -> Bool {
        var index = start
        guard index < end else { return false }
        if source.character(at: index) == 0x2D { index += 1 }
        guard index < end else { return false }

        if source.character(at: index) == 0x30 {
            index += 1
            if index < end, isDigit(source.character(at: index)) { return false }
        } else {
            guard isDigitOneToNine(source.character(at: index)) else { return false }
            repeat { index += 1 } while index < end && isDigit(source.character(at: index))
        }

        if index < end, source.character(at: index) == 0x2E {
            index += 1
            let fractionStart = index
            while index < end, isDigit(source.character(at: index)) { index += 1 }
            guard index > fractionStart else { return false }
        }

        if index < end,
            source.character(at: index) == 0x45 || source.character(at: index) == 0x65
        {
            index += 1
            if index < end,
                source.character(at: index) == 0x2B || source.character(at: index) == 0x2D
            { index += 1 }
            let exponentStart = index
            while index < end, isDigit(source.character(at: index)) { index += 1 }
            guard index > exponentStart else { return false }
        }
        return index == end
    }

    private static func nextSignificantCharacter(
        in source: SyntaxCharacterBuffer,
        from start: Int
    ) -> unichar? {
        // JSON permits only four whitespace characters. Bound this scan so a
        // pathological whitespace suffix cannot turn mode detection into a
        // long per-keystroke operation.
        let end = min(source.endLocation, start + maximumTokenLookahead)
        var index = max(source.baseLocation, start)
        while index < end {
            let character = source.character(at: index)
            if !isWhitespace(character) { return character }
            index += 1
        }
        return nil
    }

    private static func emit(
        kind: SyntaxTokenKind,
        start: Int,
        end: Int,
        requestedRange: NSRange,
        body: (SyntaxToken) -> Void
    ) {
        let clippedStart = max(start, requestedRange.location)
        let clippedEnd = min(end, NSMaxRange(requestedRange))
        guard clippedEnd > clippedStart else { return }
        body(SyntaxToken(
            kind: kind,
            range: NSRange(location: clippedStart, length: clippedEnd - clippedStart)
        ))
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0D
    }

    private static func isPunctuation(_ character: unichar) -> Bool {
        character == 0x7B || character == 0x7D
            || character == 0x5B || character == 0x5D
            || character == 0x2C || character == colon
    }

    private static func isDigit(_ character: unichar) -> Bool {
        character >= 0x30 && character <= 0x39
    }

    private static func isDigitOneToNine(_ character: unichar) -> Bool {
        character >= 0x31 && character <= 0x39
    }
}

enum SyntaxHighlightingMode: Equatable {
    case none
    case yaml
    case json
}

/// Chooses a presentation lexer for a decoded text Data value. This is a
/// bounded heuristic, intentionally separate from validation or serialization.
enum DataSyntaxHighlightingModeDetector {
    static let maximumBoundaryWhitespaceScan = 4 * 1_024

    static func mode(
        forKey key: String,
        isTextValue: Bool,
        source: NSString,
        retaining currentMode: SyntaxHighlightingMode = .none
    ) -> SyntaxHighlightingMode {
        guard isTextValue else { return .none }
        let lowercaseKey = key.lowercased()
        if lowercaseKey.hasSuffix(".yml") || lowercaseKey.hasSuffix(".yaml") {
            return .yaml
        }

        guard let first = firstNonWhitespace(in: source),
            let last = lastNonWhitespace(in: source)
        else { return .none }
        let isObject = first.character == 0x7B && last.character == 0x7D
        let isArray = first.character == 0x5B && last.character == 0x5D
        if isObject || isArray { return .json }

        // Once a complete JSON value selected the mode, retain it while one
        // outer delimiter is temporarily missing during an edit. Replacing the
        // value with ordinary text clears both hints and returns to plain text.
        if currentMode == .json {
            let startsLikeJSON = first.character == 0x7B || first.character == 0x5B
            let endsLikeJSON = last.character == 0x7D || last.character == 0x5D
            if startsLikeJSON || endsLikeJSON { return .json }
        }
        return .none
    }

    private static func firstNonWhitespace(
        in source: NSString
    ) -> (index: Int, character: unichar)? {
        let end = min(source.length, maximumBoundaryWhitespaceScan)
        for index in 0..<end {
            let character = source.character(at: index)
            if !isWhitespace(character) { return (index, character) }
        }
        return nil
    }

    private static func lastNonWhitespace(
        in source: NSString
    ) -> (index: Int, character: unichar)? {
        guard source.length > 0 else { return nil }
        let start = max(0, source.length - maximumBoundaryWhitespaceScan)
        for index in stride(from: source.length - 1, through: start, by: -1) {
            let character = source.character(at: index)
            if !isWhitespace(character) { return (index, character) }
        }
        return nil
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0D
    }
}

/// Applies lightweight YAML or JSON colors to only the visible document
/// neighborhood. Temporary layout attributes keep syntax presentation out of
/// the underlying bytes, editing notifications, copy/paste, and undo history.
@MainActor
final class SyntaxHighlighter: NSObject {
    static let maximumHighlightLength = 16 * 1_024
    private static let lookbehindLength = 1_024
    private static let lookaheadLength = 4 * 1_024

    private weak var textView: NSTextView?
    private var refreshScheduled = false
    private var paintedRange: NSRange?
    private(set) var mode: SyntaxHighlightingMode

    init(
        textView: NSTextView,
        scrollView: NSScrollView,
        mode: SyntaxHighlightingMode = .yaml
    ) {
        self.textView = textView
        self.mode = mode
        super.init()

        // Temporary colors must not make TextKit lay out an entire large value
        // before it can paint the visible neighborhood.
        textView.layoutManager?.allowsNonContiguousLayout = true
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

    func setMode(_ mode: SyntaxHighlightingMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        clearPaintedRange()
        if mode != .none { invalidate() }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func invalidate() {
        guard mode != .none else {
            clearPaintedRange()
            return
        }
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
        guard mode != .none else {
            clearPaintedRange()
            return NSRange(location: 0, length: 0)
        }
        guard let textView,
            let textStorage = textView.textStorage,
            let layoutManager = textView.layoutManager
        else { return NSRange(location: 0, length: 0) }

        // `mutableString` exposes the existing TextKit backing store. Bridging
        // through `textView.string` here would snapshot the entire document on
        // every edit, which is exactly the large-file cost this path avoids.
        let source: NSString = textStorage.mutableString
        let target = Self.boundedHighlightRange(around: visibleRange, in: source)

        clearPaintedRange()

        let paint: (SyntaxToken) -> Void = { token in
            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: Self.color(for: token.kind),
                forCharacterRange: token.range
            )
        }
        switch mode {
        case .yaml:
            YAMLSyntaxLexer.enumerateTokens(in: source, range: target, paint)
        case .json:
            JSONSyntaxLexer.enumerateTokens(in: source, range: target, paint)
        case .none:
            preconditionFailure("Plain text exits before lexer dispatch")
        }
        paintedRange = target
        return target
    }

    static func boundedHighlightRange(
        around visibleRange: NSRange,
        in source: NSString
    ) -> NSRange {
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
        guard mode != .none else {
            clearPaintedRange()
            return
        }
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

    private func clearPaintedRange() {
        guard let paintedRange else { return }
        guard let textView,
            let textStorage = textView.textStorage,
            let layoutManager = textView.layoutManager
        else {
            self.paintedRange = nil
            return
        }
        clearTemporaryColor(
            in: paintedRange,
            documentLength: textStorage.length,
            layoutManager: layoutManager
        )
        self.paintedRange = nil
    }

    private static func color(for kind: SyntaxTokenKind) -> NSColor {
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
