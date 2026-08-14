import Foundation
import KmgrCore

/// Process-memory-only drafts for the ConfigMap/Secret Data editor.
///
/// Values deliberately live in `SensitiveBytes`: this type is neither Codable
/// nor printable and releases its backing buffer when a draft is replaced or
/// removed. The store exposes short-lived copies only while painting or
/// submitting the selected value.
@MainActor
final class DataEditorDraftStore {
    struct Metadata {
        var kind: DataValueKind
        var byteCount: Int
    }

    /// A short-lived, secret-bearing copy for the selected editor only.
    /// Never persist, log, or attach this value to restoration state.
    struct SensitiveSnapshot {
        var kind: DataValueKind
        var value: Data
        var expectedContentHash: Data

        mutating func wipe() {
            value.resetBytes(in: value.startIndex..<value.endIndex)
            value.removeAll(keepingCapacity: false)
        }
    }

    private struct Draft {
        var kind: DataValueKind
        var value: SensitiveBytes
        var expectedContentHash: Data
    }

    private var drafts: [String: Draft] = [:]

    var isEmpty: Bool { drafts.isEmpty }
    var keys: [String] { Array(drafts.keys) }

    func contains(_ key: String) -> Bool {
        drafts[key] != nil
    }

    func metadata(for key: String) -> Metadata? {
        guard let draft = drafts[key] else { return nil }
        return Metadata(kind: draft.kind, byteCount: draft.value.count)
    }

    func snapshot(for key: String) -> SensitiveSnapshot? {
        guard let draft = drafts[key] else { return nil }
        var value = Data()
        draft.value.withUnsafeBytes { value.append(contentsOf: $0) }
        return SensitiveSnapshot(
            kind: draft.kind,
            value: value,
            expectedContentHash: draft.expectedContentHash
        )
    }

    /// Records a value only when it differs from the loaded value or kind.
    /// Updating an existing draft retains its original content hash so a later
    /// save cannot silently rebase over a concurrently changed server key.
    func update(
        key: String,
        kind: DataValueKind,
        value: Data,
        storedKind: DataValueKind,
        valueMatchesStored: Bool,
        storedContentHash: Data
    ) {
        guard kind != storedKind || !valueMatchesStored else {
            remove(key)
            return
        }
        if var draft = drafts[key] {
            draft.kind = kind
            draft.value.replacing(with: value)
            drafts[key] = draft
        } else {
            drafts[key] = Draft(
                kind: kind,
                value: SensitiveBytes(value),
                expectedContentHash: storedContentHash
            )
        }
    }

    /// Updates a draft whose server key is currently missing. Its original
    /// content hash remains available for diagnostics, while recreation uses
    /// an explicit create-only precondition at submission time.
    func replaceExisting(key: String, kind: DataValueKind, value: Data) {
        guard var draft = drafts[key] else { return }
        draft.kind = kind
        draft.value.replacing(with: value)
        drafts[key] = draft
    }

    func remove(_ key: String) {
        drafts.removeValue(forKey: key)
    }

    func removeAll() {
        drafts.removeAll(keepingCapacity: false)
    }
}
