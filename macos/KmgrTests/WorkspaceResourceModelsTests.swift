import Foundation
import Testing
@testable import KmgrCore

@Test func discoveredResourceIdentityIncludesGVR() {
    let resource = DiscoveredResource(
        group: "apps",
        version: "v1",
        resource: "deployments",
        kind: "Deployment",
        namespaced: true
    )
    #expect(resource.id == "apps/v1/deployments")
}

@Test func resourceStatusUsesHonestProgressText() {
    let relisting = ResourceViewStatus(freshness: .relisting, objectsExamined: 24_000)
    #expect(relisting.presentation.contains("24,000"))
    #expect(ResourceViewStatus(freshness: .stale).presentation == "Cached")
    #expect(ResourceViewStatus(freshness: .watching).presentation == "Watching")
}

@Test func everyResourceViewMessageCarriesGenerationCursor() {
    let cursor = StreamCursor(generation: 7, sequence: 31)
    let message = ResourceViewMessage.delta(
        cursor: cursor,
        delta: ResourceRowDelta(removedUIDs: ["uid-old"])
    )
    #expect(message.cursor == cursor)
}
