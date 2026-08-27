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

public struct RestorationValidationIssue: Error, Hashable, Sendable {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public struct RestorationValidationError: Error, LocalizedError, Hashable, Sendable {
    public var issues: [RestorationValidationIssue]

    public init(issues: [RestorationValidationIssue]) { self.issues = issues }

    public var errorDescription: String? {
        issues.first?.message ?? "Saved workspace state is invalid."
    }
}

/// Explicit allow-list of lightweight state safe for UserDefaults/window
/// restoration. It has no arbitrary payload field, which makes Secret values,
/// cached rows, terminal contents, logs, credentials, and mutation forms
/// unrepresentable in the persisted model.
public struct ClusterWindowRestorationState: Hashable, Codable, Sendable {
    public static let schemaVersion = 4

    public static let maximumContextNameBytes = 4 << 10
    public static let maximumQueryBytes = 64 << 10
    public static let maximumNamespaceCount = 256
    public static let maximumSortDescriptors = 16

    public private(set) var version: Int
    public var contextName: String
    public var contextReference: String
    public var gvr: GVR?
    public var namespaceScope: NamespaceScope
    public var filter: String
    public var sort: [SortDescriptorState]
    public var isSidebarVisible: Bool
    public var scrollAnchor: ScrollAnchor?

    public init(
        contextName: String,
        contextReference: String,
        gvr: GVR? = nil,
        namespaceScope: NamespaceScope = .all,
        filter: String = "",
        sort: [SortDescriptorState] = [],
        isSidebarVisible: Bool = true,
        scrollAnchor: ScrollAnchor? = nil
    ) {
        self.version = Self.schemaVersion
        self.contextName = contextName
        self.contextReference = contextReference
        self.gvr = gvr
        self.namespaceScope = namespaceScope
        self.filter = filter
        self.sort = sort
        self.isSidebarVisible = isSidebarVisible
        self.scrollAnchor = scrollAnchor
    }

    public func validated() throws -> Self {
        let issues = validationIssues()
        guard issues.isEmpty else { throw RestorationValidationError(issues: issues) }
        return self
    }

    public func validationIssues() -> [RestorationValidationIssue] {
        var issues: [RestorationValidationIssue] = []
        if version != Self.schemaVersion {
            issues.append(.init(
                path: "version",
                message: "Unsupported workspace state version \(version)."
            ))
        }
        validateToken(
            contextName, path: "contextName", maximumBytes: Self.maximumContextNameBytes,
            allowEmpty: false, issues: &issues
        )
        validateToken(
            contextReference, path: "contextReference", maximumBytes: Self.maximumContextNameBytes,
            allowEmpty: false, issues: &issues
        )
        if let gvr {
            validateToken(gvr.group, path: "gvr.group", allowEmpty: true, issues: &issues)
            validateToken(gvr.version, path: "gvr.version", allowEmpty: false, issues: &issues)
            validateToken(gvr.resource, path: "gvr.resource", allowEmpty: false, issues: &issues)
        }
        switch namespaceScope {
        case .all:
            break
        case .namespace(let namespace):
            validateToken(
                namespace, path: "namespaceScope.namespace", allowEmpty: false,
                issues: &issues
            )
        case .namespaces(let namespaces):
            if namespaces.isEmpty || namespaces.count > Self.maximumNamespaceCount {
                issues.append(.init(
                    path: "namespaceScope.namespaces",
                    message: "A saved multi-namespace scope must contain 1 through \(Self.maximumNamespaceCount) namespaces."
                ))
            }
            if Set(namespaces).count != namespaces.count {
                issues.append(.init(
                    path: "namespaceScope.namespaces",
                    message: "A saved namespace scope cannot contain duplicates."
                ))
            }
            for (index, namespace) in namespaces.enumerated() {
                validateToken(
                    namespace, path: "namespaceScope.namespaces[\(index)]",
                    allowEmpty: false, issues: &issues
                )
            }
        }
        for (path, value) in [
            ("filter", filter),
        ] where value.utf8.count > Self.maximumQueryBytes || value.contains("\0") {
            issues.append(.init(
                path: path,
                message: "A saved \(path) must contain at most \(Self.maximumQueryBytes) UTF-8 bytes and no NUL bytes."
            ))
        }
        if sort.count > Self.maximumSortDescriptors {
            issues.append(.init(
                path: "sort",
                message: "At most \(Self.maximumSortDescriptors) saved sort descriptors are allowed."
            ))
        }
        if Set(sort.map(\.columnID)).count != sort.count {
            issues.append(.init(path: "sort", message: "Saved sort column IDs must be unique."))
        }
        for (index, descriptor) in sort.enumerated() {
            validateToken(
                descriptor.columnID, path: "sort[\(index)].columnID",
                allowEmpty: false, issues: &issues
            )
        }
        if let scrollAnchor {
            validateToken(
                scrollAnchor.uid.rawValue, path: "scrollAnchor.uid",
                maximumBytes: 4 << 10, allowEmpty: false, issues: &issues
            )
            if !scrollAnchor.pixelOffsetFromTop.isFinite ||
                !(-8_192...8_192).contains(scrollAnchor.pixelOffsetFromTop)
            {
                issues.append(.init(
                    path: "scrollAnchor.pixelOffsetFromTop",
                    message: "The saved scroll offset is outside the supported range."
                ))
            }
            if scrollAnchor.priorRowIndex < 0 {
                issues.append(.init(
                    path: "scrollAnchor.priorRowIndex",
                    message: "The saved scroll row index cannot be negative."
                ))
            }
        }
        return issues
    }

