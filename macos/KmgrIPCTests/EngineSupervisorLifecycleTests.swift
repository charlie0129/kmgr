import Foundation
@testable import KmgrIPC
import KmgrCore
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
            nodeShellStartupTimeoutSeconds: 90,
            advancedPerformance: AdvancedPerformancePreferences(
                viewReleaseGraceSeconds: 30,
                projectionWorkerLimit: 11,
                globalWarmCacheViewLimit: 48,
                globalWarmCacheObjectLimit: 500_000,
                globalWarmCacheMemoryPercent: 30,
                authorityWarmCacheViewLimit: 12,
                authorityWarmCacheObjectLimit: 150_000,
                authorityWarmCacheMemoryPercent: 10,
                kubernetesQPS: 12.5,
                kubernetesBurst: 37,
                kubernetesListPageSize: 750,
                clusterConnectionTimeoutSeconds: 45,
                kubernetesRequestTimeoutSeconds: 75,
                idleMetricProviderLimit: 5,
                idleMetricSampleLimit: 75_000,
                exactPodMetricsEntryLimit: 80_000,
                exactPodMetricsSampleLimit: 70_000,
                exactPodMetricsDetailEntryLimit: 128,
                exactPodMetricsGETConcurrency: 12,
                logQueueRecordLimit: 8_192,
                logQueueByteLimit: 12 << 20,
                logSourceOpenConcurrency: 9
            ),
            logLevel: " DEBUG "
        )
        #expect(configuration.helperArguments(appendingTo: ["--socket", "/tmp/a.sock"]) == [
            "--socket", "/tmp/a.sock",
            "--columns", "/tmp/columns.yaml",
            "--metrics-refresh", "45s",
            "--node-shell-startup-timeout", "90s",
            "--view-release-delay", "30s",
            "--projection-workers", "11",
            "--warm-cache-global-views", "48",
            "--warm-cache-global-objects", "500000",
            "--warm-cache-global-memory-percent", "30",
            "--warm-cache-authority-views", "12",
            "--warm-cache-authority-objects", "150000",
            "--warm-cache-authority-memory-percent", "10",
            "--kubernetes-qps", "12.5",
            "--kubernetes-burst", "37",
            "--kubernetes-list-page-size", "750",
            "--cluster-connection-timeout", "45s",
            "--metrics-idle-provider-limit", "5",
            "--metrics-idle-sample-limit", "75000",
            "--pod-metrics-cache-entry-limit", "80000",
            "--pod-metrics-positive-sample-limit", "70000",
            "--pod-metrics-detail-entry-limit", "128",
            "--pod-metrics-get-concurrency", "12",
            "--log-queue-records", "8192",
            "--log-queue-bytes", "12582912",
            "--log-source-open-concurrency", "9",
            "--log-level", "debug",
        ])
    }

    @Test("invalid optional behavior settings are not forwarded")
    func invalidOptionalBehaviorSettingsAreNotForwarded() {
        let configuration = EngineSupervisor.Configuration(
            helperURL: URL(fileURLWithPath: "/tmp/kmgr-engine"),
            columnsConfigurationPath: "",
            metricsRefreshSeconds: 0,
            advancedPerformance: AdvancedPerformancePreferences(
                globalWarmCacheMemoryPercent: 0
            ),
            logLevel: "verbose"
        )
        #expect(configuration.helperArguments(appendingTo: ["base"]) == ["base"])
    }

    @Test("stable ready generations reset the consecutive restart budget")
    func stableReadyGenerationResetsRestartBudget() {
        let policy = EngineRestartPolicy(
            maximumAttempts: 3,
            initialDelayMilliseconds: 0,
            maximumDelayMilliseconds: 0
        )
        let stabilityDuration = Duration.seconds(30)
        var budget = EngineRestartBudget()

        #expect(budget.recordFailure(
            precedingReadyDuration: nil,
            stabilityDuration: stabilityDuration
        ) == 1)
        #expect(budget.recordFailure(
            precedingReadyDuration: .seconds(29),
            stabilityDuration: stabilityDuration
        ) == 2)

        // Reaching the boundary clears both the failure count and its
        // accumulated backoff. Widely separated crashes remain first failures
        // rather than eventually exhausting a lifetime budget.
        for _ in 0..<6 {
            let failure = budget.recordFailure(
                precedingReadyDuration: .seconds(30),
                stabilityDuration: stabilityDuration
            )
            #expect(failure == 1)
            #expect(policy.delayMilliseconds(afterFailure: failure) == 0)
        }
    }

    @Test("startup and short-ready failures exhaust the consecutive budget")
    func consecutiveFailuresExhaustRestartBudget() {
        let policy = EngineRestartPolicy(
            maximumAttempts: 3,
            initialDelayMilliseconds: 10,
            maximumDelayMilliseconds: 40
        )
        let stabilityDuration = Duration.seconds(30)
        var budget = EngineRestartBudget()

        let startupFailure = budget.recordFailure(
            precedingReadyDuration: nil,
            stabilityDuration: stabilityDuration
        )
        #expect(startupFailure == 1)
        #expect(policy.delayMilliseconds(afterFailure: startupFailure) == 10)

        let firstCrash = budget.recordFailure(
            precedingReadyDuration: .seconds(1),
            stabilityDuration: stabilityDuration
        )
        #expect(firstCrash == 2)
        #expect(policy.delayMilliseconds(afterFailure: firstCrash) == 20)

        let secondCrash = budget.recordFailure(
            precedingReadyDuration: .seconds(29),
            stabilityDuration: stabilityDuration
        )
        #expect(secondCrash == 3)
        #expect(policy.delayMilliseconds(afterFailure: secondCrash) == nil)
    }

    @Test("consecutive startup failures stop after the launch-attempt budget")
    func consecutiveStartupFailuresStopSupervisor() async throws {
        let fixtureDirectory = URL(
            fileURLWithPath: "/tmp/ks.\(String(UUID().uuidString.prefix(8)))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let countURL = fixtureDirectory.appendingPathComponent("launch-count")
        let helper = fixtureDirectory.appendingPathComponent("failing-helper")
        let script = """
        #!/bin/sh
        set -eu
        count_file='\(countURL.path)'
        count=0
        if [ -f "$count_file" ]; then
          count=$(tr -d '\\n' < "$count_file")
        fi
        count=$((count + 1))
        printf '%s\\n' "$count" > "$count_file"
        exit 17
        """
        try Data(script.utf8).write(to: helper, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helper.path
        )

        let supervisor = EngineSupervisor(configuration: .init(
            helperURL: helper,
            temporaryDirectoryURL: fixtureDirectory,
            restartPolicy: .init(
                maximumAttempts: 3,
                initialDelayMilliseconds: 0,
                maximumDelayMilliseconds: 0
            ),
            restartStabilityDuration: .seconds(30),
            startupTimeout: .milliseconds(100),
            handshakeTimeout: .milliseconds(40),
            shutdownTimeout: .milliseconds(100)
        ))
        supervisor.start()

        for _ in 0..<400 {
            if case .failed = supervisor.state { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard case .failed(let message) = supervisor.state else {
            Issue.record("Expected failed state, got \(supervisor.state)")
            await supervisor.shutdown()
            return
        }
        #expect(message.contains("status 17"))
        let launches = try String(contentsOf: countURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(launches == "3")

        await supervisor.shutdown()
        #expect(supervisor.state == .stopped)
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

    @Test("ordinary RPC connection stays unavailable until handshake succeeds")
    func connectionIsNotPublishedBeforeHandshake() async throws {
        // Unix-domain sockets have a small path limit on Darwin, so keep this
        // fixture directly under /tmp just like the production endpoint tests.
        let fixtureDirectory = URL(
            fileURLWithPath: "/tmp/ks.\(String(UUID().uuidString.prefix(8)))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let helper = fixtureDirectory.appendingPathComponent("sleeping-helper")
        try Data("#!/bin/sh\nsleep 2\n".utf8).write(to: helper, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helper.path
        )
        let supervisor = EngineSupervisor(configuration: .init(
            helperURL: helper,
            temporaryDirectoryURL: fixtureDirectory,
            restartPolicy: .init(
                maximumAttempts: 1,
                initialDelayMilliseconds: 0,
                maximumDelayMilliseconds: 0
            ),
            startupTimeout: .milliseconds(250),
            handshakeTimeout: .milliseconds(40),
            shutdownTimeout: .milliseconds(100)
        ))

        supervisor.start()
        do {
            // Give runGeneration enough time to construct its authenticated
            // gRPC client. The helper deliberately never creates its socket,
            // so a successful test must keep that client private throughout
            // startup.
            try await Task.sleep(for: .milliseconds(80))
        } catch {
            await supervisor.shutdown()
            throw error
        }
        guard case .starting = supervisor.state else {
            Issue.record("Expected starting state, got \(supervisor.state)")
            await supervisor.shutdown()
            return
        }
        do {
            _ = try supervisor.connection.engineClient()
            Issue.record("Ordinary RPC connection was published before handshake")
        } catch EngineConnectionError.unavailable {
            // Expected while the protocol handshake is still pending.
        } catch {
            Issue.record("Unexpected connection error: \(error)")
        }

        await supervisor.shutdown()
        #expect(supervisor.state == .stopped)
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
