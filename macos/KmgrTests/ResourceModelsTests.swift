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
        ]
    )

    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ResourceRow.self, from: encoded)

    #expect(decoded == original)
    #expect(decoded.identity.uid == "pod-1")
    #expect(decoded["cpu"]?.displayText == "420m / 500m / 1")
    #expect(String(decoding: encoded, as: UTF8.self).contains("rawObject") == false)
}
