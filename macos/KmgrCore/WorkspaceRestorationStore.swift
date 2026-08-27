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
/// independent navigation state.
public struct ClusterWindowRestorationRecord: Hashable, Codable, Sendable, Identifiable {
    public static let maximumIdentifierBytes = 128
    public static let frameAutosaveNamePrefix = "Kmgr-ClusterWorkspace-"

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

    /// AppKit's per-window frame key. The restoration record identity is
    /// intentionally used instead of the context reference because several
    /// windows may point at the same exact kubeconfig context.
    public var frameAutosaveName: String {
        "\(Self.frameAutosaveNamePrefix)\(id)"
    }

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

/// One versioned, allow-listed document for open cluster windows and the last
/// navigation state for each exact kubeconfig context. A context state is
/// updated only by the active workspace; background windows update their own
/// records without overwriting the shared starting point.
@MainActor
public final class WorkspaceRestorationStore {
    public static let apiVersion = "kmgr.workspace-restoration/v3"
    public static let storageKey = "kmgr.workspace-restoration.document"
    public static let maximumOpenWindows = 64
    public static let maximumContextStates = 64

    private struct Document: Codable {
        var apiVersion: String
        var windows: [ClusterWindowRestorationRecord]
        var lastStates: [ClusterWindowRestorationState]
    }

    private struct DocumentHeader: Decodable {
        var apiVersion: String
    }

    private let defaults: UserDefaults
    public private(set) var windows: [ClusterWindowRestorationRecord] = []
    public private(set) var lastStates: [ClusterWindowRestorationState] = []
    public private(set) var loadIssue: WorkspaceRestorationLoadIssue?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadFromDefaults()
    }

    public func record(for id: String) -> ClusterWindowRestorationRecord? {
        windows.first { $0.id == id }
    }

    public func lastState(for contextReference: String) -> ClusterWindowRestorationState? {
        lastStates.first { $0.contextReference == contextReference }
    }

    /// Inserts a newly opened window or checkpoints an existing window. The
    /// first record for a context seeds its shared state; later background
    /// checkpoints never replace the active context state.
    public func upsert(_ record: ClusterWindowRestorationRecord) throws {
        let record = try record.validated()
        var updatedWindows = windows
        try Self.upsertWindow(record, in: &updatedWindows)
        var updatedStates = lastStates
        if !updatedStates.contains(where: {
            $0.contextReference == record.state.contextReference
        }) {
            guard updatedStates.count < Self.maximumContextStates else {
                throw RestorationValidationError(issues: [.init(
                    path: "lastStates",
                    message: "At most \(Self.maximumContextStates) context states can be saved."
                )])
            }
            updatedStates.append(record.state)
        }
        try persist(windows: updatedWindows, lastStates: updatedStates)
    }

    /// Makes this record the shared starting state for its exact context.
    /// Only callers that know the workspace is active should use this method.
    /// Active windows move to the end of the restore order so the last active
    /// window is presented last—and therefore frontmost—on the next launch.
    public func activate(_ record: ClusterWindowRestorationRecord) throws {
        let record = try record.validated()
        var updatedWindows = windows
        try Self.upsertWindow(record, in: &updatedWindows, movesToEnd: true)
        var updatedStates = lastStates
        if let index = updatedStates.firstIndex(where: {
            $0.contextReference == record.state.contextReference
        }) {
            updatedStates[index] = record.state
        } else {
            guard updatedStates.count < Self.maximumContextStates else {
                throw RestorationValidationError(issues: [.init(
                    path: "lastStates",
                    message: "At most \(Self.maximumContextStates) context states can be saved."
                )])
            }
            updatedStates.append(record.state)
        }
        try persist(windows: updatedWindows, lastStates: updatedStates)
    }

    /// Call only for an explicit user close. App termination should retain the
    /// live records so those context windows reopen on the next launch.
    public func remove(id: String) throws {
        guard windows.contains(where: { $0.id == id }) else { return }
        try persist(
            windows: windows.filter { $0.id != id },
            lastStates: lastStates
        )
    }

