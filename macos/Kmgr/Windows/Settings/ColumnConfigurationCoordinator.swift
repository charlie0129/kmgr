import Foundation
import KmgrCore

/// Serial, process-wide persistence for the exact-GVR column document.
///
/// Every operation runs on this actor without an internal suspension point, so
/// a Columns sheet and resource-table resize can never interleave their
/// read/modify/write cycles. The cached document is also the conflict baseline:
/// an edit made by another process is rejected instead of overwritten.
private actor ColumnConfigurationRepository {
    struct MutationResult: Sendable {
        var sequence: UInt64
        var document: ColumnsConfigurationDocument
        var definitions: [ColumnDefinition]
        var applied: Bool
    }

    private let store: ColumnConfigurationFileStore
    private var document: ColumnsConfigurationDocument?
    private var latestMutationSequenceByMatch: [ColumnResourceMatch: UInt64] = [:]

    init(path: String) {
        store = ColumnConfigurationFileStore(path: path)
    }

    func load(reload: Bool) throws -> ColumnsConfigurationDocument {
        if !reload, let document { return document }
        let loaded = try store.load()
        document = loaded
        return loaded
    }

    func replace(
        _ definitions: [ColumnDefinition],
        matching match: ColumnResourceMatch,
        sequence: UInt64
    ) throws -> MutationResult {
        if let stale = try staleResult(matching: match, sequence: sequence) {
            return stale
        }
        var updated = try mutationBaseline()
        Self.upsert(definitions, matching: match, in: &updated)
        return try commit(
            updated,
            definitions: definitions,
            matching: match,
            sequence: sequence
        )
    }

    /// Applies only table presentation state to the newest durable
    /// definitions. A divider drag captured before a Columns-sheet edit can
    /// therefore never resurrect removed columns or undo extractor changes.
    func replaceLayout(
        _ layout: [ColumnDefinition],
        matching match: ColumnResourceMatch,
        sequence: UInt64
    ) throws -> MutationResult {
        if let stale = try staleResult(matching: match, sequence: sequence) {
            return stale
        }
        var updated = try mutationBaseline()
        let current = updated.views.first(where: { $0.match == match })?.columns
            ?? layout
        let definitions = Self.applyingLayout(layout, to: current)
        Self.upsert(definitions, matching: match, in: &updated)
        return try commit(
            updated,
            definitions: definitions,
            matching: match,
            sequence: sequence
        )
    }

    private func staleResult(
        matching match: ColumnResourceMatch,
        sequence: UInt64
    ) throws -> MutationResult? {
        guard let latest = latestMutationSequenceByMatch[match], sequence <= latest
        else { return nil }
        let current = try document ?? store.load()
        return MutationResult(
            sequence: sequence,
            document: current,
            definitions: current.views.first(where: { $0.match == match })?.columns ?? [],
            applied: false
        )
    }

    private func mutationBaseline() throws -> ColumnsConfigurationDocument {
        let baseline = try document ?? store.load()
        let currentOnDisk = try store.load()
        guard currentOnDisk == baseline else {
            // Keep the old baseline so every later implicit layout save also
            // fails closed. Only load(reload: true) adopts an external edit.
            throw ColumnConfigurationFileIssue(
                "The column configuration changed outside this application. "
                    + "Reload it before saving so no external edit is overwritten."
            )
        }
        return baseline
    }

    private func commit(
        _ updated: ColumnsConfigurationDocument,
        definitions: [ColumnDefinition],
        matching match: ColumnResourceMatch,
        sequence: UInt64
    ) throws -> MutationResult {
        try store.save(updated)
        latestMutationSequenceByMatch[match] = sequence
        document = updated
        return MutationResult(
            sequence: sequence,
            document: updated,
            definitions: definitions,
            applied: true
        )
    }

    private static func upsert(
        _ definitions: [ColumnDefinition],
        matching match: ColumnResourceMatch,
        in document: inout ColumnsConfigurationDocument
    ) {
        let view = ResourceColumnConfiguration(match: match, columns: definitions)
        if let index = document.views.firstIndex(where: { $0.match == match }) {
            document.views[index] = view
        } else {
            document.views.append(view)
        }
    }

    private static func applyingLayout(
        _ layout: [ColumnDefinition],
        to definitions: [ColumnDefinition]
    ) -> [ColumnDefinition] {
        let layoutByID = Dictionary(uniqueKeysWithValues: layout.map { ($0.id, $0) })
        let definitionIDs = Set(definitions.map(\.id))
        let orderedLayoutIDs = layout.map(\.id).filter(definitionIDs.contains)
        let layoutIDSet = Set(orderedLayoutIDs)
        var result = definitions

        // Reorder only slots represented by the table snapshot. Definitions
        // added by a newer Columns-sheet save retain their relative slots.
        let layoutSlots = result.indices.filter { layoutIDSet.contains(result[$0].id) }
        for (slot, id) in zip(layoutSlots, orderedLayoutIDs) {
            guard let sourceIndex = definitions.firstIndex(where: { $0.id == id })
            else { continue }
            result[slot] = definitions[sourceIndex]
        }
        for index in result.indices {
            if let width = layoutByID[result[index].id]?.width {
                result[index].width = width
            }
        }
        return result
    }

    func ensureFileExists() throws -> URL {
        let url = try store.ensureFileExists()
        if document == nil { document = try store.load() }
        return url
    }
}

