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
    public var canRestart: Bool
    public var canDelete: Bool

    public init(
        canEnterSubresource: Bool = false,
        canOpenDetails: Bool = false,
        canOpenYAML: Bool = false,
        canOpenEvents: Bool = false,
        canOpenLogs: Bool = false,
        canOpenTerminal: Bool = false,
        canStartPortForward: Bool = false,
        canRestart: Bool = false,
        canDelete: Bool = false
    ) {
        self.canEnterSubresource = canEnterSubresource
        self.canOpenDetails = canOpenDetails
        self.canOpenYAML = canOpenYAML
        self.canOpenEvents = canOpenEvents
        self.canOpenLogs = canOpenLogs
        self.canOpenTerminal = canOpenTerminal
        self.canStartPortForward = canStartPortForward
        self.canRestart = canRestart
        self.canDelete = canDelete
    }
}

/// The bounded product catalog for the passive shortcuts window. Callers pass
/// current command facts; the catalog owns stable wording and ordering.
public enum ContextualShortcutCatalog {
    public static func clusterChooser(canOpenSelection: Bool) -> ContextualShortcutSnapshot {
        var items: [ContextualShortcutItem] = []
        items.append(item("chooser.search", "/", "Search kubeconfig contexts"))
        if canOpenSelection {
            items.append(item("chooser.open", "Return", "Open selected context"))
        }
        items.append(item("chooser.move", "\u{2191} / \u{2193}", "Move context selection"))
        items.append(item("chooser.add-kubeconfig", "\u{2318}O", "Add kubeconfig files"))
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
            items.append(item("resource.details", "D", "Describe selected object"))
        }
        if availability.canOpenYAML {
            items.append(item(
                "resource.yaml",
                "Y",
                "Open selected object YAML in Details"
            ))
            items.append(item(
                "resource.yaml.window",
                "\u{21E7}Y",
                "Open selected object YAML in a new window"
            ))
        }
        if availability.canOpenEvents {
            items.append(item("resource.events", "E", "Open selected object events"))
        }
        if availability.canOpenLogs {
            items.append(item("resource.logs", "L", "Open logs"))
            items.append(item(
                "resource.logs.previous",
                "\u{21E7}L",
                "Open previous container logs"
            ))
        }
        if availability.canOpenTerminal {
            items.append(item("resource.terminal", "S", "Open Pod terminal"))
            items.append(item(
                "resource.terminal.configure",
                "\u{21E7}S",
                "Configure Pod terminal"
            ))
        }
        if availability.canStartPortForward {
            items.append(item("resource.port-forward", "P", "Start port-forward"))
        }
        if availability.canRestart {
            items.append(item("resource.restart", "R", "Rollout restart"))
        }
        if availability.canDelete {
            items.append(item("resource.delete", "\u{2318}\u{232B}", "Delete selection"))
        }
        items.append(namespaceItem)
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
            namespaceItem,
        ]
    )

    public static func containerList(
        canOpenLogs: Bool,
        canOpenTerminal: Bool,
        canStartPortForward: Bool
    ) -> ContextualShortcutSnapshot {
        var items: [ContextualShortcutItem] = []
        if canOpenLogs {
            items.append(item(
                "container.logs",
                "L / Return",
                "Open selected container logs"
            ))
            items.append(item(
                "container.logs.previous",
                "\u{21E7}L",
                "Open previous logs for selected container"
            ))
        }
        if canOpenTerminal {
            items.append(item("container.terminal", "S", "Open selected container terminal"))
            items.append(item(
                "container.terminal.configure",
                "\u{21E7}S",
                "Configure selected container terminal"
            ))
        }
        if canStartPortForward {
            items.append(item(
                "container.port-forward",
                "P",
                "Start parent Pod port-forward"
            ))
        }
        items.append(namespaceItem)
        items.append(item("subresource.back", "Escape", "Back to resource list"))
        return ContextualShortcutSnapshot(
            contextID: "pod-containers",
            title: "Pod Containers",
            items: items
        )
    }

    public static func dataEditor(secret: Bool) -> ContextualShortcutSnapshot {
        var items: [ContextualShortcutItem] = [
            item("data.search", "/ or ⌘F", "Search keys and values"),
            item("data.edit-value", "Return", "Edit selected value"),
        ]
        if secret {
            items.append(item("data.reveal", "D", "Toggle decoded Secret values"))
        }
        items.append(item("data.save", "\u{2318}S", "Review and save staged changes"))
        items.append(namespaceItem)
        items.append(item("subresource.back", "Escape", "Back to resource list"))
        return ContextualShortcutSnapshot(
            contextID: "object-data",
            title: "Object Data",
            items: items
        )
    }

    public static func metadataEditor(
        kind: ResourceMetadataKind
    ) -> ContextualShortcutSnapshot {
        ContextualShortcutSnapshot(
            contextID: "resource-metadata-\(kind.rawValue)",
            title: "Edit \(kind.title)",
            items: [
                item("metadata.search", "/ or ⌘F", "Search keys and values"),
                item("metadata.edit-value", "Return", "Edit selected value"),
                item("metadata.save", "⌘S", "Review and save staged changes"),
                item("metadata.cancel", "Escape", "Cancel editing"),
            ]
        )
    }

    public static let logs = ContextualShortcutSnapshot(
        contextID: "logs",
        title: "Logs",
        items: [
            item("logs.filter", "/", "Focus visible-log filter"),
            item("logs.follow", "F", "Toggle following"),
            item("logs.pause", "P", "Pause or resume display"),
            item("logs.wrap", "W", "Toggle line wrapping"),
            item("window.close", "\u{2318}W", "Close window"),
        ]
    )

    public static func objectDetails(
        canEditSelectedMetadata: Bool,
        canOpenEvents: Bool
    ) -> ContextualShortcutSnapshot {
        var items: [ContextualShortcutItem] = []
        if canEditSelectedMetadata {
            items.append(item(
                "details.edit-metadata",
                "Return",
                "Edit the selected label or annotation"
            ))
        }
        if canOpenEvents {
            items.append(item(
                "details.events",
                "E",
                "Open complete Events list for this object"
            ))
        }
        items.append(namespaceItem)
        items.append(contentsOf: [
            item("workspace.history", "\u{2318}[ / \u{2318}]", "Back / Forward"),
            item("workspace.palette", "\u{2318}K", "Open Command Palette"),
            item("window.close", "\u{2318}W", "Close window"),
        ])
        return ContextualShortcutSnapshot(
            contextID: "object-details",
            title: "Object Details",
            items: items
        )
    }

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

    private static let namespaceItem = item(
        "workspace.namespace",
        "\u{21E7}\u{2318}N",
        "Choose workspace namespace"
    )
}
