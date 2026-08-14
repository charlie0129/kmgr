import Foundation
import Testing
@testable import Kmgr

@Test func columnConfigurationFileStoreLoadsPromptStyleYAML() throws {
    let fixture = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.charlie0129.dev/v1alpha1
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
        apiVersion: kmgr.charlie0129.dev/v1alpha1
        celEnvironment: kmgr.cel/v1
        """#)
    #expect(
        try omitted.store.load().accelerators.autoDetectSuffixes ==
            ["/gpu", "/ppu", "/dcu"]
    )

    let disabled = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.charlie0129.dev/v1alpha1
        celEnvironment: kmgr.cel/v1
        accelerators:
          autoDetectSuffixes: []
        """#)
    #expect(try disabled.store.load().accelerators.autoDetectSuffixes.isEmpty)
}

@Test func columnConfigurationFileStoreReportsDocumentedSchemaErrors() throws {
    let blankTitle = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.charlie0129.dev/v1alpha1
        celEnvironment: kmgr.cel/v1
        views:
          - match: {version: v1, resource: pods}
            columns:
              - {id: name, title: "  ", source: builtin, value: name, type: string}
        """#)
    #expect(throwsIssue { _ = try blankTitle.store.load() }?.message.contains(".title") == true)

    let negativeWidth = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.charlie0129.dev/v1alpha1
        celEnvironment: kmgr.cel/v1
        views:
          - match: {version: v1, resource: pods}
            columns:
              - {id: name, title: Name, source: builtin, value: name, type: string, width: -1}
        """#)
    #expect(throwsIssue { _ = try negativeWidth.store.load() }?.message.contains(".width") == true)

    let nonFiniteWidth = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.charlie0129.dev/v1alpha1
        celEnvironment: kmgr.cel/v1
        views:
          - match: {version: v1, resource: pods}
            columns:
              - {id: name, title: Name, source: builtin, value: name, type: string, width: .inf}
        """#)
    #expect(
        throwsIssue { _ = try nonFiniteWidth.store.load() }?.message.contains("non-finite numbers") == true
    )

    let invalidAccelerator = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.charlie0129.dev/v1alpha1
        celEnvironment: kmgr.cel/v1
        accelerators:
          resources:
            gpu: {displayName: GPU}
        """#)
    #expect(
        throwsIssue { _ = try invalidAccelerator.store.load() }?.message.contains(
            "accelerators.resources.gpu"
        ) == true
    )
}

@Test func columnConfigurationFileStoreRejectsAnchorsAndAliases() throws {
    let fixture = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.charlie0129.dev/v1alpha1
        celEnvironment: kmgr.cel/v1
        views:
          - match: &podMatch
              version: v1
              resource: pods
            columns: []
          - match: *podMatch
            columns: []
        """#)

    let issue = throwsIssue { _ = try fixture.store.load() }

    #expect(issue?.message.contains("anchors and aliases") == true)
}

@Test func columnConfigurationFileStoreRejectsMergeKeys() throws {
    let fixture = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.charlie0129.dev/v1alpha1
        celEnvironment: kmgr.cel/v1
        views:
          - match:
              <<: {version: v1, resource: pods}
            columns: []
        """#)

    let issue = throwsIssue { _ = try fixture.store.load() }

    #expect(issue?.message.contains("merge keys") == true)
}

@Test func columnConfigurationFileStoreRejectsUnknownFields() throws {
    let fixture = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.charlie0129.dev/v1alpha1
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

    let issue = throwsIssue { _ = try fixture.store.load() }

    #expect(issue?.message.contains("views[0].columns[0].futureOption") == true)
}

@Test func columnConfigurationFileStoreRejectsInvalidFieldTypesAndDuplicateKeys() throws {
    let invalidType = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.charlie0129.dev/v1alpha1
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
    let typeIssue = throwsIssue { _ = try invalidType.store.load() }
    #expect(typeIssue?.message.contains("does not match") == true)

    let invalidSection = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.charlie0129.dev/v1alpha1
        celEnvironment: kmgr.cel/v1
        accelerators: not-a-mapping
        """#)
    let sectionIssue = throwsIssue { _ = try invalidSection.store.load() }
    #expect(sectionIssue?.message.contains("does not match") == true)

    let duplicateKey = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.charlie0129.dev/v1alpha1
        apiVersion: duplicate
        celEnvironment: kmgr.cel/v1
        """#)
    let duplicateIssue = throwsIssue { _ = try duplicateKey.store.load() }
    #expect(duplicateIssue?.message.contains("unique") == true)
}

@Test func columnConfigurationFileStoreRejectsMultipleDocumentsAndNonStringKeys() throws {
    let multipleDocuments = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.charlie0129.dev/v1alpha1
        celEnvironment: kmgr.cel/v1
        ---
        apiVersion: kmgr.charlie0129.dev/v1alpha1
        celEnvironment: kmgr.cel/v1
        """#)
    let documentIssue = throwsIssue { _ = try multipleDocuments.store.load() }
    #expect(documentIssue?.message.contains("single-document YAML") == true)

    let nonStringKey = try ColumnFileFixture(yaml: #"""
        apiVersion: kmgr.charlie0129.dev/v1alpha1
        celEnvironment: kmgr.cel/v1
        accelerators:
          resources:
            ? [nvidia.com/gpu]
            : {displayName: GPU}
        """#)
    let keyIssue = throwsIssue { _ = try nonStringKey.store.load() }
    #expect(keyIssue?.message.contains("non-string mapping keys") == true)
}

@Test func columnConfigurationFileStoreKeepsFourMiBLoadBound() throws {
    let fixture = try ColumnFileFixture(data: Data(
        repeating: UInt8(ascii: " "),
        count: ColumnConfigurationFileStore.maximumByteCount + 1
    ))

    let issue = throwsIssue { _ = try fixture.store.load() }

    #expect(issue?.message.contains("GUI editor limit") == true)
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
