import Foundation
import KmgrCore
import Yams

struct ColumnConfigurationDocumentLoader: Sendable {
    let load: @Sendable (String) async throws -> ColumnsConfigurationDocument
    /// Optional richer result used by the production loader to surface a
    /// recovery/migration notice. Test loaders can provide only `load` and
    /// retain the original document-only contract.
    let loadResult: (@Sendable (String) async throws -> ColumnConfigurationLoadResult)?

    init(
        load: @escaping @Sendable (String) async throws -> ColumnsConfigurationDocument,
        loadResult: (@Sendable (String) async throws -> ColumnConfigurationLoadResult)? = nil
    ) {
        self.load = load
        self.loadResult = loadResult
    }

    static let fileSystem = Self(
        load: { path in
            await ColumnConfigurationFileStore(path: path)
                .loadRecoveringOffMain().document
        },
        loadResult: { path in
            await ColumnConfigurationFileStore(path: path).loadRecoveringOffMain()
        }
    )
}

enum ColumnConfigurationLoadAction: Equatable, Sendable {
    case loaded
    case migrated
    case reset
}

/// The result of reading the user configuration. Notices are deliberately
/// plain text so the application can present them without coupling this file
/// store to AppKit.
struct ColumnConfigurationLoadResult: Sendable {
    let document: ColumnsConfigurationDocument
    let action: ColumnConfigurationLoadAction
    let notice: String?
    let backupURL: URL?

    init(
        document: ColumnsConfigurationDocument,
        action: ColumnConfigurationLoadAction = .loaded,
        notice: String? = nil,
        backupURL: URL? = nil
    ) {
        self.document = document
        self.action = action
        self.notice = notice
        self.backupURL = backupURL
    }
}

