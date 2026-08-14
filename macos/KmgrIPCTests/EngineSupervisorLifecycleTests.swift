import Foundation
@testable import KmgrIPC
import KmgrProto
import Testing

@Suite("Engine supervisor lifecycle")
@MainActor
struct EngineSupervisorLifecycleTests {
    @Test("protocol 1.0 engine is rejected before optional RPCs are used")
    func oldProtocolMinorIsRejected() {
        var response = compatibleHandshakeResponse()
        response.negotiatedProtocol.minor = 0
        do {
            _ = try EngineSupervisor.validateHandshakeResponse(response)
            Issue.record("Protocol 1.0 was accepted")
        } catch EngineSupervisorError.incompatibleProtocol(let message) {
            #expect(message.contains("1.1"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("workload log resolution capability is required")
    func missingResolutionCapabilityIsRejected() {
        var response = compatibleHandshakeResponse()
        response.capabilities = response.capabilities.filter {
            $0.name != "logs.resolve-sources"
        }
        do {
            _ = try EngineSupervisor.validateHandshakeResponse(response)
            Issue.record("Missing workload resolution capability was accepted")
        } catch EngineSupervisorError.incompatibleProtocol(let message) {
            #expect(message.contains("logs.resolve-sources"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("helper launch arguments include validated behavior settings")
    func helperArgumentsIncludeBehaviorSettings() {
        let configuration = EngineSupervisor.Configuration(
            helperURL: URL(fileURLWithPath: "/tmp/kmgr-engine"),
            columnsConfigurationPath: "/tmp/columns.yaml",
            metricsRefreshSeconds: 45,
            logLevel: " DEBUG "
        )
        #expect(configuration.helperArguments(appendingTo: ["--socket", "/tmp/a.sock"]) == [
            "--socket", "/tmp/a.sock",
            "--columns", "/tmp/columns.yaml",
            "--metrics-refresh", "45s",
            "--log-level", "debug",
        ])
    }

    @Test("invalid optional behavior settings are not forwarded")
    func invalidOptionalBehaviorSettingsAreNotForwarded() {
        let configuration = EngineSupervisor.Configuration(
            helperURL: URL(fileURLWithPath: "/tmp/kmgr-engine"),
            columnsConfigurationPath: "",
            metricsRefreshSeconds: 0,
            logLevel: "verbose"
        )
        #expect(configuration.helperArguments(appendingTo: ["base"]) == ["base"])
    }

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

@MainActor
private func compatibleHandshakeResponse() -> Kmgr_V1_HandshakeResponse {
    var response = Kmgr_V1_HandshakeResponse()
    response.engineVersion = "test"
    response.engineInstanceID = "engine-test"
    response.negotiatedProtocol.major = EngineSupervisor.protocolMajor
    response.negotiatedProtocol.minor = EngineSupervisor.requiredProtocolMinor
    var resolution = Kmgr_V1_Capability()
    resolution.name = "logs.resolve-sources"
    resolution.version = 1
    response.capabilities = [resolution]
    return response
}
