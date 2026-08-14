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
    public static let maximumTextCharacterCount = 160

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

        let normalized = Self.singleLine(decoded)
        let bounded = Self.bounded(normalized)
        displayText = bounded.text.isEmpty ? "(empty)" : bounded.text
        accessibilityValue = bounded.text.isEmpty
            ? "Empty text value"
            : "Text value: \(bounded.text)" + (bounded.truncated ? ", truncated preview" : "")
        state = .text
        isTruncated = bounded.truncated
    }

    private static func singleLine(_ value: String) -> String {
        var result = String.UnicodeScalarView()
        result.reserveCapacity(min(value.unicodeScalars.count, maximumTextCharacterCount + 1))
        var previousWasNormalizedControl = false

        for scalar in value.unicodeScalars {
            let isControl = CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
            if isControl {
                if !previousWasNormalizedControl {
                    result.append(" ")
                }
                previousWasNormalizedControl = true
            } else {
                result.append(scalar)
                previousWasNormalizedControl = false
            }
        }
        return String(result).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bounded(_ value: String) -> (text: String, truncated: Bool) {
        guard value.count > maximumTextCharacterCount else {
            return (value, false)
        }
        return (String(value.prefix(maximumTextCharacterCount - 1)) + "…", true)
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

    var conflictActionDescription: String {
        switch self {
        case .set(let key, _, _, _): "save key \(key)"
        case .delete(let key, _): "delete key \(key)"
        case .rename(let key, let newKey, _): "rename key \(key) to \(newKey)"
        }
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
