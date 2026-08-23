import Foundation
import KmgrCore

/// A transient, AppKit-independent rendering plan for YAML edit confirmation.
///
/// Decoded Secret bytes are copied only while their visible text is being
/// produced. The caller must keep this presentation inside the confirmation
/// flow and discard its rendered lines when that flow ends.
struct YAMLDiffPresentation {
    typealias LineRole = DiffTextLineRole
    typealias Line = DiffTextLine

    static let maximumDecodedTextDisplayByteCount = 16 * 1_024
    static let maximumDecodedTextDisplayLineCount = 2_048
    static let maximumDecodedSecretDisplayLineCount = 8_192

    struct ChangedPath {
        var path: String
        var beforeSummary: String
        var afterSummary: String
        var severity: CellSeverity
    }

    let changedPaths: [ChangedPath]
    let lines: [Line]
    let unifiedDiffTruncated: Bool

    init(prepared: PreparedYAMLEdit) {
        changedPaths = prepared.diff.map {
            ChangedPath(
                path: $0.path.isEmpty ? "." : $0.path,
                beforeSummary: $0.beforeSummary,
                afterSummary: $0.afterSummary,
                severity: $0.severity
            )
        }
        unifiedDiffTruncated = prepared.unifiedDiffTruncated

        let unifiedDiff = String(decoding: prepared.unifiedDiffUTF8, as: UTF8.self)
        var rendered = Self.unifiedDiffLines(unifiedDiff)
        if rendered.isEmpty {
            rendered = [Line(
                text: "Unified diff unavailable. Review the changed paths above.",
                role: .notice
            )]
        }

        var decodedSecretLines: [Line] = []
        decodedSecretLines.reserveCapacity(min(
            prepared.diff.count * 8,
            Self.maximumDecodedSecretDisplayLineCount
        ))
        for entry in prepared.diff {
            let entryLines = Self.decodedSecretLines(entry)
            guard !entryLines.isEmpty else { continue }
            let remaining = Self.maximumDecodedSecretDisplayLineCount
                - decodedSecretLines.count
            guard entryLines.count <= remaining else {
                decodedSecretLines.append(contentsOf: entryLines.prefix(max(0, remaining)))
                decodedSecretLines.append(Line(
                    text: "… additional decoded Secret lines omitted from this display",
                    role: .notice
                ))
                break
            }
            decodedSecretLines.append(contentsOf: entryLines)
        }
        if !decodedSecretLines.isEmpty {
            if rendered.last?.text.isEmpty == false {
                rendered.append(Line(text: "", role: .context))
            }
            rendered.append(Line(text: "Decoded Secret value changes", role: .sectionHeader))
            rendered.append(Line(
                text: "Values below are decoded; they are not Kubernetes base64 text.",
                role: .notice
            ))
            rendered.append(contentsOf: decodedSecretLines)
        }
        lines = rendered
    }

    var text: String {
        lines.map(\.text).joined(separator: "\n")
    }

    private static func unifiedDiffLines(_ value: String) -> [Line] {
        guard !value.isEmpty else { return [] }
        var rawLines = value.split(separator: "\n", omittingEmptySubsequences: false)
        if value.hasSuffix("\n"), rawLines.last?.isEmpty == true {
            rawLines.removeLast()
        }
        return rawLines.map { rawLine in
            let line = String(rawLine)
            let role: LineRole
            if line.hasPrefix("@@") {
                role = .hunkHeader
            } else if line.hasPrefix("+++") || line.hasPrefix("---") {
                role = .fileHeader
            } else if line.hasPrefix("+") {
                role = .addition
            } else if line.hasPrefix("-") {
                role = .removal
            } else if line.contains("unified diff truncated for display") {
                role = .notice
            } else {
                role = .context
            }
            let whitespaceScope: DiffTextWhitespaceScope = switch role {
            case .context, .addition, .removal:
                .contentAfterDiffPrefix
            default:
                .none
            }
            return Line(
                text: line,
                role: role,
                whitespaceScope: whitespaceScope
            )
        }
    }

