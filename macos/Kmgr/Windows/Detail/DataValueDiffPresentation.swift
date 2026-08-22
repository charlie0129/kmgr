import Foundation
import KmgrCore

struct DataValueDiffInput: Sendable {
    var key: String
    var beforeKind: DataValueKind?
    var beforeValue: Data?
    var afterKind: DataValueKind
    var afterValue: Data
    var secret: Bool

    mutating func wipe() {
        if var beforeValue {
            self.beforeValue = nil
            beforeValue.resetBytes(in: beforeValue.startIndex..<beforeValue.endIndex)
        }
        afterValue.resetBytes(in: afterValue.startIndex..<afterValue.endIndex)
        afterValue.removeAll(keepingCapacity: false)
    }
}

/// A bounded, AppKit-independent rendering plan for one decoded Data value.
/// Secret callers must keep the rendered strings inside the active review flow.
struct DataValueDiffPresentation: Sendable {
    static let contextLineCount = 3
    static let maximumLineDiffInputByteCount = 512 * 1_024
    static let maximumLineDiffLineCount = 10_000
    static let maximumLineDiffComparisonProduct = 8_000_000
    static let maximumLineUTF8ByteCount = 8 * 1_024
    static let maximumFocusedExcerptUTF8ByteCount = 16 * 1_024
    static let maximumRenderedUTF8ByteCount = 128 * 1_024
    static let maximumRenderedLineCount = 4_096
    static let maximumBinaryRowCount = 16

    enum Format: Hashable, Sendable {
        case text
        case binary
    }

    let key: String
    let beforeKind: DataValueKind?
    let afterKind: DataValueKind
    let beforeByteCount: Int?
    let afterByteCount: Int
    let secret: Bool
    let format: Format
    let lines: [DiffTextLine]
    let previewTruncated: Bool

    init(input: DataValueDiffInput) {
        key = input.key
        beforeKind = input.beforeKind
        afterKind = input.afterKind
        beforeByteCount = input.beforeValue?.count
        afterByteCount = input.afterValue.count
        secret = input.secret

        let beforeText = input.beforeValue.flatMap(Self.decodedText)
        let afterText = Self.decodedText(input.afterValue)
        let canUseTextDiff = input.afterKind == .text
            && (input.beforeKind == nil || input.beforeKind == .text)
            && afterText != nil
            && (input.beforeValue == nil || beforeText != nil)

        if canUseTextDiff, let afterText {
            format = .text
            let rendered = Self.textDiff(before: beforeText, after: afterText)
            lines = rendered.lines
            previewTruncated = rendered.truncated
        } else {
            format = .binary
            let rendered = Self.binaryDiff(
                before: input.beforeValue,
                after: input.afterValue,
                kindChanged: input.beforeKind != nil && input.beforeKind != input.afterKind
            )
            lines = rendered.lines
            previewTruncated = rendered.truncated
        }
    }

    var diffLabel: String {
        switch format {
        case .text: "Unified Value Diff"
        case .binary: "Byte Comparison"
        }
    }

    var metadataText: String {
        let before = beforeKind.map {
            "\(Self.kindText($0)) · \(Self.byteCountText(beforeByteCount ?? 0))"
        } ?? "Absent"
        let after = "\(Self.kindText(afterKind)) · \(Self.byteCountText(afterByteCount))"
        return "\(before) → \(after)"
    }

    var text: String {
        lines.map(\.text).joined(separator: "\n")
    }

    private struct TextLine: Hashable, Sendable {
        var content: String
        var hasNewline: Bool
        var synthetic: Bool
    }

    private enum EventKind: Hashable, Sendable {
        case context
        case removal
        case addition
    }

    private struct Event: Hashable, Sendable {
        var kind: EventKind
        var line: TextLine

        var consumesBefore: Bool { kind != .addition }
        var consumesAfter: Bool { kind != .removal }
    }

    private struct BoundedLines {
        var lines: [DiffTextLine] = []
        var utf8ByteCount = 0
        var truncated = false

        mutating func append(_ text: String, role: DiffTextLineRole) -> Bool {
            guard !truncated else { return false }
            let separatorBytes = lines.isEmpty ? 0 : 1
            let requiredBytes = separatorBytes + text.utf8.count
            let noticeReserve = 256
            guard lines.count < DataValueDiffPresentation.maximumRenderedLineCount,
                utf8ByteCount + requiredBytes
                    <= DataValueDiffPresentation.maximumRenderedUTF8ByteCount - noticeReserve
            else {
                truncated = true
                return false
            }
            lines.append(DiffTextLine(text: text, role: role))
            utf8ByteCount += requiredBytes
            return true
        }

