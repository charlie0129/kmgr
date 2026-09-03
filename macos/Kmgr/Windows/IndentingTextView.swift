import AppKit

enum DocumentIndentationContentKind: Equatable {
    case plain
    case json
    case yaml

    var defaultSpaceWidth: Int {
        switch self {
        case .plain: 4
        case .json, .yaml: 2
        }
    }

    var permitsTabs: Bool { self != .yaml }
}

enum DocumentIndentationStyle: Equatable {
    case tabs(tabWidth: Int)
    case spaces(width: Int)

    var width: Int {
        switch self {
        case .tabs(let tabWidth): max(1, tabWidth)
        case .spaces(let width): max(1, width)
        }
    }

    var unit: String {
        switch self {
        case .tabs: "\t"
        case .spaces: String(repeating: " ", count: width)
        }
    }
}

/// Detects the leading indentation already present in a document without
/// scanning or copying an arbitrarily large value. Detection is a load-time
/// presentation heuristic; parsing and validation remain owned by each
/// document's existing save path.
struct DocumentIndentationDetector {
    static let maximumUTF16Length = 64 * 1_024
    static let maximumLineCount = 1_024
    private static let maximumDetectedWidth = 8

    static func detect(
        in source: NSString,
        contentKind: DocumentIndentationContentKind
    ) -> DocumentIndentationStyle {
        let evidence = leadingIndentationEvidence(in: source)
        if contentKind.permitsTabs,
            evidence.tabIndentedLines > evidence.spaceIndentedLines
        {
            return .tabs(tabWidth: 4)
        }
        return .spaces(width: inferredSpaceWidth(
            from: evidence.spaceColumns,
            defaultWidth: contentKind.defaultSpaceWidth
        ))
    }

    private struct Evidence {
        var tabIndentedLines = 0
        var spaceIndentedLines = 0
        var spaceColumns: [Int] = []
    }

    private static func leadingIndentationEvidence(in source: NSString) -> Evidence {
        let scanEnd = min(source.length, maximumUTF16Length)
        var evidence = Evidence()
        evidence.spaceColumns.reserveCapacity(min(maximumLineCount, 128))
        var lineStart = 0
        var lineCount = 0

        while lineStart < scanEnd, lineCount < maximumLineCount {
            var cursor = lineStart
            var spaces = 0
            var tabs = 0
            while cursor < scanEnd {
                let character = source.character(at: cursor)
                if character == 0x20 {
                    spaces += 1
                    cursor += 1
                } else if character == 0x09 {
                    tabs += 1
                    cursor += 1
                } else {
                    break
                }
            }

            // Do not treat an indentation prefix truncated by the scan bound
            // as a complete line of evidence.
            if cursor < scanEnd {
                let character = source.character(at: cursor)
                let isBlank = character == 0x0A || character == 0x0D
                if !isBlank {
                    switch (spaces, tabs) {
                    case (let count, 0) where count > 0:
                        evidence.spaceIndentedLines += 1
                        evidence.spaceColumns.append(count)
                    case (0, let count) where count > 0:
                        evidence.tabIndentedLines += 1
                        evidence.spaceColumns.append(0)
                    case (0, 0):
                        evidence.spaceColumns.append(0)
                    default:
                        // Mixed leading whitespace is ambiguous. Reset the
                        // nesting sequence but do not let it vote for either
                        // style.
                        evidence.spaceColumns.append(0)
                    }
                }
            }

            while cursor < scanEnd {
                let character = source.character(at: cursor)
                if character == 0x0A || character == 0x0D { break }
                cursor += 1
            }
            if cursor < scanEnd, source.character(at: cursor) == 0x0D {
                cursor += 1
                if cursor < scanEnd, source.character(at: cursor) == 0x0A {
                    cursor += 1
                }
            } else if cursor < scanEnd {
                cursor += 1
            }
            lineStart = cursor
            lineCount += 1
        }
        return evidence
    }

