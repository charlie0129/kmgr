import Foundation
import KmgrCore
import Testing

@Suite("User-facing error presentation")
struct UserFacingErrorPresentationTests {
    @Test("structured Kubernetes context remains visible")
    func structuredContextIsPresented() {
        let issue = ClusterManagerIssue(
            category: .validation,
            reason: "ServerValidationFailed",
            message: "The API server rejected the object.",
            httpStatusCode: 422,
            retryable: true,
            retryAfterMilliseconds: 1_500,
            contextName: "production",
            operation: "update Deployment",
            kubernetesStatus: .init(
                reason: "Invalid",
                causes: [
                    .init(
                        reason: "FieldValueInvalid",
                        message: "must be greater than or equal to zero",
                        field: "spec.replicas"
                    ),
                    .init(reason: "FieldValueRequired", field: "spec.selector"),
                ]
            )
        )

        let presentation = issue.userFacingPresentation

        #expect(presentation.title == "Validation failed")
        #expect(presentation.message == "The API server rejected the object.")
        #expect(presentation.metadata.contains("Operation: update Deployment"))
        #expect(presentation.metadata.contains("Context: production"))
        #expect(presentation.metadata.contains("Reason: ServerValidationFailed"))
        #expect(presentation.metadata.contains("API reason: Invalid"))
        #expect(presentation.metadata.contains("HTTP 422"))
        #expect(presentation.metadata.contains("Retryable after"))
        #expect(presentation.causes == [
            "Field spec.replicas · FieldValueInvalid: must be greater than or equal to zero",
            "Field spec.selector · FieldValueRequired",
        ])
        #expect(presentation.inlineText.contains("Causes: Field spec.replicas"))
        #expect(presentation.detailedText.contains("• Field spec.selector"))

        let nonRetryable = UserFacingErrorPresentation(ClusterManagerIssue(
            category: .authorization,
            message: "This request is forbidden."
        ))
        #expect(nonRetryable.metadata == "Not retryable")
    }

    @Test("server-controlled text and cause cardinality are bounded")
    func outputIsBounded() {
        let oversized = String(repeating: "value ", count: 2_000)
        let issue = ClusterManagerIssue(
            category: .unavailable,
            reason: oversized,
            message: oversized,
            httpStatusCode: 503,
            retryable: true,
            contextName: oversized,
            operation: oversized,
            kubernetesStatus: .init(causes: (0..<12).map { index in
                .init(reason: "Cause\(index)", message: oversized, field: "spec.field\(index)")
            })
        )

        let presentation = UserFacingErrorPresentation(issue)

        #expect(presentation.message.count <= UserFacingErrorPresentation.maximumMessageCharacters)
        #expect(presentation.metadata.count <= UserFacingErrorPresentation.maximumMetadataCharacters)
        #expect(presentation.causes.count == UserFacingErrorPresentation.maximumPresentedCauses + 1)
        #expect(presentation.causes.dropLast().allSatisfy {
            $0.count <= UserFacingErrorPresentation.maximumCauseCharacters
        })
        #expect(presentation.causes.last == "+9 more causes")
        #expect(presentation.inlineText.count <= UserFacingErrorPresentation.maximumInlineCharacters)
        #expect(presentation.detailedText.count <= UserFacingErrorPresentation.maximumDetailedCharacters)
    }

    @Test("generic errors use the same compact bounds")
    func genericErrorsAreBounded() {
        let presentation = UserFacingErrorPresentation(
            TestError(message: "  first\u{0000} line\u{001B}\n\nsecond line  ")
        )

        #expect(presentation.title == "Error")
        #expect(presentation.inlineText == "first line second line")
        #expect(!presentation.detailedText.contains("\u{0000}"))
        #expect(!presentation.detailedText.contains("\u{001B}"))
        #expect(presentation.metadata.isEmpty)
        #expect(presentation.causes.isEmpty)
    }
}

private struct TestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
