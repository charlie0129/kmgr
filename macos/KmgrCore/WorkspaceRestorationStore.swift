import Foundation

/// One independently restorable cluster window. `id` is deliberately not the
/// context name: several windows may point at the same context while retaining
/// independent frames and navigation state.
public struct ClusterWindowRestorationRecord: Hashable, Codable, Sendable, Identifiable {
    public static let maximumIdentifierBytes = 128

    public var id: String
    public var state: ClusterWindowRestorationState

    public init(
        id: String = UUID().uuidString.lowercased(),
        state: ClusterWindowRestorationState
    ) {
        self.id = id
        self.state = state
    }

    public init(
        id: String = UUID().uuidString.lowercased(),
        contextName: String,
        contextReference: String
    ) {
        self.init(id: id, state: ClusterWindowRestorationState(
            contextName: contextName,
            contextReference: contextReference
        ))
    }

    /// Use with `NSWindow.setFrameAutosaveName`. The stable opaque ID avoids
    /// collisions between multiple windows for the same kubeconfig context.
    public var frameAutosaveName: String { "ClusterWorkspace-\(id)" }

    public func validated() throws -> Self {
        var issues = state.validationIssues()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        if id.isEmpty || id.utf8.count > Self.maximumIdentifierBytes ||
            id.unicodeScalars.contains(where: { !allowed.contains($0) })
        {
            issues.insert(.init(
                path: "id",
                message: "A saved cluster window ID must be a bounded opaque identifier."
            ), at: 0)
        }
        guard issues.isEmpty else { throw RestorationValidationError(issues: issues) }
        return self
    }
}

public struct WorkspaceRestorationLoadIssue: Error, LocalizedError, Hashable, Sendable {
    public enum Reason: String, Hashable, Sendable {
        case unsupportedVersion
        case invalidData
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

/// One versioned, allow-listed document for all cluster windows that were open
/// at the last application checkpoint. Frame rectangles remain in AppKit's
/// normal autosave keys; this document stores only each opaque autosave name.
@MainActor
public final class WorkspaceRestorationStore {
    public static let apiVersion = "kmgr.workspace-restoration/v1"
    public static let storageKey = "kmgr.workspace-restoration.document"
    public static let maximumOpenWindows = 64

    private struct Document: Codable {
        var apiVersion: String
        var windows: [ClusterWindowRestorationRecord]
    }

    private let defaults: UserDefaults
    public private(set) var windows: [ClusterWindowRestorationRecord] = []
    public private(set) var loadIssue: WorkspaceRestorationLoadIssue?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadFromDefaults()
    }

    public func record(for id: String) -> ClusterWindowRestorationRecord? {
        windows.first { $0.id == id }
    }

    /// Inserts a newly opened window or checkpoints an existing window. Array
    /// order is retained as the application's restore ordering.
    public func upsert(_ record: ClusterWindowRestorationRecord) throws {
        let record = try record.validated()
        var updated = windows
        if let index = updated.firstIndex(where: { $0.id == record.id }) {
            updated[index] = record
        } else {
            guard updated.count < Self.maximumOpenWindows else {
                throw RestorationValidationError(issues: [.init(
                    path: "windows",
                    message: "At most \(Self.maximumOpenWindows) cluster windows can be restored."
                )])
            }
            updated.append(record)
        }
        try persist(updated)
    }

    /// Call only for an explicit user close. App termination should retain the
    /// live records so those context windows reopen on the next launch.
    public func remove(id: String) throws {
        guard windows.contains(where: { $0.id == id }) else { return }
        try persist(windows.filter { $0.id != id })
    }

    public func reset() {
        defaults.removeObject(forKey: Self.storageKey)
        windows = []
        loadIssue = nil
    }

    private func persist(_ records: [ClusterWindowRestorationRecord]) throws {
        let document = Document(apiVersion: Self.apiVersion, windows: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(try encoder.encode(document), forKey: Self.storageKey)
        windows = records
        loadIssue = nil
    }

    private func loadFromDefaults() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            loadIssue = WorkspaceRestorationLoadIssue(
                reason: .invalidData,
                message: "Saved cluster windows could not be decoded and will not be reopened."
            )
            return
        }
        guard document.apiVersion == Self.apiVersion else {
            loadIssue = WorkspaceRestorationLoadIssue(
                reason: .unsupportedVersion,
                message: "Saved cluster windows use unsupported version \(document.apiVersion) and will not be reopened."
            )
            return
        }
        do {
            guard document.windows.count <= Self.maximumOpenWindows,
                Set(document.windows.map(\.id)).count == document.windows.count
            else {
                throw RestorationValidationError(issues: [.init(
                    path: "windows",
                    message: "Saved cluster windows exceed a limit or contain duplicate IDs."
                )])
            }
            windows = try document.windows.map { try $0.validated() }
        } catch {
            windows = []
            loadIssue = WorkspaceRestorationLoadIssue(
                reason: .invalidValues,
                message: "Saved cluster windows contain invalid values and will not be reopened."
            )
        }
    }
}