    /// Removes records that are no longer owned by a live workspace window.
    /// The application calls this after checkpointing every live controller at
    /// termination so delayed callbacks from already-closed windows cannot
    /// resurrect an older launch's restore set. Existing order is preserved,
    /// including the active window's final position.
    public func retainOpenWindows(withIDs openWindowIDs: Set<String>) throws {
        if loadIssue != nil {
            reset()
            return
        }
        let retainedWindows = windows.filter { openWindowIDs.contains($0.id) }
        guard retainedWindows.map(\.id) != windows.map(\.id) else { return }
        try persist(windows: retainedWindows, lastStates: lastStates)
    }

    /// Consumes only the prior process's open-window set when automatic
    /// restoration is disabled. Last context states remain useful for new
    /// windows opened explicitly later.
    public func removeAllOpenWindows() throws {
        if loadIssue != nil {
            reset()
            return
        }
        guard !windows.isEmpty else { return }
        try persist(windows: [], lastStates: lastStates)
    }

    public func reset() {
        defaults.removeObject(forKey: Self.storageKey)
        windows = []
        lastStates = []
        loadIssue = nil
    }

    private static func upsertWindow(
        _ record: ClusterWindowRestorationRecord,
        in windows: inout [ClusterWindowRestorationRecord],
        movesToEnd: Bool = false
    ) throws {
        if let index = windows.firstIndex(where: { $0.id == record.id }) {
            if movesToEnd {
                windows.remove(at: index)
                windows.append(record)
            } else {
                windows[index] = record
            }
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
        lastStates: [ClusterWindowRestorationState]
    ) throws {
        let document = Document(
            apiVersion: Self.apiVersion,
            windows: windows,
            lastStates: lastStates
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(try encoder.encode(document), forKey: Self.storageKey)
        self.windows = windows
        self.lastStates = lastStates
        loadIssue = nil
    }

    private func loadFromDefaults() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(DocumentHeader.self, from: data) else {
            resetAsInvalid(
                reason: .invalidData,
                message: "Saved workspaces could not be decoded and were reset."
            )
            return
        }
        guard header.apiVersion == Self.apiVersion else {
            resetAsInvalid(
                reason: .unsupportedVersion,
                message: "Saved workspaces use unsupported version \(header.apiVersion) and were reset."
            )
            return
        }
        guard let document = try? decoder.decode(Document.self, from: data) else {
            resetAsInvalid(
                reason: .invalidData,
                message: "Saved workspaces could not be decoded and were reset."
            )
            return
        }
        load(document.windows, lastStates: document.lastStates)
    }

    private func load(
        _ savedWindows: [ClusterWindowRestorationRecord],
        lastStates savedStates: [ClusterWindowRestorationState]
    ) {
        do {
            windows = try validatedWindows(savedWindows)
            lastStates = try validatedStates(savedStates)
        } catch {
            resetAsInvalid(
                reason: .invalidValues,
                message: "Saved workspaces contain invalid values and were reset."
            )
        }
    }

    private func validatedWindows(
        _ savedWindows: [ClusterWindowRestorationRecord]
    ) throws -> [ClusterWindowRestorationRecord] {
        guard savedWindows.count <= Self.maximumOpenWindows,
            Set(savedWindows.map(\.id)).count == savedWindows.count
        else {
            throw RestorationValidationError(issues: [.init(
                path: "windows",
                message: "Saved workspaces exceed a limit or contain duplicate identities."
            )])
        }
        return try savedWindows.map { try $0.validated() }
    }

    private func validatedStates(
        _ savedStates: [ClusterWindowRestorationState]
    ) throws -> [ClusterWindowRestorationState] {
        guard savedStates.count <= Self.maximumContextStates,
            Set(savedStates.map(\.contextReference)).count == savedStates.count
        else {
            throw RestorationValidationError(issues: [.init(
                path: "lastStates",
                message: "Saved context states exceed a limit or contain duplicates."
            )])
        }
        return try savedStates.map { try $0.validated() }
    }

    private func resetAsInvalid(
        reason: WorkspaceRestorationLoadIssue.Reason,
        message: String
    ) {
        defaults.removeObject(forKey: Self.storageKey)
        windows = []
        lastStates = []
        loadIssue = WorkspaceRestorationLoadIssue(reason: reason, message: message)
    }
}
