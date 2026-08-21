import Foundation

private let restorationIdentifierCharacters = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
)

private func isValidRestorationIdentifier(_ value: String) -> Bool {
    !value.isEmpty
        && value.utf8.count <= ClusterWindowRestorationRecord.maximumIdentifierBytes
        && !value.unicodeScalars.contains(where: {
            !restorationIdentifierCharacters.contains($0)
        })
}

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
        if !isValidRestorationIdentifier(id) {
            issues.insert(.init(
                path: "id",
                message: "A saved cluster window ID must be a bounded opaque identifier."
            ), at: 0)
        }
        guard issues.isEmpty else { throw RestorationValidationError(issues: issues) }
        return self
    }
}

/// One reusable starting point per exact kubeconfig-context reference.
/// `sourceWindowID` records the most recently activated same-context window,
/// so background windows cannot steal the bookmark during passive updates.
public struct ClusterContextWorkspaceBookmark: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var sourceWindowID: String
    public var state: ClusterWindowRestorationState

    public init(
        id: String = UUID().uuidString.lowercased(),
        sourceWindowID: String,
        state: ClusterWindowRestorationState
    ) {
        self.id = id
        self.sourceWindowID = sourceWindowID
        self.state = state
    }

    public var contextReference: String { state.contextReference }

    public func validated() throws -> Self {
        var issues = state.validationIssues()
        if !isValidRestorationIdentifier(id) {
            issues.insert(.init(
                path: "id",
                message: "A context bookmark ID must be a bounded opaque identifier."
            ), at: 0)
        }
        if !isValidRestorationIdentifier(sourceWindowID) {
            issues.append(.init(
                path: "sourceWindowID",
                message: "A context bookmark source must be a bounded opaque window identifier."
            ))
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

/// One versioned, allow-listed document for open cluster windows and reusable
/// exact-context navigation bookmarks. Per-window frame rectangles remain in
/// AppKit's normal autosave keys; global new-window sizing is stored separately.
@MainActor
public final class WorkspaceRestorationStore {
    public static let apiVersion = "kmgr.workspace-restoration/v2"
    public static let storageKey = "kmgr.workspace-restoration.document"
    public static let maximumOpenWindows = 64
    public static let maximumContextBookmarks = 64

    private struct Document: Codable {
        var apiVersion: String
        var windows: [ClusterWindowRestorationRecord]
        var bookmarks: [ClusterContextWorkspaceBookmark]
    }

    private let defaults: UserDefaults
    public private(set) var windows: [ClusterWindowRestorationRecord] = []
    public private(set) var bookmarks: [ClusterContextWorkspaceBookmark] = []
    public private(set) var loadIssue: WorkspaceRestorationLoadIssue?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadFromDefaults()
    }

    public func record(for id: String) -> ClusterWindowRestorationRecord? {
        windows.first { $0.id == id }
    }

    public func bookmark(for contextReference: String) -> ClusterContextWorkspaceBookmark? {
        bookmarks.first { $0.contextReference == contextReference }
    }

    /// Inserts a newly opened window or checkpoints an existing window. Array
    /// order is retained as the application's restore ordering.
    public func upsert(_ record: ClusterWindowRestorationRecord) throws {
        let record = try record.validated()
        var updatedWindows = windows
        try Self.upsertWindow(record, in: &updatedWindows)
        var updatedBookmarks = bookmarks
        if let index = updatedBookmarks.firstIndex(where: {
            $0.sourceWindowID == record.id
                && $0.contextReference == record.state.contextReference
        }) {
            updatedBookmarks[index].state = record.state
        }
        try persist(windows: updatedWindows, bookmarks: updatedBookmarks)
    }

    /// Makes this window the reusable source for its exact opaque context.
    /// The stable bookmark ID—and therefore its frame autosave key—survives
    /// activation changes between several windows for the same context.
    @discardableResult
    public func activate(
        _ record: ClusterWindowRestorationRecord
    ) throws -> ClusterContextWorkspaceBookmark {
        let record = try record.validated()
        var updatedWindows = windows
        try Self.upsertWindow(record, in: &updatedWindows)
        var updatedBookmarks = bookmarks
        let bookmark: ClusterContextWorkspaceBookmark
        if let index = updatedBookmarks.firstIndex(where: {
            $0.contextReference == record.state.contextReference
        }) {
            updatedBookmarks[index].sourceWindowID = record.id
            updatedBookmarks[index].state = record.state
            bookmark = updatedBookmarks[index]
        } else {
            guard updatedBookmarks.count < Self.maximumContextBookmarks else {
                throw RestorationValidationError(issues: [.init(
                    path: "bookmarks",
                    message: "At most \(Self.maximumContextBookmarks) context bookmarks can be saved."
                )])
            }
            bookmark = ClusterContextWorkspaceBookmark(
                sourceWindowID: record.id,
                state: record.state
            )
            updatedBookmarks.append(bookmark)
        }
        _ = try bookmark.validated()
        try persist(windows: updatedWindows, bookmarks: updatedBookmarks)
        return bookmark
    }

    /// Call only for an explicit user close. App termination should retain the
    /// live records so those context windows reopen on the next launch.
    public func remove(id: String) throws {
        guard windows.contains(where: { $0.id == id }) else { return }
        try persist(
            windows: windows.filter { $0.id != id },
            bookmarks: bookmarks
        )
    }

    /// Consumes only the prior process's open-window set when automatic
    /// restoration is disabled. Exact-context bookmarks remain useful for
    /// windows the user opens explicitly later.
    public func removeAllOpenWindows() throws {
        if loadIssue != nil {
            reset()
            return
        }
        guard !windows.isEmpty else { return }
        try persist(windows: [], bookmarks: bookmarks)
    }

    public func reset() {
        defaults.removeObject(forKey: Self.storageKey)
        windows = []
        bookmarks = []
        loadIssue = nil
    }

    private static func upsertWindow(
        _ record: ClusterWindowRestorationRecord,
        in windows: inout [ClusterWindowRestorationRecord]
    ) throws {
        if let index = windows.firstIndex(where: { $0.id == record.id }) {
            windows[index] = record
            return
        }
        guard windows.count < Self.maximumOpenWindows else {
            throw RestorationValidationError(issues: [.init(
                path: "windows",
                message: "At most \(Self.maximumOpenWindows) cluster windows can be restored."
            )])
        }
        windows.append(record)
    }

    private func persist(
        windows: [ClusterWindowRestorationRecord],
        bookmarks: [ClusterContextWorkspaceBookmark]
    ) throws {
        let document = Document(
            apiVersion: Self.apiVersion,
            windows: windows,
            bookmarks: bookmarks
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(try encoder.encode(document), forKey: Self.storageKey)
        self.windows = windows
        self.bookmarks = bookmarks
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
                message: "Saved workspaces could not be decoded and will not be reopened."
            )
            return
        }
        guard document.apiVersion == Self.apiVersion else {
            loadIssue = WorkspaceRestorationLoadIssue(
                reason: .unsupportedVersion,
                message: "Saved workspaces use unsupported version \(document.apiVersion) and will not be reopened."
            )
            return
        }
        do {
            guard document.windows.count <= Self.maximumOpenWindows,
                document.bookmarks.count <= Self.maximumContextBookmarks,
                Set(document.windows.map(\.id)).count == document.windows.count,
                Set(document.bookmarks.map(\.id)).count == document.bookmarks.count,
                Set(document.bookmarks.map(\.contextReference)).count
                    == document.bookmarks.count
            else {
                throw RestorationValidationError(issues: [.init(
                    path: "document",
                    message: "Saved workspaces exceed a limit or contain duplicate identities."
                )])
            }
            windows = try document.windows.map { try $0.validated() }
            bookmarks = try document.bookmarks.map { try $0.validated() }
        } catch {
            windows = []
            bookmarks = []
            loadIssue = WorkspaceRestorationLoadIssue(
                reason: .invalidValues,
                message: "Saved workspaces contain invalid values and will not be reopened."
            )
        }
    }
}
