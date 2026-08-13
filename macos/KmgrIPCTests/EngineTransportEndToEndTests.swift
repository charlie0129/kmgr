import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
@testable import KmgrIPC
import KmgrProto
import Testing
#if canImport(Darwin)
import Darwin
#endif

@Suite("Swift to Go engine transport")
@MainActor
struct EngineTransportEndToEndTests {
    @Test("private UDS authenticates, rejects a bad token, restarts, and shuts down")
    func authenticatedLifecycle() async throws {
        #if canImport(Darwin)
        let fixture = try EngineProcessFixture.create()
        defer { fixture.cleanup() }

        let supervisor = EngineSupervisor(configuration: .init(
            helperURL: fixture.wrapperURL,
            temporaryDirectoryURL: fixture.endpointBaseURL,
            restartPolicy: .init(
                maximumAttempts: 3,
                initialDelayMilliseconds: 10,
                maximumDelayMilliseconds: 10
            ),
            startupTimeout: .seconds(8),
            handshakeTimeout: .seconds(2),
            shutdownTimeout: .seconds(3),
            clientVersion: "ipc-e2e-test",
            columnsConfigurationPath: fixture.columnsURL.path
        ))
        var observedStates: [EngineConnectionState] = []
        let observer = supervisor.observeState { observedStates.append($0) }
        supervisor.start()

        do {
            let first = try await supervisor.waitUntilReady(timeout: .seconds(10))
            #expect(first.protocolMajor == 1)
            #expect(first.capabilities["engine.health"] == 1)

            let firstGeneration = try await fixture.generation(1)
            try await expectBadTokenRejected(socketPath: firstGeneration.socketPath)

            let socketAttributes = try FileManager.default.attributesOfItem(
                atPath: firstGeneration.socketPath
            )
            let directoryAttributes = try FileManager.default.attributesOfItem(
                atPath: URL(fileURLWithPath: firstGeneration.socketPath)
                    .deletingLastPathComponent().path
            )
            #expect((socketAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            try fixture.crash(firstGeneration)

            let second = try await waitForNewGeneration(
                from: supervisor,
                replacing: first.instanceID
            )
            let secondGeneration = try await fixture.generation(2)
            #expect(second.instanceID != first.instanceID)
            #expect(secondGeneration.processID != firstGeneration.processID)
            #expect(secondGeneration.socketPath != firstGeneration.socketPath)
            #expect(!FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: firstGeneration.socketPath)
                    .deletingLastPathComponent().path
            ))

            // This uses the newly installed production connection, proving
            // callers do not retain the dead generation after a helper crash.
            var healthRequest = Kmgr_V1_HealthRequest()
            healthRequest.context = requestContext(id: "health-after-restart")
            var healthOptions = CallOptions.defaults
            healthOptions.timeout = .seconds(2)
            let health: Kmgr_V1_HealthResponse = try await supervisor.connection
                .engineClient()
                .health(healthRequest, options: healthOptions)
            #expect(health.state == .ready)

            await supervisor.shutdown()
            supervisor.removeStateObserver(observer)

            #expect(supervisor.state == .stopped)
            #expect(observedStates.contains {
                if case .disconnected = $0 { true } else { false }
            })
            #expect(observedStates.contains {
                if case .restarting(attempt: 2, _) = $0 { true } else { false }
            })
            #expect(try FileManager.default.contentsOfDirectory(
                atPath: fixture.endpointBaseURL.path
            ).isEmpty)
            #expect(!FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: secondGeneration.socketPath)
                    .deletingLastPathComponent().path
            ))
        } catch {
            await supervisor.shutdown()
            supervisor.removeStateObserver(observer)
            throw error
        }
        #else
        throw EngineTransportEndToEndTestError.unsupportedPlatform
        #endif
    }
}

#if canImport(Darwin)
private struct EngineGeneration {
    let processID: pid_t
    let socketPath: String
}

private struct EngineProcessFixture {
    let rootURL: URL
    let endpointBaseURL: URL
    let stateURL: URL
    let columnsURL: URL
    let wrapperURL: URL

    private static let trackedGenerationLimit = 8

