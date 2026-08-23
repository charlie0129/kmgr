import Foundation
import Testing
@testable import KmgrCore

@Test func kubernetesDataKeyValidationMatchesTheServerBoundary() {
    #expect(KubernetesDataKeyValidator.validationMessage(for: "config.yaml") == nil)
    #expect(KubernetesDataKeyValidator.validationMessage(for: "UPPER_case-1") == nil)
    #expect(KubernetesDataKeyValidator.validationMessage(for: "") != nil)
    #expect(KubernetesDataKeyValidator.validationMessage(for: "contains/slash") != nil)
    #expect(KubernetesDataKeyValidator.validationMessage(for: String(repeating: "a", count: 254)) != nil)
}

@Test func kubernetesDataKeyValidationRejectsAccidentalOverwrite() {
    let keys: Set<String> = ["existing"]
    #expect(KubernetesDataKeyValidator.validationMessage(for: "existing", existingKeys: keys) != nil)
    #expect(KubernetesDataKeyValidator.validationMessage(
        for: "existing", existingKeys: keys, allowingExistingKey: "existing"
    ) == nil)
}

@Test func dataEditorSavedRowUsesOnlyStoredMetadata() {
    let row = DataEditorRowPresentation(
        key: "settings.yaml",
        storedKind: .text,
        storedByteSize: 1,
        isSelected: false
    )

    #expect(row.keyText == "settings.yaml")
    #expect(row.typeText == "text")
    #expect(row.sizeText == "1 byte")
    #expect(row.state == .saved)
    #expect(row.accessibilityValue == "settings.yaml, text, 1 byte, Saved")
}

@Test func dataEditorModifiedRowUsesDraftTypeAndByteCount() {
    let row = DataEditorRowPresentation(
        key: "archive",
        storedKind: .text,
        storedByteSize: 4,
        isSelected: true,
        draftKind: .binary,
        draftByteSize: 8_192,
        draftState: .modified
    )

    #expect(row.typeText == "binary")
    #expect(row.sizeText.contains("8"))
    #expect(row.sizeText.hasSuffix("bytes"))
    #expect(row.state == .modified)
    #expect(row.accessibilityValue.contains("Modified"))
}

@Test func dataEditorUnselectedModifiedRowKeepsItsOwnDraftMetadata() {
    let row = DataEditorRowPresentation(
        key: "archive",
        storedKind: .text,
        storedByteSize: 4,
        isSelected: false,
        draftKind: .binary,
        draftByteSize: 8_192,
        draftState: .modified
    )

    #expect(row.typeText == "binary")
    #expect(row.sizeText.contains("8"))
    #expect(row.state == .modified)
}

@Test func dataEditorConflictTakesPrecedenceWithoutAcceptingAValuePreview() {
    let row = DataEditorRowPresentation(
        key: "token",
        storedKind: .text,
        storedByteSize: 24,
        isSelected: true,
        draftKind: .text,
        draftByteSize: 30,
        draftState: .modified,
        hasConflict: true
    )

    #expect(row.state == .conflict)
    #expect(row.typeText == "text")
    #expect(row.sizeText == "30 bytes")
    #expect(row.accessibilityValue == "token, text, 30 bytes, Conflict")
}

@Test func dataEditorConflictCanDescribeAnUnchangedLocalDraft() {
    let row = DataEditorRowPresentation(
        key: "token",
        storedKind: .text,
        storedByteSize: 24,
        isSelected: true,
        draftKind: .binary,
        draftByteSize: 30,
        hasConflict: true
    )

    #expect(row.state == .conflict)
    #expect(row.typeText == "binary")
    #expect(row.sizeText == "30 bytes")
}

@Test func dataEditorUnselectedConflictDoesNotBorrowSelectedDraftMetadata() {
    let row = DataEditorRowPresentation(
        key: "old-conflict",
        storedKind: .text,
        storedByteSize: 24,
        isSelected: false,
        draftKind: .binary,
        draftByteSize: 30,
        hasConflict: true
    )

    #expect(row.state == .conflict)
    #expect(row.typeText == "text")
    #expect(row.sizeText == "24 bytes")
    #expect(row.accessibilityValue == "old-conflict, text, 24 bytes, Conflict")
}

