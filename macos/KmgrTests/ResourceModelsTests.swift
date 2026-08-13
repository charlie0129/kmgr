import Foundation
import Testing
@testable import KmgrCore

@Test func compactResourceRowRoundTripsWithoutRawObjectData() throws {
    let original = ResourceRow(
        identity: identity("pod-1", name: "api"),
        cells: [
            Cell(
                columnID: "cpu",
                displayText: "420m / 500m / 1",
                typedValue: .usage(
                    ResourceUsageValue(
                        usage: 0.420,
                        request: 0.500,
                        limit: 1,
                        sortValue: 0.84,
                        unit: "cores"
                    )
                ),
                tooltip: "CPU usage 420 millicores",
                severity: .informational
            ),
            Cell(
                columnID: "large",
                displayText: "9007199254740993",
                typedValue: .integer(9_007_199_254_740_993)
            ),
            Cell(
                columnID: "memory",
                displayText: "1Gi",
                typedValue: .quantity(KubernetesQuantityValue(
                    exact: "1Gi", display: "1Gi", sortValue: 1_073_741_824
                ))
            ),
        ]
    )

    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ResourceRow.self, from: encoded)

    #expect(decoded == original)
    #expect(decoded.identity.uid == "pod-1")
    #expect(decoded["cpu"]?.displayText == "420m / 500m / 1")
    #expect(decoded["large"]?.typedValue == .integer(9_007_199_254_740_993))
    #expect(decoded["memory"]?.typedValue == .quantity(KubernetesQuantityValue(
        exact: "1Gi", display: "1Gi", sortValue: 1_073_741_824
    )))
    #expect(String(decoding: encoded, as: UTF8.self).contains("rawObject") == false)
}
