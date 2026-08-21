import Foundation

/// The last full-frame size used by any cluster workspace window. Position is
/// deliberately absent: restored windows retain their independent AppKit
/// frames, while newly created windows share only this global size.
public struct ClusterWorkspaceWindowSize: Codable, Hashable, Sendable {
    public static let maximumDimension = 65_536.0

    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        width.isFinite && height.isFinite
            && width > 0 && width <= Self.maximumDimension
            && height > 0 && height <= Self.maximumDimension
    }
}

/// A process-wide instance gives Command-N windows the latest size immediately;
/// the compact UserDefaults value carries it across application launches.
@MainActor
public final class ClusterWorkspaceWindowSizeStore {
    public static let storageKey = "kmgr.cluster-workspace.last-window-size"

    private let defaults: UserDefaults
    public private(set) var lastSize: ClusterWorkspaceWindowSize?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    @discardableResult
    public func save(_ size: ClusterWorkspaceWindowSize) -> Bool {
        guard size.isValid else { return false }
        guard lastSize != size else { return true }
        guard let data = try? JSONEncoder().encode(size) else { return false }
        defaults.set(data, forKey: Self.storageKey)
        lastSize = size
        return true
    }

    public func reset() {
        defaults.removeObject(forKey: Self.storageKey)
        lastSize = nil
    }

    private func load() {
        guard defaults.object(forKey: Self.storageKey) != nil else { return }
        guard let data = defaults.data(forKey: Self.storageKey),
            let size = try? JSONDecoder().decode(ClusterWorkspaceWindowSize.self, from: data),
            size.isValid
        else {
            // Configuration is intentionally strict: malformed or obsolete
            // values reset instead of growing compatibility machinery.
            reset()
            return
        }
        lastSize = size
    }
}
