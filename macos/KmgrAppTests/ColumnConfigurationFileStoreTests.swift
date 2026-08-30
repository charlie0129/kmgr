import Foundation
import KmgrCore
import Testing
@testable import Kmgr

@Test func columnConfigurationFileStoreLoadsPromptStyleYAML() throws {
    let fixture = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.chlc.cc/v1alpha1
        celEnvironment: kmgr.cel/v1
        views:
          - match:
              group: ""
              version: v1
              resource: pods
            columns:
              - id: health
                title: Health
                source: cel
                expression: |
                  object.?status.?phase.orValue("") == "Running" &&
                  object.?status.?containerStatuses.orValue([]).all(c, c.ready)
                    ? "Healthy"
                    : "Needs attention"
                type: string
                width: 180
        accelerators:
          autoDetectSuffixes: [/gpu, /ppu, /dcu]
          resources:
            "nvidia.com/gpu":
              displayName: GPU
            'aliyun.com/ppu': {displayName: PPU}
        """#)

    let document = try fixture.store.load()

    let view = try #require(document.views.first)
    #expect(view.match.group == "")
    #expect(view.match.version == "v1")
    #expect(view.match.resource == "pods")
    let health = try #require(view.columns.first)
    #expect(health.id == "health")
    #expect(health.width == 180)
    #expect(health.expression == #"""
        object.?status.?phase.orValue("") == "Running" &&
        object.?status.?containerStatuses.orValue([]).all(c, c.ready)
          ? "Healthy"
          : "Needs attention"

        """#)
    #expect(document.accelerators.autoDetectSuffixes == ["/gpu", "/ppu", "/dcu"])
    #expect(document.accelerators.resources["nvidia.com/gpu"]?.displayName == "GPU")
    #expect(document.accelerators.resources["aliyun.com/ppu"]?.displayName == "PPU")
}

@Test func columnConfigurationFileStorePreservesAcceleratorSuffixDefaultAndDisableSentinels() throws {
    let omitted = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.chlc.cc/v1alpha1
        celEnvironment: kmgr.cel/v1
        """#)
    #expect(
        try omitted.store.load().accelerators.autoDetectSuffixes ==
            ["/gpu", "/ppu", "/dcu"]
    )

    let disabled = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.chlc.cc/v1alpha1
        celEnvironment: kmgr.cel/v1
        accelerators:
          autoDetectSuffixes: []
        """#)
    #expect(try disabled.store.load().accelerators.autoDetectSuffixes.isEmpty)
}

@Test func columnConfigurationMigratesByFieldsRegardlessOfAPIVersionValue() throws {
    let fixture = try ColumnFileFixture(yaml: #"""
        apiVersion: some.other.namespace/v17
        celEnvironment: kmgr.cel/v1
        views:
          - match: {version: v1, resource: pods}
            columns:
              - {id: name, title: Name, source: builtin, value: name, type: string}
        """#)

    let result = try fixture.store.loadResult()

    #expect(result.action == .migrated)
    #expect(result.notice?.contains("migrated") == true)
    #expect(result.document.apiVersion == ColumnConfigurationSchema.apiVersion)
    let rewritten = try JSONSerialization.jsonObject(
        with: Data(contentsOf: fixture.store.url)
    ) as? [String: Any]
    #expect(rewritten?["apiVersion"] as? String == ColumnConfigurationSchema.apiVersion)
}

@Test func columnConfigurationMigratesUnknownMetadataWhenFieldsAreCompatible() throws {
    let fixture = try ColumnFileFixture(yaml: #"""
        apiVersion: some.future.namespace/v99
        celEnvironment: kmgr.cel/v1
        """#)

    let result = try fixture.store.loadResult()

    #expect(result.action == .migrated)
    #expect(result.document == ColumnsConfigurationDocument())
    #expect(result.document.apiVersion == ColumnConfigurationSchema.apiVersion)
}

@Test func columnConfigurationMigrationPreservesExplicitZeroWidth() throws {
    let fixture = try ColumnFileFixture(yaml: #"""
        apiVersion: some.legacy.namespace/v2
        celEnvironment: kmgr.cel/v1
        views:
          - match: {version: v1, resource: pods}
            columns:
              - {id: name, title: Name, source: builtin, value: name, type: string, width: 0}
        """#)

    let result = try fixture.store.loadResult()

    #expect(result.action == .migrated)
    #expect(result.document.views.first?.columns.first?.width == 0)
    let rewritten = try Data(contentsOf: fixture.store.url)
    let object = try #require(JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
    let views = try #require(object["views"] as? [[String: Any]])
    let columns = try #require(views.first?["columns"] as? [[String: Any]])
    #expect((columns.first?["width"] as? NSNumber)?.doubleValue == 0)
}

@Test func invalidColumnConfigurationIsBackedUpAndReplacedWithDefaults() throws {
    let fixture = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.chlc.cc/v1alpha1
        celEnvironment: kmgr.cel/v1
        views:
          - match: {version: v1, resource: pods}
            columns:
              - {id: name, title: Name, source: builtin, value: removed, type: string}
        """#)
    let original = try Data(contentsOf: fixture.store.url)

    let result = fixture.store.loadRecovering()

    #expect(result.action == .reset)
    #expect(result.backupURL != nil)
    #expect(result.notice?.contains("backed up") == true)
    #expect(result.document == ColumnsConfigurationDocument())
    let backupURL = try #require(result.backupURL)
    #expect(try Data(contentsOf: backupURL) == original)
    let replacement = try fixture.store.load()
    #expect(replacement == ColumnsConfigurationDocument())
}

