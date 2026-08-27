import Foundation
import Testing
@testable import KmgrCore

@Test func objectDataValueCannotEnterRestorationSchema() throws {
    let sensitive = Data("plain secret".utf8)
    let entry = ObjectDataEntry(
        key: "token", kind: .text, value: sensitive,
        byteSize: UInt64(sensitive.count), contentHash: Data([1, 2, 3])
    )
    #expect(entry.value.count == sensitive.count)

    let restoration = ClusterWindowRestorationState(contextName: "prod")
    let encoded = try JSONEncoder().encode(restoration)
    #expect(!encoded.contains(sensitive))
}

@Test func operationTerminalClassificationIsExplicit() {
    #expect(!OperationState.pending.isTerminal)
    #expect(!OperationState.running.isTerminal)
    #expect(OperationState.succeeded.isTerminal)
    #expect(OperationState.partiallySucceeded.isTerminal)
    #expect(OperationState.failed.isTerminal)
    #expect(OperationState.cancelled.isTerminal)
}
