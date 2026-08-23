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
        case invalidAnnotationValue
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

enum ResourceMetadataValidation {
    static func validateQualifiedName(_ key: String, field: String) throws {
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

    static func validateLabelValue(_ value: String, field: String) throws {
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
            try ResourceMetadataValidation.validateQualifiedName(key, field: "labels[\(key)]")
            try ResourceMetadataValidation.validateLabelValue(value, field: "labels[\(key)]")
        }
        for (key, value) in annotations {
            try ResourceMetadataValidation.validateQualifiedName(key, field: "annotations[\(key)]")
            guard !value.contains("\0") else {
                throw ResourceMutationDraftError(
                    reason: .invalidAnnotationValue,
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
            try ResourceMetadataValidation.validateQualifiedName(key, field: "\(field)[\(index)]")
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

/// The two independently editable Kubernetes metadata maps. Keeping the kind
/// explicit prevents a same-named label and annotation from colliding in an
/// editor draft or in keyboard-driven actions.
public enum ResourceMetadataKind: String, Hashable, Sendable {
    case labels
    case annotations

    public var title: String {
        switch self {
        case .labels: "Labels"
        case .annotations: "Annotations"
        }
    }

    public var singularTitle: String {
        switch self {
        case .labels: "Label"
        case .annotations: "Annotation"
        }
    }

    public var setInstruction: String {
        switch self {
        case .labels:
            "Label values must be valid Kubernetes label values."
        case .annotations:
            "Annotation values may contain spaces, newlines, and equals signs."
        }
    }

    public func values(in detail: ObjectDetail) -> [String: String] {
        switch self {
        case .labels: detail.labels
        case .annotations: detail.annotations
        }
    }

    public func changes(
        set: [String: String] = [:],
        remove: [String] = []
    ) throws -> ResourceMetadataChanges {
        let changes: ResourceMetadataChanges
        switch self {
        case .labels:
            changes = ResourceMetadataChanges(
                labels: set,
                removeLabelKeys: remove
            )
        case .annotations:
            changes = ResourceMetadataChanges(
                annotations: set,
                removeAnnotationKeys: remove
            )
        }
        return try changes.validatedForMutation()
    }
}

/// A map-backed draft for one metadata kind. The editor keeps the authoritative
/// baseline separate from the desired map, allowing additions, removals, and
/// renames to become one sparse optimistic mutation without serializing the
/// complete object.
public struct ResourceMetadataDraft: Hashable, Sendable {
    public struct Change: Hashable, Sendable {
        public var beforeKey: String?
        public var afterKey: String?
        public var beforeValue: String?
        public var afterValue: String?

        public init(
            beforeKey: String?,
            afterKey: String?,
            beforeValue: String?,
            afterValue: String?
        ) {
            self.beforeKey = beforeKey
            self.afterKey = afterKey
            self.beforeValue = beforeValue
            self.afterValue = afterValue
        }
    }

    public let kind: ResourceMetadataKind
    private let baselineValues: [String: String]
    private var values: [String: String]
    /// Original key to current key. The API mutation remains remove+set, while
    /// the editor and review preserve the user's rename intent.
    private var renames: [String: String] = [:]

    public init(
        kind: ResourceMetadataKind,
        baselineValues: [String: String] = [:]
    ) {
        self.kind = kind
        self.baselineValues = baselineValues
        self.values = baselineValues
    }

    public var hasChanges: Bool { values != baselineValues || !renames.isEmpty }

    /// The union retains deleted keys long enough for the UI to show a
    /// reversible draft row instead of silently dropping the user's action.
    public var allKeys: [String] {
        Set(baselineValues.keys).union(values.keys)
            .subtracting(renames.keys)
            .sorted()
    }

    public func value(for key: String) -> String? { values[key] }

    public func baselineValue(for key: String) -> String? {
        baselineValues[renameSource(for: key) ?? key]
    }

    public func isDeleted(_ key: String) -> Bool {
        baselineValues[key] != nil && values[key] == nil
    }

    public func isAdded(_ key: String) -> Bool {
        renameSource(for: key) == nil
            && baselineValues[key] == nil && values[key] != nil
    }

    public func isChanged(_ key: String) -> Bool {
        renameSource(for: key) != nil || baselineValues[key] != values[key]
    }

    public func isRenamed(_ key: String) -> Bool {
        renameSource(for: key) != nil
    }

    public func renameSource(for key: String) -> String? {
        renames.first { $0.value == key }?.key
    }

    public mutating func setValue(_ value: String, for key: String) {
        values[key] = value
    }

    public mutating func addKey(_ key: String, value: String = "") throws {
        try Self.validateKey(key, existingKeys: occupiedKeys)
        values[key] = value
    }

    public mutating func renameKey(_ key: String, to newKey: String) throws {
        guard key != newKey else { return }
        guard let value = values[key] else { return }
        if let original = renameSource(for: key), newKey == original {
            renames.removeValue(forKey: original)
            values.removeValue(forKey: key)
            values[original] = value
            return
        }
        try Self.validateKey(newKey, existingKeys: occupiedKeys)
        if let original = renameSource(for: key) {
            renames[original] = newKey
        } else if baselineValues[key] != nil {
            renames[key] = newKey
        }
        values.removeValue(forKey: key)
        values[newKey] = value
    }

    public mutating func removeKey(_ key: String) {
        if let original = renameSource(for: key) {
            renames.removeValue(forKey: original)
        }
        values.removeValue(forKey: key)
    }

    public mutating func revertKey(_ key: String) {
        if let original = renameSource(for: key), let baseline = baselineValues[original] {
            renames.removeValue(forKey: original)
            values.removeValue(forKey: key)
            values[original] = baseline
            return
        }
        if let baseline = baselineValues[key] {
            values[key] = baseline
        } else {
            values.removeValue(forKey: key)
        }
    }

    public func changes() throws -> ResourceMetadataChanges {
        var set: [String: String] = [:]
        var remove: [String] = []
        // The API only needs the desired sparse map. Rename intent is retained
        // separately for the review; the final merge patch is the ordinary
        // baseline-to-desired set/remove diff, which also handles swaps and
        // delete/re-add sequences without overlapping operations.
        for key in Set(baselineValues.keys).union(values.keys).sorted() {
            switch (baselineValues[key], values[key]) {
            case (let before?, let after?) where before == after:
                continue
            case (_, let after?):
                set[key] = after
            case (.some, nil):
                remove.append(key)
            case (nil, nil):
                continue
            }
        }
        return try kind.changes(set: set, remove: remove.sorted())
    }

    public var changeList: [Change] {
        var result: [Change] = renames.sorted { $0.key < $1.key }.map { source, destination in
            Change(
                beforeKey: source,
                afterKey: destination,
                beforeValue: baselineValues[source],
                afterValue: values[destination]
            )
        }
        let renameSources = Set(renames.keys)
        let renameDestinations = Set(renames.values)
        for key in Set(baselineValues.keys).union(values.keys).sorted()
            where !renameSources.contains(key) && !renameDestinations.contains(key)
        {
            let before = baselineValues[key]
            let after = values[key]
            guard before != after else { continue }
            result.append(Change(
                beforeKey: before == nil ? nil : key,
                afterKey: after == nil ? nil : key,
                beforeValue: before,
                afterValue: after
            ))
        }
        return result
    }

    private var occupiedKeys: Set<String> {
        // Validate against the desired map, not the original map. A key that
        // was deleted or renamed away is available for a staged replacement;
        // the final sparse patch can then remove and set those keys atomically.
        Set(values.keys)
    }

    private static func validateKey(
        _ key: String,
        existingKeys: Set<String>
    ) throws {
        try ResourceMetadataValidation.validateQualifiedName(
            key,
            field: "metadata.key"
        )
        guard !existingKeys.contains(key) else {
            throw ResourceMutationDraftError(
                reason: .duplicateKey,
                field: "metadata.key",
                message: "Metadata key \(key.debugDescription) already exists."
            )
        }
    }
}
