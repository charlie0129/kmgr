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
