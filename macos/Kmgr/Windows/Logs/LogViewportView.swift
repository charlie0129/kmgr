import AppKit
import Darwin

/// Immutable font facts shared with detached log-indexing work. Text geometry
/// is a fixed cell grid: font fallback and Unicode glyph advances never affect
/// scrolling or wrapping.
struct LogViewportTextStyle: Hashable, Sendable {
    var fontName: String
    var pointSize: Double
    var lineHeight: Double
    var cellWidth: Double

    @MainActor
    init(font: NSFont) {
        fontName = font.fontName
        pointSize = Double(font.pointSize)
        lineHeight = Double(max(
            1,
            ceil(font.ascender - font.descender + font.leading)
        ))
        cellWidth = Double(max(
            1,
            ("M" as NSString).size(withAttributes: [
                .font: font,
                .ligature: 0,
                .kern: 0,
            ]).width
        ))
    }
}

/// A bounded random-access queue. Prefix eviction advances an index instead of
/// shifting every offscreen chunk or line; occasional compaction keeps the
/// backing allocation proportional to retained content.
fileprivate struct LogHeadBuffer<Element: Sendable>: RandomAccessCollection, Sendable {
    typealias Index = Int

    private var storage: [Element]
    private var head: Int

    init(_ elements: [Element] = []) {
        storage = elements
        head = 0
    }

    var startIndex: Int { 0 }
    var endIndex: Int { storage.count - head }

    subscript(position: Int) -> Element {
        precondition(indices.contains(position))
        return storage[head + position]
    }

    mutating func append(_ element: Element) {
        storage.append(element)
    }

    mutating func append<S: Sequence>(contentsOf elements: S) where S.Element == Element {
        storage.append(contentsOf: elements)
    }

    mutating func discardFirst(_ count: Int) {
        precondition(count >= 0 && count <= self.count)
        head += count
        compactIfNeeded()
    }

    mutating func discardLast(_ count: Int = 1) {
        precondition(count >= 0 && count <= self.count)
        storage.removeLast(count)
        if storage.isEmpty { head = 0 }
    }

    private mutating func compactIfNeeded() {
        guard head >= 4_096, head >= storage.count / 2 else { return }
        storage.removeFirst(head)
        head = 0
    }
}

private struct LogViewportCellBoundary: Sendable {
    /// Cell boundary after a grapheme whose UTF-16 length was not one.
    var cellBoundary: Int
    /// UTF-16 units in excess of one unit per preceding cell.
    var cumulativeUTF16Extra: Int
}

struct LogViewportLine: Sendable {
    /// Excludes the terminating newline. Newlines remain in the projection's
    /// global UTF-16 coordinate space for exact selection and copy.
    var textRange: NSRange
    var cellCount: Int
    var isASCII: Bool
    /// Exact rendered-line boundary heuristic; this is intentionally not JSON
    /// validation and deliberately excludes array-root logs.
    var hasJSONObjectBoundaries: Bool
    private var variableBoundaries: [LogViewportCellBoundary]

    var indexedVariableBoundaryCount: Int { variableBoundaries.count }

    fileprivate init(
        textRange: NSRange,
        cellCount: Int,
        isASCII: Bool,
        hasJSONObjectBoundaries: Bool,
        variableBoundaries: [LogViewportCellBoundary]
    ) {
        self.textRange = textRange
        self.cellCount = cellCount
        self.isASCII = isASCII
        self.hasJSONObjectBoundaries = hasJSONObjectBoundaries
        self.variableBoundaries = variableBoundaries
    }

