import Foundation
import KmgrCore
import Yams

struct ColumnConfigurationDocumentLoader: Sendable {
    let load: @Sendable (String) async throws -> ColumnsConfigurationDocument

    static let fileSystem = Self { path in
        try await ColumnConfigurationFileStore(path: path).loadOffMain()
    }
}

/// Reconciles persisted definitions loaded in the background with saves that
/// finish while that load is in flight. A late snapshot may be stale, so every
/// successful save recorded after it began must win for its exact GVR.
struct ColumnConfigurationCacheState {
    private(set) var document: ColumnsConfigurationDocument?
    private var pendingSavedDefinitions: [ColumnResourceMatch: [ColumnDefinition]] = [:]

    mutating func recordSaved(
        _ definitions: [ColumnDefinition],
        matching match: ColumnResourceMatch
    ) {
        if var document {
            // Saves are serialized by the process-wide coordinator and mutate
            // exactly one GVR. Sibling snapshots therefore remain valid and a
            // divider drag does not trigger one file reload per open window.
            Self.upsert(definitions, matching: match, in: &document)
            self.document = document
        } else {
            // A load already in flight may return an older snapshot. Reapply
            // the durable exact-GVR save when that snapshot arrives.
            pendingSavedDefinitions[match] = definitions
        }
    }

    @discardableResult
    mutating func installLoaded(
        _ loaded: ColumnsConfigurationDocument
    ) -> ColumnsConfigurationDocument {
        var reconciled = loaded
        for match in pendingSavedDefinitions.keys.sorted(by: { $0.key < $1.key }) {
            guard let definitions = pendingSavedDefinitions[match] else { continue }
            Self.upsert(definitions, matching: match, in: &reconciled)
        }
        pendingSavedDefinitions.removeAll(keepingCapacity: true)
        document = reconciled
        return reconciled
    }

    private static func upsert(
        _ definitions: [ColumnDefinition],
        matching match: ColumnResourceMatch,
        in document: inout ColumnsConfigurationDocument
    ) {
        let view = ResourceColumnConfiguration(match: match, columns: definitions)
        if let index = document.views.firstIndex(where: { $0.match == match }) {
            document.views[index] = view
        } else {
            document.views.append(view)
        }
    }
}

/// Small, deliberately strict persistence boundary for the GUI column editor.
/// JSON is emitted because it is a YAML 1.2 subset and is accepted by the Go
/// engine's strict YAML loader. Loading accepts ordinary YAML, but rejects
/// constructs whose meaning could change when the GUI rewrites the document.
struct ColumnConfigurationFileStore: Sendable {
    static let maximumByteCount = 4 << 20

    let url: URL

    init(path: String) {
        url = URL(
            fileURLWithPath: NSString(string: path).expandingTildeInPath,
            isDirectory: false
        )
    }

