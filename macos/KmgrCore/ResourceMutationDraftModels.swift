import Foundation

public struct OptimisticResourceMutationTarget: Hashable, Sendable {
    public var identity: ResourceIdentity
    public var expectedResourceVersion: String

    /// Pins a fresh authoritative detail response back to the exact selection
    /// that opened a mutation sheet. This prevents a provider bug or stale
    /// namespace/name lookup from supplying the resource version of a
    /// same-name replacement object.
    public init(
        selectedIdentity: ResourceIdentity,
        authoritativeDetail: ObjectDetail
    ) throws {
        try ResourceMutationDraftValidator.validateIdentity(selectedIdentity)
        guard authoritativeDetail.identity == selectedIdentity else {
            throw ResourceMutationDraftError(
                reason: .identityChanged,
                field: "identity",
                message: "The selected Kubernetes object changed identity before the mutation was submitted."
            )
        }
        let resourceVersion = authoritativeDetail.resourceVersion
        guard !resourceVersion.isEmpty,
            resourceVersion.utf8.count <= ResourceMutationDraftValidator.maximumIdentityTokenBytes,
            !resourceVersion.contains("\0")
        else {
            throw ResourceMutationDraftError(
                reason: .missingResourceVersion,
                field: "resourceVersion",
                message: "A fresh Kubernetes resource version is required for optimistic concurrency."
            )
        }
        identity = selectedIdentity
        expectedResourceVersion = resourceVersion
    }
}

public struct ResourceMutationDraftError: Error, Hashable, Sendable {
    public enum Reason: String, Hashable, Sendable {
        case incompleteIdentity
        case identityChanged
        case missingResourceVersion
        case invalidReplicaCount
        case unsupportedRolloutTarget
        case inputTooLarge
        case tooManyEntries
        case malformedAssignment
        case invalidMetadataKey
        case invalidLabelValue
        case duplicateKey
        case conflictingChange
        case noChanges
    }

    public var reason: Reason
    public var field: String
    public var message: String

    public init(reason: Reason, field: String, message: String) {
        self.reason = reason
        self.field = field
        self.message = message
    }
}

extension ResourceMutationDraftError: LocalizedError {
    public var errorDescription: String? { message }
}

public enum ResourceMutationDraftValidator {
    public static let maximumIdentityTokenBytes = 4 << 10
    public static let maximumMetadataInputBytes = 256 << 10
    public static let maximumMetadataEntries = 256

    public static func replicaCount(_ text: String) throws -> Int32 {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
            value.utf8.allSatisfy({ (48...57).contains($0) }),
            let parsed = UInt64(value), parsed <= Int32.max
        else {
            throw ResourceMutationDraftError(
                reason: .invalidReplicaCount,
                field: "replicas",
                message: "Replicas must be a whole number from 0 through \(Int32.max)."
            )
        }
        return Int32(parsed)
    }

    public static func validateRolloutRestart(_ identity: ResourceIdentity) throws {
        try validateIdentity(identity)
        guard identity.group == "apps", identity.version == "v1",
            ["deployments", "statefulsets", "daemonsets"].contains(identity.resource)
        else {
            throw ResourceMutationDraftError(
                reason: .unsupportedRolloutTarget,
                field: "identity.resource",
                message: "Rollout restart supports apps/v1 Deployments, StatefulSets, and DaemonSets."
            )
        }
    }

    public static func validateIdentity(_ identity: ResourceIdentity) throws {
        let required = [
            ("clusterSessionID", identity.clusterSessionID),
            ("version", identity.version),
            ("resource", identity.resource),
            ("name", identity.name),
            ("uid", identity.uid.rawValue),
        ]
        guard required.allSatisfy({ _, value in
            !value.isEmpty && value.utf8.count <= maximumIdentityTokenBytes &&
                !value.contains("\0")
        }), identity.group.utf8.count <= maximumIdentityTokenBytes,
            identity.namespace.utf8.count <= maximumIdentityTokenBytes,
            !identity.group.contains("\0"), !identity.namespace.contains("\0")
        else {
            throw ResourceMutationDraftError(
                reason: .incompleteIdentity,
                field: "identity",
                message: "The mutation requires a complete cluster, resource, name, and exact Kubernetes UID."
            )
        }
    }
}

