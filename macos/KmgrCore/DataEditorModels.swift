import CryptoKit
import Foundation

public enum KubernetesDataKeyValidator {
    /// ConfigMap and Secret data keys use the Kubernetes config-map key
    /// character set: alphanumerics, `-`, `_`, and `.`, up to 253 bytes.
    public static func validationMessage(
        for key: String,
        existingKeys: Set<String> = [],
        allowingExistingKey: String? = nil
    ) -> String? {
        guard !key.isEmpty else { return "Key must not be empty." }
        guard key.lengthOfBytes(using: .utf8) <= 253 else {
            return "Key must be no longer than 253 UTF-8 bytes."
        }
        let valid = key.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122: true
            case 45, 46, 95: true
            default: false
            }
        }
        guard valid else {
            return "Use only letters, numbers, dash, underscore, and period."
        }
        if existingKeys.contains(key), key != allowingExistingKey {
            return "A key named \(key) already exists."
        }
        return nil
    }
}

public enum DataEditorRowState: String, Hashable, Sendable {
    case saved
    case unsaved
    case conflict

    public var displayText: String {
        switch self {
        case .saved: "Saved"
        case .unsaved: "Unsaved"
        case .conflict: "Conflict"
        }
    }
}

public enum DataValuePreviewState: Hashable, Sendable {
    case text
    case binary
    case concealed
}

/// A bounded, single-line value for the Data editor's table. Secret input is
/// concealed by default and becomes presentable only when the caller supplies
/// explicit reveal authority. The source `Data` is consumed during
/// initialization and is never retained by this value.
public struct DataValuePreviewPresentation: Hashable, Sendable {
    private static let textAccessibilityPrefix = "Text value: "
    private static let truncatedAccessibilitySuffix = ", truncated preview"

    /// The visible preview is bounded in two dimensions. This character limit
    /// counts extended grapheme clusters, including a trailing ellipsis.
    public static let maximumTextCharacterCount = 160
    /// Four UTF-8 bytes per visible character preserves the full character
    /// allowance for ordinary Unicode scalars while preventing one pathological
    /// combining-mark cluster from making a nominally short preview unbounded.
    /// The trailing ellipsis, when present, is included in this limit.
    public static let maximumTextUTF8ByteCount = maximumTextCharacterCount * 4
    /// Accessibility adds fixed ASCII context around the same bounded preview.
    public static let maximumAccessibilityValueUTF8ByteCount =
        maximumTextUTF8ByteCount
        + textAccessibilityPrefix.utf8.count
        + truncatedAccessibilitySuffix.utf8.count
    public static let maximumAccessibilityValueCharacterCount =
        maximumTextCharacterCount
        + textAccessibilityPrefix.count
        + truncatedAccessibilitySuffix.count

    public let displayText: String
    public let accessibilityValue: String
    public let state: DataValuePreviewState
    public let isTruncated: Bool

    public init(
        kind: DataValueKind,
        value: Data,
        secret: Bool,
        hasRevealAuthority: Bool = false
    ) {
        let countText = Self.countText(value.count)
        guard !secret || hasRevealAuthority else {
            displayText = "Secret concealed · \(countText)"
            accessibilityValue = "Secret value concealed, \(countText)"
            state = .concealed
            isTruncated = false
            return
        }

        guard kind == .text, let decoded = String(data: value, encoding: .utf8) else {
            displayText = "Binary · \(countText)"
            accessibilityValue = "Binary value, \(countText)"
            state = .binary
            isTruncated = false
            return
        }

        let bounded = Self.boundedSingleLine(decoded)
        displayText = bounded.text.isEmpty ? "(empty)" : bounded.text
        accessibilityValue = bounded.text.isEmpty
            ? "Empty text value"
            : Self.textAccessibilityPrefix + bounded.text
                + (bounded.truncated ? Self.truncatedAccessibilitySuffix : "")
        state = .text
        isTruncated = bounded.truncated
    }

