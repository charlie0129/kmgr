import Foundation
import KmgrCore
import Testing

private let completionColumns = [
    "name", "block", "status", "field:custom", "trace:phase", "labelSelector",
]

private func completionRange(
    _ expression: String,
    _ partial: String? = nil
) -> NSRange {
    let text = expression as NSString
    if let partial {
        return text.range(of: partial, options: [],
            range: NSRange(location: 0, length: text.length))
    }
    return NSRange(location: 0, length: text.length)
}

@Test func resourceFilterCompletionOffersReservedPrefixesCaseInsensitively() {
    let completions = ResourceFilterCompletionCatalog.completions(
        in: "statu",
        partialWordRange: completionRange("statu"),
        columnIDs: completionColumns
    )
    #expect(completions == ["status:"])
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "stt",
        partialWordRange: completionRange("stt"),
        columnIDs: completionColumns
    ).isEmpty)
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "N",
        partialWordRange: completionRange("N"),
        columnIDs: completionColumns
    ).prefix(3) == ["namespace:", "name:", "ns:"])
}

@Test func resourceFilterCompletionOffersActiveColumnShorthand() {
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "blo",
        partialWordRange: completionRange("blo"),
        columnIDs: completionColumns
    ) == ["block:"])
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "trace:",
        partialWordRange: completionRange("trace:"),
        columnIDs: completionColumns
    ) == ["trace:phase:"])
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "block:",
        partialWordRange: completionRange("block:"),
        columnIDs: completionColumns
    ).isEmpty)
}

@Test func resourceFilterCompletionAcceptanceQuotesValuesAfterCompletePrefixes() throws {
    let statusExpression = "api statu"
    let statusRange = completionRange(statusExpression, "statu")
    let status = try #require(ResourceFilterCompletionCatalog.acceptedCompletion(
        "status:",
        in: statusExpression,
        partialWordRange: statusRange
    ))
    #expect(status.replacement == "status:\"\"")
    #expect(status.caretUTF16Offset == "status:\"".utf16.count)
    #expect((statusExpression as NSString).replacingCharacters(
        in: statusRange,
        with: status.replacement
    ) == "api status:\"\"")

    let intermediate = try #require(ResourceFilterCompletionCatalog.acceptedCompletion(
        "column:",
        in: "colu",
        partialWordRange: completionRange("colu")
    ))
    #expect(intermediate.replacement == "column:")
    #expect(intermediate.caretUTF16Offset == "column:".utf16.count)

    let explicitExpression = "api column:na"
    let explicitRange = completionRange(explicitExpression, "na")
    let explicit = try #require(ResourceFilterCompletionCatalog.acceptedCompletion(
        "name:",
        in: explicitExpression,
        partialWordRange: explicitRange
    ))
    #expect(explicit.replacement == "name:\"\"")
    #expect(explicit.caretUTF16Offset == "name:\"".utf16.count)
    #expect((explicitExpression as NSString).replacingCharacters(
        in: explicitRange,
        with: explicit.replacement
    ) == "api column:name:\"\"")
}

@Test func resourceFilterCompletionNarrowsActiveNodeColumnPrefix() {
    let columns = ["node"]
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "n",
        partialWordRange: completionRange("n"),
        columnIDs: columns
    ) == ["namespace:", "name:", "ns:", "node:"])
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "no",
        partialWordRange: completionRange("no"),
        columnIDs: columns
    ) == ["node:"])
}

@Test func resourceFilterCompletionUsesExplicitColumnForReservedIDs() {
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "column:na",
        partialWordRange: NSRange(location: "column:".utf16.count, length: 2),
        columnIDs: completionColumns
    ) == ["name:"])
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "column:",
        partialWordRange: completionRange("column:"),
        columnIDs: completionColumns
    ).prefix(3) == ["column:name:", "column:block:", "column:status:"])
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "column:",
        partialWordRange: NSRange(location: "column:".utf16.count, length: 0),
        columnIDs: completionColumns
    ).prefix(3) == ["name:", "block:", "status:"])
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "na",
        partialWordRange: completionRange("na"),
        columnIDs: completionColumns
    ) == ["namespace:", "name:"])
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "labelS",
        partialWordRange: completionRange("labelS"),
        columnIDs: completionColumns
    ) == ["labelSelector:"])
}

@Test func resourceFilterCompletionPreservesOtherTermsAndUsesRelativeRange() {
    let expression = "api blo"
    let partial = (expression as NSString).range(of: "blo")
    let completions = ResourceFilterCompletionCatalog.completions(
        in: expression,
        partialWordRange: partial,
        columnIDs: completionColumns
    )
    #expect(completions == ["block:"])
    #expect((expression as NSString).replacingCharacters(
        in: partial,
        with: completions[0]
    ) == "api block:")

    let explicit = "api column:na"
    let explicitPartial = (explicit as NSString).range(of: "na")
    let explicitCompletions = ResourceFilterCompletionCatalog.completions(
        in: explicit,
        partialWordRange: explicitPartial,
        columnIDs: completionColumns
    )
    #expect(explicitCompletions == ["name:"])
    #expect((explicit as NSString).replacingCharacters(
        in: explicitPartial,
        with: explicitCompletions[0]
    ) == "api column:name:")
}

@Test func resourceFilterCompletionSuppressesSelectorBodiesAndValues() {
    for expression in [
        "labelSelector:app",
        "labelSelector:\"app in (api,worker)\"",
        "fieldSelector:metadata.name",
        "name:api",
        "field:metadata.",
        "label:app",
        "status:Ready",
    ] {
        #expect(ResourceFilterCompletionCatalog.completions(
            in: expression,
            partialWordRange: completionRange(expression),
            columnIDs: completionColumns
        ).isEmpty, Comment(rawValue: expression))
    }
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "labelSelec",
        partialWordRange: completionRange("labelSelec"),
        columnIDs: completionColumns
    ) == ["labelSelector:"])
}

@Test func resourceFilterCompletionKeepsColumnIDsCaseSensitiveAndSupportsColons() {
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "column:Na",
        partialWordRange: completionRange("column:Na"),
        columnIDs: ["name"]
    ).isEmpty)
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "column:trace:",
        partialWordRange: NSRange(location: "column:trace:".utf16.count, length: 0),
        columnIDs: ["trace:phase", "trace:other"]
    ) == ["phase:", "other:"])
}

@Test func resourceFilterCompletionRejectsQuotedEscapedAndInvalidRanges() {
    for expression in [
        "foo\\ bar",
        "\"blo",
        "column:\"na",
        "labelSelector:\"app in (api,worker)\"",
    ] {
        #expect(ResourceFilterCompletionCatalog.completions(
            in: expression,
            partialWordRange: completionRange(expression),
            columnIDs: completionColumns
        ).isEmpty, Comment(rawValue: expression))
    }
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "blo",
        partialWordRange: NSRange(location: NSNotFound, length: 0),
        columnIDs: completionColumns
    ).isEmpty)
    #expect(ResourceFilterCompletionCatalog.completions(
        in: "🔥blo",
        partialWordRange: NSRange(location: 1, length: 1),
        columnIDs: completionColumns
    ).isEmpty)
}
