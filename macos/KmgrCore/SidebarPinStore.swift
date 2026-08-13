import Foundation

public struct SidebarPinStoreLoadIssue: Error, LocalizedError, Hashable, Sendable {
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

/// Ordered, application-wide sidebar pins. Only GVR components are persisted;
/// presentation names always come from the active cluster's discovery result.
@MainActor
public final class SidebarPinStore {
    public static let apiVersion = "kmgr.sidebar-pins/v1"
    public static let storageKey = "kmgr.sidebar-pins.document"
    public static let maximumPins = 512
    public static let shared = SidebarPinStore()

    private struct Document: Codable {
        var apiVersion: String
        var pins: [SidebarPin]
    }

    private let defaults: UserDefaults
    private var observers: [UUID: @MainActor ([SidebarPin]) -> Void] = [:]

    public private(set) var pins: [SidebarPin]
    public private(set) var loadIssue: SidebarPinStoreLoadIssue?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pins = DefaultSidebarPins.values
        loadFromDefaults()
    }

    public func contains(id: String) -> Bool {
        pins.contains { $0.id == id }
    }

    /// Newly pinned resources are appended, making the user's ordering
    /// deterministic without depending on discovery or display-name order.
    @discardableResult
    public func pin(_ pin: SidebarPin) -> Bool {
        guard Self.isValid(pin), !contains(id: pin.id), pins.count < Self.maximumPins else {
            return false
        }
        var updated = pins
        updated.append(pin)
        return persist(updated)
    }

    @discardableResult
    public func unpin(id: String) -> Bool {
        guard contains(id: id) else { return false }
        return persist(pins.filter { $0.id != id })
    }

    /// Moves one pin immediately before another pin. Passing `nil` moves it to
    /// the end. Referencing IDs rather than row indexes keeps reordering correct
    /// when a cluster does not discover every globally pinned GVR.
    @discardableResult
    public func move(pinID: String, beforePinID targetID: String?) -> Bool {
        guard let sourceIndex = pins.firstIndex(where: { $0.id == pinID }) else { return false }
        guard targetID != pinID else { return false }

        var updated = pins
        let pin = updated.remove(at: sourceIndex)
        if let targetID, let targetIndex = updated.firstIndex(where: { $0.id == targetID }) {
            updated.insert(pin, at: targetIndex)
        } else {
            updated.append(pin)
        }
        guard updated != pins else { return false }
        return persist(updated)
    }

    /// Observers are notified immediately and after each successful mutation.
    /// A shared store lets all open cluster windows stay in sync.
    @discardableResult
    public func observe(_ observer: @escaping @MainActor ([SidebarPin]) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        observer(pins)
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    public func reset() {
        defaults.removeObject(forKey: Self.storageKey)
        pins = DefaultSidebarPins.values
        loadIssue = nil
        notifyObservers()
    }

    private func persist(_ updated: [SidebarPin]) -> Bool {
        let document = Document(apiVersion: Self.apiVersion, pins: updated)
        guard let data = try? JSONEncoder().encode(document) else { return false }
        defaults.set(data, forKey: Self.storageKey)
        pins = updated
        loadIssue = nil
        notifyObservers()
        return true
    }

    private func notifyObservers() {
        for observer in observers.values { observer(pins) }
    }

    private func loadFromDefaults() {
        guard defaults.object(forKey: Self.storageKey) != nil else { return }
        guard let data = defaults.data(forKey: Self.storageKey) else {
            loadIssue = .init(
                reason: .invalidData,
                message: "Saved sidebar pins could not be decoded; the built-in pins are in use."
            )
            return
        }

        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            loadIssue = .init(
                reason: .invalidData,
                message: "Saved sidebar pins could not be decoded; the built-in pins are in use."
            )
            return
        }
        guard document.apiVersion == Self.apiVersion else {
            loadIssue = .init(
                reason: .unsupportedVersion,
                message: "Saved sidebar pins use an unsupported version; the built-in pins are in use."
            )
            return
        }

        let ids = document.pins.map(\.id)
        guard document.pins.count <= Self.maximumPins,
            Set(ids).count == ids.count,
            document.pins.allSatisfy(Self.isValid)
        else {
            loadIssue = .init(
                reason: .invalidValues,
                message: "Saved sidebar pins are invalid; the built-in pins are in use."
            )
            return
        }
        // An empty persisted array is intentional: a user may unpin every
        // built-in resource and that choice must survive relaunch.
        pins = document.pins
    }

    private static func isValid(_ pin: SidebarPin) -> Bool {
        pin.group.utf8.count <= 253 &&
            !pin.version.isEmpty && pin.version.utf8.count <= 63 &&
            !pin.resource.isEmpty && pin.resource.utf8.count <= 253 &&
            !pin.group.contains("/") && !pin.version.contains("/") && !pin.resource.contains("/")
    }
}
