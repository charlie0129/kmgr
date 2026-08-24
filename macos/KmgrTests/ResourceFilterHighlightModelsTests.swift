import Foundation
import KmgrCore
import Testing

@Test func resourceFilterHighlightRecognizesGlobalAndStructuredTerms() {
    #expect(ResourceFilterHighlightParser.parse("api") == [
        ResourceFilterHighlight(term: "api", columnID: nil),
    ])
    #expect(ResourceFilterHighlightParser.parse(
        "NAME:api-server namespace:team status:Ready"
    ) == [
        ResourceFilterHighlight(term: "api-server", columnID: "name"),
        ResourceFilterHighlight(term: "team", columnID: "namespace"),
        ResourceFilterHighlight(term: "Ready", columnID: "status"),
    ])
    let name = ResourceFilterHighlightParser.parse("name:api").first
    #expect(name?.applies(to: "status") == false)
    #expect(name?.applies(to: "name") == true)
}

@Test func mixedNativeSelectorAndBareTermsHighlightOnlyBareTerms() {
    let expression = #"labelSelector:"app=tob-glm-5p3-flash-lb" flash-lb"#
    #expect(ResourceFilterHighlightParser.parse(expression) == [
        ResourceFilterHighlight(term: "flash-lb", columnID: nil),
    ])
    let mixed = #"labelSelector:"app=tob-glm-5p3-flash-lb" flash-lb block:ready"#
    #expect(ResourceFilterHighlightParser.parse(
        mixed,
        columnIDs: ["name", "block"]
    ) == [
        ResourceFilterHighlight(term: "flash-lb", columnID: nil),
        ResourceFilterHighlight(term: "ready", columnID: "block"),
    ])
}

@Test func resourceFilterHighlightSupportsColumnShorthandAndExplicitForm() {
    let columns = ["name", "block", "field:custom"]
    #expect(ResourceFilterHighlightParser.parse(
        "block:ready column:block:healthy",
        columnIDs: columns
    ) == [
        ResourceFilterHighlight(term: "ready", columnID: "block"),
        ResourceFilterHighlight(term: "healthy", columnID: "block"),
    ])
    #expect(ResourceFilterHighlightParser.parse(
        "field:ignored column:field:custom:value",
        columnIDs: columns
    ) == [
        ResourceFilterHighlight(term: "value", columnID: "field:custom"),
    ])
}

@Test func reservedPrefixesRequireExplicitColumnForm() {
    let columns = ["name", "status", "column"]
    #expect(ResourceFilterHighlightParser.parse(
        "name:api status:Ready column:name:custom",
        columnIDs: columns
    ) == [
        ResourceFilterHighlight(term: "api", columnID: "name"),
        ResourceFilterHighlight(term: "Ready", columnID: "status"),
        ResourceFilterHighlight(term: "custom", columnID: "name"),
    ])
    #expect(ResourceFilterHighlightParser.parse(
        "column:column:value",
        columnIDs: columns
    ) == [
        ResourceFilterHighlight(term: "value", columnID: "column"),
    ])
}

@Test func quotedAndEscapedTermsRemainHighlightable() {
    #expect(ResourceFilterHighlightParser.parse(#""hello world" web\ server"#) == [
        ResourceFilterHighlight(term: "hello world", columnID: nil),
        ResourceFilterHighlight(term: "web server", columnID: nil),
    ])
}

@Test func complexOrUnsupportedFiltersAreNotVisuallyMisrepresented() {
    for expression in [
        "", "label:app==api", "field:metadata.name=api", "text:api",
        "column:block:api", "block:api", "name:",
        String(repeating: "x", count: ResourceFilterHighlightParser.maximumTermUTF8Bytes + 1),
    ] {
        #expect(ResourceFilterHighlightParser.parse(expression) == [], "\(expression)")
    }
    #expect(ResourceFilterHighlightParser.parse(
        #"labelSelector:"app=api" api"#
    ) == [ResourceFilterHighlight(term: "api", columnID: nil)])
}