@Test func nativeOnlyColumnOptionsAreIncompatibleWithTheEngineContract() throws {
    let fixture = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.chlc.cc/v1alpha1
        celEnvironment: kmgr.cel/v1
        views:
          - match: {version: v1, resource: pods}
            columns:
              - id: name
                title: Name
                source: builtin
                value: name
                type: string
                missing: "—"
        """#)

    let result = fixture.store.loadRecovering()

    #expect(result.action == .reset)
    #expect(result.backupURL != nil)
    #expect(result.document == ColumnsConfigurationDocument())
}

@Test func ordinaryColumnLoadAlsoRecoversAnIncompatibleDocument() throws {
    let fixture = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.chlc.cc/v1alpha1
        celEnvironment: kmgr.cel/v1
        futureField: true
        """#)

    let document = try fixture.store.load()

    #expect(document == ColumnsConfigurationDocument())
    #expect(try fixture.store.loadStrict() == ColumnsConfigurationDocument())
    let backups = try FileManager.default.contentsOfDirectory(
        at: fixture.directory,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.contains(".invalid-") }
    #expect(backups.count == 1)
}

@Test func incompatibleColumnFieldTypesAreBackedUpAndReset() throws {
    let fixture = try ColumnFileFixture(yaml: #"""
        apiVersion: some.metadata/v2
        celEnvironment: kmgr.cel/v1
        accelerators:
          autoDetectSuffixes: definitely
        """#)
    let original = try Data(contentsOf: fixture.store.url)

    let result = try fixture.store.loadResult()

    #expect(result.action == .reset)
    #expect(result.document == ColumnsConfigurationDocument())
    let backupURL = try #require(result.backupURL)
    #expect(try Data(contentsOf: backupURL) == original)
    let permissions = (try FileManager.default.attributesOfItem(atPath: backupURL.path))[
        .posixPermissions
    ] as? NSNumber
    #expect(permissions?.intValue == 0o600)
}

@Test func missingColumnFileUsesDefaultsWithoutAResetNotice() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("kmgr-columns-missing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ColumnConfigurationFileStore(
        path: directory.appendingPathComponent("columns.yaml").path
    )

    let result = store.loadRecovering()

    #expect(result.action == .loaded)
    #expect(result.notice == nil)
    #expect(result.document == ColumnsConfigurationDocument())
}

@Test func columnConfigurationFileStoreReportsDocumentedSchemaErrors() throws {
    let blankTitle = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.chlc.cc/v1alpha1
        celEnvironment: kmgr.cel/v1
        views:
          - match: {version: v1, resource: pods}
            columns:
              - {id: name, title: "  ", source: builtin, value: name, type: string}
        """#)
    #expect(throwsIssue { _ = try blankTitle.store.loadStrict() }?.message.contains(".title") == true)

    let negativeWidth = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.chlc.cc/v1alpha1
        celEnvironment: kmgr.cel/v1
        views:
          - match: {version: v1, resource: pods}
            columns:
              - {id: name, title: Name, source: builtin, value: name, type: string, width: -1}
        """#)
    #expect(throwsIssue { _ = try negativeWidth.store.loadStrict() }?.message.contains(".width") == true)

    let nonFiniteWidth = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.chlc.cc/v1alpha1
        celEnvironment: kmgr.cel/v1
        views:
          - match: {version: v1, resource: pods}
            columns:
              - {id: name, title: Name, source: builtin, value: name, type: string, width: .inf}
        """#)
    #expect(
        throwsIssue { _ = try nonFiniteWidth.store.loadStrict() }?.message.contains("non-finite numbers") == true
    )

    let invalidAccelerator = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.chlc.cc/v1alpha1
        celEnvironment: kmgr.cel/v1
        accelerators:
          resources:
            gpu: {displayName: GPU}
        """#)
    #expect(
        throwsIssue { _ = try invalidAccelerator.store.loadStrict() }?.message.contains(
            "accelerators.resources.gpu"
        ) == true
    )
}

@Test func columnConfigurationFileStoreRejectsAnchorsAndAliases() throws {
    let fixture = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.chlc.cc/v1alpha1
        celEnvironment: kmgr.cel/v1
        views:
          - match: &podMatch
              version: v1
              resource: pods
            columns: []
          - match: *podMatch
            columns: []
        """#)

    let issue = throwsIssue { _ = try fixture.store.loadStrict() }

    #expect(issue?.message.contains("anchors and aliases") == true)
}

