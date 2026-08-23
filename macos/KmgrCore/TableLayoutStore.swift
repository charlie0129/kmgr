import Foundation

/// Stable identities for tables whose columns are independent of Kubernetes
/// resource discovery. Resource-list layouts use the separate exact-GVR
/// columns configuration and never enter this store.
public enum TableSurfaceID: String, CaseIterable, Codable, Hashable, Sendable {
    case clusterContexts = "cluster-contexts"
    case podContainers = "pod-containers"
    case objectSummary = "object-summary"
    case objectRelationships = "object-relationships"
    case objectDataKeys = "object-data-keys"
    case objectMetadataKeys = "object-metadata-keys"
    case columnsManager = "columns-manager"
    case nativeColumnPicker = "native-column-picker"
    case portForwards = "port-forwards"
    case operationHistory = "operation-history"
    case deleteConfirmation = "delete-confirmation"
    case yamlDiffPaths = "yaml-diff-paths"
    case keyValueDiffChanges = "key-value-diff-changes"
}

public struct TableColumnLayout: Codable, Hashable, Sendable {
    public var id: String
    public var width: Double

    public init(id: String, width: Double) {
        self.id = id
        self.width = width
    }
}

/// Complete left-to-right presentation for one fixed table. A schema mismatch
/// resets that surface to its new code-defined defaults; fixed-table layouts
/// deliberately do not carry migration or compatibility machinery.
public struct TableLayout: Codable, Hashable, Sendable {
    public var columns: [TableColumnLayout]

    public init(columns: [TableColumnLayout]) {
        self.columns = columns
    }
}

public struct TableLayoutStoreLoadIssue: Error, LocalizedError, Hashable, Sendable {
    public enum Reason: String, Hashable, Sendable {
        case invalidData
        case unsupportedVersion
        case invalidValues
    }

    public var reason: Reason
    public var message: String