    static func create() throws -> Self {
        let fileManager = FileManager.default
        let rootURL = URL(
            fileURLWithPath: "/tmp/ke.\(String(UUID().uuidString.prefix(8)))",
            isDirectory: true
        )
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: false)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootURL.path
        )

        do {
            let endpointBaseURL = rootURL.appendingPathComponent("endpoints", isDirectory: true)
            let stateURL = rootURL.appendingPathComponent("state", isDirectory: true)
            try fileManager.createDirectory(at: endpointBaseURL, withIntermediateDirectories: false)
            try fileManager.createDirectory(at: stateURL, withIntermediateDirectories: false)

            let helperURL = rootURL.appendingPathComponent("kmgr-engine")
            try buildEngine(at: helperURL)

            let wrapperURL = rootURL.appendingPathComponent("engine-wrapper")
            let isolatedKubeconfigURL = rootURL.appendingPathComponent("no-kubeconfig")
            let wrapper = """
            #!/bin/sh
            set -eu
            state_dir=\(shellQuote(stateURL.path))
            count_file="$state_dir/count"
            generation=0
            if [ -f "$count_file" ]; then
              generation=$(tr -d '\\n' < "$count_file")
            fi
            generation=$((generation + 1))
            printf '%s\\n' "$generation" > "$count_file"
            socket_path=
            previous=
            for argument in "$@"; do
              if [ "$previous" = "--socket" ]; then
                socket_path=$argument
                break
              fi
              previous=$argument
            done
            printf '%s\\n' "$$" > "$state_dir/pid.$generation"
            printf '%s\\n' "$socket_path" > "$state_dir/socket.$generation"
            export KUBECONFIG=\(shellQuote(isolatedKubeconfigURL.path))
            exec \(shellQuote(helperURL.path)) "$@"
            """
            try Data(wrapper.utf8).write(to: wrapperURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: wrapperURL.path
            )

            return Self(
                rootURL: rootURL,
                endpointBaseURL: endpointBaseURL,
                stateURL: stateURL,
                columnsURL: rootURL.appendingPathComponent("no-columns.yaml"),
                wrapperURL: wrapperURL
            )
        } catch {
            try? fileManager.removeItem(at: rootURL)
            throw error
        }
    }

    func generation(_ number: Int) async throws -> EngineGeneration {
        let deadline = ContinuousClock.now + .seconds(3)
        let pidURL = stateURL.appendingPathComponent("pid.\(number)")
        let socketURL = stateURL.appendingPathComponent("socket.\(number)")
        while ContinuousClock.now < deadline {
            if let pidText = try? String(contentsOf: pidURL, encoding: .utf8),
                let processID = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
                let socketPath = try? String(contentsOf: socketURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !socketPath.isEmpty
            {
                return EngineGeneration(processID: processID, socketPath: socketPath)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw EngineTransportEndToEndTestError.fixtureTimedOut("generation \(number)")
    }

    func crash(_ generation: EngineGeneration) throws {
        guard generation.processID > 1, owns(processID: generation.processID)
        else {
            throw EngineTransportEndToEndTestError.unrecognizedHelperProcess
        }
        guard Darwin.kill(generation.processID, SIGKILL) == 0 else {
            throw EngineTransportEndToEndTestError.signalFailed(errno)
        }
    }

    func cleanup() {
        for number in 1...Self.trackedGenerationLimit {
            let pidURL = stateURL.appendingPathComponent("pid.\(number)")
            guard let pidText = try? String(contentsOf: pidURL, encoding: .utf8),
                let processID = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
                processID > 1,
                Darwin.kill(processID, 0) == 0,
                owns(processID: processID)
            else { continue }
            _ = Darwin.kill(processID, SIGKILL)
        }
        guard rootURL.deletingLastPathComponent().path == "/tmp",
            rootURL.lastPathComponent.hasPrefix("ke.")
        else { return }
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func owns(processID: pid_t) -> Bool {
        let expectedPath = rootURL.appendingPathComponent("kmgr-engine")
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard let actualPath = executablePath(processID) else { return false }
        return URL(fileURLWithPath: actualPath)
            .resolvingSymlinksInPath().standardizedFileURL.path == expectedPath
    }

    private static func buildEngine(at outputURL: URL) throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KmgrIPCTests
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // repository root
        let process = Process()
        let diagnostics = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "go", "build", "-trimpath", "-o", outputURL.path,
            "./backend/cmd/kmgr-engine",
        ]
        process.currentDirectoryURL = repositoryURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = diagnostics
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = try diagnostics.fileHandleForReading.readToEnd() ?? Data()
            throw EngineTransportEndToEndTestError.engineBuildFailed(
                String(decoding: data, as: UTF8.self)
            )
        }
    }
}

private func expectBadTokenRejected(socketPath: String) async throws {
    let transport = try HTTP2ClientTransport.Posix(
        target: .unixDomainSocket(path: socketPath),
        transportSecurity: .plaintext
    )
    let client = GRPCClient(
        transport: transport,
        interceptors: [
            BearerTokenInterceptor(authorizationValue: "Bearer \(String(repeating: "b", count: 64))")
        ]
    )
    let connections = Task.detached {
        try await client.runConnections()
    }
    defer {
        client.beginGracefulShutdown()
        connections.cancel()
    }

    var request = Kmgr_V1_HandshakeRequest()
    request.context = requestContext(id: "bad-token")
    request.clientProtocol.major = 1
    request.clientProtocol.minor = 0
    request.clientVersion = "ipc-e2e-test"
    var options = CallOptions.defaults
    options.timeout = .seconds(2)
    options.waitForReady = false
    do {
        let _: Kmgr_V1_HandshakeResponse = try await Kmgr_V1_EngineService.Client(
            wrapping: client
        ).handshake(request, options: options)
        throw EngineTransportEndToEndTestError.badTokenAccepted
    } catch let error as RPCError {
        guard error.code == .unauthenticated else { throw error }
    }
}

@MainActor
private func waitForNewGeneration(
    from supervisor: EngineSupervisor,
    replacing instanceID: String
) async throws -> EngineInformation {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if case .ready(let information) = supervisor.state,
            information.instanceID != instanceID
        {
            return information
        }
        if case .failed(let message) = supervisor.state {
            throw EngineTransportEndToEndTestError.supervisorFailed(message)
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw EngineTransportEndToEndTestError.fixtureTimedOut("engine restart")
}

private func requestContext(id: String) -> Kmgr_V1_RequestContext {
    var context = Kmgr_V1_RequestContext()
    context.requestID = id
    context.deadlineUnixMs = Int64((Date().timeIntervalSince1970 + 3) * 1_000)
    return context
}

private func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func executablePath(_ processID: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4_096)
    let length = proc_pidpath(processID, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(
        decoding: buffer.prefix(Int(length)).map(UInt8.init(bitPattern:)),
        as: UTF8.self
    )
}
#endif

private enum EngineTransportEndToEndTestError: Error {
    case unsupportedPlatform
    case engineBuildFailed(String)
    case fixtureTimedOut(String)
    case supervisorFailed(String)
    case badTokenAccepted
    case unrecognizedHelperProcess
    case signalFailed(Int32)
}
