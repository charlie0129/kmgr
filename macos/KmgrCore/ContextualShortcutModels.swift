import Foundation

/// One keyboard binding that is useful in the currently active UI context.
/// The model deliberately contains no AppKit types so command availability can
/// be derived and tested without constructing windows.
public struct ContextualShortcutItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var keys: String
    public var action: String

    public init(id: String, keys: String, action: String) {
        self.id = id
        self.keys = keys
        self.action = action
    }
}

/// A complete, immutable description of the shortcut help for one active
/// context. An empty item list means there is no useful help to present.
public struct ContextualShortcutSnapshot: Hashable, Sendable {
    public var contextID: String
    public var title: String
    public var items: [ContextualShortcutItem]

    public init(
        contextID: String,
        title: String,
        items: [ContextualShortcutItem]
    ) {
        self.contextID = contextID
        self.title = title
        self.items = items
    }
}

/// Command facts supplied by the resource table's authoritative compatibility
/// checks. This keeps the help catalog independent of Kubernetes identities and
/// prevents it from growing a second, subtly different command validator.
public struct ResourceListShortcutAvailability: Hashable, Sendable {
    public var canEnterSubresource: Bool
    public var canOpenDetails: Bool
    public var canOpenYAML: Bool
    public var canOpenEvents: Bool
    public var canOpenLogs: Bool
    public var canOpenTerminal: Bool
    public var canStartPortForward: Bool
    public var canDelete: Bool

    public init(
        canEnterSubresource: Bool = false,
        canOpenDetails: Bool = false,
        canOpenYAML: Bool = false,
        canOpenEvents: Bool = false,
        canOpenLogs: Bool = false,
        canOpenTerminal: Bool = false,
        canStartPortForward: Bool = false,
        canDelete: Bool = false
    ) {
        self.canEnterSubresource = canEnterSubresource
        self.canOpenDetails = canOpenDetails
        self.canOpenYAML = canOpenYAML
        self.canOpenEvents = canOpenEvents
        self.canOpenLogs = canOpenLogs
        self.canOpenTerminal = canOpenTerminal
        self.canStartPortForward = canStartPortForward
        self.canDelete = canDelete
    }
}

/// The bounded product catalog for the passive shortcuts window. Callers pass
/// current command facts; the catalog owns stable wording and ordering.
public enum ContextualShortcutCatalog {
    public static func clusterChooser(canOpenSelection: Bool) -> ContextualShortcutSnapshot {
        var items: [ContextualShortcutItem] = []
        if canOpenSelection {
            items.append(item("chooser.open", "Return", "Open selected context"))
        }
        items.append(item("chooser.move", "\u{2191} / \u{2193}", "Move context selection"))
        items.append(item("app.new-cluster", "\u{2318}N", "New Cluster Manager window"))
        items.append(item("window.close", "\u{2318}W", "Close window"))
        return ContextualShortcutSnapshot(
            contextID: "cluster-chooser",
            title: "Cluster Manager",
            items: items
        )
    }

    public static func resourceList(
        title: String,
        availability: ResourceListShortcutAvailability
    ) -> ContextualShortcutSnapshot {
        var items = [
            item("resource.filter", "/", "Filter this resource list"),
            item("resource.move", "J / K", "Move selection"),
            item("resource.extend", "\u{21E7}\u{2191} / \u{21E7}\u{2193}", "Extend selection"),
        ]
        if availability.canEnterSubresource {
            items.append(item("resource.enter", "Return", "Enter selected subresource"))
        }
        if availability.canOpenDetails {
            items.append(item("resource.details", "\u{2318}Return", "Open selected object details"))
        }
        if availability.canOpenYAML {
            items.append(item("resource.yaml", "Y", "Open selected object YAML"))
        }
        if availability.canOpenEvents {
            items.append(item("resource.events", "E", "Open selected object events"))
        }
        if availability.canOpenLogs {
            items.append(item("resource.logs", "L", "Open logs"))
        }
        if availability.canOpenTerminal {
            items.append(item("resource.terminal", "S", "Open Pod terminal"))
        }
        if availability.canStartPortForward {
            items.append(item("resource.port-forward", "P", "Start port-forward"))
        }
        if availability.canDelete {
            items.append(item("resource.delete", "\u{2318}\u{232B}", "Delete selection"))
        }
        items.append(item("workspace.history", "\u{2318}[ / \u{2318}]", "Back / Forward"))
        items.append(item("workspace.palette", "\u{2318}K", "Open Command Palette"))

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return ContextualShortcutSnapshot(
            contextID: "resource-list",
            title: normalizedTitle.isEmpty ? "Resources" : normalizedTitle,
            items: items
        )
    }

    public static let resourceFilter = ContextualShortcutSnapshot(
        contextID: "resource-filter",
        title: "Resource Filter",
        items: [
            item("filter.apply", "Return", "Apply filter and return to the list"),
            item("filter.cancel", "Escape", "Clear filter or return to the list"),
        ]
    )

    public static func containerList(canOpenLogs: Bool) -> ContextualShortcutSnapshot {
        var items: [ContextualShortcutItem] = []
        if canOpenLogs {
            items.append(item(
                "container.logs",
                "L / Return",
                "Open selected container logs"
            ))
        }
        items.append(item("subresource.back", "Escape", "Back to resource list"))
        return ContextualShortcutSnapshot(
            contextID: "pod-containers",
            title: "Pod Containers",
            items: items
        )
    }

    public static func dataList(canOpenEditor: Bool) -> ContextualShortcutSnapshot {
        var items: [ContextualShortcutItem] = []
        if canOpenEditor {
            items.append(item("data.open", "Return", "Open Data editor"))
        }
        items.append(item("subresource.back", "Escape", "Back to resource list"))
        return ContextualShortcutSnapshot(
            contextID: "object-data",
            title: "Object Data",
            items: items
        )
    }

    public static let objectDetails = ContextualShortcutSnapshot(
        contextID: "object-details",
        title: "Object Details",
        items: [
            item("workspace.history", "\u{2318}[ / \u{2318}]", "Back / Forward"),
            item("workspace.palette", "\u{2318}K", "Open Command Palette"),
            item("window.close", "\u{2318}W", "Close window"),
        ]
    )

    /// Safe fallback for a sheet or child window that has not opted into
    /// contextual help. It intentionally contains no resource-table letters.
    public static let genericDialog = ContextualShortcutSnapshot(
        contextID: "generic-dialog",
        title: "Dialog",
        items: [
            item("window.close", "\u{2318}W", "Close window or dialog"),
            item("app.quit", "\u{2318}Q", "Quit Kmgr"),
        ]
    )

    private static func item(
        _ id: String,
        _ keys: String,
        _ action: String
    ) -> ContextualShortcutItem {
        ContextualShortcutItem(id: id, keys: keys, action: action)
    }
}