/// Strict text grammar for the native labels/annotations editor:
///
///     set entry:       qualified-key=value
///     removal entry:   qualified-key
///
/// Entries are separated by newlines and blank lines are ignored. The first
/// `=` separates key and value, so annotation values may contain `=` and
/// commas without quoting or shell-like escaping. Annotation values are kept
/// byte-for-byte; label values are validated using Kubernetes' label grammar.
public enum ResourceMetadataDraftParser {
    public static func changes(
        labels: String,
        annotations: String,
        removeLabels: String,
        removeAnnotations: String
    ) throws -> ResourceMetadataChanges {
        try validateInputSize([
            ("labels", labels),
            ("annotations", annotations),
            ("removeLabelKeys", removeLabels),
            ("removeAnnotationKeys", removeAnnotations),
        ])
        let changes = ResourceMetadataChanges(
            labels: try assignments(labels, kind: .label),
            annotations: try assignments(annotations, kind: .annotation),
            removeLabelKeys: try removalKeys(removeLabels, field: "removeLabelKeys"),
            removeAnnotationKeys: try removalKeys(
                removeAnnotations, field: "removeAnnotationKeys"
            )
        )
        return try changes.validatedForMutation()
    }

    private enum Kind {
        case label
        case annotation

        var field: String { self == .label ? "labels" : "annotations" }
    }

    private static func assignments(_ text: String, kind: Kind) throws -> [String: String] {
        let lines = meaningfulLines(text)
        guard lines.count <= ResourceMutationDraftValidator.maximumMetadataEntries else {
            throw tooManyEntries(field: kind.field)
        }
        var result: [String: String] = [:]
        result.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            guard let separator = line.firstIndex(of: "=") else {
                throw ResourceMutationDraftError(
                    reason: .malformedAssignment,
                    field: "\(kind.field)[\(index)]",
                    message: "Each \(kind.field) entry must use qualified-key=value on its own line."
                )
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...])
            try validateQualifiedName(key, field: "\(kind.field)[\(index)].key")
            guard result[key] == nil else {
                throw duplicate(key: key, field: "\(kind.field)[\(index)].key")
            }
            if kind == .label {
                try validateLabelValue(value, field: "\(kind.field)[\(index)].value")
            } else if value.contains("\0") {
                throw ResourceMutationDraftError(
                    reason: .malformedAssignment,
                    field: "\(kind.field)[\(index)].value",
                    message: "Annotation values cannot contain NUL bytes."
                )
            }
            result[key] = value
        }
        return result
    }

    private static func removalKeys(_ text: String, field: String) throws -> [String] {
        let lines = meaningfulLines(text)
        guard lines.count <= ResourceMutationDraftValidator.maximumMetadataEntries else {
            throw tooManyEntries(field: field)
        }
        var result: [String] = []
        var seen: Set<String> = []
        result.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            let key = line.trimmingCharacters(in: .whitespaces)
            try validateQualifiedName(key, field: "\(field)[\(index)]")
            guard seen.insert(key).inserted else {
                throw duplicate(key: key, field: "\(field)[\(index)]")
            }
            result.append(key)
        }
        return result
    }

    private static func meaningfulLines(_ text: String) -> [Substring] {
        text.split(whereSeparator: \Character.isNewline).filter { line in
            !line.allSatisfy(\.isWhitespace)
        }
    }

    private static func validateInputSize(_ values: [(String, String)]) throws {
        for (field, value) in values where
            value.utf8.count > ResourceMutationDraftValidator.maximumMetadataInputBytes
        {
            throw ResourceMutationDraftError(
                reason: .inputTooLarge,
                field: field,
                message: "\(field) input exceeds the \(ResourceMutationDraftValidator.maximumMetadataInputBytes)-byte limit."
            )
        }
    }

    fileprivate static func validateQualifiedName(_ key: String, field: String) throws {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        let valid: Bool
        if parts.count == 1 {
            valid = validName(String(parts[0]))
        } else if parts.count == 2 {
            valid = validDNSSubdomain(String(parts[0])) && validName(String(parts[1]))
        } else {
            valid = false
        }
        guard valid else {
            throw ResourceMutationDraftError(
                reason: .invalidMetadataKey,
                field: field,
                message: "Metadata key \(key.debugDescription) is not a valid Kubernetes qualified name."
            )
        }
    }

    fileprivate static func validateLabelValue(_ value: String, field: String) throws {
        let bytes = Array(value.utf8)
        let valid = bytes.isEmpty || (bytes.count <= 63 && isAlphaNumeric(bytes[0]) &&
            isAlphaNumeric(bytes[bytes.count - 1]) && bytes.allSatisfy(isNameByte))
        guard valid else {
            throw ResourceMutationDraftError(
                reason: .invalidLabelValue,
                field: field,
                message: "Label value \(value.debugDescription) is not a valid Kubernetes label value."
            )
        }
    }

    private static func validName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= 63 && isAlphaNumeric(bytes[0]) &&
            isAlphaNumeric(bytes[bytes.count - 1]) && bytes.allSatisfy(isNameByte)
    }

    private static func validDNSSubdomain(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 253 else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { segment in
            let segmentBytes = Array(segment.utf8)
            return !segmentBytes.isEmpty && segmentBytes.count <= 63 &&
                isLowerAlphaNumeric(segmentBytes[0]) &&
                isLowerAlphaNumeric(segmentBytes[segmentBytes.count - 1]) &&
                segmentBytes.allSatisfy { isLowerAlphaNumeric($0) || $0 == 45 }
        }
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        isAlphaNumeric(byte) || byte == 45 || byte == 46 || byte == 95
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        isLowerAlphaNumeric(byte) || (65...90).contains(byte)
    }

    private static func isLowerAlphaNumeric(_ byte: UInt8) -> Bool {
        (97...122).contains(byte) || (48...57).contains(byte)
    }

    private static func duplicate(key: String, field: String) -> ResourceMutationDraftError {
        ResourceMutationDraftError(
            reason: .duplicateKey,
            field: field,
            message: "Metadata key \(key.debugDescription) appears more than once."
        )
    }

    private static func tooManyEntries(field: String) -> ResourceMutationDraftError {
        ResourceMutationDraftError(
            reason: .tooManyEntries,
            field: field,
            message: "\(field) may contain at most \(ResourceMutationDraftValidator.maximumMetadataEntries) entries."
        )
    }
}