@Test func configMapValuePreviewNormalizesControlsIntoOneLine() {
    let value = Data("  first\r\nsecond\t\u{7}\u{2028}third  ".utf8)
    let preview = DataValuePreviewPresentation(
        kind: .text,
        value: value,
        secret: false
    )

    #expect(preview.displayText == "first second third")
    #expect(!preview.displayText.contains("\n"))
    #expect(!preview.displayText.contains("\r"))
    #expect(preview.accessibilityValue == "Text value: first second third")
    #expect(preview.state == .text)
    #expect(!preview.isTruncated)
}

@Test func textValuePreviewIsBoundedAndMarksTruncation() {
    let limit = DataValuePreviewPresentation.maximumTextCharacterCount
    let value = Data(String(repeating: "a", count: limit + 80).utf8)
    let preview = DataValuePreviewPresentation(
        kind: .text,
        value: value,
        secret: false
    )

    #expect(preview.displayText.count == limit)
    #expect(preview.displayText.hasSuffix("…"))
    #expect(preview.isTruncated)
    #expect(preview.accessibilityValue.contains("truncated preview"))
    #expect(preview.displayText.utf8.count
        <= DataValuePreviewPresentation.maximumTextUTF8ByteCount)
    #expect(preview.accessibilityValue.utf8.count
        <= DataValuePreviewPresentation.maximumAccessibilityValueUTF8ByteCount)
    #expect(preview.accessibilityValue.count
        <= DataValuePreviewPresentation.maximumAccessibilityValueCharacterCount)
}

@Test func textValuePreviewRejectsAnOversizedCombiningMarkClusterWhole() {
    // One valid extended grapheme can occupy essentially the entire Kubernetes
    // object-size budget while still reporting a character count of one.
    let value = "a" + String(repeating: "\u{0301}", count: 524_287)
    #expect(value.count == 1)
    #expect(value.utf8.count == (1 << 20) - 1)

    let preview = DataValuePreviewPresentation(
        kind: .text,
        value: Data(value.utf8),
        secret: false
    )

    #expect(preview.displayText == "…")
    #expect(preview.isTruncated)
    #expect(preview.displayText.utf8.count
        <= DataValuePreviewPresentation.maximumTextUTF8ByteCount)
    #expect(preview.accessibilityValue.utf8.count
        <= DataValuePreviewPresentation.maximumAccessibilityValueUTF8ByteCount)
    #expect(preview.accessibilityValue.count
        <= DataValuePreviewPresentation.maximumAccessibilityValueCharacterCount)
    #expect(String(data: Data(preview.displayText.utf8), encoding: .utf8)
        == preview.displayText)
}

@Test func textValuePreviewStopsAtAnOversizedTrailingWhitespaceRun() {
    let value = "visible" + String(repeating: " ", count: 1 << 20)
    let preview = DataValuePreviewPresentation(
        kind: .text,
        value: Data(value.utf8),
        secret: false
    )

    #expect(preview.displayText == "visible…")
    #expect(preview.accessibilityValue
        == "Text value: visible…, truncated preview")
    #expect(preview.isTruncated)
}

@Test func textValuePreviewUTF8LimitIncludesWholeMultibyteCharactersAndEllipsis() {
    let limit = DataValuePreviewPresentation.maximumTextCharacterCount
    let exactValue = String(repeating: "😀", count: limit)
    #expect(exactValue.utf8.count
        == DataValuePreviewPresentation.maximumTextUTF8ByteCount)
    let exact = DataValuePreviewPresentation(
        kind: .text,
        value: Data(exactValue.utf8),
        secret: false
    )
    #expect(exact.displayText == exactValue)
    #expect(!exact.isTruncated)

    let overflow = DataValuePreviewPresentation(
        kind: .text,
        value: Data((exactValue + "😀").utf8),
        secret: false
    )
    #expect(overflow.displayText.count == limit)
    #expect(overflow.displayText.hasSuffix("…"))
    #expect(overflow.displayText.utf8.count
        <= DataValuePreviewPresentation.maximumTextUTF8ByteCount)
    #expect(overflow.accessibilityValue.utf8.count
        <= DataValuePreviewPresentation.maximumAccessibilityValueUTF8ByteCount)
    #expect(overflow.accessibilityValue.count
        <= DataValuePreviewPresentation.maximumAccessibilityValueCharacterCount)
    #expect(String(data: Data(overflow.displayText.utf8), encoding: .utf8)
        == overflow.displayText)
    #expect(overflow.isTruncated)
}

