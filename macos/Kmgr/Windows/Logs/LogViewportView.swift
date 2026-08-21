import AppKit
import CoreText

/// Immutable font facts passed to the detached log-layout worker. AppKit
/// objects stay on the main actor; the worker creates its own CTFont.
struct LogViewportTextStyle: Hashable, Sendable {
    var fontName: String
    var pointSize: Double
    var lineHeight: Double
    var tabWidth: Double

    @MainActor
    init(font: NSFont) {
        fontName = font.fontName
        pointSize = Double(font.pointSize)
        lineHeight = Double(max(
            1,
            ceil(font.ascender - font.descender + font.leading)
        ))
        let advance = max(
            1,
            ("M" as NSString).size(withAttributes: [.font: font]).width
        )
        tabWidth = Double(advance * 8)
    }

    nonisolated func makeCTFont() -> CTFont {
        CTFontCreateWithName(
            fontName as CFString,
            CGFloat(pointSize),
            nil
        )
    }
}

/// A chunk is retained by value so unchanged suffix chunks can be reused
/// between streaming renders. Each piece is small enough to shape and draw
/// without ever asking Core Text to process an entire pathological line.
struct LogViewportChunkLayout: Sendable {
    enum Piece: Sendable {
        case text(range: NSRange, width: Double)
        case tab(range: NSRange)
        case newline(range: NSRange)

        var range: NSRange {
            switch self {
            case .text(let range, _), .tab(let range), .newline(let range):
                return range
            }
        }
    }

    var text: String
    var pieces: [Piece]
}

struct LogViewportRun: Sendable {
    var chunkIndex: Int
    var pieceIndex: Int
    var globalRange: NSRange
    var x: Double
    var width: Double
}

struct LogViewportRow: Sendable {
    var runs: [LogViewportRun]
    /// The range excludes the terminating newline. The newline remains part
    /// of the projection's global UTF-16 coordinate space for copy/selection.
    var textRange: NSRange
    var width: Double
}

/// Main-actor-independent geometry for a plain, unwrapped log surface.
/// Vertical positions are arithmetic row positions; horizontal positions are
/// measured in bounded pieces. No TextKit line fragments are involved.
struct LogViewportProjection: Sendable {
    static let maximumPieceUTF16Length = 4_096

    var style: LogViewportTextStyle
    var chunks: [LogViewportChunkLayout]
    var chunkStarts: [Int]
    var rows: [LogViewportRow]
    var textUTF16Length: Int
    var maximumWidth: Double

    static func empty(style: LogViewportTextStyle) -> Self {
        Self(
            style: style,
            chunks: [],
            chunkStarts: [],
            rows: [LogViewportRow(
                runs: [],
                textRange: NSRange(location: 0, length: 0),
                width: 0
            )],
            textUTF16Length: 0,
            maximumWidth: 0
        )
    }

    /// Builds a replacement while reusing the unchanged suffix identified by
    /// `LogTextInstallPlanner`. Only newly appended/reformatted chunks are
    /// shaped; row assembly is a cheap linear pass over already measured
    /// pieces.
    static func make(
        chunks: [String],
        previous: Self?,
        retainedChunkCount: Int,
        style: LogViewportTextStyle
    ) throws -> Self {
        let overlap = max(0, min(retainedChunkCount, chunks.count))
        let measurement = Measurement(style: style)
        var layouts: [LogViewportChunkLayout] = []
        layouts.reserveCapacity(chunks.count)

        let canReuse: Bool
        if let previous,
            previous.style == style,
            previous.chunks.count >= overlap,
            overlap > 0
        {
            canReuse = (0..<overlap).allSatisfy { index in
                previous.chunks[previous.chunks.count - overlap + index].text
                    == chunks[index]
            }
        } else {
            canReuse = false
        }
        if canReuse, let previous {
            layouts.append(contentsOf: previous.chunks.suffix(overlap))
        } else {
            for text in chunks.prefix(overlap) {
                try Task.checkCancellation()
                layouts.append(try makeChunk(text, measurement: measurement))
            }
        }

        if chunks.count > overlap {
            for text in chunks.dropFirst(overlap) {
                try Task.checkCancellation()
                layouts.append(try makeChunk(text, measurement: measurement))
            }
        }
        return assemble(layouts, style: style)
    }

