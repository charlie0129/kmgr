import Foundation
@testable import KmgrIPC
import Testing

@Suite("Engine supervisor lifecycle")
@MainActor
struct EngineSupervisorLifecycleTests {
    @Test("missing helper reaches a bounded failure and shutdown is clean")
    func missingHelperFailsWithoutRestartLoop() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgr-missing-\(UUID().uuidString)")
        let supervisor = EngineSupervisor(
            configuration: .init(
                helperURL: missing,
                restartPolicy: .init(
                    maximumAttempts: 1,
                    initialDelayMilliseconds: 0,
                    maximumDelayMilliseconds: 0
                ),
                startupTimeout: .milliseconds(100),
                handshakeTimeout: .milliseconds(50),
                shutdownTimeout: .milliseconds(100)
            )
        )

        supervisor.start()
        for _ in 0..<100 {
            if case .failed = supervisor.state { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard case .failed(let message) = supervisor.state else {
            Issue.record("Expected failed state, got \(supervisor.state)")
            await supervisor.shutdown()
            return
        }
        #expect(message.contains("missing"))
        await supervisor.shutdown()
        #expect(supervisor.state == .stopped)
        #expect(throws: EngineConnectionError.self) {
            try supervisor.connection.engineClient()
        }
    }

    @Test("start is idempotent while supervision is active")
    func repeatedStartDoesNotCreateAnotherLoop() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgr-missing-\(UUID().uuidString)")
        let supervisor = EngineSupervisor(
            configuration: .init(
                helperURL: missing,
                restartPolicy: .init(
                    maximumAttempts: 2,
                    initialDelayMilliseconds: 500,
                    maximumDelayMilliseconds: 500
                )
            )
        )
        supervisor.start()
        supervisor.start()
        for _ in 0..<100 {
            if case .restarting(let attempt, _) = supervisor.state {
                #expect(attempt == 2)
                break
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        await supervisor.shutdown()
        #expect(supervisor.state == .stopped)
    }

    @Test("state observers receive current state and can unsubscribe")
    func stateObserversReceiveCurrentStateAndCanUnsubscribe() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmgr-missing-\(UUID().uuidString)")
        let supervisor = EngineSupervisor(configuration: .init(
            helperURL: missing,
            restartPolicy: .init(
                maximumAttempts: 1,
                initialDelayMilliseconds: 0,
                maximumDelayMilliseconds: 0
            )
        ))
        var observed: [EngineConnectionState] = []
        let token = supervisor.observeState { observed.append($0) }
        #expect(observed == [.stopped])

        supervisor.start()
        for _ in 0..<100 {
            if case .failed = supervisor.state { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(observed.contains { if case .starting = $0 { true } else { false } })
        #expect(observed.contains { if case .failed = $0 { true } else { false } })

        supervisor.removeStateObserver(token)
        let count = observed.count
        await supervisor.shutdown()
        #expect(observed.count == count)
    }
}
