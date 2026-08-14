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

@Test func dataEditorUnsavedRowUsesDraftTypeAndByteCount() {
    let row = DataEditorRowPresentation(
        key: "archive",
        storedKind: .text,
        storedByteSize: 4,
        isSelected: true,
        draftKind: .binary,
        draftByteSize: 8_192,
        hasUnsavedChanges: true
    )

    #expect(row.typeText == "binary")
    #expect(row.sizeText.contains("8"))
    #expect(row.sizeText.hasSuffix("bytes"))
    #expect(row.state == .unsaved)
    #expect(row.accessibilityValue.contains("Unsaved"))
}

@Test func dataEditorConflictTakesPrecedenceWithoutAcceptingAValuePreview() {
    let row = DataEditorRowPresentation(
        key: "token",
        storedKind: .text,
        storedByteSize: 24,
        isSelected: true,
        draftKind: .text,
        draftByteSize: 30,
        hasUnsavedChanges: true,
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
