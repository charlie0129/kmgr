import Foundation
import Testing
@testable import KmgrCore

@Test func execStatusIdentifiesOnlyFinishedStatesAsTerminal() {
    #expect(!ExecConnectionState.connecting.isTerminal)
    #expect(!ExecConnectionState.running.isTerminal)
    #expect(ExecConnectionState.exited.isTerminal)
    #expect(ExecConnectionState.cancelled.isTerminal)
    #expect(ExecConnectionState.failed.isTerminal)
}

@Test func execServerEventsRetainOpaqueBytesAndCursor() {
    let cursor = StreamCursor(generation: 3, sequence: 42)
    let data = Data([0xff, 0, 0x1b, 0x5b])
    let event = ExecServerEvent.stdout(cursor: cursor, data: data)
    #expect(event.cursor == cursor)
    guard case .stdout(_, let output) = event else {
        Issue.record("expected stdout")
        return
    }
    #expect(output == data)
}