        mutating func finish() -> [DiffTextLine] {
            if truncated {
                lines.append(DiffTextLine(
                    text: "… additional changes omitted from this bounded preview",
                    role: .notice
                ))
            }
            return lines
        }
    }

    private static func decodedText(_ value: Data) -> String? {
        guard !value.contains(0), let text = String(data: value, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private static func textDiff(
        before: String?,
        after: String
    ) -> (lines: [DiffTextLine], truncated: Bool) {
        let inputBytes = (before?.utf8.count ?? 0) + after.utf8.count
        guard inputBytes <= maximumLineDiffInputByteCount else {
            return focusedTextDiff(before: before, after: after)
        }
        let beforeLines: [TextLine]
        if let before {
            guard let parsed = textLines(before, maximumCount: maximumLineDiffLineCount) else {
                return focusedTextDiff(before: before, after: after)
            }
            beforeLines = parsed
        } else {
            beforeLines = [TextLine(
                content: "<absent>", hasNewline: false, synthetic: true
            )]
        }
        guard let afterLines = textLines(after, maximumCount: maximumLineDiffLineCount) else {
            return focusedTextDiff(before: before, after: after)
        }
        let comparisonProduct = beforeLines.count.multipliedReportingOverflow(
            by: afterLines.count
        )
        guard beforeLines.count + afterLines.count <= maximumLineDiffLineCount,
            !comparisonProduct.overflow,
            comparisonProduct.partialValue <= maximumLineDiffComparisonProduct
        else {
            return focusedTextDiff(before: before, after: after)
        }

        let events = diffEvents(before: beforeLines, after: afterLines)
        let changeIndexes = events.indices.filter { events[$0].kind != .context }
        var builder = BoundedLines()
        _ = builder.append("--- saved value", role: .fileHeader)
        _ = builder.append("+++ edited value", role: .fileHeader)
        guard !changeIndexes.isEmpty else {
            _ = builder.append("Value bytes are unchanged.", role: .notice)
            return (builder.finish(), builder.truncated)
        }

        let ranges = hunkRanges(changeIndexes: changeIndexes, eventCount: events.count)
        var beforeLine = 1
        var afterLine = 1
        var beforeAtEvent = [Int](repeating: 1, count: events.count + 1)
        var afterAtEvent = [Int](repeating: 1, count: events.count + 1)
        for index in events.indices {
            beforeAtEvent[index] = beforeLine
            afterAtEvent[index] = afterLine
            if events[index].consumesBefore { beforeLine += 1 }
            if events[index].consumesAfter { afterLine += 1 }
        }
        beforeAtEvent[events.count] = beforeLine
        afterAtEvent[events.count] = afterLine

        hunkLoop: for range in ranges {
            let beforeCount = events[range].lazy.filter(\.consumesBefore).count
            let afterCount = events[range].lazy.filter(\.consumesAfter).count
            let header = "@@ -\(rangeText(start: beforeAtEvent[range.lowerBound], count: beforeCount))"
                + " +\(rangeText(start: afterAtEvent[range.lowerBound], count: afterCount)) @@"
            guard builder.append(header, role: .hunkHeader) else { break }
            for event in events[range] {
                let marker: String
                let role: DiffTextLineRole
                switch event.kind {
                case .context:
                    marker = " "
                    role = .context
                case .removal:
                    marker = "-"
                    role = .removal
                case .addition:
                    marker = "+"
                    role = .addition
                }
                guard builder.append(marker + event.line.content, role: role) else {
                    break hunkLoop
                }
                if !event.line.synthetic, !event.line.hasNewline,
                    !builder.append("\\ No newline at end of value", role: .notice)
                {
                    break hunkLoop
                }
            }
        }
        let truncated = builder.truncated
        return (builder.finish(), truncated)
    }

    private static func textLines(
        _ value: String,
        maximumCount: Int
    ) -> [TextLine]? {
        guard !value.isEmpty else {
            return [TextLine(content: "(empty)", hasNewline: false, synthetic: true)]
        }
        var result: [TextLine] = []
        result.reserveCapacity(min(value.utf8.count / 24 + 1, 512))
        var start = value.startIndex
        while start < value.endIndex {
            guard result.count < maximumCount else { return nil }
            if let newline = value[start...].firstIndex(of: "\n") {
                let content = value[start..<newline]
                guard content.utf8.count <= maximumLineUTF8ByteCount else { return nil }
                result.append(TextLine(
                    content: String(content),
                    hasNewline: true,
                    synthetic: false
                ))
                start = value.index(after: newline)
            } else {
                let content = value[start...]
                guard content.utf8.count <= maximumLineUTF8ByteCount else { return nil }
                result.append(TextLine(
                    content: String(content),
                    hasNewline: false,
                    synthetic: false
                ))
                start = value.endIndex
            }
        }
        return result
    }

    private static func diffEvents(before: [TextLine], after: [TextLine]) -> [Event] {
        let difference = after.difference(from: before)
        var removals = Set<Int>()
        var insertions = Set<Int>()
        removals.reserveCapacity(difference.removals.count)
        insertions.reserveCapacity(difference.insertions.count)
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }

        var result: [Event] = []
        result.reserveCapacity(before.count + after.count)
        var beforeIndex = 0
        var afterIndex = 0
        while beforeIndex < before.count || afterIndex < after.count {
            if beforeIndex < before.count, removals.contains(beforeIndex) {
                result.append(Event(kind: .removal, line: before[beforeIndex]))
                beforeIndex += 1
            } else if afterIndex < after.count, insertions.contains(afterIndex) {
                result.append(Event(kind: .addition, line: after[afterIndex]))
                afterIndex += 1
            } else if beforeIndex < before.count, afterIndex < after.count {
                result.append(Event(kind: .context, line: before[beforeIndex]))
                beforeIndex += 1
                afterIndex += 1
            } else if beforeIndex < before.count {
                result.append(Event(kind: .removal, line: before[beforeIndex]))
                beforeIndex += 1
            } else if afterIndex < after.count {
                result.append(Event(kind: .addition, line: after[afterIndex]))
                afterIndex += 1
            }
        }
        return result
    }

    private static func hunkRanges(
        changeIndexes: [Int],
        eventCount: Int
    ) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        for index in changeIndexes {
            let candidate = max(0, index - contextLineCount)
                ... min(eventCount - 1, index + contextLineCount)
            if let last = result.last, candidate.lowerBound <= last.upperBound + 1 {
                result[result.count - 1] = last.lowerBound...max(
                    last.upperBound, candidate.upperBound
                )
            } else {
                result.append(candidate)
            }
        }
        return result
    }