    public init(reason: Reason, message: String) {
        self.reason = reason
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// One process-wide, strict, coalescing store for fixed-table column order and
/// widths. Mutations update observers immediately but write UserDefaults only
/// after the shared debounce, so resize drags across any number of windows do
/// not produce repeated persistence traffic.
@MainActor
public final class TableLayoutStore {
    public static let apiVersion = "kmgr.table-layouts/v1"
    public static let storageKey = "kmgr.table-layouts.document"
    public static let maximumDocumentBytes = 256 << 10
    public static let maximumColumnsPerSurface = 64
    public static let maximumColumnIDBytes = 128
    public static let minimumColumnWidth = 24.0
    public static let maximumColumnWidth = 4_096.0
    public static let defaultPersistenceDelay: Duration = .milliseconds(250)

    private struct Document: Codable {
        var apiVersion: String
        var layouts: [String: TableLayout]
    }

    private struct Observer {
        var surface: TableSurfaceID
        var callback: @MainActor (TableLayout?) -> Void
    }

    private let defaults: UserDefaults
    private let persistenceDelay: Duration
    private var pendingSaveTask: Task<Void, Never>?
    private var observers: [UUID: Observer] = [:]
    private var dirty = false

    public private(set) var layouts: [TableSurfaceID: TableLayout] = [:]
    public private(set) var loadIssue: TableLayoutStoreLoadIssue?

    /// Internal instrumentation makes debounce behavior directly testable
    /// without relying on UserDefaults notifications.
    private(set) var successfulPersistenceCount = 0

    public init(
        defaults: UserDefaults = .standard,
        persistenceDelay: Duration = TableLayoutStore.defaultPersistenceDelay
    ) {
        self.defaults = defaults
        self.persistenceDelay = persistenceDelay
        loadFromDefaults()
    }

    deinit {
        pendingSaveTask?.cancel()
    }

    public func layout(for surface: TableSurfaceID) -> TableLayout? {
        layouts[surface]
    }

    /// Returns false without changing state when the proposed layout is not a
    /// complete, bounded, unique, and persistable fixed-table presentation.
    @discardableResult
    public func set(_ layout: TableLayout, for surface: TableSurfaceID) -> Bool {
        guard Self.isValid(layout) else { return false }
        guard layouts[surface] != layout else { return true }
        layouts[surface] = layout
        loadIssue = nil
        dirty = true
        notifyObservers(for: surface)
        schedulePersistence()
        return true
    }

    @discardableResult
    public func removeLayout(for surface: TableSurfaceID) -> Bool {
        guard layouts.removeValue(forKey: surface) != nil else { return false }
        loadIssue = nil
        dirty = true
        notifyObservers(for: surface)
        schedulePersistence()
        return true
    }

    /// Observers receive the current value synchronously, then every in-memory
    /// mutation for their one stable surface. Cross-window synchronization does
    /// not wait for disk persistence.
    @discardableResult
    public func observe(
        _ surface: TableSurfaceID,
        _ callback: @escaping @MainActor (TableLayout?) -> Void
    ) -> UUID {
        let id = UUID()
        observers[id] = Observer(surface: surface, callback: callback)
        callback(layouts[surface])
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    /// Flushes the one pending coalesced document. Application termination
    /// calls this so the last resize cannot be lost inside the debounce interval.
    @discardableResult
    public func flushPendingSave() -> Bool {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        return persistIfNeeded()
    }

    /// Waits for the currently scheduled coalesced save, if any. This is
    /// useful to lifecycle callers that need to observe durable state without
    /// guessing how long the debounce or main-actor scheduling will take.
    internal func waitForPendingSave() async {
        while let task = pendingSaveTask {
            await task.value
        }
    }

    public func reset() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        defaults.removeObject(forKey: Self.storageKey)
        let affected = Set(layouts.keys).union(observers.values.map(\.surface))
        layouts = [:]
        dirty = false
        loadIssue = nil
        for surface in affected { notifyObservers(for: surface) }
    }

    public static func isValid(_ layout: TableLayout) -> Bool {
        guard !layout.columns.isEmpty,
            layout.columns.count <= maximumColumnsPerSurface
        else { return false }
        let identifiers = layout.columns.map(\.id)
        guard Set(identifiers).count == identifiers.count else { return false }
        return layout.columns.allSatisfy { column in
            let id = column.id
            return !id.isEmpty && id == id.trimmingCharacters(in: .whitespacesAndNewlines)
                && id.utf8.count <= maximumColumnIDBytes
                && !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                && column.width.isFinite
                && (minimumColumnWidth...maximumColumnWidth).contains(column.width)
        }
    }

    private func schedulePersistence() {
        pendingSaveTask?.cancel()
        let delay = persistenceDelay
        pendingSaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            pendingSaveTask = nil
            _ = persistIfNeeded()
        }
    }

    private func persistIfNeeded() -> Bool {
        guard dirty else { return true }
        let encodedLayouts = Dictionary(uniqueKeysWithValues: layouts.map {
            ($0.key.rawValue, $0.value)
        })
        let document = Document(apiVersion: Self.apiVersion, layouts: encodedLayouts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(document),
            data.count <= Self.maximumDocumentBytes
        else { return false }
        defaults.set(data, forKey: Self.storageKey)
        dirty = false
        successfulPersistenceCount += 1
        return true
    }

    private func notifyObservers(for surface: TableSurfaceID) {
        let value = layouts[surface]
        let callbacks = observers.values
            .filter { $0.surface == surface }
            .map(\.callback)
        for callback in callbacks { callback(value) }
    }

    private func loadFromDefaults() {
        guard defaults.object(forKey: Self.storageKey) != nil else { return }
        guard let data = defaults.data(forKey: Self.storageKey),
            data.count <= Self.maximumDocumentBytes
        else {
            resetInvalidDocument(
                reason: .invalidData,
                message: "Saved table layouts could not be decoded; default layouts are in use."
            )
            return
        }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            resetInvalidDocument(
                reason: .invalidData,
                message: "Saved table layouts could not be decoded; default layouts are in use."
            )
            return
        }
        guard Self.hasExactDocumentShape(data) else {
            resetInvalidDocument(
                reason: .invalidValues,
                message: "Saved table layouts contain invalid values; default layouts are in use."
            )
            return
        }
        guard document.apiVersion == Self.apiVersion else {
            resetInvalidDocument(
                reason: .unsupportedVersion,
                message: "Saved table layouts use an unsupported version; default layouts are in use."
            )
            return
        }
        guard document.layouts.count <= TableSurfaceID.allCases.count else {
            resetInvalidDocument(
                reason: .invalidValues,
                message: "Saved table layouts contain invalid values; default layouts are in use."
            )
            return
        }

        var decoded: [TableSurfaceID: TableLayout] = [:]
        decoded.reserveCapacity(document.layouts.count)
        for (rawSurface, layout) in document.layouts {
            guard let surface = TableSurfaceID(rawValue: rawSurface),
                Self.isValid(layout), decoded[surface] == nil
            else {
                resetInvalidDocument(
                    reason: .invalidValues,
                    message: "Saved table layouts contain invalid values; default layouts are in use."
                )
                return
            }
            decoded[surface] = layout
        }
        layouts = decoded
    }

    private static func hasExactDocumentShape(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            Set(root.keys) == ["apiVersion", "layouts"],
            let layouts = root["layouts"] as? [String: Any]
        else { return false }
        for value in layouts.values {
            guard let layout = value as? [String: Any],
                Set(layout.keys) == ["columns"],
                let columns = layout["columns"] as? [Any]
            else { return false }
            for value in columns {
                guard let column = value as? [String: Any],
                    Set(column.keys) == ["id", "width"]
                else { return false }
            }
        }
        return true
    }

    private func resetInvalidDocument(
        reason: TableLayoutStoreLoadIssue.Reason,
        message: String
    ) {
        defaults.removeObject(forKey: Self.storageKey)
        layouts = [:]
        dirty = false
        loadIssue = TableLayoutStoreLoadIssue(reason: reason, message: message)
    }
}