/// Main-actor fan-out around the serial repository. Resource tables use the
/// debounced layout path; the Columns manager already owns its edit debounce
/// and therefore calls `save` directly. Both converge on the same repository
/// and observer stream.
@MainActor
final class ColumnConfigurationCoordinator {
    typealias Observer = @MainActor (
        _ match: ColumnResourceMatch,
        _ definitions: [ColumnDefinition]
    ) -> Void

    private struct PendingLayoutSave {
        var sequence: UInt64
        var definitions: [ColumnDefinition]
        var task: Task<Void, Never>
        var onFailure: (@MainActor (Error) -> Void)?
    }

    static let defaultLayoutPersistenceDelay: Duration = .milliseconds(250)

    private let repository: ColumnConfigurationRepository
    private let layoutPersistenceDelay: Duration
    private var observers: [UUID: Observer] = [:]
    private var pendingLayoutSaves: [ColumnResourceMatch: PendingLayoutSave] = [:]
    private var nextMutationSequence: UInt64 = 0
    private var latestPublishedMutationSequenceByMatch: [ColumnResourceMatch: UInt64] = [:]

    init(
        path: String,
        layoutPersistenceDelay: Duration = ColumnConfigurationCoordinator
            .defaultLayoutPersistenceDelay
    ) {
        repository = ColumnConfigurationRepository(path: path)
        self.layoutPersistenceDelay = layoutPersistenceDelay
    }

    deinit {
        for pending in pendingLayoutSaves.values { pending.task.cancel() }
    }

    func load(reload: Bool = false) async throws -> ColumnsConfigurationDocument {
        if reload {
            for pending in pendingLayoutSaves.values { pending.task.cancel() }
            pendingLayoutSaves.removeAll(keepingCapacity: true)
        }
        return try await repository.load(reload: reload)
    }

    @discardableResult
    func save(
        _ definitions: [ColumnDefinition],
        matching match: ColumnResourceMatch
    ) async throws -> ColumnsConfigurationDocument {
        // Any pending layout for this GVR represents an older user action.
        pendingLayoutSaves.removeValue(forKey: match)?.task.cancel()
        let sequence = makeMutationSequence()
        let result = try await repository.replace(
            definitions,
            matching: match,
            sequence: sequence
        )
        publish(result, matching: match)
        return result.document
    }

    func ensureFileExists() async throws -> URL {
        try await repository.ensureFileExists()
    }

    @discardableResult
    func observe(_ observer: @escaping Observer) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    /// Coalesces resize drags independently per exact GVR. A resource switch
    /// therefore cannot cancel another resource's pending preferred width.
    func scheduleLayoutSave(
        _ definitions: [ColumnDefinition],
        matching match: ColumnResourceMatch,
        onFailure: (@MainActor (Error) -> Void)? = nil
    ) {
        pendingLayoutSaves[match]?.task.cancel()
        let sequence = makeMutationSequence()
        let delay = layoutPersistenceDelay
        let task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await persistScheduledLayout(matching: match, sequence: sequence)
        }
        pendingLayoutSaves[match] = PendingLayoutSave(
            sequence: sequence,
            definitions: definitions,
            task: task,
            onFailure: onFailure
        )
    }

    /// Application termination awaits this before stopping the helper, so the
    /// final divider drag cannot be lost inside the debounce interval.
    func flushPendingLayoutSaves() async {
        let pending = pendingLayoutSaves
            .sorted { $0.key.key < $1.key.key }
            .map { ($0.key, $0.value) }
        pendingLayoutSaves.removeAll(keepingCapacity: true)
        for (_, value) in pending { value.task.cancel() }
        for (match, value) in pending {
            do {
                try await persistLayout(value, matching: match)
            } catch {
                value.onFailure?(error)
            }
        }
    }

    private func persistScheduledLayout(
        matching match: ColumnResourceMatch,
        sequence: UInt64
    ) async {
        guard let pending = pendingLayoutSaves[match],
            pending.sequence == sequence
        else { return }
        pendingLayoutSaves.removeValue(forKey: match)
        do {
            try await persistLayout(pending, matching: match)
        } catch {
            pending.onFailure?(error)
        }
    }

    private func persistLayout(
        _ pending: PendingLayoutSave,
        matching match: ColumnResourceMatch
    ) async throws {
        let result = try await repository.replaceLayout(
            pending.definitions,
            matching: match,
            sequence: pending.sequence
        )
        publish(result, matching: match)
    }

    private func makeMutationSequence() -> UInt64 {
        nextMutationSequence &+= 1
        return nextMutationSequence
    }

    private func publish(
        _ result: ColumnConfigurationRepository.MutationResult,
        matching match: ColumnResourceMatch
    ) {
        guard result.applied,
            result.sequence > (latestPublishedMutationSequenceByMatch[match] ?? 0)
        else { return }
        latestPublishedMutationSequenceByMatch[match] = result.sequence
        notify(match: match, definitions: result.definitions)
    }

    private func notify(
        match: ColumnResourceMatch,
        definitions: [ColumnDefinition]
    ) {
        // Snapshot callbacks so observers may safely remove themselves while
        // responding to a save.
        for observer in Array(observers.values) {
            observer(match, definitions)
        }
    }
}