    private static func rangeText(start: Int, count: Int) -> String {
        let adjustedStart = count == 0 ? max(0, start - 1) : start
        return "\(adjustedStart),\(count)"
    }

    private static func focusedTextDiff(
        before: String?,
        after: String
    ) -> (lines: [DiffTextLine], truncated: Bool) {
        let beforeValue = before ?? "<absent>"
        let bounds = changedBounds(before: beforeValue, after: after)
        let beforeExcerpt = focusedExcerpt(
            beforeValue,
            changeStart: bounds.beforeStart,
            changeEnd: bounds.beforeEnd
        )
        let afterExcerpt = focusedExcerpt(
            after,
            changeStart: bounds.afterStart,
            changeEnd: bounds.afterEnd
        )
        return ([
            DiffTextLine(text: "--- saved value", role: .fileHeader),
            DiffTextLine(text: "+++ edited value", role: .fileHeader),
            DiffTextLine(text: "@@ bounded changed text region @@", role: .hunkHeader),
            DiffTextLine(text: "-" + visibleExcerpt(beforeExcerpt.text), role: .removal),
            DiffTextLine(text: "+" + visibleExcerpt(afterExcerpt.text), role: .addition),
            DiffTextLine(
                text: "Large or highly fragmented value; showing bounded context around the changed region.",
                role: .notice
            ),
        ], true)
    }

    private static func changedBounds(
        before: String,
        after: String
    ) -> (
        beforeStart: String.Index, beforeEnd: String.Index,
        afterStart: String.Index, afterEnd: String.Index
    ) {
        var beforeStart = before.startIndex
        var afterStart = after.startIndex
        while beforeStart < before.endIndex, afterStart < after.endIndex,
            before[beforeStart] == after[afterStart]
        {
            before.formIndex(after: &beforeStart)
            after.formIndex(after: &afterStart)
        }

        var beforeEnd = before.endIndex
        var afterEnd = after.endIndex
        while beforeEnd > beforeStart, afterEnd > afterStart {
            let previousBefore = before.index(before: beforeEnd)
            let previousAfter = after.index(before: afterEnd)
            guard before[previousBefore] == after[previousAfter] else { break }
            beforeEnd = previousBefore
            afterEnd = previousAfter
        }
        return (beforeStart, beforeEnd, afterStart, afterEnd)
    }