/// Reconciles persisted definitions loaded in the background with saves that
/// finish while that load is in flight. A late snapshot may be stale, so every
/// successful save recorded after it began must win for its exact GVR.
struct ColumnConfigurationCacheState {
    private(set) var document: ColumnsConfigurationDocument?
    /// A strict engine version is available only for bytes written by this
    /// process. An externally-authored YAML document is still valid input, but
    /// its raw-byte digest cannot be reconstructed from the normalized model;
    /// leaving this empty lets the engine accept that document and return its
    /// authoritative version during resolution.
    private(set) var persistedVersion: String?
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
            persistedVersion = document.persistedVersion()
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
        let hadPendingSave = !pendingSavedDefinitions.isEmpty
        for match in pendingSavedDefinitions.keys.sorted(by: { $0.key < $1.key }) {
            guard let definitions = pendingSavedDefinitions[match] else { continue }
            Self.upsert(definitions, matching: match, in: &reconciled)
        }
        pendingSavedDefinitions.removeAll(keepingCapacity: true)
        document = reconciled
        persistedVersion = hadPendingSave ? reconciled.persistedVersion() : nil
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
        // The ordinary load path follows the user-facing recovery policy. The
        // throwing signature is retained for callers that already use `try`;
        // filesystem/configuration failures are represented by the returned
        // default document and notice instead of escaping into the UI.
        loadRecovering().document
    }

    /// Loads and, when necessary, rewrites a compatible metadata value to the
    /// current schema. Invalid input is backed up and replaced with defaults.
    /// The API value is deliberately not an allowlist: field compatibility is
    /// established before it is canonicalized.
    func loadResult() throws -> ColumnConfigurationLoadResult {
        loadRecovering()
    }

    /// Strict parser used by the conflict detector and focused diagnostics.
    /// User-facing loads should use `load()`/`loadResult()` so an incompatible
    /// file follows the backup-and-reset policy.
    func loadStrict() throws -> ColumnsConfigurationDocument {
        // Conflict checks must not rewrite a file merely because another
        // process supplied compatible legacy metadata. The next successful
        // application save will still emit the canonical document.
        try loadParsedResult(persistMigration: false).document
    }

    private func loadParsedResult(
        persistMigration: Bool = true
    ) throws -> ColumnConfigurationLoadResult {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            return ColumnConfigurationLoadResult(document: ColumnsConfigurationDocument())
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
        guard let root = object as? [String: Any] else {
            throw ColumnConfigurationFileIssue("The column configuration must be a mapping document.")
        }

        guard let apiVersion = root["apiVersion"] as? String else {
            throw ColumnConfigurationFileIssue(
                "The column configuration must declare a compatible apiVersion."
            )
        }
        // The API value is metadata, not a compatibility dispatch key. Any
        // nonempty string is eligible for the field-level checks below; a
        // successful load is always emitted with the current API value.
        guard !apiVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ColumnConfigurationFileIssue("The column configuration apiVersion must not be empty.")
        }
        guard root["celEnvironment"] as? String == ColumnConfigurationSchema.celEnvironment else {
            let value = (root["celEnvironment"] as? String) ?? "missing"
            throw ColumnConfigurationFileIssue(
                "Unsupported CEL environment \(value); expected \(ColumnConfigurationSchema.celEnvironment)."
            )
        }

        let unknownPaths = Self.unknownKeyPaths(in: root)
        guard unknownPaths.isEmpty else {
            throw ColumnConfigurationFileIssue(
                "The column configuration contains fields this app version cannot preserve: \(unknownPaths.prefix(4).joined(separator: ", ")). Open it in an external editor."
            )
        }

        // Keep the source tree separate from the decode tree. The Swift model
        // has non-optional collection properties so it needs safe empty
        // values while decoding, but a metadata-only migration must not write
        // those synthesized fields back to disk. The minimal durable change
        // is the apiVersion value itself.
        let sourceRoot = root
        var decodeRoot = root

        // The Go schema intentionally permits these sections to be omitted.
        // Supply their empty values before decoding into the strongly typed UI
        // model, whose synthesized Codable conformance requires them.
        if decodeRoot["views"] == nil {
            decodeRoot["views"] = []
        }
        if var views = decodeRoot["views"] as? [[String: Any]] {
            for index in views.indices {
                guard var match = views[index]["match"] as? [String: Any] else { continue }
                if match["group"] == nil {
                    match["group"] = ""
                }
                views[index]["match"] = match
            }
            decodeRoot["views"] = views
        }
        if decodeRoot["accelerators"] == nil {
            decodeRoot["accelerators"] = [:]
        }
        if var accelerators = decodeRoot["accelerators"] as? [String: Any] {
            if accelerators["autoDetectSuffixes"] == nil {
                accelerators["autoDetectSuffixes"] = AcceleratorColumnConfiguration.defaultAutoDetectSuffixes
            }
            if accelerators["resources"] == nil {
                accelerators["resources"] = [:]
            }
            decodeRoot["accelerators"] = accelerators
        }

        // Explicit nulls are accepted by some Swift Optional properties but
        // not by the Go engine's corresponding non-pointer fields. Reject
        // them before declaring a field-compatible migration; `enabled` is
        // the one intentional nullable field on both sides.
        if let nullPath = Self.unsupportedEngineNullPath(in: sourceRoot) {
            throw ColumnConfigurationFileIssue(
                "The column configuration contains null at \(nullPath), which is not compatible with the engine schema."
            )
        }

        // Metadata is the only legacy change we can safely translate. All
        // field names, types, enum values, and semantic values have already
        // been checked against the current model below.
        decodeRoot["apiVersion"] = ColumnConfigurationSchema.apiVersion
        let normalized = try JSONSerialization.data(withJSONObject: decodeRoot)

        let document: ColumnsConfigurationDocument
        do {
            document = try JSONDecoder().decode(ColumnsConfigurationDocument.self, from: normalized)
        } catch {
            throw ColumnConfigurationFileIssue(
                "The column configuration does not match \(ColumnConfigurationSchema.apiVersion): \(error.localizedDescription)"
            )
        }
        let issues = document.validationIssues()
        let engineIssues = Self.engineCompatibilityIssues(document)
        guard issues.isEmpty, engineIssues.isEmpty else {
            throw ColumnConfigurationFileIssue(
                Self.issueSummary(issues + engineIssues)
            )
        }

        if apiVersion != ColumnConfigurationSchema.apiVersion {
            guard persistMigration else {
                return ColumnConfigurationLoadResult(
                    document: document,
                    action: .migrated,
                    notice: "Programmable columns migrated to the current format."
                )
            }
            do {
                // Preserve every field that was present in the source tree.
                // Encoding the strongly typed model would apply `omitempty`
                // semantics in its callers and could erase meaningful values
                // such as an explicit width of 0 or an empty suffix list.
                var migratedRoot = sourceRoot
                migratedRoot["apiVersion"] = ColumnConfigurationSchema.apiVersion
                try saveRaw(migratedRoot)
                return ColumnConfigurationLoadResult(
                    document: document,
                    action: .migrated,
                    notice: "Programmable columns migrated to the current format."
                )
            } catch {
                // A migration is only successful when the canonical document
                // can be persisted. Fall through to the same backup/reset
                // policy used for an incompatible document rather than
                // activating a configuration that will be lost on relaunch.
                return recoverInvalidConfiguration(cause: error)
            }
        }
        return ColumnConfigurationLoadResult(document: document)
    }

    /// Best-effort boundary. A malformed or incompatible existing file is
    /// backed up before it is atomically replaced with a canonical empty
    /// current document. If either filesystem operation fails, the original is
    /// left untouched and in-memory defaults are still returned.
    func loadRecovering() -> ColumnConfigurationLoadResult {
        do {
            return try loadParsedResult()
        } catch {
            return recoverInvalidConfiguration(cause: error)
        }
    }

    /// File I/O and YAML/JSON parsing must never run on AppKit's main actor.
    /// The synchronous primitives remain available for command-line/unit use;
    /// UI callers use these detached boundaries.
    func loadOffMain() async throws -> ColumnsConfigurationDocument {
        try await Task.detached(priority: .userInitiated) { [self] in
            try load()
        }.value
    }

    func loadRecoveringOffMain() async -> ColumnConfigurationLoadResult {
        await Task.detached(priority: .userInitiated) { [self] in
            loadRecovering()
        }.value
    }

    func save(_ document: ColumnsConfigurationDocument) throws {
        // Persist one canonical metadata value. Compatibility is established
        // by the loader's field checks; a caller that supplies an older or
        // otherwise descriptive apiVersion must not write that metadata back
        // out as the active format.
        var canonicalDocument = document
        canonicalDocument.apiVersion = ColumnConfigurationSchema.apiVersion
        let issues = canonicalDocument.validationIssues()
        guard issues.isEmpty else {
            throw ColumnConfigurationFileIssue(Self.issueSummary(issues))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(canonicalDocument)
        try write(data)
    }

    /// Writes a validated raw JSON-compatible tree for migrations. This is
    /// intentionally separate from `save(_:)`, whose model encoder omits some
    /// optional zero/empty values for ordinary editor writes.
    private func saveRaw(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard data.count <= Self.maximumByteCount else {
            throw ColumnConfigurationFileIssue(
                "The encoded column configuration exceeds the GUI editor's \(Self.maximumByteCount.formatted()) byte limit."
            )
        }
        try write(data)
    }

    private func write(_ data: Data) throws {
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

    /// The Go engine is authoritative for execution, but the native editor
    /// must not label a definition as safely migrated when the helper would
    /// reject it on startup. Keep this small mirror of the extractor contract
    /// at the persistence boundary so invalid native values take the same
    /// backup/reset path as structural incompatibilities.
    private static func engineCompatibilityIssues(
        _ document: ColumnsConfigurationDocument
    ) -> [ColumnConfigurationIssue] {
        var issues: [ColumnConfigurationIssue] = []
        for (viewIndex, view) in document.views.enumerated() {
            let group = view.match.group
            let version = view.match.version
            let resource = view.match.resource
            for (columnIndex, definition) in view.columns.enumerated() {
                let path = "views[\(viewIndex)].columns[\(columnIndex)]"
                switch definition.source {
                case .cel:
                    if definition.type == .resourceUsage {
                        issues.append(.init(
                            path: "\(path).type",
                            message: "CEL columns cannot use the native resourceUsage type."
                        ))
                    }
                case .builtin:
                    guard let value = definition.value?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ), !value.isEmpty else { continue }
                    guard let descriptor = NativeColumnCatalog.descriptor(
                        source: .builtin,
                        value: value
                    ) else {
                        issues.append(.init(
                            path: "\(path).value",
                            message: "Unsupported built-in extractor \(value.debugDescription)."
                        ))
                        continue
                    }
                    if descriptor.type != definition.type {
                        issues.append(.init(
                            path: "\(path).type",
                            message: "Built-in \(value.debugDescription) requires type \(descriptor.type.rawValue)."
                        ))
                    }
                    if !descriptor.resourceScope.supports(
                        group: group,
                        version: version,
                        resource: resource
                    ) {
                        issues.append(.init(
                            path: "\(path).value",
                            message: "Built-in \(value.debugDescription) is not supported for \(group)/\(version)/\(resource)."
                        ))
                    }
                case .metric:
                    guard let value = definition.value?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ), !value.isEmpty else { continue }
                    if definition.type != .resourceUsage {
                        issues.append(.init(
                            path: "\(path).type",
                            message: "Metric columns require type resourceUsage."
                        ))
                    }
                    if let descriptor = NativeColumnCatalog.descriptor(
                        source: .metric,
                        value: value
                    ) {
                        if !descriptor.resourceScope.supports(
                            group: group,
                            version: version,
                            resource: resource
                        ) {
                            issues.append(.init(
                                path: "\(path).value",
                                message: "Metric \(value.debugDescription) is not supported for \(group)/\(version)/\(resource)."
                            ))
                        }
                    } else if let exact = value.split(
                        separator: ":",
                        maxSplits: 1,
                        omittingEmptySubsequences: false
                    ).dropFirst().first,
                        value.hasPrefix("resource:"),
                        KubernetesQualifiedName.isValid(String(exact)),
                        group.isEmpty, version == "v1",
                        resource == "pods" || resource == "nodes"
                    {
                        // Exact scheduler resources are validated by their
                        // qualified name and are only meaningful on Pod/Node
                        // metric views.
                    } else {
                        issues.append(.init(
                            path: "\(path).value",
                            message: "Unsupported metric extractor \(value.debugDescription)."
                        ))
                    }
                case .server:
                    if definition.type == .resourceUsage {
                        issues.append(.init(
                            path: "\(path).type",
                            message: "Server Table columns cannot use the native resourceUsage type."
                        ))
                    }
                }
            }
        }
        return issues
    }

    private static func unsupportedEngineNullPath(
        in root: [String: Any]
    ) -> String? {
        func visit(_ value: Any, path: String) -> String? {
            if value is NSNull {
                // `enabled` is represented as a nullable pointer in the Go
                // schema and as an Optional in Swift. Every other persisted
                // field is non-nullable on the engine side; an explicit null
                // is therefore not the same compatible shape as omission.
                return path.hasSuffix(".enabled") ? nil : (path.isEmpty ? "document" : path)
            }
            if let object = value as? [String: Any] {
                for key in object.keys.sorted() {
                    if let issue = visit(
                        object[key] as Any,
                        path: path.isEmpty ? key : "\(path).\(key)"
                    ) {
                        return issue
                    }
                }
                return nil
            }
            if let array = value as? [Any] {
                for (index, element) in array.enumerated() {
                    if let issue = visit(
                        element,
                        path: "\(path)[\(index)]"
                    ) {
                        return issue
                    }
                }
            }
            return nil
        }

        return visit(root, path: "")
    }

    private func recoverInvalidConfiguration(cause: Error) -> ColumnConfigurationLoadResult {
        let defaults = ColumnsConfigurationDocument()
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            return ColumnConfigurationLoadResult(
                document: defaults,
                action: .reset,
                notice: "Programmable columns were invalid and have been reset to defaults."
            )
        }

        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular
        else {
            return ColumnConfigurationLoadResult(
                document: defaults,
                action: .reset,
                notice: "Programmable columns could not be read (\(cause.localizedDescription)); defaults are in use, and the original path was left untouched."
            )
        }

        let backupURL = uniqueBackupURL(using: manager)
        do {
            try manager.copyItem(at: url, to: backupURL)
            do {
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
            } catch {
                // Do not strand an unprotected copy when tightening the
                // backup's permissions fails. The source remains untouched.
                try? manager.removeItem(at: backupURL)
                throw error
            }
        } catch {
            return ColumnConfigurationLoadResult(
                document: defaults,
                action: .reset,
                notice: "Programmable columns were invalid or incompatible (\(cause.localizedDescription)) and were reset in memory; defaults are in use, but the original could not be backed up and was left untouched."
            )
        }

        do {
            try replaceWithDefaults(defaults, using: manager)
            return ColumnConfigurationLoadResult(
                document: defaults,
                action: .reset,
                notice: "Programmable columns were invalid or incompatible and were reset. The original file was backed up to \(backupURL.path) and replaced with defaults.",
                backupURL: backupURL
            )
        } catch {
            return ColumnConfigurationLoadResult(
                document: defaults,
                action: .reset,
                notice: "Programmable columns were invalid or incompatible and were reset in memory. The original was backed up to \(backupURL.path), but replacing it failed; defaults are in use until the file can be repaired.",
                backupURL: backupURL
            )
        }
    }

    private func uniqueBackupURL(using manager: FileManager) -> URL {
        let directory = url.deletingLastPathComponent()
        repeat {
            let candidate = directory.appendingPathComponent(
                "\(url.lastPathComponent).invalid-\(UUID().uuidString).bak",
                isDirectory: false
            )
            if !manager.fileExists(atPath: candidate.path) { return candidate }
        } while true
    }

    private func replaceWithDefaults(
        _ document: ColumnsConfigurationDocument,
        using manager: FileManager
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).reset-\(UUID().uuidString)",
            isDirectory: false
        )
        defer {
            try? manager.removeItem(at: temporaryURL)
        }
        try data.write(to: temporaryURL, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        _ = try manager.replaceItemAt(url, withItemAt: temporaryURL)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