    /// Normalizes and bounds in one pass. The output buffer can exceed the
    /// public byte limit by at most one Unicode scalar (four bytes), which lets
    /// us identify and discard the complete grapheme that crossed the limit.
    /// Pending whitespace is retained separately and only committed when a
    /// later non-whitespace scalar proves it is not trailing trim.
    private static func boundedSingleLine(
        _ value: String
    ) -> (text: String, truncated: Bool) {
        var result = String.UnicodeScalarView()
        result.reserveCapacity(maximumTextUTF8ByteCount + 4)
        var resultUTF8ByteCount = 0
        var pendingWhitespace = String.UnicodeScalarView()
        pendingWhitespace.reserveCapacity(maximumTextUTF8ByteCount + 4)
        var pendingWhitespaceUTF8ByteCount = 0
        var previousWasNormalizedControl = false

        for scalar in value.unicodeScalars {
            let isControl = CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
            if isControl {
                guard !previousWasNormalizedControl else { continue }
                previousWasNormalizedControl = true
                if Self.appendPendingWhitespace(
                    " ",
                    resultIsEmpty: result.isEmpty,
                    resultUTF8ByteCount: resultUTF8ByteCount,
                    pending: &pendingWhitespace,
                    pendingUTF8ByteCount: &pendingWhitespaceUTF8ByteCount
                ) {
                    return Self.bounded(String(result), forcingTruncation: true)
                }
                continue
            }

            previousWasNormalizedControl = false
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if Self.appendPendingWhitespace(
                    scalar,
                    resultIsEmpty: result.isEmpty,
                    resultUTF8ByteCount: resultUTF8ByteCount,
                    pending: &pendingWhitespace,
                    pendingUTF8ByteCount: &pendingWhitespaceUTF8ByteCount
                ) {
                    return Self.bounded(String(result), forcingTruncation: true)
                }
                continue
            }

            for pendingScalar in pendingWhitespace {
                if Self.append(
                    pendingScalar,
                    to: &result,
                    utf8ByteCount: &resultUTF8ByteCount
                ) {
                    return Self.truncatedBeforeLastCharacter(result)
                }
            }
            pendingWhitespace.removeAll(keepingCapacity: true)
            pendingWhitespaceUTF8ByteCount = 0

            if Self.append(
                scalar,
                to: &result,
                utf8ByteCount: &resultUTF8ByteCount
            ) {
                return Self.truncatedBeforeLastCharacter(result)
            }
        }
        return Self.bounded(String(result), forcingTruncation: false)
    }

    private static func appendPendingWhitespace(
        _ scalar: UnicodeScalar,
        resultIsEmpty: Bool,
        resultUTF8ByteCount: Int,
        pending: inout String.UnicodeScalarView,
        pendingUTF8ByteCount: inout Int
    ) -> Bool {
        // Ordinary leading and trailing whitespace remain presentation-only
        // trim. An oversized interior or trailing run is itself meaningful
        // omitted input, so stop immediately and present a concise ellipsis
        // instead of retaining or scanning the entire run.
        guard !resultIsEmpty else { return false }
        pending.append(scalar)
        pendingUTF8ByteCount += utf8ByteCount(of: scalar)
        return resultUTF8ByteCount + pendingUTF8ByteCount
            > maximumTextUTF8ByteCount
    }

    /// Returns true after appending the first scalar that crosses the byte
    /// budget. Keeping that one scalar lets Swift's grapheme segmenter tell us
    /// whether it joined the preceding character.
    private static func append(
        _ scalar: UnicodeScalar,
        to result: inout String.UnicodeScalarView,
        utf8ByteCount: inout Int
    ) -> Bool {
        result.append(scalar)
        utf8ByteCount += Self.utf8ByteCount(of: scalar)
        return utf8ByteCount > maximumTextUTF8ByteCount
    }

    private static func truncatedBeforeLastCharacter(
        _ scalars: String.UnicodeScalarView
    ) -> (text: String, truncated: Bool) {
        let value = String(scalars)
        return bounded(String(value.dropLast()), forcingTruncation: true)
    }

    private static func utf8ByteCount(of scalar: UnicodeScalar) -> Int {
        switch scalar.value {
        case 0...0x7f: 1
        case 0x80...0x7ff: 2
        case 0x800...0xffff: 3
        default: 4
        }
    }

    private static func bounded(
        _ value: String,
        forcingTruncation: Bool
    ) -> (text: String, truncated: Bool) {
        let characters = Array(value)
        let valueUTF8ByteCount = value.utf8.count
        guard forcingTruncation
            || characters.count > maximumTextCharacterCount
            || valueUTF8ByteCount > maximumTextUTF8ByteCount
        else {
            return (value, false)
        }

        let ellipsis = "…"
        let ellipsisUTF8ByteCount = ellipsis.utf8.count
        var result = String()
        result.reserveCapacity(min(valueUTF8ByteCount, maximumTextUTF8ByteCount))
        var resultCharacterCount = 0
        var resultUTF8ByteCount = 0
        for character in characters {
            let characterUTF8ByteCount = Self.utf8ByteCount(of: character)
            guard resultCharacterCount + 1 < maximumTextCharacterCount,
                resultUTF8ByteCount + characterUTF8ByteCount + ellipsisUTF8ByteCount
                    <= maximumTextUTF8ByteCount
            else { break }
            result.append(character)
            resultCharacterCount += 1
            resultUTF8ByteCount += characterUTF8ByteCount
        }
        result.append(ellipsis)
        return (result, true)
    }

    private static func utf8ByteCount(of character: Character) -> Int {
        character.unicodeScalars.reduce(into: 0) {
            $0 += utf8ByteCount(of: $1)
        }
    }

    private static func countText(_ count: Int) -> String {
        count == 1 ? "1 byte" : "\(count.formatted()) bytes"
    }
}

