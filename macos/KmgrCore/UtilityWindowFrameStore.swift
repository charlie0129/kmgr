import Foundation

/// Stable identities for independent utility windows. The identity describes
/// the kind of surface, rather than the resource or cluster shown in it, so
/// the store keeps one bounded last frame for each kind.
public enum UtilityWindowKind: String, CaseIterable, Codable, Hashable, Sendable {
    case settings
    case details
    case yaml
    case portForwards = "port-forwards"
    case operationHistory = "operation-history"
    case logs
    case engineDiagnostics = "engine-diagnostics"
    case terminal
}

public struct UtilityWindowFrameStoreLoadIssue: Error, LocalizedError, Hashable, Sendable {
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

/// One process-wide, strict, coalescing store for utility-window geometry.
/// Content, sessions, and visibility are intentionally absent: reopening the
/// application restores only the last frame when a utility is next shown.
@MainActor
public final class UtilityWindowFrameStore {
    public static let apiVersion = "kmgr.utility-window-frames/v1"
    public static let storageKey = "kmgr.utility-window-frames.document"
    public static let maximumFrames = UtilityWindowKind.allCases.count
    public static let maximumDocumentBytes = 64 << 10
    public static let defaultPersistenceDelay: Duration = .milliseconds(250)

    private struct Document: Codable {
        var apiVersion: String
        var frames: [String: WorkspaceWindowFrame]
    }

    private let defaults: UserDefaults
    private let persistenceDelay: Duration
    private var pendingSaveTask: Task<Void, Never>?
    private var persistenceGeneration: UInt64 = 0
    private var dirty = false

    public private(set) var frames: [UtilityWindowKind: WorkspaceWindowFrame] = [:]
    public private(set) var loadIssue: UtilityWindowFrameStoreLoadIssue?

    /// Kept internal so the debounce contract can be tested without observing
    /// UserDefaults notifications or depending on a wall-clock race.
    private(set) var successfulPersistenceCount = 0

    public init(
        defaults: UserDefaults = .standard,
        persistenceDelay: Duration = UtilityWindowFrameStore.defaultPersistenceDelay
    ) {
        self.defaults = defaults
        self.persistenceDelay = persistenceDelay
        loadFromDefaults()
    }

    deinit {
        pendingSaveTask?.cancel()
    }

    public func frame(for kind: UtilityWindowKind) -> WorkspaceWindowFrame? {
        frames[kind]
    }

    /// Updates memory immediately and coalesces the durable write. Invalid
    /// geometry is rejected before it can enter either representation.
    @discardableResult
    public func set(_ frame: WorkspaceWindowFrame, for kind: UtilityWindowKind) -> Bool {
        guard frame.isValid else { return false }
        guard frames[kind] != frame else { return true }
        frames[kind] = frame
        loadIssue = nil
        dirty = true
        schedulePersistence()
        return true
    }

    @discardableResult
    public func removeFrame(for kind: UtilityWindowKind) -> Bool {
        guard frames.removeValue(forKey: kind) != nil else { return false }
        loadIssue = nil
        dirty = true
        schedulePersistence()
        return true
    }

    /// Flushes the one pending coalesced document. Application termination
    /// calls this before asynchronous engine shutdown can end the process.
    @discardableResult
    public func flushPendingSave() -> Bool {
        persistenceGeneration &+= 1
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        return persistIfNeeded()
    }

    /// Waits for the currently scheduled save, if any. This is primarily
    /// useful for deterministic store tests and lifecycle callers.
    internal func waitForPendingSave() async {
        while let task = pendingSaveTask {
            await task.value
        }
    }

    public func reset() {
        persistenceGeneration &+= 1
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        defaults.removeObject(forKey: Self.storageKey)
        frames = [:]
        dirty = false
        loadIssue = nil
    }

    public static func isValid(_ frame: WorkspaceWindowFrame) -> Bool {
        frame.isValid
    }

    private func schedulePersistence() {
        persistenceGeneration &+= 1
        let generation = persistenceGeneration
        pendingSaveTask?.cancel()
        let delay = persistenceDelay
        pendingSaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                guard let self, self.persistenceGeneration == generation else {
                    return
                }
                self.pendingSaveTask = nil
                return
            }
            guard let self,
                self.persistenceGeneration == generation,
                !Task.isCancelled
            else { return }
            pendingSaveTask = nil
            _ = persistIfNeeded()
        }
    }

    private func persistIfNeeded() -> Bool {
        guard dirty else { return true }
        let encodedFrames = Dictionary(uniqueKeysWithValues: frames.map {
            ($0.key.rawValue, $0.value)
        })
        let document = Document(
            apiVersion: Self.apiVersion,
            frames: encodedFrames
        )
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

    private func loadFromDefaults() {
        guard defaults.object(forKey: Self.storageKey) != nil else { return }
        guard let data = defaults.data(forKey: Self.storageKey),
            data.count <= Self.maximumDocumentBytes
        else {
            resetInvalidDocument(
                reason: .invalidData,
                message: "Saved utility-window frames could not be decoded; default frames are in use."
            )
            return
        }

        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            resetInvalidDocument(
                reason: .invalidData,
                message: "Saved utility-window frames could not be decoded; default frames are in use."
            )
            return
        }
        guard Self.hasExactDocumentShape(data) else {
            resetInvalidDocument(
                reason: .invalidValues,
                message: "Saved utility-window frames contain invalid values; default frames are in use."
            )
            return
        }
        guard document.apiVersion == Self.apiVersion else {
            resetInvalidDocument(
                reason: .unsupportedVersion,
                message: "Saved utility-window frames use an unsupported version; default frames are in use."
            )
            return
        }
        guard document.frames.count <= Self.maximumFrames else {
            resetInvalidDocument(
                reason: .invalidValues,
                message: "Saved utility-window frames exceed the supported limit; default frames are in use."
            )
            return
        }

        var decoded: [UtilityWindowKind: WorkspaceWindowFrame] = [:]
        decoded.reserveCapacity(document.frames.count)
        for (rawKind, frame) in document.frames {
            guard let kind = UtilityWindowKind(rawValue: rawKind),
                Self.isValid(frame), decoded[kind] == nil
            else {
                resetInvalidDocument(
                    reason: .invalidValues,
                    message: "Saved utility-window frames contain invalid values; default frames are in use."
                )
                return
            }
            decoded[kind] = frame
        }
        frames = decoded
    }

    private static func hasExactDocumentShape(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            Set(root.keys) == ["apiVersion", "frames"],
            let frames = root["frames"] as? [String: Any]
        else { return false }
        for value in frames.values {
            guard let frame = value as? [String: Any],
                Set(frame.keys) == ["height", "width", "x", "y"]
            else { return false }
        }
        return true
    }

    private func resetInvalidDocument(
        reason: UtilityWindowFrameStoreLoadIssue.Reason,
        message: String
    ) {
        defaults.removeObject(forKey: Self.storageKey)
        frames = [:]
        dirty = false
        loadIssue = UtilityWindowFrameStoreLoadIssue(reason: reason, message: message)
    }
}
