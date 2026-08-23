import Foundation
import KmgrCore

/// Process-memory-only staged transaction for ConfigMap/Secret Data.
///
/// Values remain in `SensitiveBytes`; snapshots are short-lived copies that
/// callers must wipe after rendering a review or submitting a mutation batch.
@MainActor
final class DataEditorDraftStore {
    enum State: String {
        case added = "Added"
        case modified = "Modified"
        case renamed = "Renamed"
        case deleted = "Deleted"
    }

    struct Metadata {
        var kind: DataValueKind
        var byteCount: Int
        var sourceKey: String?
        var state: State
        var valueChanged: Bool
    }

    struct SensitiveSnapshot {
        var beforeKey: String?
        var afterKey: String?
        var afterKind: DataValueKind?
        var afterValue: Data?
        var expectedContentHash: Data
        var valueChanged: Bool

        mutating func wipe() {
            guard var afterValue else { return }
            self.afterValue = nil
            afterValue.resetBytes(in: afterValue.startIndex..<afterValue.endIndex)
        }
    }

    private struct Draft {
        var sourceKey: String?
        var currentKey: String
        var originalKind: DataValueKind?
        var kind: DataValueKind
        var value: SensitiveBytes
        var expectedContentHash: Data
        var valueChanged: Bool

        var state: State {
            guard let sourceKey else { return .added }
            return sourceKey == currentKey ? .modified : .renamed
        }
    }

    private var drafts: [String: Draft] = [:]
    private var deletions: [String: Data] = [:]

    var isEmpty: Bool { drafts.isEmpty && deletions.isEmpty }
    var changedKeyCount: Int { drafts.count + deletions.count }

    func contains(_ displayKey: String) -> Bool {
        drafts[displayKey] != nil || deletions[displayKey] != nil
    }

    func isDeleted(_ displayKey: String) -> Bool {
        deletions[displayKey] != nil
    }

    func metadata(for displayKey: String) -> Metadata? {
        guard let draft = drafts[displayKey] else { return nil }
        return Metadata(
            kind: draft.kind,
            byteCount: draft.value.count,
            sourceKey: draft.sourceKey,
            state: draft.state,
            valueChanged: draft.valueChanged
        )
    }

    func sourceKey(for displayKey: String) -> String? {
        drafts[displayKey]?.sourceKey ?? (deletions[displayKey] != nil ? displayKey : nil)
    }

    func displayKey(forSourceKey sourceKey: String) -> String? {
        if deletions[sourceKey] != nil { return sourceKey }
        return drafts.values.first { $0.sourceKey == sourceKey }?.currentKey
    }

    func displayedKeys(baselineKeys: [String]) -> [String] {
        let renamedSources = Set<String>(drafts.values.compactMap { draft in
            guard let sourceKey = draft.sourceKey, sourceKey != draft.currentKey else {
                return nil
            }
            return sourceKey
        })
        return Set(baselineKeys.filter { !renamedSources.contains($0) })
            .union(drafts.keys)
            .sorted()
    }

    func snapshot(for displayKey: String) -> SensitiveSnapshot? {
        if let draft = drafts[displayKey] {
            var value = Data()
            draft.value.withUnsafeBytes { value.append(contentsOf: $0) }
            return SensitiveSnapshot(
                beforeKey: draft.sourceKey,
                afterKey: draft.currentKey,
                afterKind: draft.kind,
                afterValue: value,
                expectedContentHash: draft.expectedContentHash,
                valueChanged: draft.valueChanged
            )
        }
        guard let hash = deletions[displayKey] else { return nil }
        return SensitiveSnapshot(
            beforeKey: displayKey,
            afterKey: nil,
            afterKind: nil,
            afterValue: nil,
            expectedContentHash: hash,
            valueChanged: false
        )
    }

    func allSnapshots() -> [SensitiveSnapshot] {
        let keys = Set(drafts.keys).union(deletions.keys).sorted()
        return keys.compactMap(snapshot(for:))
    }

    func add(key: String, kind: DataValueKind, value: Data = Data()) {
        deletions.removeValue(forKey: key)
        drafts[key] = Draft(
            sourceKey: nil,
            currentKey: key,
            originalKind: nil,
            kind: kind,
            value: SensitiveBytes(value),
            expectedContentHash: Data(),
            valueChanged: true
        )
    }

    func update(
        key: String,
        kind: DataValueKind,
        value: Data,
        baselineKind: DataValueKind,
        valueMatchesBaseline: Bool,
        baselineContentHash: Data
    ) {
        if var draft = drafts[key] {
            draft.kind = kind
            draft.value.replacing(with: value)
            draft.valueChanged = draft.sourceKey == nil
                || kind != draft.originalKind
                || !valueMatchesBaseline
            if draft.sourceKey == draft.currentKey, !draft.valueChanged {
                drafts.removeValue(forKey: key)
            } else {
                drafts[key] = draft
            }
            return
        }
        guard kind != baselineKind || !valueMatchesBaseline else { return }
        drafts[key] = Draft(
            sourceKey: key,
            currentKey: key,
            originalKind: baselineKind,
            kind: kind,
            value: SensitiveBytes(value),
            expectedContentHash: baselineContentHash,
            valueChanged: true
        )
    }