@Test func emptyTextValueHasAUsefulAccessiblePlaceholder() {
    let preview = DataValuePreviewPresentation(
        kind: .text,
        value: Data("\n\t".utf8),
        secret: false
    )

    #expect(preview.displayText == "(empty)")
    #expect(preview.accessibilityValue == "Empty text value")
    #expect(preview.state == .text)
}

@Test func binaryValuePreviewUsesBoundedHexAndASCII() {
    let value = Data("binary-looking-text".utf8)
    let preview = DataValuePreviewPresentation(
        kind: .binary,
        value: value,
        secret: false
    )

    #expect(preview.displayText
        == "62 69 6E 61 72 79 2D 6C 6F 6F 6B 69 6E 67 2D 74 … |binary-looking-t…| · 19 bytes")
    #expect(preview.accessibilityValue == "Binary value: \(preview.displayText)")
    #expect(preview.isTruncated)
    #expect(preview.state == .binary)
}

@Test func emptyBinaryValuePreviewIsReadable() {
    let preview = DataValuePreviewPresentation(
        kind: .binary,
        value: Data(),
        secret: false
    )

    #expect(preview.displayText == "(empty) · 0 bytes")
    #expect(preview.accessibilityValue == "Binary value: (empty) · 0 bytes")
    #expect(!preview.isTruncated)
}

@Test func invalidUTF8TextValueFallsBackToTheSafeBinaryLabel() {
    let preview = DataValuePreviewPresentation(
        kind: .text,
        value: Data([0xff, 0xfe, 0xfd]),
        secret: false
    )

    #expect(preview.displayText == "FF FE FD |...| · 3 bytes")
    #expect(preview.accessibilityValue == "Binary value: FF FE FD |...| · 3 bytes")
    #expect(preview.state == .binary)
}

@Test func secretValuePreviewRequiresExplicitRevealAuthority() {
    let sentinel = "decoded-secret-value"
    let value = Data(sentinel.utf8)
    let encoded = value.base64EncodedString()
    let preview = DataValuePreviewPresentation(
        kind: .text,
        value: value,
        secret: true
    )

    #expect(preview.displayText == "Secret concealed · 20 bytes")
    #expect(preview.accessibilityValue == "Secret value concealed, 20 bytes")
    #expect(!preview.displayText.contains(sentinel))
    #expect(!preview.displayText.contains(encoded))
    #expect(!preview.accessibilityValue.contains(sentinel))
    #expect(preview.state == .concealed)
}

@Test func revealedSecretUsesTheDecodedConfigMapTextPolicy() {
    let value = Data("decoded\nsecret".utf8)
    let configMap = DataValuePreviewPresentation(
        kind: .text,
        value: value,
        secret: false
    )
    let secret = DataValuePreviewPresentation(
        kind: .text,
        value: value,
        secret: true,
        hasRevealAuthority: true
    )

    #expect(secret.displayText == "decoded secret")
    #expect(secret.displayText == configMap.displayText)
    #expect(secret.accessibilityValue == configMap.accessibilityValue)
    #expect(secret.state == .text)
    #expect(!secret.displayText.contains(value.base64EncodedString()))
}

@Test func revealedBinarySecretUsesBoundedHexAndASCII() {
    let preview = DataValuePreviewPresentation(
        kind: .binary,
        value: Data([0x00, 0x01, 0x02]),
        secret: true,
        hasRevealAuthority: true
    )

    #expect(preview.displayText == "00 01 02 |...| · 3 bytes")
    #expect(preview.accessibilityValue == "Binary value: 00 01 02 |...| · 3 bytes")
    #expect(preview.state == .binary)
}

@Test func binaryDumpAndDiffAreBoundedAndByteAligned() {
    let oversized = Data(repeating: 0x41, count: 300)
    let dump = BinaryHexASCIIPresentation.dump(oversized)
    #expect(dump.contains("000000F0"))
    #expect(!dump.contains("00000100"))
    #expect(dump.contains("44 additional bytes not shown"))

    let diff = BinaryHexASCIIPresentation.diff(
        local: Data([0x00, 0xff, 0x10]),
        current: Data([0x00, 0x7f, 0x10, 0x80])
    )
    #expect(diff.local.contains("00 FF 10 --"))
    #expect(diff.current.contains("00 7F 10 80"))
    #expect(diff.local.contains("^^"))
    #expect(diff.current.contains("^^"))
}