    fileprivate func textIndex(atCellBoundary requestedCell: Int) -> Int {
        let cell = max(0, min(requestedCell, cellCount))
        var low = 0
        var high = variableBoundaries.count
        while low < high {
            let middle = (low + high) / 2
            if variableBoundaries[middle].cellBoundary <= cell {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let extra = low == 0 ? 0 : variableBoundaries[low - 1]
            .cumulativeUTF16Extra
        return textRange.location + cell + extra
    }

    fileprivate func cellBoundary(
        atTextIndex requestedIndex: Int,
        roundingUp: Bool
    ) -> Int {
        let index = max(
            textRange.location,
            min(requestedIndex, textRange.location + textRange.length)
        )
        var low = 0
        var high = cellCount
        while low < high {
            let middle = (low + high) / 2
            if textIndex(atCellBoundary: middle) < index {
                low = middle + 1
            } else {
                high = middle
            }
        }
        if textIndex(atCellBoundary: low) == index || roundingUp {
            return low
        }
        return max(0, low - 1)
    }

    fileprivate func textRange(forCells requestedCells: Range<Int>) -> NSRange {
        let lower = max(0, min(requestedCells.lowerBound, cellCount))
        let upper = max(lower, min(requestedCells.upperBound, cellCount))
        let start = textIndex(atCellBoundary: lower)
        let end = textIndex(atCellBoundary: upper)
        return NSRange(location: start, length: end - start)
    }

    fileprivate func cellRange(containing sourceRange: NSRange) -> Range<Int> {
        let sourceEnd = sourceRange.location.addingReportingOverflow(
            sourceRange.length
        )
        let safeEnd = sourceEnd.overflow ? Int.max : sourceEnd.partialValue
        let lower = cellBoundary(
            atTextIndex: sourceRange.location,
            roundingUp: false
        )
        let upper = cellBoundary(atTextIndex: safeEnd, roundingUp: true)
        return lower..<max(lower, upper)
    }
}

/// Presents absolute stored line ranges in the projection's current local text
/// coordinate space without rewriting every retained range after eviction.
struct LogViewportLines: RandomAccessCollection, Sendable {
    typealias Index = Int

    fileprivate var storage: LogHeadBuffer<LogViewportLine>
    fileprivate var textOrigin: Int

    var startIndex: Int { storage.startIndex }
    var endIndex: Int { storage.endIndex }

    subscript(position: Int) -> LogViewportLine {
        var line = storage[position]
        line.textRange.location -= textOrigin
        return line
    }
}

struct LogViewportJSONHighlight {
    var tokens: [SyntaxToken]
    var scannedUTF16Length: Int
}

struct LogViewportProjectionEditResult {
    var removedLineCount: Int
    /// The previous open final line is replaced by this many rebuilt lines
    /// when a suffix is appended.
    var rebuiltTailLineCount: Int
}

/// Main-actor-independent text and cell index. It contains no glyphs, pixel
/// widths, or materialized wrapped rows. A normal ASCII cell needs no index
/// entry; only extended graphemes spanning multiple UTF-16 units are recorded.
struct LogViewportProjection: Sendable {
    static let maximumJSONHighlightCells = 16 * 1_024
    private static let jsonHighlightLookbehindCells = 1_024
    private static let jsonHighlightLookaheadCells = 4 * 1_024

    var style: LogViewportTextStyle
    private var chunkStorage: LogHeadBuffer<String>
    private var chunkStartStorage: LogHeadBuffer<Int>
    /// Always contains at least the empty final line for an empty projection.
    private var lineStorage: LogHeadBuffer<LogViewportLine>
    private var textOrigin: Int
    var textUTF16Length: Int
    var maximumCellCount: Int
    var highlightedText: String

    var lines: LogViewportLines {
        LogViewportLines(storage: lineStorage, textOrigin: textOrigin)
    }

    var chunkCount: Int { chunkStorage.count }

    var maximumWidth: Double {
        Double(maximumCellCount) * style.cellWidth
    }

    private static func emptyLine(at location: Int) -> LogViewportLine {
        LogViewportLine(
            textRange: NSRange(location: location, length: 0),
            cellCount: 0,
            isASCII: true,
            hasJSONObjectBoundaries: false,
            variableBoundaries: []
        )
    }

    static func empty(
        style: LogViewportTextStyle,
        highlightedText: String = ""
    ) -> Self {
        Self(
            style: style,
            chunkStorage: LogHeadBuffer(),
            chunkStartStorage: LogHeadBuffer(),
            lineStorage: LogHeadBuffer([Self.emptyLine(at: 0)]),
            textOrigin: 0,
            textUTF16Length: 0,
            maximumCellCount: 0,
            highlightedText: highlightedText
        )
    }

    /// Reuses the immutable line index for an unchanged projection and only
    /// rebuilds its open final line for a pure append. Live log rendering uses
    /// `applyLineAlignedEdit` below so prefix eviction also remains incremental.
    static func make(
        chunks: [String],
        previous: Self?,
        retainedChunkCount: Int,
        style: LogViewportTextStyle,
        highlightedText: String = ""
    ) throws -> Self {
        let chunkStarts = makeChunkStarts(chunks)
        let textUTF16Length = chunkStarts.last.map {
            $0 + (chunks.last?.utf16.count ?? 0)
        } ?? 0

        if let previous,
            retainedChunkCount == previous.chunkStorage.count,
            chunks.count >= previous.chunkStorage.count,
            zip(previous.chunkStorage, chunks).allSatisfy(==)
        {
            if chunks.count == previous.chunkStorage.count {
                var replacement = previous
                replacement.style = style
                replacement.highlightedText = highlightedText
                return replacement
            }

            let finalLine = previous.lines.last
                ?? Self.emptyLine(at: previous.textUTF16Length)
            let rebuildStart = finalLine.textRange.location
            var suffix = [previous.substring(in: NSRange(
                location: rebuildStart,
                length: previous.textUTF16Length - rebuildStart
            ))]
            suffix.append(contentsOf: chunks.dropFirst(previous.chunkStorage.count))
            var builder = LineIndexBuilder(
                startOffset: rebuildStart,
                precedingTerminatorWasCarriageReturn: previous.codeUnitBeforeEnd == 0x000d
                    && rebuildStart == previous.textUTF16Length
            )
            try builder.append(contentsOf: suffix)
            let rebuiltLines = try builder.finish()
            let lines = Array(previous.lines.dropLast()) + rebuiltLines
            return Self(
                style: style,
                chunkStorage: LogHeadBuffer(chunks),
                chunkStartStorage: LogHeadBuffer(chunkStarts),
                lineStorage: LogHeadBuffer(lines),
                textOrigin: 0,
                textUTF16Length: textUTF16Length,
                maximumCellCount: lines.lazy.map(\.cellCount).max() ?? 0,
                highlightedText: highlightedText
            )
        }

        var builder = LineIndexBuilder(startOffset: 0)
        try builder.append(contentsOf: chunks)
        let lines = try builder.finish()
        return Self(
            style: style,
            chunkStorage: LogHeadBuffer(chunks),
            chunkStartStorage: LogHeadBuffer(chunkStarts),
            lineStorage: LogHeadBuffer(lines),
            textOrigin: 0,
            textUTF16Length: textUTF16Length,
            maximumCellCount: lines.lazy.map(\.cellCount).max() ?? 0,
            highlightedText: highlightedText
        )
    }

    /// Applies the normal live-log edit without touching retained chunks or
    /// line metadata. Chunk starts and line ranges remain absolute internally;
    /// advancing `textOrigin` makes prefix eviction O(evicted + appended).
    mutating func applyLineAlignedEdit(
        removePrefixChunkCount: Int,
        appendChunks: [String]
    ) throws -> LogViewportProjectionEditResult {
        precondition(
            removePrefixChunkCount >= 0
                && removePrefixChunkCount <= chunkStorage.count
        )
        var removedUTF16Length = 0
        for index in 0..<removePrefixChunkCount {
            removedUTF16Length += chunkStorage[index].utf16.count
        }
        let replacementOrigin = textOrigin + removedUTF16Length
        chunkStorage.discardFirst(removePrefixChunkCount)
        chunkStartStorage.discardFirst(removePrefixChunkCount)

        var removedLineCount = 0
        while removedLineCount < lineStorage.count,
            lineStorage[removedLineCount].textRange.location < replacementOrigin
        {
            removedLineCount += 1
        }
        lineStorage.discardFirst(removedLineCount)
        textOrigin = replacementOrigin
        textUTF16Length -= removedUTF16Length

        // Keep the projection's line collection non-empty even when prefix
        // eviction removes the final unterminated line. Geometry deliberately
        // exposes one drawable row for an empty document, so it needs a real
        // empty line rather than an empty collection. This also gives the
        // append path below a final line to replace when the buffer was fully
        // evicted and new text arrives in the same update.
        if lineStorage.isEmpty {
            lineStorage.append(Self.emptyLine(
                at: textOrigin + textUTF16Length
            ))
        }
        if chunkStorage.isEmpty {
            maximumCellCount = 0
        }

        guard !appendChunks.isEmpty else {
            return LogViewportProjectionEditResult(
                removedLineCount: removedLineCount,
                rebuiltTailLineCount: 0
            )
        }

        let finalLine = lines.last ?? Self.emptyLine(at: textUTF16Length)
        let rebuildStart = textOrigin + finalLine.textRange.location
        let retainedOpenSuffix = substring(in: finalLine.textRange)
        let precedingTerminatorWasCarriageReturn = codeUnitBeforeEnd == 0x000d
            && finalLine.textRange.location == textUTF16Length
        lineStorage.discardLast()

        var absoluteEnd = textOrigin + textUTF16Length
        for chunk in appendChunks {
            chunkStartStorage.append(absoluteEnd)
            chunkStorage.append(chunk)
            let length = chunk.utf16.count
            absoluteEnd += length
            textUTF16Length += length
        }

        var builder = LineIndexBuilder(
            startOffset: rebuildStart,
            precedingTerminatorWasCarriageReturn:
                precedingTerminatorWasCarriageReturn
        )
        if !retainedOpenSuffix.isEmpty { builder.append(retainedOpenSuffix) }
        try builder.append(contentsOf: appendChunks)
        let rebuiltLines = try builder.finish()
        lineStorage.append(contentsOf: rebuiltLines)
        maximumCellCount = max(
            maximumCellCount,
            rebuiltLines.lazy.map(\.cellCount).max() ?? 0
        )
        return LogViewportProjectionEditResult(
            removedLineCount: removedLineCount,
            rebuiltTailLineCount: rebuiltLines.count
        )
    }

    func joinedText() -> String {
        chunkStorage.joined()
    }

    func substring(in requestedRange: NSRange) -> String {
        guard textUTF16Length > 0 else { return "" }
        let start = max(0, min(requestedRange.location, textUTF16Length))
        let requestedEnd = requestedRange.location.addingReportingOverflow(
            requestedRange.length
        )
        let end = max(
            start,
            min(
                requestedEnd.overflow ? Int.max : requestedEnd.partialValue,
                textUTF16Length
            )
        )
        guard end > start else { return "" }

        var chunkIndex = chunkIndex(containingOrFollowing: start)
        var result = String()
        result.reserveCapacity(end - start)
        let absoluteStart = textOrigin + start
        let absoluteEnd = textOrigin + end
        while chunkIndex < chunkStorage.count {
            let chunkStart = chunkStartStorage[chunkIndex]
            let chunk = chunkStorage[chunkIndex]
            let chunkLength = chunk.utf16.count
            let chunkEnd = chunkStart + chunkLength
            if chunkStart >= absoluteEnd { break }
            if chunkEnd > absoluteStart {
                let localStart = max(0, absoluteStart - chunkStart)
                let localEnd = min(chunkLength, absoluteEnd - chunkStart)
                if localEnd > localStart {
                    result += (chunk as NSString).substring(with: NSRange(
                        location: localStart,
                        length: localEnd - localStart
                    ))
                }
            }
            chunkIndex += 1
        }
        return result
    }

    fileprivate func lineIndex(containingTextIndex requestedIndex: Int) -> Int {
        let index = max(0, min(requestedIndex, textUTF16Length))
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].textRange.location <= index {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return max(0, min(lines.count - 1, low - 1))
    }

    fileprivate func highlightedRanges(
        inLine lineIndex: Int,
        intersecting targetCells: Range<Int>
    ) -> [NSRange] {
        guard !highlightedText.isEmpty,
            lines.indices.contains(lineIndex),
            !targetCells.isEmpty
        else { return [] }
        let line = lines[lineIndex]
        let padding = max(1, highlightedText.utf16.count * 2)
        let searchStart = max(0, targetCells.lowerBound - padding)
        let searchEnd = min(
            line.cellCount,
            targetCells.upperBound + padding
        )
        let searchCells = searchStart..<searchEnd
        let searchSourceRange = line.textRange(forCells: searchCells)
        let value = substring(in: searchSourceRange) as NSString
        guard value.length > 0 else { return [] }

        var result: [NSRange] = []
        var cursor = 0
        while cursor < value.length {
            let match = value.range(
                of: highlightedText,
                options: NSString.CompareOptions.caseInsensitive,
                range: NSRange(location: cursor, length: value.length - cursor)
            )
            guard match.location != NSNotFound, match.length > 0 else { break }
            let global = NSRange(
                location: searchSourceRange.location + match.location,
                length: match.length
            )
            let matchCells = line.cellRange(containing: global)
            if matchCells.overlaps(targetCells) { result.append(global) }
            cursor = NSMaxRange(match)
        }
        return result
    }

    /// Reuses the editor's lightweight lexer, but never materializes or scans
    /// an entire pathological log line merely to color the visible viewport.
    /// The returned ranges use the projection's global UTF-16 coordinates.
    func jsonHighlight(
        inLine lineIndex: Int,
        intersecting requestedCells: Range<Int>
    ) -> LogViewportJSONHighlight {
        let empty = LogViewportJSONHighlight(tokens: [], scannedUTF16Length: 0)
        guard lines.indices.contains(lineIndex), !requestedCells.isEmpty else {
            return empty
        }
        let line = lines[lineIndex]
        guard line.hasJSONObjectBoundaries else { return empty }

        let targetStart = max(0, min(requestedCells.lowerBound, line.cellCount))
        let requestedEnd = max(targetStart, min(requestedCells.upperBound, line.cellCount))
        guard requestedEnd > targetStart else { return empty }

        let scanStart = max(0, targetStart - Self.jsonHighlightLookbehindCells)
        let scanCapacity = min(
            Self.maximumJSONHighlightCells,
            line.cellCount - scanStart
        )
        let hardEnd = scanStart + scanCapacity
        let targetEnd = min(requestedEnd, hardEnd)
        guard targetEnd > targetStart else { return empty }
        let availableAfterTarget = line.cellCount - targetEnd
        let scanEnd = min(
            hardEnd,
            targetEnd + min(Self.jsonHighlightLookaheadCells, availableAfterTarget)
        )
        let scanSourceRange = line.textRange(forCells: scanStart..<scanEnd)
        let targetSourceRange = line.textRange(forCells: targetStart..<targetEnd)
        let source = substring(in: scanSourceRange) as NSString
        guard source.length > 0 else { return empty }

        var tokens: [SyntaxToken] = []
        JSONSyntaxLexer.enumerateTokens(
            in: source,
            range: NSRange(location: 0, length: source.length)
        ) { token in
            let globalStart = scanSourceRange.location + token.range.location
            let globalEnd = globalStart + token.range.length
            let clippedStart = max(globalStart, targetSourceRange.location)
            let clippedEnd = min(globalEnd, NSMaxRange(targetSourceRange))
            guard clippedEnd > clippedStart else { return }
            tokens.append(SyntaxToken(
                kind: token.kind,
                range: NSRange(
                    location: clippedStart,
                    length: clippedEnd - clippedStart
                )
            ))
        }
        return LogViewportJSONHighlight(
            tokens: tokens,
            scannedUTF16Length: source.length
        )
    }

    private var codeUnitBeforeEnd: unichar? {
        guard textUTF16Length > 0 else { return nil }
        let value = substring(in: NSRange(
            location: textUTF16Length - 1,
            length: 1
        )) as NSString
        return value.length == 1 ? value.character(at: 0) : nil
    }

    private func chunkIndex(containingOrFollowing textIndex: Int) -> Int {
        guard !chunkStorage.isEmpty else { return 0 }
        let absoluteIndex = textOrigin + textIndex
        var low = 0
        var high = chunkStartStorage.count
        while low < high {
            let middle = (low + high) / 2
            if chunkStartStorage[middle] <= absoluteIndex {
                low = middle + 1
            } else {
                high = middle
            }
        }
        var index = max(0, low - 1)
        while index < chunkStorage.count,
            chunkStartStorage[index] + chunkStorage[index].utf16.count <= absoluteIndex
        {
            index += 1
        }
        return index
    }

    private static func makeChunkStarts(_ chunks: [String]) -> [Int] {
        var starts: [Int] = []
        starts.reserveCapacity(chunks.count)
        var offset = 0
        for chunk in chunks {
            starts.append(offset)
            offset += chunk.utf16.count
        }
        return starts
    }

    private struct LineIndexBuilder {
        var lines: [LogViewportLine] = []
        var lineStart: Int
        var globalOffset: Int
        var lineParts: [String] = []
        var lineIsASCII = true
        var lineFirstCodeUnit: unichar?
        var lineLastCodeUnit: unichar?
        var previousTerminatorWasCarriageReturn: Bool
        var isFinished = false

        init(
            startOffset: Int,
            precedingTerminatorWasCarriageReturn: Bool = false
        ) {
            lineStart = startOffset
            globalOffset = startOffset
            previousTerminatorWasCarriageReturn =
                precedingTerminatorWasCarriageReturn
        }

        mutating func append(contentsOf chunks: [String]) throws {
            for (index, chunk) in chunks.enumerated() {
                if index & 63 == 0 { try Task.checkCancellation() }
                append(chunk)
            }
        }

        mutating func append(_ chunk: String) {
            let utf16Length = chunk.utf16.count
            // Every non-ASCII Unicode scalar occupies more UTF-8 units than
            // UTF-16 units, so equal counts prove ASCII without another scan.
            if chunk.utf8.count == utf16Length,
                chunk.utf8.withContiguousStorageIfAvailable({ bytes in
                    appendASCII(chunk, bytes: bytes)
                    return true
                }) == true
            {
                globalOffset += utf16Length
                return
            }

            appendUnicode(chunk, utf16Length: utf16Length)
        }

        private mutating func appendASCII(
            _ chunk: String,
            bytes: UnsafeBufferPointer<UInt8>
        ) {
            var cursor = 0
            while let newlineOffset = firstASCIINewline(
                in: bytes,
                from: cursor
            ) {
                appendASCIISegment(
                    of: chunk,
                    bytes: bytes,
                    range: cursor..<newlineOffset
                )
                finishNewline(
                    at: globalOffset + newlineOffset,
                    codeUnit: unichar(bytes[newlineOffset]),
                    length: 1
                )
                cursor = newlineOffset + 1
            }
            appendASCIISegment(
                of: chunk,
                bytes: bytes,
                range: cursor..<bytes.count
            )
        }

        private mutating func appendASCIISegment(
            of chunk: String,
            bytes: UnsafeBufferPointer<UInt8>,
            range: Range<Int>
        ) {
            guard !range.isEmpty else { return }
            recordLineBoundaries(
                first: unichar(bytes[range.lowerBound]),
                last: unichar(bytes[range.upperBound - 1])
            )
            if range.lowerBound == 0, range.upperBound == bytes.count {
                lineParts.append(chunk)
            } else {
                lineParts.append(String(decoding: bytes[range], as: UTF8.self))
            }
            previousTerminatorWasCarriageReturn = false
        }

        private mutating func appendUnicode(
            _ chunk: String,
            utf16Length: Int
        ) {
            let value = chunk as NSString
            let newlines = CharacterSet.newlines
            var cursor = 0
            while cursor < value.length {
                let newline = value.rangeOfCharacter(
                    from: newlines,
                    options: [],
                    range: NSRange(location: cursor, length: value.length - cursor)
                )
                let segmentEnd = newline.location == NSNotFound
                    ? value.length
                    : newline.location
                if segmentEnd > cursor {
                    let range = NSRange(
                        location: cursor,
                        length: segmentEnd - cursor
                    )
                    recordLineBoundaries(
                        first: value.character(at: cursor),
                        last: value.character(at: segmentEnd - 1)
                    )
                    lineParts.append(
                        cursor == 0 && segmentEnd == value.length
                            ? chunk
                            : value.substring(with: range)
                    )
                    lineIsASCII = false
                    previousTerminatorWasCarriageReturn = false
                }
                guard newline.location != NSNotFound else { break }

                let location = globalOffset + newline.location
                let codeUnit = value.character(at: newline.location)
                finishNewline(
                    at: location,
                    codeUnit: codeUnit,
                    length: newline.length
                )
                cursor = NSMaxRange(newline)
            }
            globalOffset += utf16Length
        }

        private mutating func recordLineBoundaries(
            first: unichar,
            last: unichar
        ) {
            if lineFirstCodeUnit == nil { lineFirstCodeUnit = first }
            lineLastCodeUnit = last
        }

        private mutating func finishNewline(
            at location: Int,
            codeUnit: unichar,
            length: Int
        ) {
            if codeUnit == 0x000a,
                previousTerminatorWasCarriageReturn,
                lineStart == location
            {
                lineStart = location + length
                previousTerminatorWasCarriageReturn = false
            } else {
                finishLine(at: location)
                lineStart = location + length
                previousTerminatorWasCarriageReturn = codeUnit == 0x000d
            }
        }

        private func firstASCIINewline(
            in bytes: UnsafeBufferPointer<UInt8>,
            from start: Int
        ) -> Int? {
            guard start < bytes.count, let baseAddress = bytes.baseAddress else {
                return nil
            }
            let base = UnsafeRawPointer(baseAddress.advanced(by: start))
            let count = bytes.count - start

            @inline(__always)
            func offset(of byte: Int32) -> Int? {
                guard let match = memchr(base, byte, count) else { return nil }
                return start + base.distance(to: UnsafeRawPointer(match))
            }

            // CharacterSet.newlines contains these four ASCII controls. libc's
            // vectorized memchr keeps the overwhelmingly common ASCII path at
            // memory bandwidth without constructing NSString search state.
            return [
                offset(of: 0x0a),
                offset(of: 0x0b),
                offset(of: 0x0c),
                offset(of: 0x0d),
            ].compactMap { $0 }.min()
        }

        mutating func finish() throws -> [LogViewportLine] {
            precondition(!isFinished)
            try Task.checkCancellation()
            finishLine(at: globalOffset)
            isFinished = true
            return lines
        }

        private mutating func finishLine(at end: Int) {
            let length = max(0, end - lineStart)
            let range = NSRange(location: lineStart, length: length)
            let hasJSONObjectBoundaries = lineFirstCodeUnit == 0x7B
                && lineLastCodeUnit == 0x7D
            lineFirstCodeUnit = nil
            lineLastCodeUnit = nil
            if lineIsASCII {
                lines.append(LogViewportLine(
                    textRange: range,
                    cellCount: length,
                    isASCII: true,
                    hasJSONObjectBoundaries: hasJSONObjectBoundaries,
                    variableBoundaries: []
                ))
                lineParts.removeAll(keepingCapacity: true)
                lineIsASCII = true
                return
            }

            let text: String
            switch lineParts.count {
            case 0: text = ""
            case 1: text = lineParts[0]
            default: text = lineParts.joined()
            }
            lineParts.removeAll(keepingCapacity: true)
            lineIsASCII = true

            var cellCount = 0
            var utf16Count = 0
            var boundaries: [LogViewportCellBoundary] = []
            for character in text {
                let characterLength = character.utf16.count
                cellCount += 1
                utf16Count += characterLength
                if characterLength != 1 {
                    boundaries.append(LogViewportCellBoundary(
                        cellBoundary: cellCount,
                        cumulativeUTF16Extra: utf16Count - cellCount
                    ))
                }
            }
            lines.append(LogViewportLine(
                textRange: range,
                cellCount: cellCount,
                isASCII: false,
                hasJSONObjectBoundaries: hasJSONObjectBoundaries,
                variableBoundaries: boundaries
            ))
        }
    }
}

struct LogViewportAnchor: Sendable {
    var textIndex: Int
    var offsetWithinRow: Double
}

private struct LogViewportVisualRow {
    var lineIndex: Int
    var cells: Range<Int>
}

private struct LogViewportGeometry {
    var wrapsLines: Bool
    var columnCapacity: Int
    private var lineRowStarts: LogHeadBuffer<Int>
    private(set) var lineCount: Int

    var visualRowCount: Int {
        guard wrapsLines else { return max(1, lineCount) }
        guard let first = lineRowStarts.first, let last = lineRowStarts.last else {
            return 1
        }
        return max(1, last - first)
    }

    init(
        projection: LogViewportProjection,
        wrapsLines: Bool,
        viewportWidth: CGFloat,
        horizontalInsets: CGFloat
    ) {
        self.wrapsLines = wrapsLines
        columnCapacity = max(
            1,
            Int(floor(
                Double(max(1, viewportWidth - horizontalInsets))
                    / projection.style.cellWidth
            ))
        )
        var starts = [0]
        if wrapsLines { starts.reserveCapacity(projection.lines.count + 1) }
        var total = 0
        if wrapsLines {
            for line in projection.lines {
                total += max(1, (line.cellCount + columnCapacity - 1) / columnCapacity)
                starts.append(total)
            }
        }
        lineRowStarts = LogHeadBuffer(starts)
        lineCount = projection.lines.count
    }

    mutating func apply(
        _ edit: LogViewportProjectionEditResult,
        projection: LogViewportProjection
    ) {
        defer { lineCount = projection.lines.count }
        guard wrapsLines else { return }
        if edit.removedLineCount > 0 {
            lineRowStarts.discardFirst(edit.removedLineCount)
        }
        let newLineCount = projection.lines.count
        guard edit.rebuiltTailLineCount > 0 else {
            // Prefix eviction can replace every old line with the single
            // empty sentinel above. The retained endpoint is then also the
            // new line's start; append its endpoint so later edits continue
            // to have the usual lineCount + 1 geometry entries.
            if newLineCount > 0,
                lineRowStarts.count == newLineCount,
                let lastLine = projection.lines.last
            {
                let total = lineRowStarts.last ?? 0
                lineRowStarts.append(total + rows(for: lastLine))
            }
            return
        }

        // The old open final line contributed the last endpoint. Retain its
        // start and append endpoints for only the rebuilt tail.
        lineRowStarts.discardLast()
        if lineRowStarts.isEmpty {
            // Every old line was removed. There is no retained start to anchor
            // the rebuilt suffix, so begin its row endpoints at zero.
            lineRowStarts.append(0)
        }
        var total = lineRowStarts.last ?? 0
        for line in projection.lines.suffix(edit.rebuiltTailLineCount) {
            total += rows(for: line)
            lineRowStarts.append(total)
        }
    }

    func rowStart(forLine lineIndex: Int) -> Int {
        guard wrapsLines, let origin = lineRowStarts.first else {
            return lineIndex
        }
        return lineRowStarts[lineIndex] - origin
    }

    func visualRow(
        at requestedRow: Int,
        projection: LogViewportProjection
    ) -> LogViewportVisualRow {
        let row = max(0, min(requestedRow, max(0, visualRowCount - 1)))
        guard wrapsLines else {
            let lineIndex = min(row, projection.lines.count - 1)
            let line = projection.lines[lineIndex]
            return LogViewportVisualRow(
                lineIndex: lineIndex,
                cells: 0..<line.cellCount
            )
        }

        let absoluteRow = (lineRowStarts.first ?? 0) + row
        var low = 0
        var high = max(0, lineCount - 1)
        while low < high {
            let middle = (low + high + 1) / 2
            if lineRowStarts[middle] <= absoluteRow {
                low = middle
            } else {
                high = middle - 1
            }
        }
        let lineIndex = min(low, projection.lines.count - 1)
        let line = projection.lines[lineIndex]
        let rowWithinLine = absoluteRow - lineRowStarts[lineIndex]
        let start = min(line.cellCount, rowWithinLine * columnCapacity)
        let end = min(line.cellCount, start + columnCapacity)
        return LogViewportVisualRow(lineIndex: lineIndex, cells: start..<end)
    }

    private func rows(for line: LogViewportLine) -> Int {
        max(1, (line.cellCount + columnCapacity - 1) / columnCapacity)
    }
}

/// A selectable fixed-cell log surface. Its document dimensions are exact
/// arithmetic values, wrapped rows are virtual, and only cells intersecting a
/// dirty rectangle are shaped or drawn.
@MainActor
final class LogViewportView: NSView, NSMenuItemValidation {
    let font: NSFont
    let textContainerInset = NSSize(width: 8, height: 8)
    private(set) var projection: LogViewportProjection
    private(set) var wrapsLines = false
    private var geometry: LogViewportGeometry
    private var selectionAnchor: Int?
    private var isSelecting = false
    private let glyphWidthCache = NSCache<NSString, NSNumber>()

    /// Test-visible work counters prove that a huge offscreen line never turns
    /// into glyph work during a viewport draw.
    private(set) var lastDrawnCellCount = 0
    private(set) var lastDrawnUnicodeCellCount = 0
    private(set) var lastJSONTokenCount = 0
    private(set) var lastJSONScannedUTF16Length = 0
    /// Lines indexed by the most recent projection installation. Sustained
    /// updates should report only their appended suffix, never retained rows.
    private(set) var lastProjectionIndexedLineCount = 0

    var selectedRangeValue = NSRange(location: 0, length: 0) {
        didSet { setNeedsDisplay(visibleRect) }
    }

    var visualRowCount: Int { geometry.visualRowCount }
    var wrappingColumnCapacity: Int { geometry.columnCapacity }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(
        frame frameRect: NSRect,
        font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    ) {
        self.font = font
        let style = LogViewportTextStyle(font: font)
        projection = .empty(style: style)
        geometry = LogViewportGeometry(
            projection: projection,
            wrapsLines: false,
            viewportWidth: frameRect.width,
            horizontalInsets: 16
        )
        super.init(frame: frameRect)
        glyphWidthCache.countLimit = 2_048
        wantsLayer = false
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Pod logs")
        setAccessibilityEnabled(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic") }

    var string: String { projection.joinedText() }

    func selectedRange() -> NSRange { selectedRangeValue }

    func setSelectedRange(_ range: NSRange) {
        let location = max(0, min(range.location, projection.textUTF16Length))
        let requestedEnd = range.location.addingReportingOverflow(range.length)
        let end = max(
            location,
            min(
                requestedEnd.overflow ? Int.max : requestedEnd.partialValue,
                projection.textUTF16Length
            )
        )
        selectedRangeValue = NSRange(location: location, length: end - location)
    }

    func install(
        _ replacement: LogViewportProjection,
        viewportSize: NSSize
    ) {
        projection = replacement
        lastProjectionIndexedLineCount = replacement.lines.count
        setSelectedRange(selectedRangeValue)
        rebuildGeometry(viewportSize: viewportSize)
        updateFrame(for: viewportSize)
        setNeedsDisplay(visibleRect)
    }

    func applyLineAlignedEdit(
        removePrefixChunkCount: Int,
        appendChunks: [String],
        viewportSize: NSSize
    ) throws {
        let edit = try projection.applyLineAlignedEdit(
            removePrefixChunkCount: removePrefixChunkCount,
            appendChunks: appendChunks
        )
        lastProjectionIndexedLineCount = edit.rebuiltTailLineCount
        geometry.apply(edit, projection: projection)
        setSelectedRange(selectedRangeValue)
        updateFrame(for: viewportSize)
        setNeedsDisplay(visibleRect)
    }

    func setWrapsLines(_ enabled: Bool, viewportSize: NSSize) {
        guard wrapsLines != enabled else {
            updateDocumentFrame(for: viewportSize)
            return
        }
        wrapsLines = enabled
        rebuildGeometry(viewportSize: viewportSize)
        updateFrame(for: viewportSize)
        setNeedsDisplay(visibleRect)
    }

    func updateDocumentFrame(for viewportSize: NSSize) {
        let oldCapacity = geometry.columnCapacity
        let capacity = columnCapacity(for: viewportSize.width)
        if geometry.wrapsLines != wrapsLines
            || (wrapsLines && oldCapacity != capacity)
            || geometry.lineCount != projection.lines.count
        {
            rebuildGeometry(viewportSize: viewportSize)
        }
        updateFrame(for: viewportSize)
    }

    func verticalAnchor(at documentY: CGFloat) -> LogViewportAnchor {
        let lineHeight = CGFloat(projection.style.lineHeight)
        let relative = documentY - textContainerInset.height
        let row = max(
            0,
            min(
                visualRowCount - 1,
                Int(floor(max(0, relative) / lineHeight))
            )
        )
        let visual = geometry.visualRow(at: row, projection: projection)
        let line = projection.lines[visual.lineIndex]
        return LogViewportAnchor(
            textIndex: line.textIndex(atCellBoundary: visual.cells.lowerBound),
            offsetWithinRow: Double(relative - CGFloat(row) * lineHeight)
        )
    }

    func verticalOffset(for anchor: LogViewportAnchor) -> CGFloat {
        let lineIndex = projection.lineIndex(
            containingTextIndex: anchor.textIndex
        )
        let line = projection.lines[lineIndex]
        let cell = line.cellBoundary(
            atTextIndex: anchor.textIndex,
            roundingUp: false
        )
        let rowWithinLine = wrapsLines ? cell / geometry.columnCapacity : 0
        let row = geometry.rowStart(forLine: lineIndex) + rowWithinLine
        return textContainerInset.height
            + CGFloat(row) * CGFloat(projection.style.lineHeight)
            + CGFloat(anchor.offsetWithinRow)
    }

    func visualRowText(at row: Int) -> String {
        let visual = geometry.visualRow(at: row, projection: projection)
        let line = projection.lines[visual.lineIndex]
        return projection.substring(in: line.textRange(forCells: visual.cells))
    }

    func visualRowCellCount(at row: Int) -> Int {
        geometry.visualRow(at: row, projection: projection).cells.count
    }

    func filterHighlightRanges(forVisualRow row: Int) -> [NSRange] {
        let visual = geometry.visualRow(at: row, projection: projection)
        return projection.highlightedRanges(
            inLine: visual.lineIndex,
            intersecting: visual.cells
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        lastDrawnCellCount = 0
        lastDrawnUnicodeCellCount = 0
        lastJSONTokenCount = 0
        lastJSONScannedUTF16Length = 0

        let lineHeight = CGFloat(projection.style.lineHeight)
        guard lineHeight > 0, visualRowCount > 0 else { return }
        let firstRow = max(
            0,
            Int(floor((dirtyRect.minY - textContainerInset.height) / lineHeight))
        )
        let lastRow = min(
            visualRowCount - 1,
            Int(ceil((dirtyRect.maxY - textContainerInset.height) / lineHeight))
        )
        guard firstRow <= lastRow else { return }

        let attributes = textAttributes
        for rowIndex in firstRow...lastRow {
            let visual = geometry.visualRow(at: rowIndex, projection: projection)
            let line = projection.lines[visual.lineIndex]
            let top = textContainerInset.height + CGFloat(rowIndex) * lineHeight
            let visibleCells = cellsToDraw(
                in: visual,
                dirtyRect: dirtyRect
            )
            guard !visibleCells.isEmpty || line.cellCount == 0 else { continue }

            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(
                x: dirtyRect.minX,
                y: top,
                width: dirtyRect.width,
                height: lineHeight
            )).addClip()
            drawFilterHighlights(
                visual: visual,
                visibleCells: visibleCells,
                top: top
            )
            drawSelection(
                visual: visual,
                visibleCells: visibleCells,
                top: top
            )
            drawText(
                line: line,
                visual: visual,
                cells: visibleCells,
                top: top,
                attributes: attributes
            )
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .ligature: 0,
            .kern: 0,
        ]
    }

    private func cellsToDraw(
        in visual: LogViewportVisualRow,
        dirtyRect: NSRect
    ) -> Range<Int> {
        let width = CGFloat(projection.style.cellWidth)
        let rowOriginCell = wrapsLines ? visual.cells.lowerBound : 0
        let localLeft = dirtyRect.minX - textContainerInset.width
        let localRight = dirtyRect.maxX - textContainerInset.width
        let first = rowOriginCell + max(0, Int(floor(localLeft / width)))
        let end = rowOriginCell + max(0, Int(ceil(localRight / width)))
        let visibleStart = max(visual.cells.lowerBound, first)
        let visibleEnd = min(visual.cells.upperBound, max(first, end))
        guard visibleEnd > visibleStart else {
            return visual.cells.lowerBound..<visual.cells.lowerBound
        }
        return visibleStart..<visibleEnd
    }

    private func drawText(
        line: LogViewportLine,
        visual: LogViewportVisualRow,
        cells: Range<Int>,
        top: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard !cells.isEmpty else { return }
        let sourceRange = line.textRange(forCells: cells)
        let value = projection.substring(in: sourceRange)
        let jsonHighlight = projection.jsonHighlight(
            inLine: visual.lineIndex,
            intersecting: cells
        )
        lastDrawnCellCount += cells.count
        lastJSONTokenCount += jsonHighlight.tokens.count
        lastJSONScannedUTF16Length += jsonHighlight.scannedUTF16Length

        if line.isASCII,
            value.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7f })
        {
            let origin = NSPoint(
                x: xPosition(forCell: cells.lowerBound, in: visual),
                y: top
            )
            if jsonHighlight.tokens.isEmpty {
                (value as NSString).draw(at: origin, withAttributes: attributes)
            } else {
                let styled = NSMutableAttributedString(
                    string: value,
                    attributes: attributes
                )
                for token in jsonHighlight.tokens {
                    let clipped = NSIntersectionRange(token.range, sourceRange)
                    guard clipped.length > 0 else { continue }
                    styled.addAttribute(
                        .foregroundColor,
                        value: SyntaxHighlightingPalette.color(for: token.kind),
                        range: NSRange(
                            location: clipped.location - sourceRange.location,
                            length: clipped.length
                        )
                    )
                }
                styled.draw(at: origin)
            }
            return
        }

        var cell = cells.lowerBound
        var textIndex = sourceRange.location
        var tokenIndex = 0
        var asciiRun = String()
        var asciiRunStart = cell
        var asciiRunKind: SyntaxTokenKind?

        func tokenKind(at location: Int) -> SyntaxTokenKind? {
            while tokenIndex < jsonHighlight.tokens.count,
                NSMaxRange(jsonHighlight.tokens[tokenIndex].range) <= location
            {
                tokenIndex += 1
            }
            guard tokenIndex < jsonHighlight.tokens.count else { return nil }
            let token = jsonHighlight.tokens[tokenIndex]
            return token.range.location <= location && location < NSMaxRange(token.range)
                ? token.kind : nil
        }

        func flushASCII() {
            guard !asciiRun.isEmpty else { return }
            (asciiRun as NSString).draw(
                at: NSPoint(x: xPosition(forCell: asciiRunStart, in: visual), y: top),
                withAttributes: textAttributes(attributes, syntaxKind: asciiRunKind)
            )
            asciiRun.removeAll(keepingCapacity: true)
        }

        for character in value {
            let syntaxKind = tokenKind(at: textIndex)
            let isPrintableASCII = character.unicodeScalars.count == 1
                && character.unicodeScalars.first.map {
                    $0.isASCII && $0.value >= 0x20 && $0.value < 0x7f
                } == true
            if isPrintableASCII {
                if !asciiRun.isEmpty, asciiRunKind != syntaxKind { flushASCII() }
                if asciiRun.isEmpty {
                    asciiRunStart = cell
                    asciiRunKind = syntaxKind
                }
                asciiRun.append(character)
            } else {
                flushASCII()
                if character != "\t" {
                    lastDrawnUnicodeCellCount += 1
                    drawFixedCell(
                        String(character),
                        at: xPosition(forCell: cell, in: visual),
                        top: top,
                        attributes: textAttributes(
                            attributes,
                            syntaxKind: syntaxKind
                        )
                    )
                }
            }
            cell += 1
            textIndex += character.utf16.count
        }
        flushASCII()
    }

    private func textAttributes(
        _ base: [NSAttributedString.Key: Any],
        syntaxKind: SyntaxTokenKind?
    ) -> [NSAttributedString.Key: Any] {
        guard let syntaxKind else { return base }
        var result = base
        result[.foregroundColor] = SyntaxHighlightingPalette.color(for: syntaxKind)
        return result
    }

    private func drawFixedCell(
        _ value: String,
        at x: CGFloat,
        top: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) {
        let key = value as NSString
        let naturalWidth: CGFloat
        if let cached = glyphWidthCache.object(forKey: key) {
            naturalWidth = CGFloat(cached.doubleValue)
        } else {
            naturalWidth = max(1, key.size(withAttributes: attributes).width)
            glyphWidthCache.setObject(NSNumber(value: Double(naturalWidth)), forKey: key)
        }
        let cellWidth = CGFloat(projection.style.cellWidth)
        let rect = NSRect(
            x: x,
            y: top,
            width: cellWidth,
            height: CGFloat(projection.style.lineHeight)
        )
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: rect)
        if naturalWidth > cellWidth {
            context.translateBy(x: x, y: 0)
            context.scaleBy(x: cellWidth / naturalWidth, y: 1)
            key.draw(at: NSPoint(x: 0, y: top), withAttributes: attributes)
        } else {
            key.draw(
                at: NSPoint(x: x + (cellWidth - naturalWidth) / 2, y: top),
                withAttributes: attributes
            )
        }
        context.restoreGState()
    }

    private func drawFilterHighlights(
        visual: LogViewportVisualRow,
        visibleCells: Range<Int>,
        top: CGFloat
    ) {
        let ranges = projection.highlightedRanges(
            inLine: visual.lineIndex,
            intersecting: visibleCells
        )
        guard !ranges.isEmpty else { return }
        let line = projection.lines[visual.lineIndex]
        NSColor.systemYellow.withAlphaComponent(0.42).setFill()
        for range in ranges {
            let cells = line.cellRange(containing: range)
            let visibleStart = max(cells.lowerBound, visibleCells.lowerBound)
            let visibleEnd = min(cells.upperBound, visibleCells.upperBound)
            guard visibleEnd > visibleStart else { continue }
            let visible = visibleStart..<visibleEnd
            cellRect(visible, in: visual, top: top).fill()
        }
    }

    private func drawSelection(
        visual: LogViewportVisualRow,
        visibleCells: Range<Int>,
        top: CGFloat
    ) {
        let selectionStart = selectedRangeValue.location
        let selectionEnd = selectionStart + selectedRangeValue.length
        guard selectionEnd > selectionStart else { return }
        let line = projection.lines[visual.lineIndex]
        let lineStart = line.textRange.location
        let lineEnd = lineStart + line.textRange.length
        let sourceStart = max(selectionStart, lineStart)
        let sourceEnd = min(selectionEnd, lineEnd)
        guard sourceEnd > sourceStart else { return }
        let cells = line.cellRange(containing: NSRange(
            location: sourceStart,
            length: sourceEnd - sourceStart
        ))
        let visibleStart = max(cells.lowerBound, visibleCells.lowerBound)
        let visibleEnd = min(cells.upperBound, visibleCells.upperBound)
        guard visibleEnd > visibleStart else { return }
        let visible = visibleStart..<visibleEnd
        NSColor.selectedTextBackgroundColor.setFill()
        cellRect(visible, in: visual, top: top).fill()
    }

    private func cellRect(
        _ cells: Range<Int>,
        in visual: LogViewportVisualRow,
        top: CGFloat
    ) -> NSRect {
        let width = CGFloat(projection.style.cellWidth)
        return NSRect(
            x: xPosition(forCell: cells.lowerBound, in: visual),
            y: top,
            width: CGFloat(cells.count) * width,
            height: CGFloat(projection.style.lineHeight)
        )
    }

    private func xPosition(
        forCell cell: Int,
        in visual: LogViewportVisualRow
    ) -> CGFloat {
        let localCell = wrapsLines ? cell - visual.cells.lowerBound : cell
        return textContainerInset.width
            + CGFloat(localCell) * CGFloat(projection.style.cellWidth)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let index = textIndex(at: point)
        selectionAnchor = index
        isSelecting = true
        setSelectedRange(NSRange(location: index, length: 0))
    }

    override func mouseDragged(with event: NSEvent) {
        guard isSelecting, let selectionAnchor else { return }
        autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let index = textIndex(at: point)
        setSelectedRange(NSRange(
            location: min(selectionAnchor, index),
            length: abs(index - selectionAnchor)
        ))
    }

    override func mouseUp(with event: NSEvent) {
        isSelecting = false
        selectionAnchor = nil
    }

    override func selectAll(_ sender: Any?) {
        setSelectedRange(NSRange(location: 0, length: projection.textUTF16Length))
    }

    @objc func copy(_ sender: Any?) {
        guard selectedRangeValue.length > 0 else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            projection.substring(in: selectedRangeValue),
            forType: .string
        )
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return selectedRangeValue.length > 0
        case #selector(selectAll(_:)):
            return projection.textUTF16Length > 0
        default:
            return true
        }
    }

    private func textIndex(at point: NSPoint) -> Int {
        let lineHeight = CGFloat(projection.style.lineHeight)
        guard lineHeight > 0, visualRowCount > 0 else { return 0 }
        let row = max(
            0,
            min(
                visualRowCount - 1,
                Int(floor((point.y - textContainerInset.height) / lineHeight))
            )
        )
        let visual = geometry.visualRow(at: row, projection: projection)
        let line = projection.lines[visual.lineIndex]
        let width = CGFloat(projection.style.cellWidth)
        let localX = max(0, point.x - textContainerInset.width)
        let baseCell = wrapsLines ? visual.cells.lowerBound : 0
        let cellPosition = localX / width
        var boundary = baseCell + Int(floor(cellPosition))
        if cellPosition - floor(cellPosition) >= 0.5 { boundary += 1 }
        boundary = max(
            visual.cells.lowerBound,
            min(boundary, visual.cells.upperBound)
        )
        return line.textIndex(atCellBoundary: boundary)
    }

    private func columnCapacity(for viewportWidth: CGFloat) -> Int {
        max(
            1,
            Int(floor(
                Double(max(1, viewportWidth - textContainerInset.width * 2))
                    / projection.style.cellWidth
            ))
        )
    }

    private func rebuildGeometry(viewportSize: NSSize) {
        geometry = LogViewportGeometry(
            projection: projection,
            wrapsLines: wrapsLines,
            viewportWidth: viewportSize.width,
            horizontalInsets: textContainerInset.width * 2
        )
    }

    private func updateFrame(for viewportSize: NSSize) {
        let width = wrapsLines
            ? max(1, viewportSize.width)
            : max(
                1,
                max(
                    viewportSize.width,
                    CGFloat(projection.maximumWidth)
                        + textContainerInset.width * 2
                )
            )
        let height = max(
            1,
            max(
                viewportSize.height,
                CGFloat(visualRowCount) * CGFloat(projection.style.lineHeight)
                    + textContainerInset.height * 2
            )
        )
        let size = NSSize(width: width, height: height)
        if frame.size != size { setFrameSize(size) }
    }
}