@Test func columnConfigurationFileStoreRejectsMergeKeys() throws {
    let fixture = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.chlc.cc/v1alpha1
        celEnvironment: kmgr.cel/v1
        views:
          - match:
              <<: {version: v1, resource: pods}
            columns: []
        """#)

    let issue = throwsIssue { _ = try fixture.store.loadStrict() }

    #expect(issue?.message.contains("merge keys") == true)
}

@Test func columnConfigurationFileStoreRejectsUnknownFields() throws {
    let fixture = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.chlc.cc/v1alpha1
        celEnvironment: kmgr.cel/v1
        views:
          - match: {version: v1, resource: pods}
            columns:
              - id: name
                title: Name
                source: builtin
                value: name
                type: string
                futureOption: true
        """#)

    let issue = throwsIssue { _ = try fixture.store.loadStrict() }

    #expect(issue?.message.contains("views[0].columns[0].futureOption") == true)
}

@Test func columnConfigurationFileStoreRejectsInvalidFieldTypesAndDuplicateKeys() throws {
    let invalidType = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.chlc.cc/v1alpha1
        celEnvironment: kmgr.cel/v1
        views:
          - match: {version: v1, resource: pods}
            columns:
              - id: name
                title: Name
                source: builtin
                value: name
                type: string
                enabled: definitely
        """#)
    let typeIssue = throwsIssue { _ = try invalidType.store.loadStrict() }
    #expect(typeIssue?.message.contains("does not match") == true)

    let invalidSection = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.chlc.cc/v1alpha1
        celEnvironment: kmgr.cel/v1
        accelerators: not-a-mapping
        """#)
    let sectionIssue = throwsIssue { _ = try invalidSection.store.loadStrict() }
    #expect(sectionIssue?.message.contains("does not match") == true)

    let duplicateKey = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.chlc.cc/v1alpha1
        apiVersion: duplicate
        celEnvironment: kmgr.cel/v1
        """#)
    let duplicateIssue = throwsIssue { _ = try duplicateKey.store.loadStrict() }
    #expect(duplicateIssue?.message.contains("unique") == true)
}

@Test func columnConfigurationFileStoreRejectsMultipleDocumentsAndNonStringKeys() throws {
    let multipleDocuments = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.chlc.cc/v1alpha1
        celEnvironment: kmgr.cel/v1
        ---
        apiVersion: kmgr.chlc.cc/v1alpha1
        celEnvironment: kmgr.cel/v1
        """#)
    let documentIssue = throwsIssue { _ = try multipleDocuments.store.loadStrict() }
    #expect(documentIssue?.message.contains("single-document YAML") == true)

    let nonStringKey = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.chlc.cc/v1alpha1
        celEnvironment: kmgr.cel/v1
        accelerators:
          resources:
            ? [nvidia.com/gpu]
            : {displayName: GPU}
        """#)
    let keyIssue = throwsIssue { _ = try nonStringKey.store.loadStrict() }
    #expect(keyIssue?.message.contains("non-string mapping keys") == true)
}

@Test func columnConfigurationFileStoreKeepsFourMiBLoadBound() throws {
    let fixture = try ColumnFileFixture(data: Data(
        repeating: UInt8(ascii: " "),
        count: ColumnConfigurationFileStore.maximumByteCount + 1
    ))

    let issue = throwsIssue { _ = try fixture.store.loadStrict() }

    #expect(issue?.message.contains("GUI editor limit") == true)
}

@Test func columnConfigurationCacheKeepsSavesThatRaceWithBackgroundLoad() throws {
    let pods = ColumnResourceMatch(group: "", version: "v1", resource: "pods")
    let nodes = ColumnResourceMatch(group: "", version: "v1", resource: "nodes")
    let stalePods = [testColumn(id: "old-pods")]
    let savedPods = [testColumn(id: "saved-pods")]
    let loadedNodes = [testColumn(id: "loaded-nodes")]
    var cache = ColumnConfigurationCacheState()

    // The disk snapshot was captured before this successful save completed.
    cache.recordSaved(savedPods, matching: pods)
    let reconciled = cache.installLoaded(ColumnsConfigurationDocument(views: [
        ResourceColumnConfiguration(match: pods, columns: stalePods),
        ResourceColumnConfiguration(match: nodes, columns: loadedNodes),
    ]))

    #expect(reconciled.views.first { $0.match == pods }?.columns == savedPods)
    #expect(reconciled.views.first { $0.match == nodes }?.columns == loadedNodes)

    let laterNodes = [testColumn(id: "saved-nodes")]
    cache.recordSaved(laterNodes, matching: nodes)
    #expect(cache.document?.views.first { $0.match == pods }?.columns == savedPods)
    #expect(cache.document?.views.first { $0.match == nodes }?.columns == laterNodes)
}

@Test func columnConfigurationCacheDoesNotInventAFileDigestForExternalYAML() throws {
    let pods = ColumnResourceMatch(group: "", version: "v1", resource: "pods")
    var cache = ColumnConfigurationCacheState()
    let loaded = ColumnsConfigurationDocument(views: [
        ResourceColumnConfiguration(match: pods, columns: [testColumn(id: "loaded")]),
    ])

    _ = cache.installLoaded(loaded)
    #expect(cache.persistedVersion == nil)

    cache.recordSaved([testColumn(id: "saved")], matching: pods)
    #expect(cache.persistedVersion == cache.document?.persistedVersion())
}

private func testColumn(id: String) -> ColumnDefinition {
    ColumnDefinition(
        id: id,
        title: id,
        source: .builtin,
        value: "name",
        type: .string
    )
}

private struct ColumnFileFixture {
    let directory: URL
    let store: ColumnConfigurationFileStore

    init(yaml: String) throws {
        try self.init(data: Data(yaml.utf8))
    }

    init(data: Data) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("columns.yaml", isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url)
        store = ColumnConfigurationFileStore(path: url.path)
    }
}

private func throwsIssue(_ body: () throws -> Void) -> ColumnConfigurationFileIssue? {
    do {
        try body()
        Issue.record("Expected ColumnConfigurationFileIssue")
        return nil
    } catch let issue as ColumnConfigurationFileIssue {
        return issue
    } catch {
        Issue.record("Unexpected error: \(error)")
        return nil
    }
}
