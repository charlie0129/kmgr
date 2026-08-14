import Foundation
import KmgrCore
import Testing

private let podCompletionContext = ResourceFilterCompletionContext(
    gvr: GVR(group: "", version: "v1", resource: "pods"),
    namespaced: true
)

@Test func resourceFilterCompletionOffersDeterministicStructuredPrefixes() {
    let completions = ResourceFilterCompletionCatalog.completions(
        in: "n",
        partialWordRange: NSRange(location: 0, length: 1),
        context: podCompletionContext
    )

    #expect(completions == ["namespace:", "name:", "ns:"])
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "N",
        partialWordRange: NSRange(location: 0, length: 1),
        context: podCompletionContext
    ) == completions)
}

@Test func resourceFilterCompletionReplacesOnlyTheAppKitPartialFieldPath() throws {
    let expression = "status:running field:metadata."
    let partialRange = (expression as NSString).range(of: "metadata.")
    let completions = ResourceFilterCompletionCatalog.completions(
        in: expression,
        partialWordRange: partialRange,
        context: podCompletionContext
    )

    #expect(Array(completions.prefix(4)) == [
        "metadata.name",
        "metadata.namespace",
        "metadata.uid",
        "metadata.resourceVersion",
    ])
    let completed = (expression as NSString).replacingCharacters(
        in: partialRange,
        with: try #require(completions.first)
    )
    #expect(completed == "status:running field:metadata.name")
}

@Test func resourceFilterCompletionIsNamespacedAndExactGVRScoped() {
    let clusterScopedCRD = ResourceFilterCompletionContext(
        gvr: GVR(group: "example.io", version: "v1", resource: "widgets"),
        namespaced: false
    )
    let metadataExpression = "field:metadata."
    let metadataRange = (metadataExpression as NSString).range(of: "metadata.")
    let metadata = ResourceFilterCompletionCatalog.completions(
        in: metadataExpression,
        partialWordRange: metadataRange,
        context: clusterScopedCRD
    )
    #expect(metadata.contains("metadata.name"))
    #expect(!metadata.contains("metadata.namespace"))

    let specExpression = "field:spec."
    let specRange = (specExpression as NSString).range(of: "spec.")
    #expect(ResourceFilterCompletionCatalog.completions(
        in: specExpression,
        partialWordRange: specRange,
        context: podCompletionContext
    ) == ["spec.nodeName", "spec.serviceAccountName", "spec.schedulerName"])
    #expect(ResourceFilterCompletionCatalog.completions(
        in: specExpression,
        partialWordRange: specRange,
        context: clusterScopedCRD
    ).isEmpty)
}

@Test func resourceFilterCompletionSuppliesFullFieldTermsForNativeTracking() {
    let completions = ResourceFilterCompletionCatalog.completions(
        in: "f",
        partialWordRange: NSRange(location: 0, length: 1),
        context: podCompletionContext
    )

    #expect(completions.first == "field:metadata.name")
    #expect(completions.contains("field:metadata.namespace"))
    #expect(completions.contains("field:spec.nodeName"))
    #expect(completions.contains("field:status.phase"))
    #expect(completions.count <= ResourceFilterCompletionCatalog.maximumResults)
    #expect(completions.allSatisfy { $0.lowercased().hasPrefix("f") })
}

@Test func resourceFilterCompletionUsesCaseSensitiveFieldPaths() {
    let lower = "field:meta"
    let lowerRange = (lower as NSString).range(of: "meta")
    #expect(!ResourceFilterCompletionCatalog.completions(
        in: lower,
        partialWordRange: lowerRange,
        context: podCompletionContext
    ).isEmpty)

    let upper = "FIELD:Meta"
    let upperRange = (upper as NSString).range(of: "Meta")
    #expect(ResourceFilterCompletionCatalog.completions(
        in: upper,
        partialWordRange: upperRange,
        context: podCompletionContext
    ).isEmpty)
}

@Test func resourceFilterCompletionRejectsUnsafeUTF16AndComplexTokens() {
    let unicode = "🔥n"
    #expect(ResourceFilterCompletionCatalog.completions(
        in: unicode,
        partialWordRange: NSRange(location: 1, length: 1),
        context: podCompletionContext
    ).isEmpty)
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "n",
        partialWordRange: NSRange(location: 0, length: 2),
        context: podCompletionContext
    ).isEmpty)
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "n",
        partialWordRange: NSRange(location: NSNotFound, length: 0),
        context: podCompletionContext
    ).isEmpty)
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "n",
        partialWordRange: NSRange(location: -1, length: 1),
        context: podCompletionContext
    ).isEmpty)
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "n",
        partialWordRange: NSRange(location: 0, length: -1),
        context: podCompletionContext
    ).isEmpty)

    for expression in ["field:\\metadata.", "field:\"metadata.", "foo\\ field:meta"] {
        let range = (expression as NSString).range(
            of: expression.hasSuffix("meta") ? "meta" : "metadata."
        )
        #expect(ResourceFilterCompletionCatalog.completions(
            in: expression,
            partialWordRange: range,
            context: podCompletionContext
        ).isEmpty, Comment(rawValue: expression))
    }
}

@Test func resourceFilterCompletionContextCanUseDiscoveryIdentity() {
    let resource = DiscoveredResource(
        group: "batch",
        version: "v1",
        resource: "jobs",
        kind: "Job",
        namespaced: true
    )
    let context = ResourceFilterCompletionContext(resource: resource)
    #expect(context.gvr == GVR(group: "batch", version: "v1", resource: "jobs"))
    #expect(context.namespaced)

    let expression = "field:status."
    let range = (expression as NSString).range(of: "status.")
    #expect(ResourceFilterCompletionCatalog.completions(
        in: expression,
        partialWordRange: range,
        context: context
    ) == ["status.active", "status.succeeded", "status.failed"])
}
