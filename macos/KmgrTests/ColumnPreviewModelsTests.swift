import Foundation
import Testing
@testable import KmgrCore

@Test func columnPreviewValidationIgnoresStaleSuccessAndFailure() {
    var state = ColumnPreviewValidationState()
    let firstRevision = state.beginRevision()
    let secondRevision = state.beginRevision()

    let acceptedStaleResult = state.accept(previewResult(text: "stale"), for: firstRevision)
    let rejectedStaleResult = state.reject("also stale", for: firstRevision)
    #expect(!acceptedStaleResult)
    #expect(!rejectedStaleResult)
    #expect(state.phase == .validating)
    #expect(!state.canCommit)

    let current = previewResult(text: "current")
    let acceptedCurrentResult = state.accept(current, for: secondRevision)
    #expect(acceptedCurrentResult)
    #expect(state.phase == .succeeded(current))
    #expect(state.canCommit)
}

@Test func columnPreviewRequiresLatestAuthoritativeSuccessToCommit() {
    var state = ColumnPreviewValidationState()
    let validRevision = state.beginRevision()
    #expect(!state.canCommit)
    let acceptedValidResult = state.accept(previewResult(text: "ready"), for: validRevision)
    #expect(acceptedValidResult)
    #expect(state.canCommit)

    _ = state.beginRevision(localFailure: "Expression is required.")
    #expect(state.phase == .localFailure("Expression is required."))
    #expect(!state.canCommit)

    let failedRevision = state.beginRevision()
    let rejectedFailedResult = state.reject("CEL compilation failed.", for: failedRevision)
    #expect(rejectedFailedResult)
    #expect(state.phase == .failed("CEL compilation failed."))
    #expect(!state.canCommit)
}

private func previewResult(text: String) -> ColumnPreviewResult {
    ColumnPreviewResult(
        requestID: UUID().uuidString,
        celEnvironment: ColumnConfigurationSchema.celEnvironment,
        preview: Cell(columnID: "team", displayText: text),
        usedSampleObject: true
    )
}
