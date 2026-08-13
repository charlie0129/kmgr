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