    private static func inferredSpaceWidth(
        from columns: [Int],
        defaultWidth: Int
    ) -> Int {
        var votes = Array(repeating: 0, count: maximumDetectedWidth + 1)
        var previous = 0
        var shallowestIndentation: Int?

        for column in columns {
            if column > previous {
                let increase = column - previous
                if increase <= maximumDetectedWidth { votes[increase] += 2 }
            }
            previous = column
            if column > 0 {
                shallowestIndentation = min(shallowestIndentation ?? column, column)
            }
        }
        if let shallowestIndentation,
            shallowestIndentation <= maximumDetectedWidth
        {
            // A shallow level is stronger evidence than a one-off alignment
            // delta inside a continuation or block scalar.
            votes[shallowestIndentation] += 1
        }

        let highestVote = votes.max() ?? 0
        guard highestVote > 0 else { return defaultWidth }
        let candidates = (1...maximumDetectedWidth).filter { votes[$0] == highestVote }
        if candidates.contains(defaultWidth) { return defaultWidth }
        return candidates.min() ?? defaultWidth
    }
}

/// Native multiline editor behavior for document-like technical input.
///
/// The style is explicitly refreshed when a new document is installed and
/// then remains stable while the user edits. Tab indents to the next stop;
/// selections indent by one unit; Shift-Tab outdents complete lines.
@MainActor
class IndentingTextView: NSTextView {
    private(set) var indentationStyle: DocumentIndentationStyle = .spaces(width: 4)

    func detectIndentation(
        for contentKind: DocumentIndentationContentKind,
        in source: NSString? = nil
    ) {
        let document: NSString
        if let source {
            document = source
        } else if let mutableString = textStorage?.mutableString {
            document = mutableString
        } else {
            document = string as NSString
        }
        indentationStyle = DocumentIndentationDetector.detect(
            in: document,
            contentKind: contentKind
        )
    }

    override func insertTab(_ sender: Any?) {
        guard isEditable else {
            super.insertTab(sender)
            return
        }
        performIndentation()
    }

    override func insertTabIgnoringFieldEditor(_ sender: Any?) {
        guard isEditable else {
            super.insertTabIgnoringFieldEditor(sender)
            return
        }
        performIndentation()
    }