@Test func valuePreviewDoesNotRetainItsInputData() {
    let preview = DataValuePreviewPresentation(
        kind: .text,
        value: Data("transient".utf8),
        secret: false
    )

    #expect(!Mirror(reflecting: preview).children.contains { $0.value is Data })
}

@Test func configMapConflictDisplayShowsTextAndDecodedByteHash() {
    let value = Data("local value".utf8)
    let display = DataConflictValueDisplay(
        secret: false,
        kind: .text,
        byteCount: value.count,
        contentHash: DataConflictValueDisplay.contentHash(of: value),
        decodedText: "local value"
    )

    #expect(display.valueText == "local value")
    #expect(display.summaryText.contains("11 bytes"))
    #expect(display.summaryText.contains("SHA-256"))
}

@Test func secretConflictDisplayNeverRetainsDecodedText() {
    let sentinel = "do-not-show-this-secret"
    let value = Data(sentinel.utf8)
    let display = DataConflictValueDisplay(
        secret: true,
        kind: .text,
        byteCount: value.count,
        contentHash: DataConflictValueDisplay.contentHash(of: value),
        decodedText: sentinel
    )

    #expect(display.valueText == nil)
    #expect(!display.summaryText.contains(sentinel))
    #expect(!display.placeholderText.contains(sentinel))
    #expect(display.placeholderText.contains("concealed"))
}

@Test func revealedSecretConflictCanShowTransientTextAndBinaryDiffs() {
    let text = Data("edited secret".utf8)
    let revealedText = DataConflictValueDisplay(
        secret: true,
        kind: .text,
        byteCount: text.count,
        contentHash: DataConflictValueDisplay.contentHash(of: text),
        decodedText: "edited secret",
        secretRevealed: true
    )
    #expect(revealedText.valueText == "edited secret")

    let binary = DataConflictValueDisplay(
        secret: true,
        kind: .binary,
        byteCount: 4,
        contentHash: Data(repeating: 1, count: 32),
        decodedText: nil,
        binaryText: "00000000  00 FF 10 80  |....|",
        secretRevealed: true
    )
    #expect(binary.valueText?.contains("00 FF 10 80") == true)
}

@Test func retrySetUsesTheFreshKeyHashWithoutDiscardingLocalBytes() {
    let local = Data("local".utf8)
    let freshHash = Data(repeating: 7, count: 32)
    let stale = DataMutationKind.set(
        key: "settings",
        kind: .text,
        value: local,
        expectedContentHash: Data(repeating: 3, count: 32)
    )

    #expect(stale.conflictRetryPlan(currentContentHash: freshHash) == .retry(.set(
        key: "settings",
        kind: .text,
        value: local,
        expectedContentHash: freshHash
    )))
}

@Test func retryCreateRemainsCreateOnlyWhenTheFreshKeyIsAbsent() {
    let mutation = DataMutationKind.set(
        key: "new-key", kind: .text, value: Data(), expectedContentHash: Data()
    )

    #expect(mutation.conflictRetryPlan(currentContentHash: nil) == .retry(.set(
        key: "new-key", kind: .text, value: Data(), expectedContentHash: Data()
    )))
}

@Test func retryRenameRefusesToOverwriteAFreshDestination() {
    let mutation = DataMutationKind.rename(
        key: "old", newKey: "new", expectedContentHash: Data(repeating: 1, count: 32)
    )

    guard case .unavailable(let reason) = mutation.conflictRetryPlan(
        currentContentHash: Data(repeating: 2, count: 32),
        destinationExists: true
    ) else {
        Issue.record("Expected retry to remain unavailable")
        return
    }
    #expect(reason.contains("destination key new now exists"))
}

@Test func retryDeleteRefusesWhenTheFreshSourceIsMissing() {
    let mutation = DataMutationKind.delete(
        key: "old", expectedContentHash: Data(repeating: 1, count: 32)
    )

    guard case .unavailable(let reason) = mutation.conflictRetryPlan(
        currentContentHash: nil
    ) else {
        Issue.record("Expected retry to remain unavailable")
        return
    }
    #expect(reason.contains("already absent"))
}
