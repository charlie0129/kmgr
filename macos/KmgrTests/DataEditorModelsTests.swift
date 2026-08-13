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
