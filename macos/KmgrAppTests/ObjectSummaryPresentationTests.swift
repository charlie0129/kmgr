import Foundation
import KmgrCore
import Testing
@testable import Kmgr

@Suite("Object Summary presentation")
struct ObjectSummaryPresentationTests {
    private let identity = ResourceIdentity(
        clusterSessionID: "session",
        group: "apps",
        version: "v1",
        resource: "deployments",
        namespace: "dev",
        name: "api",
        uid: ResourceUID("uid")
    )

    @Test("Summary sections follow inspection priority with Conditions last")
    func summarySectionPriority() {
        let fields = [
            "conditions", "endpoints", "ports", "containers", "selectors", "owners",
            "future-section", "secret", "service", "network", "replicas", "status",
            "identity",
        ].map {
            ObjectSummaryField(
                sectionID: $0,
                fieldID: $0,
                label: $0,
                displayText: $0
            )
        }
        let sections = ObjectDetailSummaryPresentation.sections(for: ObjectDetail(
            identity: identity,
            resourceVersion: "rv",
            summaryFields: fields,
            labels: ["app": "api"],
            annotations: ["owner": "team"]
        ))

        #expect(sections.map(\.id) == [
            "identity", "labels", "annotations", "status", "replicas", "network",
            "service", "secret", "owners", "selectors", "containers", "ports",
            "endpoints", "future-section", "conditions",
        ])
    }

    @Test("Summary bounds metadata values and entry counts")
    func boundedSummaryMetadata() throws {
        let labels = Dictionary(uniqueKeysWithValues:
            (0..<(ObjectDetailSummaryPresentation.maximumMetadataEntriesPerSection + 10))
                .map { (String(format: "key-%03d", $0), "value-\($0)") }
        )
        let longJSON = "{\"payload\":\"\(String(repeating: "x", count: 2_000))\"}"
        let longText = (0..<200).map { _ in "plain-value" }.joined(separator: " ")
        let sections = ObjectDetailSummaryPresentation.sections(for: ObjectDetail(
            identity: identity,
            resourceVersion: "rv-1",
            labels: labels,
            annotations: ["long": longJSON, "plain": longText]
        ))
        let labelFields = try #require(sections.first { $0.id == "labels" }?.rows)
        let annotations = try #require(sections.first { $0.id == "annotations" }?.rows)
        let annotation = try #require(annotations.first { $0.label == "long" })
        let plainAnnotation = try #require(annotations.first { $0.label == "plain" })
        let expectedJSONPreview = String(
            longJSON.prefix(ObjectDetailSummaryPresentation.maximumVisibleValueCharacters - 1)
        ) + "…"
        let expectedPlainPreview = String(
            longText.prefix(ObjectDetailSummaryPresentation.maximumVisibleValueCharacters - 1)
        ) + "…"

        #expect(labelFields.count
            == ObjectDetailSummaryPresentation.maximumMetadataEntriesPerSection + 1)
        #expect(labelFields.last?.displayText == "10 not shown")
        #expect(annotation.displayText == expectedJSONPreview)
        #expect(plainAnnotation.displayText == expectedPlainPreview)
        #expect(annotation.tooltip.contains("Command-C"))
        #expect(annotation.copyValue == longJSON)
        #expect(plainAnnotation.copyValue == longText)
    }

    @Test("Summary timestamps use local time and compact ages")
    func summaryTimestamps() throws {
        let timeZone = try #require(TimeZone(secondsFromGMT: 8 * 60 * 60))
        let timestamp = Date(timeIntervalSince1970: 1_755_427_785.123)
        let sections = ObjectDetailSummaryPresentation.sections(
            for: ObjectDetail(
                identity: identity,
                resourceVersion: "rv-1",
                summaryFields: [
                    ObjectSummaryField(
                        sectionID: "conditions",
                        fieldID: "ready",
                        label: "Ready",
                        displayText: "True",
                        timestamp: .elapsedSince(timestamp)
                    ),
                    ObjectSummaryField(
                        sectionID: "status",
                        fieldID: "restart",
                        label: "Last Restart",
                        displayText: "OOMKilled",
                        timestamp: .occurredAt(timestamp)
                    ),
                ]
            ),
            timeZone: timeZone,
            now: timestamp.addingTimeInterval(86_460)
        )
        let condition = try #require(sections.first { $0.id == "conditions" }?.rows.first)
        let restart = try #require(sections.first { $0.id == "status" }?.rows.first)

        #expect(condition.displayText.contains("for 1d"))
        #expect(condition.displayText.contains("+08:00"))
        #expect(restart.displayText.contains("1d ago"))
        #expect(ObjectDetailSummaryPresentation.compactAge(
            since: timestamp,
            now: timestamp.addingTimeInterval(60)
        ) == "1m")
    }

    @Test("Summary metadata removes control characters")
    func summaryMetadataControlCharacters() throws {
        let sections = ObjectDetailSummaryPresentation.sections(for: ObjectDetail(
            identity: identity,
            resourceVersion: "rv-1",
            labels: ["unsafe\u{0000}key": "first\u{0007}\nsecond"]
        ))
        let label = try #require(sections.first { $0.id == "labels" }?.rows.first)

        #expect(label.label == "unsafe key")
        #expect(label.displayText == "first second")
        #expect(!label.label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
        #expect(!label.displayText.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
    }
}