    private static func decodedSecretLines(_ entry: SemanticDiffEntry) -> [Line] {
        guard entry.beforeDecodedSecretValue != nil || entry.afterDecodedSecretValue != nil else {
            return []
        }

        var before = copiedData(entry.beforeDecodedSecretValue)
        var after = copiedData(entry.afterDecodedSecretValue)
        defer {
            clear(&before)
            clear(&after)
        }

        let beforeFormat = before.map(decodedFormat)
        let afterFormat = after.map(decodedFormat)
        let binaryComparison: (before: String, after: String)?
        if case .binary? = beforeFormat, case .binary? = afterFormat,
            let before, let after
        {
            let compared = BinaryHexASCIIPresentation.diff(local: before, current: after)
            binaryComparison = (compared.local, compared.current)
        } else {
            binaryComparison = nil
        }

        var result = [Line(text: "", role: .context)]
        result.append(Line(text: entry.path.isEmpty ? "." : entry.path, role: .sectionHeader))
        result.append(contentsOf: decodedSideLines(
            label: "before",
            value: before,
            format: beforeFormat,
            missingSummary: entry.beforeSummary,
            binaryComparisonText: binaryComparison?.before,
            role: .removal
        ))
        result.append(contentsOf: decodedSideLines(
            label: "after",
            value: after,
            format: afterFormat,
            missingSummary: entry.afterSummary,
            binaryComparisonText: binaryComparison?.after,
            role: .addition
        ))
        return result
    }

    private enum DecodedFormat {
        case text
        case binary
    }

    private static func decodedFormat(_ value: Data) -> DecodedFormat {
        guard !value.contains(0), String(data: value, encoding: .utf8) != nil else {
            return .binary
        }
        return .text
    }

    private static func decodedSideLines(
        label: String,
        value: Data?,
        format: DecodedFormat?,
        missingSummary: String,
        binaryComparisonText: String?,
        role: LineRole
    ) -> [Line] {
        let marker = role == .removal ? "---" : "+++"
        guard let value, let format else {
            let reason = missingSummary == "<absent>"
                ? "not present"
                : "decoded value unavailable"
            return [Line(text: "\(marker) \(label) (\(reason))", role: role)]
        }

        switch format {
        case .text:
            var result = [Line(
                text: "\(marker) \(label) (decoded UTF-8, \(byteCountText(value.count)))",
                role: role
            )]
            let bounded = boundedTextLines(value)
            result.append(contentsOf: bounded.lines.map {
                Line(
                    text: $0,
                    role: role,
                    whitespaceScope: .content
                )
            })
            if bounded.omittedByteCount > 0 {
                result.append(Line(
                    text: "… \(byteCountText(bounded.omittedByteCount)) omitted "
                        + "(decoded display limit: 16 KiB and "
                        + "\(maximumDecodedTextDisplayLineCount.formatted()) lines per side)",
                    role: .notice
                ))
            }
            return result
        case .binary:
            let dump = binaryComparisonText ?? BinaryHexASCIIPresentation.dump(value)
            return [Line(
                text: "\(marker) \(label) (decoded binary, \(byteCountText(value.count)))",
                role: role
            )] + dump.split(separator: "\n", omittingEmptySubsequences: false)
                .map { Line(text: String($0), role: role) }
        }
    }

    private static func copiedData(_ value: SensitiveBytes?) -> Data? {
        value?.withUnsafeBytes { Data($0) }
    }

    private static func boundedTextLines(
        _ value: Data
    ) -> (lines: [String], omittedByteCount: Int) {
        guard !value.isEmpty else { return (["(empty)"], 0) }

        var prefixByteCount = min(value.count, maximumDecodedTextDisplayByteCount)
        while prefixByteCount > 0, prefixByteCount < value.count,
            value[prefixByteCount] & 0xC0 == 0x80
        {
            prefixByteCount -= 1
        }
        let text = String(decoding: value.prefix(prefixByteCount), as: UTF8.self)
        var lines: [String] = []
        lines.reserveCapacity(min(maximumDecodedTextDisplayLineCount, 128))
        var start = text.startIndex

        while start < text.endIndex, lines.count < maximumDecodedTextDisplayLineCount {
            if let newline = text[start...].firstIndex(of: "\n") {
                lines.append(String(text[start..<newline]))
                start = text.index(after: newline)
            } else {
                lines.append(String(text[start...]))
                start = text.endIndex
            }
        }
        if start == text.endIndex, text.last == "\n",
            lines.count < maximumDecodedTextDisplayLineCount
        {
            lines.append("")
        }

        let displayedByteCount = start == text.endIndex
            ? prefixByteCount
            : text[..<start].utf8.count
        return (lines, max(0, value.count - displayedByteCount))
    }

    private static func clear(_ value: inout Data?) {
        guard var bytes = value else { return }
        value = nil
        bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex)
    }

    private static func byteCountText(_ count: Int) -> String {
        count == 1 ? "1 byte" : "\(count.formatted()) bytes"
    }
}