    func joinedText() -> String {
        chunks.map(\.text).joined()
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

        var result = String()
        result.reserveCapacity(end - start)
        for (index, chunk) in chunks.enumerated() {
            let chunkStart = chunkStarts[index]
            let chunkEnd = chunkStart + chunk.text.utf16.count
            guard chunkEnd > start, chunkStart < end else {
                continue
            }
            let localStart = max(0, start - chunkStart)
            let localEnd = min(chunk.text.utf16.count, end - chunkStart)
            guard localEnd > localStart else { continue }
            result += (chunk.text as NSString).substring(
                with: NSRange(
                    location: localStart,
                    length: localEnd - localStart
                )
            )
        }
        return result
    }

    private static func makeChunk(
        _ text: String,
        measurement: Measurement
    ) throws -> LogViewportChunkLayout {
        let value = text as NSString
        guard value.length > 0 else {
            return LogViewportChunkLayout(text: text, pieces: [])
        }

        var pieces: [LogViewportChunkLayout.Piece] = []
        pieces.reserveCapacity(max(1, value.length / maximumPieceUTF16Length))
        let controls = CharacterSet.newlines.union(
            CharacterSet(charactersIn: "\t")
        )
        var cursor = 0
        while cursor < value.length {
            try Task.checkCancellation()
            let codeUnit = value.character(at: cursor)
            if isNewline(codeUnit) {
                let range = NSRange(location: cursor, length: 1)
                pieces.append(.newline(range: range))
                cursor += 1
                continue
            }
            if codeUnit == 0x09 {
                let range = NSRange(location: cursor, length: 1)
                pieces.append(.tab(range: range))
                cursor += 1
                continue
            }

            let start = cursor
            var end = min(value.length, start + maximumPieceUTF16Length)
            if end < value.length {
                let sequence = value.rangeOfComposedCharacterSequence(at: end)
                if sequence.location < end {
                    end = sequence.location
                }
                if end == start {
                    // A composed sequence larger than the normal piece budget
                    // is still finite and must make progress.
                    end = sequence.location + sequence.length
                }
            }
            let special = value.rangeOfCharacter(
                from: controls,
                options: [],
                range: NSRange(location: start, length: end - start)
            )
            if special.location != NSNotFound {
                end = special.location
            }
            guard end > start else { continue }
            let range = NSRange(location: start, length: end - start)
            let pieceText = value.substring(with: range)
            pieces.append(.text(
                range: range,
                width: measurement.measure(pieceText)
            ))
            cursor = end
        }
        return LogViewportChunkLayout(text: text, pieces: pieces)
    }

    private static func isNewline(_ codeUnit: unichar) -> Bool {
        switch codeUnit {
        case 0x000a, 0x000b, 0x000c, 0x000d, 0x0085, 0x2028, 0x2029:
            true
        default:
            false
        }
    }

    private final class Measurement {
        private let attributes: CFDictionary

        init(style: LogViewportTextStyle) {
            attributes = [
                kCTFontAttributeName: style.makeCTFont(),
                kCTLigatureAttributeName: 0,
                kCTKernAttributeName: 0,
            ] as CFDictionary
        }

        func measure(_ text: String) -> Double {
            guard !text.isEmpty else { return 0 }
            guard let attributed = CFAttributedStringCreate(
                nil,
                text as CFString,
                attributes
            ) else { return 0 }
            let line = CTLineCreateWithAttributedString(attributed)
            return max(
                0,
                Double(CTLineGetTypographicBounds(line, nil, nil, nil))
            )
        }
    }

