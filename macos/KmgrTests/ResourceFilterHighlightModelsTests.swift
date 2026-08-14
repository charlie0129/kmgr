import Foundation
import KmgrCore
import Testing

@Test func simpleResourceFilterHighlightRecognizesBareAndNameTerms() {
    #expect(ResourceFilterHighlightParser.parse("api") == ResourceFilterHighlight(
        term: "api",
        columnID: nil
    ))
    #expect(ResourceFilterHighlightParser.parse("  NAME:api-server  ")
        == ResourceFilterHighlight(term: "api-server", columnID: "name"))
    #expect(ResourceFilterHighlightParser.parse("api")?.applies(to: "status") == true)
    #expect(ResourceFilterHighlightParser.parse("name:api")?.applies(to: "status") == false)
    #expect(ResourceFilterHighlightParser.parse("name:api")?.applies(to: "name") == true)
}

@Test func complexOrUnboundedResourceFiltersAreNotVisuallyMisrepresented() {
    for expression in [
        "", "api running", "namespace:team", "label:app==api",
        "field:metadata.name=api", "name:\"api\"", "name:api\\ server",
        "name:api=value", "name:",
        String(repeating: "x", count: ResourceFilterHighlightParser.maximumTermUTF8Bytes + 1),
    ] {
        #expect(ResourceFilterHighlightParser.parse(expression) == nil, "\(expression)")
    }
}