    private func validateToken(
        _ value: String,
        path: String,
        maximumBytes: Int = 4 << 10,
        allowEmpty: Bool,
        issues: inout [RestorationValidationIssue]
    ) {
        if (!allowEmpty && value.isEmpty) || value.utf8.count > maximumBytes || value.contains("\0") {
            issues.append(.init(
                path: path,
                message: "Saved \(path) is empty, too large, or contains an invalid NUL byte."
            ))
        }
    }
}

public extension NamespaceScope {
    init(_ selection: NamespaceSelection) {
        if selection.allNamespaces {
            self = .all
        } else if selection.namespaces.count == 1, let namespace = selection.namespaces.first {
            self = .namespace(namespace)
        } else {
            self = .namespaces(selection.namespaces)
        }
    }

    var namespaceSelection: NamespaceSelection {
        switch self {
        case .all: NamespaceSelection()
        case .namespace(let namespace): .namespace(namespace)
        case .namespaces(let namespaces): NamespaceSelection(
            allNamespaces: false, namespaces: namespaces
        )
        }
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

public enum CommandID: String, Hashable, Codable, Sendable {
    case openDetails
    case openYAML
    case editYAML
    case openEvents
    case openLogs
    case openExec
    case startPortForward
    case delete
    case scale
    case restart
    case editLabels
    case editAnnotations
    case copyName
    case copyNamespacedName
    case copyReference
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

public enum ResourceListResponderClassifier {
    /// Converts AppKit ownership facts into the stable responder context used
    /// by command validation. A field editor belongs to its text control even
    /// though `NSWindow.firstResponder` is the editor, not the control. Table
    /// descendants count only while the table has no active cell editor.
    public static func classify(
        tableOwnsResponder: Bool,
        filterOwnsResponder: Bool,
        tableHasActiveEditor: Bool
    ) -> ResponderContext {
        if filterOwnsResponder { return .filterField }
        if tableOwnsResponder && !tableHasActiveEditor { return .resourceTable }
        return .other
    }
}

public struct CommandContext: Hashable, Sendable {
    public let firstResponder: ResponderContext
    public let selectedIdentities: [ResourceIdentity]
    public let hiddenSelectionUIDs: Set<ResourceUID>
    /// Engine-owned immutable selection captured at the Command-K event. When
    /// present, `selectedIdentities` deliberately stays empty so presenting a
    /// palette is constant-space even for a whole-cluster Command-A.
    public let selectionReference: ResourceSelectionDeleteReference?
    public let selectionRevision: ResourceSelectionRevision?
    public let selectionIsNamespaced: Bool
    public let logCompatibleSelection: Bool
    public let execCompatibleSelection: Bool
    public let portForwardCompatibleSelection: Bool
    public let activeEditorHasChanges: Bool
    public let networkActionsAllowed: Bool

    public init(
        firstResponder: ResponderContext,
        selectedIdentities: [ResourceIdentity] = [],
        hiddenSelectionUIDs: Set<ResourceUID> = [],
        selectionReference: ResourceSelectionDeleteReference? = nil,
        selectionRevision: ResourceSelectionRevision? = nil,
        selectionIsNamespaced: Bool = false,
        logCompatibleSelection: Bool = false,
        execCompatibleSelection: Bool = false,
        portForwardCompatibleSelection: Bool = false,
        activeEditorHasChanges: Bool = false,
        networkActionsAllowed: Bool = true
    ) {
        self.firstResponder = firstResponder
        self.selectedIdentities = selectedIdentities
        self.hiddenSelectionUIDs = hiddenSelectionUIDs.intersection(
            Set(selectedIdentities.map(\.uid))
        )
        self.selectionReference = selectionReference
        self.selectionRevision = selectionRevision
        self.selectionIsNamespaced = selectionIsNamespaced
        self.logCompatibleSelection = logCompatibleSelection
        self.execCompatibleSelection = execCompatibleSelection
        self.portForwardCompatibleSelection = portForwardCompatibleSelection
        self.activeEditorHasChanges = activeEditorHasChanges
        self.networkActionsAllowed = networkActionsAllowed
    }

    public var selectedCount: UInt64 {
        selectionReference?.selectedCount ?? UInt64(selectedIdentities.count)
    }

    public var selectionGVR: GVR? {
        if let selectionReference { return selectionReference.gvr }
        guard let first = selectedIdentities.first,
            selectedIdentities.allSatisfy({
                $0.group == first.group && $0.version == first.version
                    && $0.resource == first.resource
            })
        else { return nil }
        return GVR(group: first.group, version: first.version, resource: first.resource)
    }

    /// Builds one immutable value snapshot for resource-table commands. The
    /// compatibility facts are derived from the copied full identities so a
    /// later table selection change cannot retarget a command palette action.
    public static func capturingResourceSelection(
        firstResponder: ResponderContext,
        selectedIdentities: [ResourceIdentity],
        hiddenSelectionUIDs: Set<ResourceUID> = [],
        networkActionsAllowed: Bool = true
    ) -> Self {
        let isPod: (ResourceIdentity) -> Bool = {
            $0.group.isEmpty && $0.version == "v1" && $0.resource == "pods"
        }
        let logCompatible = LogResourceCompatibility.supportsSelection(selectedIdentities)
        let execCompatible = selectedIdentities.count == 1
            && selectedIdentities.first.map(isPod) == true
        let portForwardCompatible = selectedIdentities.count == 1
            && selectedIdentities.first.map {
                $0.group.isEmpty && $0.version == "v1"
                    && ($0.resource == "pods" || $0.resource == "services")
            } == true
        return Self(
            firstResponder: firstResponder,
            selectedIdentities: selectedIdentities,
            hiddenSelectionUIDs: hiddenSelectionUIDs.intersection(
                Set(selectedIdentities.map(\.uid))
            ),
            logCompatibleSelection: logCompatible,
            execCompatibleSelection: execCompatible,
            portForwardCompatibleSelection: portForwardCompatible,
            networkActionsAllowed: networkActionsAllowed
        )
    }

    /// Captures only immutable token metadata. Operations that intrinsically
    /// need identities may page this token after activation; delete can pass
    /// it straight to the engine without ever materializing the selection.
    public static func capturingTokenSelection(
        firstResponder: ResponderContext,
        selectionReference: ResourceSelectionDeleteReference,
        selectionRevision: ResourceSelectionRevision,
        selectionIsNamespaced: Bool,
        networkActionsAllowed: Bool = true
    ) -> Self {
        let gvr = selectionReference.gvr
        let count = selectionReference.selectedCount
        let isPod = gvr.group.isEmpty && gvr.version == "v1"
            && gvr.resource == "pods"
        let logCompatible = count > 0 && count <= 128 && (
            isPod
                || (gvr.group == "apps" && gvr.version == "v1"
                    && ["deployments", "statefulsets", "daemonsets", "replicasets"]
                        .contains(gvr.resource))
                || (gvr.group == "batch" && gvr.version == "v1"
                    && ["jobs", "cronjobs"].contains(gvr.resource))
        )
        return Self(
            firstResponder: firstResponder,
            selectionReference: selectionReference,
            selectionRevision: selectionRevision,
            selectionIsNamespaced: selectionIsNamespaced,
            logCompatibleSelection: logCompatible,
            execCompatibleSelection: count == 1 && isPod,
            portForwardCompatibleSelection: count == 1
                && gvr.group.isEmpty && gvr.version == "v1"
                && (gvr.resource == "pods" || gvr.resource == "services"),
            networkActionsAllowed: networkActionsAllowed
        )
    }
}

public enum CommandValidator {
    /// Pure validation used by menu validation and the command palette. Native
    /// responder routing remains authoritative; table-only shortcuts are not
    /// considered valid while an editor, filter, or terminal owns focus.
    public static func isEnabled(_ command: CommandID, in context: CommandContext) -> Bool {
        let count = context.selectedCount
        switch command {
        case .copyName, .copyNamespacedName, .copyReference, .selectAll,
            .focusFilter:
            break
        case .openDetails, .openYAML, .editYAML, .openEvents, .openLogs, .openExec,
            .startPortForward, .delete, .scale, .restart,
            .editLabels, .editAnnotations, .save:
            guard context.networkActionsAllowed else { return false }
        }
        switch command {
        case .openDetails, .openYAML, .editYAML, .openEvents:
            return context.firstResponder == .resourceTable && count == 1
        case .openLogs:
            return context.firstResponder == .resourceTable && count > 0 && context.logCompatibleSelection
        case .openExec:
            return context.firstResponder == .resourceTable && count == 1 && context.execCompatibleSelection
        case .startPortForward:
            return context.firstResponder == .resourceTable && count == 1 && context.portForwardCompatibleSelection
        case .delete:
            return context.firstResponder == .resourceTable && count > 0
        case .scale:
            return context.firstResponder == .resourceTable && count == 1
                && isScalable(context)
        case .restart:
            return context.firstResponder == .resourceTable && count == 1
                && supportsRestart(context)
        case .editLabels, .editAnnotations:
            return context.firstResponder == .resourceTable && count == 1
        case .copyName, .copyNamespacedName, .copyReference:
            return context.firstResponder == .resourceTable && count > 0
        case .selectAll, .focusFilter:
            return context.firstResponder == .resourceTable
        case .save:
            return (context.firstResponder == .yamlEditor || context.firstResponder == .keyValueEditor)
                && context.activeEditorHasChanges
        }
    }

    private static func isScalable(_ context: CommandContext) -> Bool {
        guard context.selectionIsNamespaced || context.selectedIdentities.first.map({
            !$0.namespace.isEmpty
        }) == true else { return false }
        return context.selectionGVR.map {
            ["deployments", "statefulsets", "replicasets"].contains($0.resource)
        } == true
    }

    private static func supportsRestart(_ context: CommandContext) -> Bool {
        context.selectionGVR.map {
            $0.group == "apps" && $0.version == "v1"
                && ["deployments", "statefulsets", "daemonsets"].contains($0.resource)
        } == true
    }
}