    private static func focusedExcerpt(
        _ value: String,
        changeStart: String.Index,
        changeEnd: String.Index
    ) -> (text: String, truncated: Bool) {
        let context = 48
        let changedEdge = 128
        let windowStart = value.index(
            changeStart, offsetBy: -context, limitedBy: value.startIndex
        ) ?? value.startIndex
        let windowEnd = value.index(
            changeEnd, offsetBy: context, limitedBy: value.endIndex
        ) ?? value.endIndex
        let firstChangedEnd = value.index(
            changeStart, offsetBy: changedEdge, limitedBy: changeEnd
        ) ?? changeEnd
        let lastChangedStart = value.index(
            changeEnd, offsetBy: -changedEdge, limitedBy: changeStart
        ) ?? changeStart

        var result = String()
        if windowStart != value.startIndex { result.append("…") }
        if firstChangedEnd < lastChangedStart {
            result.append(contentsOf: value[windowStart..<firstChangedEnd])
            result.append(" … ")
            result.append(contentsOf: value[lastChangedStart..<windowEnd])
        } else {
            result.append(contentsOf: value[windowStart..<windowEnd])
        }
        if windowEnd != value.endIndex { result.append("…") }
        let truncated = windowStart != value.startIndex || windowEnd != value.endIndex
            || firstChangedEnd < lastChangedStart
        return (result, truncated)
    }

    private static func visibleExcerpt(_ value: String) -> String {
        let visible = value
            .replacingOccurrences(of: "\r", with: "␍")
            .replacingOccurrences(of: "\n", with: "↵")
        guard visible.utf8.count > maximumFocusedExcerptUTF8ByteCount else {
            return visible
        }

        let omission = " … "
        let available = maximumFocusedExcerptUTF8ByteCount - omission.utf8.count
        let leadingBudget = available / 2
        let trailingBudget = available - leadingBudget
        let utf8 = visible.utf8
        var leadingEnd = utf8.index(utf8.startIndex, offsetBy: leadingBudget)
        while leadingEnd > utf8.startIndex, leadingEnd < utf8.endIndex,
            utf8[leadingEnd] & 0xC0 == 0x80
        {
            utf8.formIndex(before: &leadingEnd)
        }
        var trailingStart = utf8.index(utf8.endIndex, offsetBy: -trailingBudget)
        while trailingStart < utf8.endIndex, utf8[trailingStart] & 0xC0 == 0x80 {
            utf8.formIndex(after: &trailingStart)
        }
        return String(decoding: utf8[..<leadingEnd], as: UTF8.self)
            + omission
            + String(decoding: utf8[trailingStart...], as: UTF8.self)
    }

    private static func binaryDiff(
        before: Data?,
        after: Data,
        kindChanged: Bool
    ) -> (lines: [DiffTextLine], truncated: Bool) {
        let totalByteCount = max(before?.count ?? 0, after.count)
        let totalRowCount = (totalByteCount + 15) / 16
        var changedRows: [Int] = []
        changedRows.reserveCapacity(min(totalRowCount, maximumBinaryRowCount + 1))
        var lastChangedRow = -1
        if totalByteCount > 0 {
            for index in 0..<totalByteCount where byte(before, at: index) != byte(after, at: index) {
                let row = index / 16
                if row != lastChangedRow {
                    changedRows.append(row)
                    lastChangedRow = row
                }
            }
        }

        var relevantRows = Set<Int>()
        for row in changedRows {
            for candidate in max(0, row - 1)...min(max(0, totalRowCount - 1), row + 1) {
                relevantRows.insert(candidate)
            }
        }
        if relevantRows.isEmpty, totalRowCount > 0 {
            relevantRows.formUnion(0..<min(totalRowCount, maximumBinaryRowCount))
        }
        let allRelevantRows = relevantRows.sorted()
        let selectedRows: [Int]
        if allRelevantRows.count <= maximumBinaryRowCount {
            selectedRows = allRelevantRows
        } else {
            let leadingCount = maximumBinaryRowCount / 2
            let trailingCount = maximumBinaryRowCount - leadingCount
            selectedRows = Array(allRelevantRows.prefix(leadingCount))
                + Array(allRelevantRows.suffix(trailingCount))
        }
        let omittedChangedRows = Set(changedRows).subtracting(selectedRows).count

        var lines: [DiffTextLine] = [
            DiffTextLine(text: "--- saved value", role: .fileHeader),
            DiffTextLine(text: "+++ edited value", role: .fileHeader),
            DiffTextLine(text: "@@ changed byte ranges @@", role: .hunkHeader),
        ]
        appendBinarySide(
            value: before,
            other: after,
            selectedRows: selectedRows,
            absent: before == nil,
            marker: "-",
            role: .removal,
            to: &lines
        )
        appendBinarySide(
            value: after,
            other: before,
            selectedRows: selectedRows,
            absent: false,
            marker: "+",
            role: .addition,
            to: &lines
        )
        if changedRows.isEmpty, kindChanged {
            lines.append(DiffTextLine(
                text: "Value bytes are unchanged; the text/binary storage kind changes.",
                role: .notice
            ))
        }
        if omittedChangedRows > 0 {
            lines.append(DiffTextLine(
                text: "… \(omittedChangedRows.formatted()) additional changed byte row"
                    + "\(omittedChangedRows == 1 ? "" : "s") omitted from this preview",
                role: .notice
            ))
        }
        return (lines, omittedChangedRows > 0)
    }

