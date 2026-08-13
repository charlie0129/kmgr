import Foundation

public enum ColumnConfigurationSchema {
    public static let apiVersion = "kmgr.charlie0129.dev/v1alpha1"
    public static let celEnvironment = "kmgr.cel/v1"
}

public enum ColumnSource: String, Codable, CaseIterable, Hashable, Sendable {
    case cel
    case builtin
    case metric
}

public enum ColumnResultType: String, Codable, CaseIterable, Hashable, Sendable {
    case string
    case integer
    case number
    case boolean
    case quantity
    case timestamp
    case duration
    case resourceUsage
}

public enum ColumnAlignment: String, Codable, CaseIterable, Hashable, Sendable {
    case leading
    case center
    case trailing
}

public struct ColumnResourceMatch: Codable, Hashable, Sendable {
    public var group: String
    public var version: String
    public var resource: String

    public init(group: String = "", version: String, resource: String) {
        self.group = group
        self.version = version
        self.resource = resource
    }

    public var key: String { "\(group)/\(version)/\(resource)" }
}

public struct ColumnDefinition: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var source: ColumnSource
    public var expression: String?
    public var value: String?
    public var type: ColumnResultType
    public var alignment: ColumnAlignment?
    public var missing: String?
    public var width: Double?
    public var listJoiner: String?
    public var enabled: Bool?

    public init(
        id: String,
        title: String,
        source: ColumnSource,
        expression: String? = nil,
        value: String? = nil,
        type: ColumnResultType,
        alignment: ColumnAlignment? = nil,
        missing: String? = nil,
        width: Double? = nil,
        listJoiner: String? = nil,
        enabled: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.expression = expression
        self.value = value
        self.type = type
        self.alignment = alignment
        self.missing = missing
        self.width = width
        self.listJoiner = listJoiner
        self.enabled = enabled
    }

    public var isEnabled: Bool { enabled ?? true }
}

public struct ResourceColumnConfiguration: Codable, Hashable, Sendable {
    public var match: ColumnResourceMatch
    public var columns: [ColumnDefinition]

    public init(match: ColumnResourceMatch, columns: [ColumnDefinition]) {
        self.match = match
        self.columns = columns
    }
}

public struct AcceleratorResourceConfiguration: Codable, Hashable, Sendable {
    public var displayName: String?

    public init(displayName: String? = nil) {
        self.displayName = displayName
    }
}

public struct AcceleratorColumnConfiguration: Codable, Hashable, Sendable {
    public var autoDetectSuffixes: [String]
    public var resources: [String: AcceleratorResourceConfiguration]

    public init(
        autoDetectSuffixes: [String] = [],
        resources: [String: AcceleratorResourceConfiguration] = [:]
    ) {
        self.autoDetectSuffixes = autoDetectSuffixes
        self.resources = resources
    }
}

public struct ColumnsConfigurationDocument: Codable, Hashable, Sendable {
    public var apiVersion: String
    public var celEnvironment: String
    public var views: [ResourceColumnConfiguration]
    public var accelerators: AcceleratorColumnConfiguration

    public init(
        apiVersion: String = ColumnConfigurationSchema.apiVersion,
        celEnvironment: String = ColumnConfigurationSchema.celEnvironment,
        views: [ResourceColumnConfiguration] = [],
        accelerators: AcceleratorColumnConfiguration = AcceleratorColumnConfiguration()
    ) {
        self.apiVersion = apiVersion
        self.celEnvironment = celEnvironment
        self.views = views
        self.accelerators = accelerators
    }