    func rename(
        key: String,
        to newKey: String,
        baselineKind: DataValueKind,
        baselineValue: Data,
        baselineContentHash: Data
    ) {
        guard key != newKey else { return }
        if var draft = drafts.removeValue(forKey: key) {
            draft.currentKey = newKey
            if draft.sourceKey == newKey, !draft.valueChanged {
                return
            }
            drafts[newKey] = draft
            return
        }
        deletions.removeValue(forKey: key)
        drafts[newKey] = Draft(
            sourceKey: key,
            currentKey: newKey,
            originalKind: baselineKind,
            kind: baselineKind,
            value: SensitiveBytes(baselineValue),
            expectedContentHash: baselineContentHash,
            valueChanged: false
        )
    }

    func delete(key: String, baselineContentHash: Data?) {
        if let draft = drafts.removeValue(forKey: key) {
            guard let sourceKey = draft.sourceKey else { return }
            deletions[sourceKey] = draft.expectedContentHash
            return
        }
        guard let baselineContentHash else { return }
        deletions[key] = baselineContentHash
    }

    /// Reverts one displayed row and returns the key that should be selected.
    func revert(key: String) -> String? {
        if deletions.removeValue(forKey: key) != nil { return key }
        guard let draft = drafts.removeValue(forKey: key) else { return key }
        return draft.sourceKey
    }

    func rebase(
        displayKey: String,
        currentKind: DataValueKind?,
        currentValue: Data?,
        currentContentHash: Data?
    ) {
        if var draft = drafts[displayKey] {
            guard let currentKind, let currentValue, let currentContentHash else {
                // A locally modified server key that disappeared becomes a
                // create-only draft against the freshly accepted baseline.
                draft.sourceKey = nil
                draft.originalKind = nil
                draft.expectedContentHash = Data()
                draft.valueChanged = true
                drafts[displayKey] = draft
                return
            }

            let localMatchesCurrent = draft.kind == currentKind
                && Self.valuesEqual(draft.value, currentValue)
            if !draft.valueChanged {
                // A rename-only draft follows the current server value; the
                // user's intent was the key rename, not restoring stale bytes.
                draft.kind = currentKind
                draft.value.replacing(with: currentValue)
            }
            draft.sourceKey = draft.sourceKey ?? draft.currentKey
            draft.originalKind = currentKind
            draft.expectedContentHash = currentContentHash
            draft.valueChanged = draft.valueChanged && !localMatchesCurrent
            if draft.sourceKey == draft.currentKey, !draft.valueChanged {
                drafts.removeValue(forKey: displayKey)
            } else {
                drafts[displayKey] = draft
            }
        } else if deletions[displayKey] != nil, let currentContentHash {
            deletions[displayKey] = currentContentHash
        }
    }

    func removeAll() {
        drafts.removeAll(keepingCapacity: false)
        deletions.removeAll(keepingCapacity: false)
    }

    func mutations() -> [DataMutationKind] {
        var mutations: [DataMutationKind] = []
        mutations.reserveCapacity(deletions.count + drafts.count * 2)
        for key in deletions.keys.sorted() {
            guard let hash = deletions[key] else { continue }
            mutations.append(.delete(key: key, expectedContentHash: hash))
        }
        for key in drafts.keys.sorted() {
            guard let draft = drafts[key] else { continue }
            if let sourceKey = draft.sourceKey, sourceKey != draft.currentKey {
                mutations.append(.rename(
                    key: sourceKey,
                    newKey: draft.currentKey,
                    expectedContentHash: draft.expectedContentHash
                ))
                if !draft.valueChanged { continue }
                var value = Data()
                draft.value.withUnsafeBytes { value.append(contentsOf: $0) }
                mutations.append(.set(
                    key: draft.currentKey,
                    kind: draft.kind,
                    value: value,
                    expectedContentHash: Data()
                ))
                continue
            }
            var value = Data()
            draft.value.withUnsafeBytes { value.append(contentsOf: $0) }
            mutations.append(.set(
                key: draft.currentKey,
                kind: draft.kind,
                value: value,
                expectedContentHash: draft.expectedContentHash
            ))
        }
        return mutations
    }

    private static func valuesEqual(_ sensitive: SensitiveBytes, _ value: Data) -> Bool {
        guard sensitive.count == value.count else { return false }
        return sensitive.withUnsafeBytes { local in
            value.withUnsafeBytes { current in
                local.elementsEqual(current)
            }
        }
    }
}
