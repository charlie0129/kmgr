import Foundation
import Testing
@testable import KmgrCore

@Test func terminalEOFClosesOnlyForConfirmedExitInTheSameGeneration() {
    var policy = TerminalEOFAutoClosePolicy()
    policy.beginGeneration(7)
    policy.observeInput(Data([0x04]), generation: 7)

    let failedClose = policy.shouldClose(
        after: ExecStatus(state: .failed, statusReason: "disconnected"),
        generation: 7
    )
    let cancelledClose = policy.shouldClose(
        after: ExecStatus(state: .cancelled, statusReason: "cancelled"),
        generation: 7
    )
    let otherGenerationClose = policy.shouldClose(
        after: ExecStatus(state: .exited, exitCode: 0),
        generation: 8
    )
    let confirmedClose = policy.shouldClose(
        after: ExecStatus(state: .exited, exitCode: 0),
        generation: 7
    )
    let repeatedClose = policy.shouldClose(
        after: ExecStatus(state: .exited, exitCode: 0),
        generation: 7
    )
    #expect(!failedClose)
    #expect(!cancelledClose)
    #expect(!otherGenerationClose)
    #expect(confirmedClose)
    #expect(!repeatedClose)
}

@Test func laterTerminalInputOrReconnectClearsPendingEOF() {
    var policy = TerminalEOFAutoClosePolicy()
    policy.observeInput(Data([0x04]), generation: 1)
    policy.observeInput(Data("x".utf8), generation: 1)
    let afterInputClose = policy.shouldClose(
        after: ExecStatus(state: .exited, exitCode: 0),
        generation: 1
    )
    #expect(!afterInputClose)

    policy.observeInput(Data([0x04]), generation: 1)
    policy.beginGeneration(2)
    let afterReconnectClose = policy.shouldClose(
        after: ExecStatus(state: .exited, exitCode: 0),
        generation: 2
    )
    #expect(!afterReconnectClose)
}