    private func performIndentation() {
        let ranges = selectedRanges
        guard !ranges.isEmpty else { return }
        if ranges.contains(where: { $0.rangeValue.length > 0 }) {
            indentLines(containing: ranges)
        } else {
            insertIndentation(at: ranges)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        guard isEditable else {
            super.insertBacktab(sender)
            return
        }
        outdentLines(containing: selectedRanges)
    }

    private struct Replacement {
        var range: NSRange
        var string: String
    }

    private func insertIndentation(at ranges: [NSValue]) {
        guard let source = textStorage?.mutableString else { return }
        let replacements = ranges.compactMap { value -> Replacement? in
            let range = value.rangeValue
            guard range.location <= source.length else { return nil }
            let inserted: String
            switch indentationStyle {
            case .tabs:
                inserted = "\t"
            case .spaces:
                let width = indentationStyle.width
                let column = visualColumn(at: range.location, in: source, tabWidth: width)
                let count = width - (column % width)
                inserted = String(repeating: " ", count: count)
            }
            return Replacement(range: range, string: inserted)
        }
        apply(replacements)
    }

    private func indentLines(containing ranges: [NSValue]) {
        guard let source = textStorage?.mutableString else { return }
        let replacements = lineStarts(containing: ranges, in: source).map {
            Replacement(range: NSRange(location: $0, length: 0), string: indentationStyle.unit)
        }
        apply(replacements)
    }

    private func outdentLines(containing ranges: [NSValue]) {
        guard let source = textStorage?.mutableString else { return }
        let width = max(1, indentationStyle.width)
        let replacements = lineStarts(containing: ranges, in: source).compactMap {
            lineStart -> Replacement? in
            guard lineStart < source.length else { return nil }
            if source.character(at: lineStart) == 0x09 {
                return Replacement(
                    range: NSRange(location: lineStart, length: 1),
                    string: ""
                )
            }
            var count = 0
            while count < width, lineStart + count < source.length,
                source.character(at: lineStart + count) == 0x20
            {
                count += 1
            }
            guard count > 0 else { return nil }
            return Replacement(
                range: NSRange(location: lineStart, length: count),
                string: ""
            )
        }
        apply(replacements)
    }

    private func lineStarts(
        containing ranges: [NSValue],
        in source: NSString
    ) -> [Int] {
        var starts = Set<Int>()
        for value in ranges {
            let selected = value.rangeValue
            let lowerBound = min(selected.location, source.length)
            let upperBound = min(NSMaxRange(selected), source.length)
            var lastCharacter = upperBound
            if upperBound > lowerBound,
                source.lineRange(for: NSRange(location: upperBound, length: 0)).location
                    == upperBound
            {
                lastCharacter -= 1
            }

            var lineStart = source.lineRange(
                for: NSRange(location: lowerBound, length: 0)
            ).location
            let lastLineStart = source.lineRange(
                for: NSRange(location: lastCharacter, length: 0)
            ).location
            while lineStart <= lastLineStart {
                starts.insert(lineStart)
                guard lineStart < source.length else { break }
                let next = NSMaxRange(source.lineRange(
                    for: NSRange(location: lineStart, length: 0)
                ))
                guard next > lineStart else { break }
                lineStart = next
            }
        }
        return starts.sorted()
    }

    private func visualColumn(
        at location: Int,
        in source: NSString,
        tabWidth: Int
    ) -> Int {
        let lineStart = source.lineRange(
            for: NSRange(location: min(location, source.length), length: 0)
        ).location
        var column = 0
        guard lineStart < location else { return column }
        for index in lineStart..<min(location, source.length) {
            if source.character(at: index) == 0x09 {
                column += tabWidth - (column % tabWidth)
            } else {
                column += 1
            }
        }
        return column
    }

    private func apply(_ proposedReplacements: [Replacement]) {
        guard let storage = textStorage, !proposedReplacements.isEmpty else { return }
        let replacements = proposedReplacements.sorted {
            if $0.range.location == $1.range.location {
                return $0.range.length < $1.range.length
            }
            return $0.range.location < $1.range.location
        }
        for pair in zip(replacements, replacements.dropFirst()) {
            guard NSMaxRange(pair.0.range) <= pair.1.range.location else { return }
        }

        let originalSelections = selectedRanges
        let affectedRanges = replacements.map { NSValue(range: $0.range) }
        let replacementStrings = replacements.map(\.string)
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.endUndoGrouping()
            breakUndoCoalescing()
        }
        guard shouldChangeText(
            inRanges: affectedRanges,
            replacementStrings: replacementStrings
        ) else { return }

        storage.beginEditing()
        for replacement in replacements.reversed() {
            storage.replaceCharacters(in: replacement.range, with: replacement.string)
        }
        storage.endEditing()
        selectedRanges = originalSelections.map { value in
            let range = value.rangeValue
            let start = transformedPosition(range.location, by: replacements)
            let end = transformedPosition(NSMaxRange(range), by: replacements)
            return NSValue(range: NSRange(location: start, length: max(0, end - start)))
        }
        didChangeText()
    }

    private func transformedPosition(
        _ position: Int,
        by replacements: [Replacement]
    ) -> Int {
        var offset = 0
        for replacement in replacements {
            let lowerBound = replacement.range.location
            let upperBound = NSMaxRange(replacement.range)
            let replacementLength = (replacement.string as NSString).length
            if position < lowerBound { break }
            if replacement.range.length == 0 {
                offset += replacementLength
                continue
            }
            if position <= upperBound {
                return lowerBound + offset + replacementLength
            }
            offset += replacementLength - replacement.range.length
        }
        return position + offset
    }
}
