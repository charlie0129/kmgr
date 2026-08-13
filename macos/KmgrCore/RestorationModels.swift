import Foundation

public struct GVR: Hashable, Codable, Sendable {
    public var group: String
    public var version: String
    public var resource: String

    public init(group: String, version: String, resource: String) {
        self.group = group
        self.version = version
        self.resource = resource
    }
}

public enum NamespaceScope: Hashable, Codable, Sendable {
    case all
    case namespace(String)
    case namespaces([String])
}

public struct SortDescriptorState: Hashable, Codable, Sendable {
    public var columnID: String
    public var ascending: Bool

    public init(columnID: String, ascending: Bool) {
        self.columnID = columnID
        self.ascending = ascending
    }
}

public struct ColumnPresentationState: Hashable, Codable, Sendable {
    public var columnID: String
    public var width: Double
    public var isVisible: Bool

    public init(columnID: String, width: Double, isVisible: Bool = true) {
        self.columnID = columnID
        self.width = width
        self.isVisible = isVisible
    }
}

/// Explicit allow-list of lightweight state safe for UserDefaults/window
/// restoration. It has no arbitrary payload field, which makes Secret values,
/// cached rows, terminal contents, logs, credentials, and mutation forms
/// unrepresentable in the persisted model.
public struct ClusterWindowRestorationState: Hashable, Codable, Sendable {
    public static let schemaVersion = 1

    public var version: Int
    public var contextName: String
    public var gvr: GVR?
    public var namespaceScope: NamespaceScope
    public var filter: String
    public var sort: [SortDescriptorState]
    public var columns: [ColumnPresentationState]
    public var isSidebarVisible: Bool
    public var scrollAnchor: ScrollAnchor?

    public init(
        contextName: String,
        gvr: GVR? = nil,
        namespaceScope: NamespaceScope = .all,
        filter: String = "",
        sort: [SortDescriptorState] = [],
        columns: [ColumnPresentationState] = [],
        isSidebarVisible: Bool = true,
        scrollAnchor: ScrollAnchor? = nil
    ) {
        self.version = Self.schemaVersion
        self.contextName = contextName
        self.gvr = gvr
        self.namespaceScope = namespaceScope
        self.filter = filter
        self.sort = sort
        self.columns = columns
        self.isSidebarVisible = isSidebarVisible
        self.scrollAnchor = scrollAnchor
    }
}

/// Secret bytes live only in this transient reference type. It is intentionally
/// neither Codable nor CustomStringConvertible and cannot be placed in a
/// restoration or diagnostic model.
public final class SensitiveBytes: @unchecked Sendable {
    private var storage: Data

    public init(_ data: Data) {
        self.storage = data
    }

    public var count: Int { storage.count }

    public func withUnsafeBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        try storage.withUnsafeBytes(body)
    }

    public func replacing(with newData: Data) {
        storage.resetBytes(in: storage.startIndex..<storage.endIndex)
        storage = newData
    }

    deinit {
        storage.resetBytes(in: storage.startIndex..<storage.endIndex)
    }
}

/// Diagnostic metadata for a key/value editor. Values are never representable.
public struct KeyValueEditorDiagnostic: Hashable, Codable, Sendable {
    public enum ResourceKind: String, Hashable, Codable, Sendable {
        case configMap
        case secret
    }

    public var resourceKind: ResourceKind
    public var namespace: String
    public var name: String
    public var key: String?
    public var byteCount: Int?
    public var hasUnsavedChanges: Bool

    public init(
        resourceKind: ResourceKind,
        namespace: String,
        name: String,
        key: String? = nil,
        byteCount: Int? = nil,
        hasUnsavedChanges: Bool = false
    ) {
        self.resourceKind = resourceKind
        self.namespace = namespace
        self.name = name
        self.key = key
        self.byteCount = byteCount
        self.hasUnsavedChanges = hasUnsavedChanges
    }
}

public enum CommandID: String, Hashable, Codable, Sendable {
    case openDetails
    case openYAML
    case openEvents
    case openLogs
    case openExec
    case startPortForward
    case delete
    case selectAll
    case focusFilter
    case save
}

public enum ResponderContext: String, Hashable, Codable, Sendable {
    case resourceTable
    case filterField
    case yamlEditor
    case keyValueEditor
    case terminal
    case other

    public var isEditingText: Bool {
        switch self {
        case .filterField, .yamlEditor, .keyValueEditor, .terminal:
            true
        case .resourceTable, .other:
            false
        }
    }
}

public struct CommandContext: Hashable, Sendable {
    public var firstResponder: ResponderContext
    public var selectedIdentities: [ResourceIdentity]
    public var logCompatibleSelection: Bool
    public var execCompatibleSelection: Bool
    public var portForwardCompatibleSelection: Bool
    public var activeEditorHasChanges: Bool

    public init(
        firstResponder: ResponderContext,
        selectedIdentities: [ResourceIdentity] = [],
        logCompatibleSelection: Bool = false,
        execCompatibleSelection: Bool = false,
        portForwardCompatibleSelection: Bool = false,
        activeEditorHasChanges: Bool = false
    ) {
        self.firstResponder = firstResponder
        self.selectedIdentities = selectedIdentities
        self.logCompatibleSelection = logCompatibleSelection
        self.execCompatibleSelection = execCompatibleSelection
        self.portForwardCompatibleSelection = portForwardCompatibleSelection
        self.activeEditorHasChanges = activeEditorHasChanges
    }
}

public enum CommandValidator {
    /// Pure validation used by menu validation and the command palette. Native
    /// responder routing remains authoritative; table-only shortcuts are not
    /// considered valid while an editor, filter, or terminal owns focus.
    public static func isEnabled(_ command: CommandID, in context: CommandContext) -> Bool {
        let count = context.selectedIdentities.count
        switch command {
        case .openDetails, .openYAML, .openEvents:
            return context.firstResponder == .resourceTable && count == 1
        case .openLogs:
            return context.firstResponder == .resourceTable && count > 0 && context.logCompatibleSelection
        case .openExec:
            return context.firstResponder == .resourceTable && count == 1 && context.execCompatibleSelection
        case .startPortForward:
            return context.firstResponder == .resourceTable && count == 1 && context.portForwardCompatibleSelection
        case .delete:
            return context.firstResponder == .resourceTable && count > 0
        case .selectAll, .focusFilter:
            return context.firstResponder == .resourceTable
        case .save:
            return (context.firstResponder == .yamlEditor || context.firstResponder == .keyValueEditor)
                && context.activeEditorHasChanges
        }
    }
}
