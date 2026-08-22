import Foundation

public struct KubeconfigSourceStoreLoadIssue: Error, LocalizedError, Hashable, Sendable {
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

/// Ordered, application-wide paths explicitly added in Cluster Manager. Only
/// standardized absolute paths are persisted; kubeconfig contents and
/// credentials remain in their original files.
@MainActor
public final class KubeconfigSourceStore {
    public static let apiVersion = "kmgr.kubeconfig-sources/v1"
    public static let storageKey = "kmgr.kubeconfig-sources.document"
    public static let maximumSources = 256
    public static let shared = KubeconfigSourceStore()

    private struct Document: Codable {
        var apiVersion: String
        var paths: [String]
    }

    private let defaults: UserDefaults
    private var observers: [UUID: @MainActor ([String]) -> Void] = [:]

    public private(set) var paths: [String] = []
    public private(set) var loadIssue: KubeconfigSourceStoreLoadIssue?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadFromDefaults()
    }

    @discardableResult
    public func add(paths candidates: [String]) -> Bool {
        guard !candidates.isEmpty else { return false }
        var updated = paths
        var seen = Set(updated)
        for candidate in candidates {
            guard let path = Self.normalizedFilePath(candidate) else { return false }
            if seen.insert(path).inserted {
                updated.append(path)
            }
        }
        guard updated != paths, updated.count <= Self.maximumSources else { return false }
        return persist(updated)
    }

    @discardableResult
    public func remove(paths candidates: [String]) -> Bool {
        let removed = Set(candidates.compactMap(Self.normalizedFilePath))
        guard !removed.isEmpty else { return false }
        let updated = paths.filter { !removed.contains($0) }
        guard updated != paths else { return false }
        return persist(updated)
    }

    @discardableResult
    public func observe(_ observer: @escaping @MainActor ([String]) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        observer(paths)
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    public func reset() {
        defaults.removeObject(forKey: Self.storageKey)
        paths = []
        loadIssue = nil
        notifyObservers()
    }

    public static func normalizedFilePath(_ path: String) -> String? {
        guard !path.isEmpty,
            path.utf8.count <= 4_096,
            (path as NSString).isAbsolutePath
        else { return nil }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !normalized.isEmpty, normalized.utf8.count <= 4_096 else { return nil }
        return normalized
    }

    private func persist(_ updated: [String]) -> Bool {
        let document = Document(apiVersion: Self.apiVersion, paths: updated)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(document) else { return false }
        defaults.set(data, forKey: Self.storageKey)
        paths = updated
        loadIssue = nil
        notifyObservers()
        return true
    }

    private func notifyObservers() {
        for observer in observers.values { observer(paths) }
    }

    private func loadFromDefaults() {
        guard defaults.object(forKey: Self.storageKey) != nil else { return }
        guard let data = defaults.data(forKey: Self.storageKey) else {
            rejectSavedPaths(reason: .invalidData)
            return
        }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            rejectSavedPaths(reason: .invalidData)
            return
        }
        guard document.apiVersion == Self.apiVersion else {
            rejectSavedPaths(reason: .unsupportedVersion)
            return
        }
        let normalized = document.paths.compactMap(Self.normalizedFilePath)
        guard document.paths.count <= Self.maximumSources,
            normalized == document.paths,
            Set(document.paths).count == document.paths.count
        else {
            rejectSavedPaths(reason: .invalidValues)
            return
        }
        paths = document.paths
    }

    private func rejectSavedPaths(reason: KubeconfigSourceStoreLoadIssue.Reason) {
        defaults.removeObject(forKey: Self.storageKey)
        paths = []
        let detail: String
        switch reason {
        case .unsupportedVersion:
            detail = "use an unsupported version"
        case .invalidData:
            detail = "could not be decoded"
        case .invalidValues:
            detail = "contain invalid paths"
        }
        loadIssue = KubeconfigSourceStoreLoadIssue(
            reason: reason,
            message: "Saved kubeconfig files \(detail); no custom files were loaded."
        )
    }
}