public extension ResourceMetadataChanges {
    func validatedForMutation() throws -> Self {
        guard !isEmpty else {
            throw ResourceMutationDraftError(
                reason: .noChanges,
                field: "metadata",
                message: "Enter at least one label or annotation change."
            )
        }
        guard labels.count <= ResourceMutationDraftValidator.maximumMetadataEntries,
            annotations.count <= ResourceMutationDraftValidator.maximumMetadataEntries,
            removeLabelKeys.count <= ResourceMutationDraftValidator.maximumMetadataEntries,
            removeAnnotationKeys.count <= ResourceMutationDraftValidator.maximumMetadataEntries
        else {
            throw ResourceMutationDraftError(
                reason: .tooManyEntries,
                field: "metadata",
                message: "Each metadata change list may contain at most \(ResourceMutationDraftValidator.maximumMetadataEntries) entries."
            )
        }
        for (key, value) in labels {
            try ResourceMetadataDraftParser.validateQualifiedName(key, field: "labels[\(key)]")
            try ResourceMetadataDraftParser.validateLabelValue(value, field: "labels[\(key)]")
        }
        for (key, value) in annotations {
            try ResourceMetadataDraftParser.validateQualifiedName(key, field: "annotations[\(key)]")
            guard !value.contains("\0") else {
                throw ResourceMutationDraftError(
                    reason: .malformedAssignment,
                    field: "annotations[\(key)]",
                    message: "Annotation values cannot contain NUL bytes."
                )
            }
        }
        let removeLabelSet = try validatedRemovalSet(removeLabelKeys, field: "removeLabelKeys")
        let removeAnnotationSet = try validatedRemovalSet(
            removeAnnotationKeys, field: "removeAnnotationKeys"
        )
        if let key = removeLabelSet.intersection(labels.keys).first {
            throw conflicting(key: key, field: "labels")
        }
        if let key = removeAnnotationSet.intersection(annotations.keys).first {
            throw conflicting(key: key, field: "annotations")
        }
        let annotationBytes = annotations.reduce(into: 0) { total, entry in
            total += entry.key.utf8.count + entry.value.utf8.count
        }
        guard annotationBytes <= ResourceMutationDraftValidator.maximumMetadataInputBytes else {
            throw ResourceMutationDraftError(
                reason: .inputTooLarge,
                field: "annotations",
                message: "Annotation keys and values exceed Kubernetes' 256 KiB metadata limit."
            )
        }
        return self
    }

    private func validatedRemovalSet(
        _ keys: [String],
        field: String
    ) throws -> Set<String> {
        var seen: Set<String> = []
        for (index, key) in keys.enumerated() {
            try ResourceMetadataDraftParser.validateQualifiedName(key, field: "\(field)[\(index)]")
            guard seen.insert(key).inserted else {
                throw ResourceMutationDraftError(
                    reason: .duplicateKey,
                    field: "\(field)[\(index)]",
                    message: "Metadata key \(key.debugDescription) appears more than once."
                )
            }
        }
        return seen
    }

    private func conflicting(key: String, field: String) -> ResourceMutationDraftError {
        ResourceMutationDraftError(
            reason: .conflictingChange,
            field: field,
            message: "Metadata key \(key.debugDescription) cannot be set and removed in the same mutation."
        )
    }
}