    private static func appendBinarySide(
        value: Data?,
        other: Data?,
        selectedRows: [Int],
        absent: Bool,
        marker: String,
        role: DiffTextLineRole,
        to lines: inout [DiffTextLine]
    ) {
        if absent {
            lines.append(DiffTextLine(text: marker + "<absent>", role: role))
            return
        }
        guard let value, !value.isEmpty else {
            lines.append(DiffTextLine(text: marker + "(empty)", role: role))
            return
        }

        let totalByteCount = max(value.count, other?.count ?? 0)
        let totalRowCount = (totalByteCount + 15) / 16
        var previousRow: Int?
        for row in selectedRows {
            if let previousRow, row > previousRow + 1 {
                let omitted = (row - previousRow - 1) * 16
                lines.append(DiffTextLine(
                    text: " … \(omitted.formatted()) unchanged or undisplayed bytes …",
                    role: .context
                ))
            } else if previousRow == nil, row > 0 {
                lines.append(DiffTextLine(
                    text: " … \((row * 16).formatted()) leading bytes not shown …",
                    role: .context
                ))
            }
            let rendered = binaryRow(value: value, other: other, row: row)
            lines.append(DiffTextLine(text: marker + rendered.value, role: role))
            if let changes = rendered.changes {
                lines.append(DiffTextLine(text: marker + changes, role: role))
            }
            previousRow = row
        }
        if let previousRow, previousRow + 1 < totalRowCount {
            let omitted = max(0, totalByteCount - (previousRow + 1) * 16)
            lines.append(DiffTextLine(
                text: " … \(omitted.formatted()) trailing bytes not shown …",
                role: .context
            ))
        }
    }

    private static func binaryRow(
        value: Data,
        other: Data?,
        row: Int
    ) -> (value: String, changes: String?) {
        let offset = row * 16
        var hex: [String] = []
        var markers: [String] = []
        var ascii = ""
        var asciiMarkers = ""
        hex.reserveCapacity(16)
        markers.reserveCapacity(16)
        for index in offset..<(offset + 16) {
            let current = byte(value, at: index)
            let comparison = byte(other, at: index)
            hex.append(current.map { String(format: "%02X", $0) } ?? "--")
            ascii.append(current.map(asciiCharacter) ?? " ")
            let changed = current != comparison
            markers.append(changed ? "^^" : "  ")
            asciiMarkers.append(changed ? "^" : " ")
        }
        let valueLine = String(format: "%08X  ", offset)
            + hex.joined(separator: " ") + "  |\(ascii)|"
        guard markers.contains("^^") else { return (valueLine, nil) }
        return (
            valueLine,
            "          " + markers.joined(separator: " ") + "  |\(asciiMarkers)|"
        )
    }

    private static func byte(_ value: Data?, at offset: Int) -> UInt8? {
        guard let value, offset >= 0, offset < value.count else { return nil }
        return value[value.index(value.startIndex, offsetBy: offset)]
    }

    private static func asciiCharacter(_ byte: UInt8) -> Character {
        guard (0x20...0x7E).contains(byte) else { return "." }
        return Character(UnicodeScalar(byte))
    }

    private static func kindText(_ kind: DataValueKind) -> String {
        switch kind {
        case .text: "Text"
        case .binary: "Binary"
        }
    }

    private static func byteCountText(_ count: Int) -> String {
        count == 1 ? "1 byte" : "\(count.formatted()) bytes"
    }
}
