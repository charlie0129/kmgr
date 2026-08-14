import Foundation
import Yams

/// Keeps the complete server YAML as the editing authority while providing a
/// quieter read-only presentation with metadata.managedFields omitted.
struct YAMLManagedFieldsPresentation: Equatable, Sendable {
    let completeYAML: String
    let YAMLWithoutManagedFields: String
    let hasManagedFields: Bool

    /// A parse-free presentation used while the Yams-backed representation is
    /// prepared away from the main actor. The complete source remains
    /// available immediately for editing.
    init(unprocessedYAMLUTF8 yamlUTF8: Data) {
        let source = String(decoding: yamlUTF8, as: UTF8.self)
        completeYAML = source
        YAMLWithoutManagedFields = source
        hasManagedFields = false
    }

    init(yamlUTF8: Data) {
        let source = String(decoding: yamlUTF8, as: UTF8.self)
        completeYAML = source

        do {
            guard var root = try compose(yaml: source),
                var rootMapping = root.mapping,
                var metadata = rootMapping["metadata"],
                var metadataMapping = metadata.mapping,
                metadataMapping["managedFields"] != nil
            else {
                YAMLWithoutManagedFields = source
                hasManagedFields = false
                return
            }

            metadataMapping["managedFields"] = nil
            metadata.mapping = metadataMapping
            rootMapping["metadata"] = metadata
            root.mapping = rootMapping
            YAMLWithoutManagedFields = try serialize(node: root, allowUnicode: true)
            hasManagedFields = true
        } catch {
            // Object YAML came from the engine and should parse. If it does not,
            // showing the authoritative text is safer than hiding arbitrary
            // source ranges with a heuristic.
            YAMLWithoutManagedFields = source
            hasManagedFields = false
        }
    }

    func text(showingManagedFields: Bool) -> String {
        showingManagedFields || !hasManagedFields
            ? completeYAML
            : YAMLWithoutManagedFields
    }
}
