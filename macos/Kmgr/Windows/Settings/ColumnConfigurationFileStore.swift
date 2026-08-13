import Foundation
import KmgrCore

/// Small, deliberately strict persistence boundary for the GUI column editor.
/// JSON is emitted because it is a YAML 1.2 subset and is accepted by the Go
/// engine's strict YAML loader without adding a second YAML implementation to
/// the GUI process.
struct ColumnConfigurationFileStore {
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
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ColumnConfigurationFileIssue(
                "This file uses YAML syntax that the native column editor cannot safely preserve. Open it in an external editor, or save it as JSON-compatible YAML."
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
        var accelerators = root["accelerators"] as? [String: Any] ?? [:]
        if accelerators["autoDetectSuffixes"] == nil { accelerators["autoDetectSuffixes"] = [] }
        if accelerators["resources"] == nil { accelerators["resources"] = [:] }
        root["accelerators"] = accelerators

        let normalized = try JSONSerialization.data(withJSONObject: root)
        var document: ColumnsConfigurationDocument
        do {
            document = try JSONDecoder().decode(ColumnsConfigurationDocument.self, from: normalized)
        } catch {
            throw ColumnConfigurationFileIssue(
                "The column configuration does not match \(ColumnConfigurationSchema.apiVersion): \(error.localizedDescription)"
            )
        }
        NativeColumnCatalog.normalizeLegacyTypes(in: &document)
        let issues = document.validationIssues()
        guard issues.isEmpty else {
            throw ColumnConfigurationFileIssue(Self.issueSummary(issues))
        }
        return document
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
}

struct ColumnConfigurationFileIssue: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