    private static func assemble(
        _ chunks: [LogViewportChunkLayout],
        style: LogViewportTextStyle
    ) -> Self {
        var chunkStarts: [Int] = []
        chunkStarts.reserveCapacity(chunks.count)
        var globalOffset = 0
        for chunk in chunks {
            chunkStarts.append(globalOffset)
            globalOffset += chunk.text.utf16.count
        }

        var rows: [LogViewportRow] = []
        rows.reserveCapacity(max(1, chunks.count))
        var runs: [LogViewportRun] = []
        var lineStart = 0
        var lineWidth = 0.0
        var maximumWidth = 0.0
        var previousTerminatorWasCarriageReturn = false

        func finishLine(at end: Int) {
            rows.append(LogViewportRow(
                runs: runs,
                textRange: NSRange(
                    location: lineStart,
                    length: max(0, end - lineStart)
                ),
                width: lineWidth
            ))
            maximumWidth = max(maximumWidth, lineWidth)
            runs.removeAll(keepingCapacity: true)
            lineStart = end
            lineWidth = 0
        }

        for (chunkIndex, chunk) in chunks.enumerated() {
            let chunkStart = chunkStarts[chunkIndex]
            let chunkText = chunk.text as NSString
            for (pieceIndex, piece) in chunk.pieces.enumerated() {
                let location = chunkStart + piece.range.location
                switch piece {
                case .text(_, let width):
                    previousTerminatorWasCarriageReturn = false
                    runs.append(LogViewportRun(
                        chunkIndex: chunkIndex,
                        pieceIndex: pieceIndex,
                        globalRange: NSRange(
                            location: location,
                            length: piece.range.length
                        ),
                        x: lineWidth,
                        width: width
                    ))
                    lineWidth += width
                case .tab:
                    previousTerminatorWasCarriageReturn = false
                    let tabWidth = max(1, style.tabWidth)
                    let remainder = lineWidth.truncatingRemainder(
                        dividingBy: tabWidth
                    )
                    let width = max(1, tabWidth - remainder)
                    runs.append(LogViewportRun(
                        chunkIndex: chunkIndex,
                        pieceIndex: pieceIndex,
                        globalRange: NSRange(
                            location: location,
                            length: piece.range.length
                        ),
                        x: lineWidth,
                        width: width
                    ))
                    lineWidth += width
                case .newline(let range):
                    let codeUnit = chunkText.character(at: range.location)
                    if codeUnit == 0x000a,
                        previousTerminatorWasCarriageReturn,
                        lineStart == location
                    {
                        // CRLF is one visual boundary even when the two code
                        // units arrive in separate streaming chunks.
                        lineStart = location + range.length
                        previousTerminatorWasCarriageReturn = false
                        continue
                    }
                    finishLine(at: location)
                    lineStart = location + range.length
                    previousTerminatorWasCarriageReturn = codeUnit == 0x000d
                }
            }
        }
        finishLine(at: globalOffset)
        if rows.isEmpty {
            rows.append(LogViewportRow(
                runs: [],
                textRange: NSRange(location: 0, length: 0),
                width: 0
            ))
        }
        return Self(
            style: style,
            chunks: chunks,
            chunkStarts: chunkStarts,
            rows: rows,
            textUTF16Length: globalOffset,
            maximumWidth: maximumWidth
        )
    }
}

/// A read-only, unwrapped log surface. The document view has deterministic
/// arithmetic row geometry and only shapes the small pieces intersecting the
/// dirty rectangle, including for a multi-megabyte single line.
@MainActor
final class LogViewportView: NSView, NSMenuItemValidation {
    let font: NSFont
    let textContainerInset = NSSize(width: 8, height: 8)
    private(set) var projection: LogViewportProjection
    private var selectionAnchor: Int?
    private var isSelecting = false