    func load() throws -> ColumnsConfigurationDocument {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            return ColumnsConfigurationDocument()
        }

        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ColumnConfigurationFileIssue(
                "The column configuration is not a regular file: \(url.path)"
            )
        }
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount <= Self.maximumByteCount else {
            throw ColumnConfigurationFileIssue(
                "The column configuration is \(byteCount.formatted()) bytes; the GUI editor limit is \(Self.maximumByteCount.formatted()) bytes. Open it in an external editor instead."
            )
        }

        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumByteCount else {
            throw ColumnConfigurationFileIssue(
                "The column configuration is \(data.count.formatted()) bytes; the GUI editor limit is \(Self.maximumByteCount.formatted()) bytes. Open it in an external editor instead."
            )
        }
        let object: Any
        do {
            let resolver = Resolver.default.removing(.timestamp).removing(.value)
            let parser = try Parser(yaml: data, resolver: resolver, encoding: .utf8)
            guard let rootNode = try parser.singleRoot() else {
                throw ColumnConfigurationFileIssue(
                    "The column configuration must be a mapping document."
                )
            }
            object = try withExtendedLifetime(parser) {
                try Self.jsonValue(from: rootNode)
            }
        } catch let issue as ColumnConfigurationFileIssue {
            throw issue
        } catch {
            throw ColumnConfigurationFileIssue(
                "The column configuration is not valid single-document YAML: \(error)"
            )
        }
        guard var root = object as? [String: Any] else {
            throw ColumnConfigurationFileIssue("The column configuration must be a mapping document.")
        }

        let unknownPaths = Self.unknownKeyPaths(in: root)
        guard unknownPaths.isEmpty else {
            throw ColumnConfigurationFileIssue(
                "The column configuration contains fields this app version cannot preserve: \(unknownPaths.prefix(4).joined(separator: ", ")). Open it in an external editor."
            )
        }

        // The Go schema intentionally permits these sections to be omitted.
        // Supply their empty values before decoding into the strongly typed UI
        // model, whose synthesized Codable conformance requires them.
        if root["views"] == nil { root["views"] = [] }
        if var views = root["views"] as? [[String: Any]] {
            for index in views.indices {
                guard var match = views[index]["match"] as? [String: Any] else { continue }
                if match["group"] == nil { match["group"] = "" }
                views[index]["match"] = match
            }
            root["views"] = views
        }
        if root["accelerators"] == nil { root["accelerators"] = [:] }
        if var accelerators = root["accelerators"] as? [String: Any] {
            if accelerators["autoDetectSuffixes"] == nil {
                accelerators["autoDetectSuffixes"] = AcceleratorColumnConfiguration.defaultAutoDetectSuffixes
            }
            if accelerators["resources"] == nil { accelerators["resources"] = [:] }
            root["accelerators"] = accelerators
        }

        let normalized = try JSONSerialization.data(withJSONObject: root)
        let document: ColumnsConfigurationDocument
        do {
            document = try JSONDecoder().decode(ColumnsConfigurationDocument.self, from: normalized)
        } catch {
            throw ColumnConfigurationFileIssue(
                "The column configuration does not match \(ColumnConfigurationSchema.apiVersion): \(error.localizedDescription)"
            )
        }
        let issues = document.validationIssues()
        guard issues.isEmpty else {
            throw ColumnConfigurationFileIssue(Self.issueSummary(issues))
        }
        return document
    }

    /// File I/O and YAML/JSON parsing must never run on AppKit's main actor.
    /// The synchronous primitives remain available for command-line/unit use;
    /// UI callers use these detached boundaries.
    func loadOffMain() async throws -> ColumnsConfigurationDocument {
        try await Task.detached(priority: .userInitiated) { [self] in
            try load()
        }.value
    }

    func save(_ document: ColumnsConfigurationDocument) throws {
        let issues = document.validationIssues()
        guard issues.isEmpty else {
            throw ColumnConfigurationFileIssue(Self.issueSummary(issues))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumByteCount else {
            throw ColumnConfigurationFileIssue(
                "The encoded column configuration exceeds the GUI editor's \(Self.maximumByteCount.formatted()) byte limit."
            )
        }

        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func saveOffMain(_ document: ColumnsConfigurationDocument) async throws {
        try await Task.detached(priority: .userInitiated) { [self, document] in
            try save(document)
        }.value
    }

    @discardableResult
    func ensureFileExists() throws -> URL {
        if FileManager.default.fileExists(atPath: url.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ColumnConfigurationFileIssue(
                    "The column configuration is not a regular file: \(url.path)"
                )
            }
            return url
        }
        try save(ColumnsConfigurationDocument())
        return url
    }

    func ensureFileExistsOffMain() async throws -> URL {
        try await Task.detached(priority: .userInitiated) { [self] in
            try ensureFileExists()
        }.value
    }

    private static func issueSummary(_ issues: [ColumnConfigurationIssue]) -> String {
        let details = issues.prefix(4).map { "\($0.path): \($0.message)" }.joined(separator: "  ")
        let suffix = issues.count > 4 ? "  (+\(issues.count - 4) more)" : ""
        return details + suffix
    }

    private static func unknownKeyPaths(in root: [String: Any]) -> [String] {
        var result: [String] = []
        appendUnknownKeys(
            in: root,
            allowed: ["apiVersion", "celEnvironment", "views", "accelerators"],
            path: "",
            to: &result
        )

        if let views = root["views"] as? [Any] {
            for (viewIndex, value) in views.enumerated() {
                guard let view = value as? [String: Any] else { continue }
                let viewPath = "views[\(viewIndex)]"
                appendUnknownKeys(
                    in: view,
                    allowed: ["match", "columns"],
                    path: viewPath,
                    to: &result
                )
                if let match = view["match"] as? [String: Any] {
                    appendUnknownKeys(
                        in: match,
                        allowed: ["group", "version", "resource"],
                        path: "\(viewPath).match",
                        to: &result
                    )
                }
                if let columns = view["columns"] as? [Any] {
                    for (columnIndex, value) in columns.enumerated() {
                        guard let column = value as? [String: Any] else { continue }
                        appendUnknownKeys(
                            in: column,
                            allowed: [
                                "id", "title", "source", "expression", "value", "type",
                                "alignment", "missing", "width", "listJoiner", "enabled",
                            ],
                            path: "\(viewPath).columns[\(columnIndex)]",
                            to: &result
                        )
                    }
                }
            }
        }

        if let accelerators = root["accelerators"] as? [String: Any] {
            appendUnknownKeys(
                in: accelerators,
                allowed: ["autoDetectSuffixes", "resources"],
                path: "accelerators",
                to: &result
            )
            if let resources = accelerators["resources"] as? [String: Any] {
                for (resource, value) in resources {
                    guard let settings = value as? [String: Any] else { continue }
                    appendUnknownKeys(
                        in: settings,
                        allowed: ["displayName"],
                        path: "accelerators.resources.\(resource)",
                        to: &result
                    )
                }
            }
        }
        return result.sorted()
    }

    private static func appendUnknownKeys(
        in object: [String: Any],
        allowed: Set<String>,
        path: String,
        to result: inout [String]
    ) {
        for key in object.keys where !allowed.contains(key) {
            result.append(path.isEmpty ? key : "\(path).\(key)")
        }
    }

    private static func jsonValue(from node: Node) throws -> Any {
        guard node.anchor == nil else {
            throw unsupportedYAMLIssue("anchors and aliases")
        }

        switch node {
        case let .mapping(mapping):
            guard node.tag.rawValue == Tag.Name.map.rawValue else {
                throw unsupportedYAMLIssue("custom mapping tags")
            }
            var result: [String: Any] = [:]
            result.reserveCapacity(mapping.count)
            for (keyNode, valueNode) in mapping {
                guard keyNode.anchor == nil else {
                    throw unsupportedYAMLIssue("anchors and aliases")
                }
                guard case let .scalar(key) = keyNode,
                    keyNode.tag.rawValue == Tag.Name.str.rawValue
                else {
                    if keyNode.tag.rawValue == Tag.Name.merge.rawValue {
                        throw unsupportedYAMLIssue("merge keys, anchors, and aliases")
                    }
                    throw unsupportedYAMLIssue("non-string mapping keys")
                }
                result[key.string] = try jsonValue(from: valueNode)
            }
            return result

        case let .sequence(sequence):
            guard node.tag.rawValue == Tag.Name.seq.rawValue else {
                throw unsupportedYAMLIssue("custom sequence tags")
            }
            return try sequence.map(jsonValue(from:))

        case let .scalar(scalar):
            switch node.tag.rawValue {
            case Tag.Name.str.rawValue:
                return scalar.string
            case Tag.Name.bool.rawValue:
                guard let value = node.bool else {
                    throw unsupportedYAMLIssue("invalid boolean scalars")
                }
                return value
            case Tag.Name.int.rawValue:
                guard let value = node.int else {
                    throw unsupportedYAMLIssue("integers outside the supported range")
                }
                return value
            case Tag.Name.float.rawValue:
                guard let value = node.float, value.isFinite else {
                    throw unsupportedYAMLIssue("non-finite numbers")
                }
                return value
            case Tag.Name.null.rawValue:
                return NSNull()
            default:
                throw unsupportedYAMLIssue("custom or non-JSON scalar tags")
            }

        case .alias:
            // Parser resolves aliases to their anchored node, so this branch is
            // defensive; the anchor check above catches normal alias input.
            throw unsupportedYAMLIssue("anchors and aliases")
        }
    }

    private static func unsupportedYAMLIssue(_ construct: String) -> ColumnConfigurationFileIssue {
        ColumnConfigurationFileIssue(
            "The native column editor cannot safely rewrite YAML containing \(construct). Open it in an external editor instead."
        )
    }
}

struct ColumnConfigurationFileIssue: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