/// Metadata-only presentation for the Data editor's key list. It deliberately
/// has no value or preview input, so the same presentation is safe for Secrets
/// whether or not the selected value is currently revealed in the editor.
public struct DataEditorRowPresentation: Hashable, Sendable {
    public var keyText: String
    public var typeText: String
    public var sizeText: String
    public var state: DataEditorRowState
    public var accessibilityValue: String

    public init(
        key: String,
        storedKind: DataValueKind,
        storedByteSize: UInt64,
        isSelected: Bool,
        draftKind: DataValueKind? = nil,
        draftByteSize: UInt64? = nil,
        hasUnsavedChanges: Bool = false,
        hasConflict: Bool = false
    ) {
        // Unsaved drafts can remain when another key is selected. Callers pass
        // metadata for this row's draft only; a conflict without a local draft
        // continues to use the stored metadata.
        let usesDraftMetadata = isSelected || hasUnsavedChanges
        let effectiveKind = usesDraftMetadata ? (draftKind ?? storedKind) : storedKind
        let effectiveByteSize = usesDraftMetadata
            ? (draftByteSize ?? storedByteSize)
            : storedByteSize
        let rowState: DataEditorRowState = hasConflict
            ? .conflict
            : (hasUnsavedChanges ? .unsaved : .saved)
        let countText = effectiveByteSize == 1
            ? "1 byte"
            : "\(effectiveByteSize.formatted()) bytes"

        keyText = key
        typeText = effectiveKind.rawValue
        sizeText = countText
        state = rowState
        accessibilityValue = [key, effectiveKind.rawValue, countText, rowState.displayText]
            .joined(separator: ", ")
    }
}

/// A display-only description used by the key conflict sheet. Callers may
/// provide decoded text for ConfigMaps, but Secret text is discarded by the
/// initializer so a Secret can only be represented by kind, byte count, and
/// content hash.
public struct DataConflictValueDisplay: Hashable, Sendable {
    public var summaryText: String
    public var valueText: String?
    public var placeholderText: String

    public init(
        secret: Bool,
        kind: DataValueKind,
        byteCount: Int,
        contentHash: Data,
        decodedText: String?
    ) {
        let kindText = kind == .text ? "Text" : "Binary"
        let countText = byteCount == 1 ? "1 byte" : "\(byteCount.formatted()) bytes"
        summaryText = "\(kindText) · \(countText)\nSHA-256 \(Self.hex(contentHash))"
        if secret {
            valueText = nil
            placeholderText = "Secret value concealed. Compare the decoded-byte hash above."
        } else if kind == .text, let decodedText {
            valueText = decodedText
            placeholderText = ""
        } else {
            valueText = nil
            placeholderText = "Binary value. Compare the byte count and hash above."
        }
    }

    public static func missing(_ message: String = "Key is not present on the server.") -> Self {
        Self(summaryText: "Not present", valueText: nil, placeholderText: message)
    }

    public static func contentHash(of value: Data) -> Data {
        Data(SHA256.hash(data: value))
    }

    private init(summaryText: String, valueText: String?, placeholderText: String) {
        self.summaryText = summaryText
        self.valueText = valueText
        self.placeholderText = placeholderText
    }

    private static func hex(_ value: Data) -> String {
        value.map { String(format: "%02x", $0) }.joined()
    }
}

public enum DataConflictRetryPlan: Hashable, Sendable {
    case retry(DataMutationKind)
    case unavailable(reason: String)
}

public extension DataMutationKind {
    var sourceKey: String {
        switch self {
        case .set(let key, _, _, _), .delete(let key, _), .rename(let key, _, _): key
        }
    }

    var destinationKey: String? {
        guard case .rename(_, let newKey, _) = self else { return nil }
        return newKey
    }

    /// Rebuilds only the originally requested key mutation against a freshly
    /// fetched key snapshot. The caller supplies the fresh object
    /// resourceVersion separately when submitting the returned mutation.
    func conflictRetryPlan(
        currentContentHash: Data?,
        destinationExists: Bool = false
    ) -> DataConflictRetryPlan {
        switch self {
        case .set(let key, let kind, let value, _):
            // A nil hash retains the create-only precondition. A present hash
            // makes overwriting the exact value just shown an explicit choice.
            return .retry(.set(
                key: key,
                kind: kind,
                value: value,
                expectedContentHash: currentContentHash ?? Data()
            ))
        case .delete(let key, _):
            guard let currentContentHash else {
                return .unavailable(
                    reason: "The key is already absent, so there is no current value to delete."
                )
            }
            return .retry(.delete(key: key, expectedContentHash: currentContentHash))
        case .rename(let key, let newKey, _):
            guard let currentContentHash else {
                return .unavailable(
                    reason: "The source key is no longer present, so it cannot be renamed."
                )
            }
            guard !destinationExists else {
                return .unavailable(
                    reason: "The destination key \(newKey) now exists. Reload before choosing another name."
                )
            }
            return .retry(.rename(
                key: key,
                newKey: newKey,
                expectedContentHash: currentContentHash
            ))
        }
    }
}