    public func validationIssues() -> [ColumnConfigurationIssue] {
        var issues: [ColumnConfigurationIssue] = []
        if apiVersion != ColumnConfigurationSchema.apiVersion {
            issues.append(.init(
                path: "apiVersion",
                message: "Unsupported schema \(apiVersion); expected \(ColumnConfigurationSchema.apiVersion)."
            ))
        }
        if celEnvironment != ColumnConfigurationSchema.celEnvironment {
            issues.append(.init(
                path: "celEnvironment",
                message: "Unsupported CEL environment \(celEnvironment); expected \(ColumnConfigurationSchema.celEnvironment)."
            ))
        }
        var matches: Set<String> = []
        for (viewIndex, view) in views.enumerated() {
            let base = "views[\(viewIndex)]"
            if view.match.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(path: "\(base).match.version", message: "Version is required."))
            }
            if view.match.resource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(path: "\(base).match.resource", message: "Resource is required."))
            }
            if !matches.insert(view.match.key).inserted {
                issues.append(.init(path: "\(base).match", message: "Resource match is duplicated."))
            }
            var ids: Set<String> = []
            for (columnIndex, column) in view.columns.enumerated() {
                let path = "\(base).columns[\(columnIndex)]"
                if column.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(.init(path: "\(path).id", message: "Column ID is required."))
                } else if !ids.insert(column.id).inserted {
                    issues.append(.init(path: "\(path).id", message: "Column ID is duplicated in this view."))
                }
                if column.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(.init(path: "\(path).title", message: "Column title is required."))
                }
                if let width = column.width, width < 0 || !width.isFinite {
                    issues.append(.init(path: "\(path).width", message: "Column width must be a finite non-negative value."))
                }
                switch column.source {
                case .cel:
                    if column.expression?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                        issues.append(.init(path: "\(path).expression", message: "CEL expression is required."))
                    }
                    if column.value?.isEmpty == false {
                        issues.append(.init(path: "\(path).value", message: "CEL columns cannot declare a built-in value."))
                    }
                case .builtin, .metric:
                    if column.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                        issues.append(.init(path: "\(path).value", message: "Built-in and metric columns require a value."))
                    }
                    if column.expression?.isEmpty == false {
                        issues.append(.init(path: "\(path).expression", message: "Built-in and metric columns cannot declare CEL."))
                    }
                }
            }
        }
        return issues
    }
}

public struct ColumnConfigurationIssue: Error, Codable, Hashable, Sendable {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public struct ResourceColumnDraft: Hashable, Sendable {
    public var match: ColumnResourceMatch
    public private(set) var columns: [ColumnDefinition]

    public init(match: ColumnResourceMatch, columns: [ColumnDefinition]) {
        self.match = match
        self.columns = columns
    }

    @discardableResult
    public mutating func setEnabled(_ enabled: Bool, columnID: String) -> Bool {
        guard let index = columns.firstIndex(where: { $0.id == columnID }) else { return false }
        columns[index].enabled = enabled
        return true
    }

    @discardableResult
    public mutating func move(columnID: String, to destination: Int) -> Bool {
        guard let source = columns.firstIndex(where: { $0.id == columnID }),
            destination >= 0, destination < columns.count
        else { return false }
        let value = columns.remove(at: source)
        columns.insert(value, at: destination)
        return true
    }

    public mutating func reset(to defaults: [ColumnDefinition]) {
        columns = defaults
    }

    public mutating func appendCEL(_ definition: ColumnDefinition) throws {
        guard definition.source == .cel,
            !definition.id.isEmpty,
            !columns.contains(where: { $0.id == definition.id })
        else {
            throw ColumnDraftError.invalidOrDuplicateCELColumn
        }
        columns.append(definition)
    }

    public func containsNativeColumn(source: ColumnSource, value: String) -> Bool {
        columns.contains { definition in
            definition.source == source && definition.value == value
        }
    }

    public func canAppendNative(_ definition: ColumnDefinition) -> Bool {
        guard definition.source == .builtin || definition.source == .metric,
            !definition.id.isEmpty,
            definition.value?.isEmpty == false,
            definition.expression == nil,
            !columns.contains(where: { $0.id == definition.id })
        else { return false }
        return !containsNativeColumn(
            source: definition.source,
            value: definition.value ?? ""
        )
    }

    public mutating func appendNative(_ definition: ColumnDefinition) throws {
        guard canAppendNative(definition) else {
            throw ColumnDraftError.invalidOrDuplicateNativeColumn
        }
        columns.append(definition)
    }
}

public enum ColumnDraftError: Error, Hashable, Sendable, LocalizedError {
    case invalidOrDuplicateCELColumn
    case invalidOrDuplicateNativeColumn

    public var errorDescription: String? {
        switch self {
        case .invalidOrDuplicateCELColumn:
            "The CEL column is invalid or its ID is already present."
        case .invalidOrDuplicateNativeColumn:
            "The built-in or metric column is invalid, or its ID/exact extractor is already present."
        }
    }
}