    var selectedRangeValue = NSRange(location: 0, length: 0) {
        didSet { setNeedsDisplay(visibleRect) }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(
        frame frameRect: NSRect,
        font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    ) {
        self.font = font
        let style = LogViewportTextStyle(font: font)
        projection = .empty(style: style)
        super.init(frame: frameRect)
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
        let end = max(
            location,
            min(
                range.location.addingReportingOverflow(range.length).overflow
                    ? Int.max
                    : range.location + range.length,
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
        setSelectedRange(selectedRangeValue)
        updateDocumentFrame(for: viewportSize)
        setNeedsDisplay(visibleRect)
    }

    func updateDocumentFrame(for viewportSize: NSSize) {
        let width = max(
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
                CGFloat(projection.rows.count)
                    * CGFloat(projection.style.lineHeight)
                    + textContainerInset.height * 2
            )
        )
        if frame.size != NSSize(width: width, height: height) {
            setFrameSize(NSSize(width: width, height: height))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        let lineHeight = CGFloat(projection.style.lineHeight)
        guard lineHeight > 0, !projection.rows.isEmpty else { return }
        let firstRow = max(
            0,
            Int(floor((dirtyRect.minY - textContainerInset.height) / lineHeight))
        )
        let lastRow = min(
            projection.rows.count - 1,
            Int(ceil((dirtyRect.maxY - textContainerInset.height) / lineHeight))
        )
        guard firstRow <= lastRow else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .ligature: 0,
            .kern: 0,
        ]
        let left = dirtyRect.minX - textContainerInset.width
        let right = dirtyRect.maxX - textContainerInset.width
        for rowIndex in firstRow...lastRow {
            let row = projection.rows[rowIndex]
            let top = textContainerInset.height + CGFloat(rowIndex) * lineHeight
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(
                x: dirtyRect.minX,
                y: top,
                width: dirtyRect.width,
                height: lineHeight
            )).addClip()
            drawSelection(for: row, top: top, left: left, right: right)
            let runStart = firstRun(in: row, intersecting: left)
            if runStart < row.runs.count {
                for run in row.runs[runStart...] {
                    guard run.x < right else { break }
                    guard run.x + run.width > left else { continue }
                    guard case .text(let range, _) = projection.chunks[run.chunkIndex]
                        .pieces[run.pieceIndex]
                    else { continue }
                    let value = (projection.chunks[run.chunkIndex].text as NSString)
                        .substring(with: range)
                    (value as NSString).draw(
                        at: NSPoint(
                            x: textContainerInset.width + CGFloat(run.x),
                            y: top
                        ),
                        withAttributes: attributes
                    )
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawSelection(
        for row: LogViewportRow,
        top: CGFloat,
        left: CGFloat,
        right: CGFloat
    ) {
        let selectionStart = selectedRangeValue.location
        let selectionEnd = selectionStart + selectedRangeValue.length
        guard selectionEnd > selectionStart else { return }
        NSColor.selectedTextBackgroundColor.setFill()
        let runStartIndex = firstRun(in: row, intersecting: left)
        guard runStartIndex < row.runs.count else { return }
        for run in row.runs[runStartIndex...] {
            guard run.x < Double(right) else { break }
            let runStart = run.globalRange.location
            let runEnd = runStart + run.globalRange.length
            guard runEnd > selectionStart, runStart < selectionEnd else { continue }
            let start = max(runStart, selectionStart) - runStart
            let end = min(runEnd, selectionEnd) - runStart
            let startX = run.x + (run.width * Double(start) / Double(run.globalRange.length))
            let endX = run.x + (run.width * Double(end) / Double(run.globalRange.length))
            let rect = NSRect(
                x: textContainerInset.width + CGFloat(startX),
                y: top,
                width: max(1, CGFloat(endX - startX)),
                height: CGFloat(projection.style.lineHeight)
            )
            guard rect.maxX >= left + textContainerInset.width,
                rect.minX <= right + textContainerInset.width
            else { continue }
            rect.fill()
        }
    }

    private func firstRun(
        in row: LogViewportRow,
        intersecting x: CGFloat
    ) -> Int {
        let target = Double(x)
        var low = 0
        var high = row.runs.count
        while low < high {
            let middle = (low + high) / 2
            if row.runs[middle].x + row.runs[middle].width < target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
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
        pasteboard.setString(projection.substring(in: selectedRangeValue), forType: .string)
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
        guard lineHeight > 0, !projection.rows.isEmpty else { return 0 }
        let rowIndex = max(
            0,
            min(
                projection.rows.count - 1,
                Int(floor((point.y - textContainerInset.height) / lineHeight))
            )
        )
        let row = projection.rows[rowIndex]
        let x = Double(point.x - textContainerInset.width)
        guard !row.runs.isEmpty else { return row.textRange.location }
        let runIndex = firstRun(in: row, intersecting: CGFloat(x))
        if runIndex >= row.runs.count {
            return row.textRange.location + row.textRange.length
        }
        let run = row.runs[runIndex]
        if x < run.x { return run.globalRange.location }
        if x >= run.x + run.width {
            return run.globalRange.location + run.globalRange.length
        }
        guard case .text(let range, _) = projection.chunks[run.chunkIndex]
            .pieces[run.pieceIndex]
        else {
            return x - run.x < run.width / 2
                ? run.globalRange.location
                : run.globalRange.location + run.globalRange.length
        }
        let value = (projection.chunks[run.chunkIndex].text as NSString)
            .substring(with: range)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .ligature: 0,
            .kern: 0,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: value, attributes: attributes)
        )
        let local = CTLineGetStringIndexForPosition(
            line,
            CGPoint(x: max(0, x - run.x), y: 0)
        )
        let safe = max(0, min(range.length, local == kCFNotFound ? 0 : local))
        return run.globalRange.location + safe
    }
}
