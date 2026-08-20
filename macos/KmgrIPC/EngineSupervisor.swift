import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import KmgrCore
import KmgrProto
import OSLog
#if canImport(Darwin)
import Darwin
#endif

public struct EngineInformation: Hashable, Sendable {
    public var version: String
    public var instanceID: String
    public var protocolMajor: UInt32
    public var protocolMinor: UInt32
    public var capabilities: [String: UInt32]

    public init(
        version: String,
        instanceID: String,
        protocolMajor: UInt32,
        protocolMinor: UInt32,
        capabilities: [String: UInt32]
    ) {
        self.version = version
        self.instanceID = instanceID
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.capabilities = capabilities
    }
}

public enum EngineConnectionState: Hashable, Sendable {
    case stopped
    case starting(attempt: Int)
    case ready(EngineInformation)
    case disconnected(message: String)
    case restarting(attempt: Int, delayMilliseconds: Int)
    case stopping
    case failed(message: String)
}

public struct EngineRestartPolicy: Hashable, Sendable {
    public var maximumAttempts: Int
    public var initialDelayMilliseconds: Int
    public var maximumDelayMilliseconds: Int

    public init(
        maximumAttempts: Int = 6,
        initialDelayMilliseconds: Int = 200,
        maximumDelayMilliseconds: Int = 5_000
    ) {
        precondition(maximumAttempts >= 1)
        precondition(initialDelayMilliseconds >= 0)
        precondition(maximumDelayMilliseconds >= initialDelayMilliseconds)
        self.maximumAttempts = maximumAttempts
        self.initialDelayMilliseconds = initialDelayMilliseconds
        self.maximumDelayMilliseconds = maximumDelayMilliseconds
    }

    public func delayMilliseconds(afterFailure failure: Int) -> Int? {
        guard failure > 0, failure < maximumAttempts else { return nil }
        guard initialDelayMilliseconds > 0 else { return 0 }
        let exponent = min(failure - 1, 20)
        let multiplier = 1 << exponent
        let (candidate, overflow) = initialDelayMilliseconds.multipliedReportingOverflow(
            by: multiplier
        )
        return min(overflow ? Int.max : candidate, maximumDelayMilliseconds)
    }
}

/// Counts only consecutive unhealthy helper generations. A generation that
/// remains handshaken and ready through the configured stability boundary
/// starts a fresh restart sequence when it eventually exits.
struct EngineRestartBudget {
    private(set) var consecutiveFailures = 0

    mutating func recordFailure(
        precedingReadyDuration: Duration?,
        stabilityDuration: Duration
    ) -> Int {
        if let precedingReadyDuration,
            precedingReadyDuration >= stabilityDuration
        {
            consecutiveFailures = 0
        }
        consecutiveFailures += 1
        return consecutiveFailures
    }
}

public enum EngineSupervisorError: Error, LocalizedError, Sendable {
    case helperMissing(String)
    case helperExited(Int32)
    case startupTimedOut
    case incompatibleProtocol(String)
    case invalidHandshake(String)
    case stopped

    public var errorDescription: String? {
        switch self {
        case .helperMissing(let path):
            "The bundled Kubernetes engine is missing at \(path)."
        case .helperExited(let status):
            "The Kubernetes engine exited unexpectedly (status \(status))."
        case .startupTimedOut:
            "The Kubernetes engine did not become ready in time."
        case .incompatibleProtocol(let message), .invalidHandshake(let message):
            message
        case .stopped:
            "The Kubernetes engine has stopped."
        }
    }
}

@MainActor
public final class EngineSupervisor {
    static let protocolMajor: UInt32 = 1
    static let requiredProtocolMinor: UInt32 = 1
    static let requiredCapabilities: [String: UInt32] = [
        "logs.resolve-sources": 1
    ]

    public struct Configuration: Sendable {
        public var helperURL: URL
        public var temporaryDirectoryURL: URL
        public var restartPolicy: EngineRestartPolicy
        /// Ready time required before a generation clears earlier failures.
        /// Short-lived handshaken generations therefore remain a bounded
        /// crash loop, while unrelated crashes do not consume a lifetime cap.
        public var restartStabilityDuration: Duration
        public var startupTimeout: Duration
        public var handshakeTimeout: Duration
        public var shutdownTimeout: Duration
        public var clientVersion: String
        public var columnsConfigurationPath: String?
        public var metricsRefreshSeconds: Int?
        public var advancedPerformance: AdvancedPerformancePreferences?
        public var logLevel: String?

        public init(
            helperURL: URL,
            temporaryDirectoryURL: URL = URL(fileURLWithPath: "/tmp", isDirectory: true),
            restartPolicy: EngineRestartPolicy = EngineRestartPolicy(),
            restartStabilityDuration: Duration = .seconds(30),
            startupTimeout: Duration = .seconds(8),
            handshakeTimeout: Duration = .seconds(2),
            shutdownTimeout: Duration = .seconds(5),
            clientVersion: String = "dev",
            columnsConfigurationPath: String? = nil,
            metricsRefreshSeconds: Int? = nil,
            advancedPerformance: AdvancedPerformancePreferences? = nil,
            logLevel: String? = nil
        ) {
            precondition(restartStabilityDuration >= .zero)
            self.helperURL = helperURL
            self.temporaryDirectoryURL = temporaryDirectoryURL
            self.restartPolicy = restartPolicy
            self.restartStabilityDuration = restartStabilityDuration
            self.startupTimeout = startupTimeout
            self.handshakeTimeout = handshakeTimeout
            self.shutdownTimeout = shutdownTimeout
            self.clientVersion = clientVersion
            self.columnsConfigurationPath = columnsConfigurationPath
            self.metricsRefreshSeconds = metricsRefreshSeconds
            self.advancedPerformance = advancedPerformance
            self.logLevel = logLevel
        }

        public static func bundled(bundle: Bundle = .main) -> Self {
            let override = ProcessInfo.processInfo.environment["KMGR_ENGINE_PATH"]
            let helperURL: URL
            if let override, !override.isEmpty {
                helperURL = URL(fileURLWithPath: override)
            } else {
                let bundled = bundle.bundleURL
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("Helpers", isDirectory: true)
                    .appendingPathComponent("kmgr-engine", isDirectory: false)
                if FileManager.default.isExecutableFile(atPath: bundled.path) {
                    helperURL = bundled
                } else {
                    helperURL = developmentHelperURL() ?? bundled
                }
            }
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "dev"
            return Self(
                helperURL: helperURL,
                clientVersion: version,
                logLevel: ProcessInfo.processInfo.environment["KMGR_ENGINE_LOG_LEVEL"]
            )
        }

        /// `swift run` has no application bundle Helpers directory. Walk up
        /// from the executable/current directory only far enough to recognize
        /// this repository, then use its normal build output if available.
        private static func developmentHelperURL() -> URL? {
            let fileManager = FileManager.default
            var candidates: [URL] = []
            if let executable = Bundle.main.executableURL {
                candidates.append(executable.deletingLastPathComponent())
            }
            candidates.append(
                URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            )

            var visited: Set<String> = []
            for start in candidates {
                var directory = start.standardizedFileURL
                for _ in 0..<8 {
                    guard visited.insert(directory.path).inserted else { break }
                    let manifest = directory.appendingPathComponent("go.mod")
                    let source = directory.appendingPathComponent(
                        "backend/cmd/kmgr-engine/main.go"
                    )
                    if fileManager.fileExists(atPath: manifest.path),
                        fileManager.fileExists(atPath: source.path)
                    {
                        let built = directory.appendingPathComponent(
                            "build/Kmgr.app/Contents/Helpers/kmgr-engine"
                        )
                        if fileManager.isExecutableFile(atPath: built.path) { return built }
                        let local = directory.appendingPathComponent("bin/kmgr-engine")
                        if fileManager.isExecutableFile(atPath: local.path) { return local }
                    }
                    let parent = directory.deletingLastPathComponent()
                    if parent.path == directory.path { break }
                    directory = parent
                }
            }
            return nil
        }
    }

    public private(set) var state: EngineConnectionState = .stopped {
        didSet {
            guard oldValue != state else { return }
            let value = state
            for observer in Array(stateObservers.values) { observer(value) }
        }
    }
    public nonisolated let connection = EngineConnection()

    private let configuration: Configuration
    private let logger = Logger(subsystem: "cc.chlc.kmgr", category: "engine-supervisor")
    private var supervisionTask: Task<Void, Never>?
    private var shutdownRequested = false
    private var currentProcess: Process?
    private var currentClient: EngineConnection.Client?
    private var currentConnectionTask: Task<Void, Never>?
    private var stateObservers: [UUID: @MainActor (EngineConnectionState) -> Void] = [:]

    public init(configuration: Configuration = .bundled()) {
        self.configuration = configuration
    }

    deinit {
        supervisionTask?.cancel()
        if let currentClient { currentClient.beginGracefulShutdown() }
        currentConnectionTask?.cancel()
        if let currentProcess, currentProcess.isRunning { currentProcess.terminate() }
    }

    public func start() {
        guard supervisionTask == nil else { return }
        shutdownRequested = false
        supervisionTask = Task { [weak self] in
            await self?.supervise()
        }
    }

    /// Observe helper generations without polling. The current state is
    /// delivered immediately so application composition can subscribe after
    /// constructing the shared providers without missing startup progress.
    @discardableResult
    public func observeState(
        _ observer: @escaping @MainActor (EngineConnectionState) -> Void
    ) -> UUID {
        let token = UUID()
        stateObservers[token] = observer
        observer(state)
        return token
    }

    public func removeStateObserver(_ token: UUID) {
        stateObservers.removeValue(forKey: token)
    }

    public func waitUntilReady(timeout: Duration = .seconds(10)) async throws -> EngineInformation {
        let deadline = ContinuousClock.now + timeout
        while true {
            try Task.checkCancellation()
            switch state {
            case .ready(let information):
                return information
            case .failed(let message):
                throw EngineSupervisorError.invalidHandshake(message)
            case .stopped where supervisionTask == nil:
                throw EngineSupervisorError.stopped
            default:
                break
            }
            guard ContinuousClock.now < deadline else {
                throw EngineSupervisorError.startupTimedOut
            }
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    public func shutdown(stopActivePortForwards: Bool = true) async {
        guard supervisionTask != nil else {
            state = .stopped
            connection.stop()
            return
        }

        shutdownRequested = true
        state = .stopping
        let shutdownClient = currentClient
        connection.stop()
        if let shutdownClient {
            do {
                let client = Kmgr_V1_EngineService.Client(wrapping: shutdownClient)
                var request = Kmgr_V1_ShutdownRequest()
                request.context = requestContext(timeout: configuration.handshakeTimeout)
                request.stopActivePortForwards = stopActivePortForwards
                var options = CallOptions.defaults
                options.timeout = configuration.handshakeTimeout
                let response: Kmgr_V1_Acknowledgement = try await client.shutdown(
                    request,
                    options: options
                )
                if !response.accepted {
                    logger.warning("Engine declined graceful shutdown")
                }
            } catch {
                logger.warning("Graceful engine shutdown RPC failed")
            }
        }
        shutdownClient?.beginGracefulShutdown()
        currentConnectionTask?.cancel()
        currentConnectionTask = nil

        let shutdownDeadline = ContinuousClock.now + configuration.shutdownTimeout
        while currentProcess?.isRunning == true, ContinuousClock.now < shutdownDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let process = currentProcess, process.isRunning {
            process.terminate()
            try? await Task.sleep(for: .milliseconds(250))
            #if canImport(Darwin)
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            #endif
        }

        supervisionTask?.cancel()
        await supervisionTask?.value
        supervisionTask = nil
        currentProcess = nil
        currentClient = nil
        connection.stop()
        state = .stopped
    }

    private func supervise() async {
        var restartBudget = EngineRestartBudget()
        while !shutdownRequested, !Task.isCancelled {
            state = .starting(attempt: restartBudget.consecutiveFailures + 1)
            var precedingReadyDuration: Duration?
            do {
                let generationExit = try await runGeneration()
                if shutdownRequested || Task.isCancelled { break }
                precedingReadyDuration = generationExit.readyDuration
                throw EngineSupervisorError.helperExited(generationExit.status)
            } catch is CancellationError {
                break
            } catch {
                if shutdownRequested { break }
                let failure = restartBudget.recordFailure(
                    precedingReadyDuration: precedingReadyDuration,
                    stabilityDuration: configuration.restartStabilityDuration
                )
                let message = safeMessage(for: error)
                state = .disconnected(message: message)
                guard let delay = configuration.restartPolicy.delayMilliseconds(
                    afterFailure: failure
                ) else {
                    state = .failed(message: message)
                    break
                }
                state = .restarting(attempt: failure + 1, delayMilliseconds: delay)
                try? await Task.sleep(for: .milliseconds(delay))
            }
        }
        if shutdownRequested || Task.isCancelled { state = .stopped }
        supervisionTask = nil
    }

    private func runGeneration() async throws -> EngineGenerationExit {
        guard FileManager.default.isExecutableFile(atPath: configuration.helperURL.path) else {
            throw EngineSupervisorError.helperMissing(configuration.helperURL.path)
        }

        let endpoint = try EngineLaunchEndpoint.create(
            baseDirectoryURL: configuration.temporaryDirectoryURL
        )
        let process = Process()
        let stderrPipe = configuration.normalizedLogLevel == nil ? Pipe() : nil
        let exitWaiter = ProcessExitWaiter()
        process.executableURL = configuration.helperURL
        let helperArguments = configuration.helperArguments(
            appendingTo: endpoint.helperArguments
        )
        process.arguments = helperArguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        if let stderrPipe {
            process.standardError = stderrPipe
        } else {
            // A valid, explicitly configured log level is a local diagnostic
            // opt-in. Inherit stderr so a terminal-launched app can expose the
            // helper's already-redacted structured records without persisting
            // them or copying them into the app's ordinary OSLog stream.
            process.standardError = FileHandle.standardError
        }
        process.terminationHandler = { process in
            exitWaiter.signal(status: process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            try? endpoint.cleanup()
            throw error
        }
        currentProcess = process

        let diagnosticsTask = stderrPipe.map { pipe in
            Task.detached(priority: .utility) {
                let handle = pipe.fileHandleForReading
                while !Task.isCancelled {
                    do {
                        guard let data = try handle.read(upToCount: 4_096), !data.isEmpty else {
                            break
                        }
                        // The engine owns formatting/redaction. Draining without
                        // mirroring raw text keeps diagnostics out of app logs.
                    } catch {
                        break
                    }
                }
            }
        }

        let transport: HTTP2ClientTransport.Posix
        let client: EngineConnection.Client
        let connectionTask: Task<Void, Never>
        do {
            transport = try HTTP2ClientTransport.Posix(
                target: .unixDomainSocket(path: endpoint.socketURL.path),
                transportSecurity: .plaintext
            )
            client = GRPCClient(
                transport: transport,
                interceptors: [
                    BearerTokenInterceptor(
                        authorizationValue: endpoint.token.authorizationValue
                    )
                ]
            )
            currentClient = client
            connectionTask = Task.detached {
                do {
                    try await client.runConnections()
                } catch {
                    // Process exit/restart is the lifecycle authority. The
                    // transport reconnects internally while the helper lives.
                }
            }
            currentConnectionTask = connectionTask
        } catch {
            await stopProcess(process, waiter: exitWaiter)
            diagnosticsTask?.cancel()
            try? endpoint.cleanup()
            throw error
        }

        do {
            let information = try await handshake(client: client, process: process)
            // Do not publish a generation to ordinary RPC providers until its
            // authenticated protocol handshake and capability validation have
            // succeeded. The supervisor retains `currentClient` privately so
            // shutdown can still stop a helper whose startup is in progress.
            let readyAt = ContinuousClock.now
            connection.install(client)
            state = .ready(information)
            let status = await exitWaiter.wait()
            let readyDuration = readyAt.duration(to: ContinuousClock.now)
            connection.clear(client)
            currentClient = nil
            currentProcess = nil
            client.beginGracefulShutdown()
            connectionTask.cancel()
            currentConnectionTask = nil
            diagnosticsTask?.cancel()
            try? endpoint.cleanup()
            return EngineGenerationExit(status: status, readyDuration: readyDuration)
        } catch {
            connection.clear(client)
            currentClient = nil
            await stopProcess(process, waiter: exitWaiter)
            currentProcess = nil
            client.beginGracefulShutdown()
            connectionTask.cancel()
            currentConnectionTask = nil
            diagnosticsTask?.cancel()
            try? endpoint.cleanup()
            throw error
        }
    }

    private func handshake(
        client: EngineConnection.Client,
        process: Process
    ) async throws -> EngineInformation {
        let startupDeadline = ContinuousClock.now + configuration.startupTimeout
        var retryDelay = 25
        while process.isRunning, ContinuousClock.now < startupDeadline {
            try Task.checkCancellation()
            do {
                let service = Kmgr_V1_EngineService.Client(wrapping: client)
                var request = Kmgr_V1_HandshakeRequest()
                request.context = requestContext(timeout: configuration.handshakeTimeout)
                request.clientProtocol.major = Self.protocolMajor
                request.clientProtocol.minor = Self.requiredProtocolMinor
                request.clientVersion = configuration.clientVersion
                var options = CallOptions.defaults
                options.timeout = configuration.handshakeTimeout
                options.waitForReady = false
                let response: Kmgr_V1_HandshakeResponse = try await service.handshake(
                    request,
                    options: options
                )
                return try Self.validateHandshakeResponse(response)
            } catch let error as EngineSupervisorError {
                throw error
            } catch {
                if !process.isRunning { break }
                try await Task.sleep(for: .milliseconds(retryDelay))
                retryDelay = min(retryDelay * 2, 400)
            }
        }
        if !process.isRunning {
            throw EngineSupervisorError.helperExited(process.terminationStatus)
        }
        throw EngineSupervisorError.startupTimedOut
    }

    static func validateHandshakeResponse(
        _ response: Kmgr_V1_HandshakeResponse
    ) throws -> EngineInformation {
        if response.hasError {
            throw EngineSupervisorError.incompatibleProtocol(
                response.error.message.isEmpty
                    ? "The engine rejected the protocol handshake."
                    : response.error.message
            )
        }
        guard response.hasNegotiatedProtocol,
            response.negotiatedProtocol.major == protocolMajor,
            !response.engineInstanceID.isEmpty
        else {
            throw EngineSupervisorError.invalidHandshake(
                "The engine returned an incomplete protocol handshake."
            )
        }
        guard response.negotiatedProtocol.minor >= requiredProtocolMinor else {
            throw EngineSupervisorError.incompatibleProtocol(
                "This version of kmgr requires Kubernetes engine protocol \(protocolMajor).\(requiredProtocolMinor) or newer."
            )
        }
        let capabilities = Dictionary(
            response.capabilities.map { ($0.name, $0.version) },
            uniquingKeysWith: max
        )
        let missing = requiredCapabilities.keys.sorted().filter {
            capabilities[$0, default: 0] < requiredCapabilities[$0, default: 0]
        }
        guard missing.isEmpty else {
            throw EngineSupervisorError.incompatibleProtocol(
                "The Kubernetes engine is missing required capability: \(missing.joined(separator: ", "))."
            )
        }
        return EngineInformation(
            version: response.engineVersion,
            instanceID: response.engineInstanceID,
            protocolMajor: response.negotiatedProtocol.major,
            protocolMinor: response.negotiatedProtocol.minor,
            capabilities: capabilities
        )
    }

    private func stopProcess(_ process: Process, waiter: ProcessExitWaiter) async {
        if process.isRunning { process.terminate() }
        let deadline = ContinuousClock.now + .seconds(1)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        #if canImport(Darwin)
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        #endif
        _ = await waiter.wait()
    }

    private func requestContext(timeout: Duration) -> Kmgr_V1_RequestContext {
        var context = Kmgr_V1_RequestContext()
        context.requestID = UUID().uuidString.lowercased()
        let seconds = durationSeconds(timeout)
        context.deadlineUnixMs = Int64((Date().timeIntervalSince1970 + seconds) * 1_000)
        return context
    }

    private func durationSeconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func safeMessage(for error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }
        return "The Kubernetes engine disconnected unexpectedly."
    }
}

private struct EngineGenerationExit {
    var status: Int32
    var readyDuration: Duration
}

extension EngineSupervisor.Configuration {
    var normalizedLogLevel: String? {
        guard let logLevel else { return nil }
        let normalized = logLevel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["debug", "info", "warn", "error"].contains(normalized) ? normalized : nil
    }

    /// Adds only non-sensitive engine behavior settings. Endpoint credentials
    /// stay in the launch endpoint and are never exposed through preferences.
    func helperArguments(appendingTo base: [String]) -> [String] {
        var arguments = base
        if let columnsConfigurationPath, !columnsConfigurationPath.isEmpty {
            arguments += ["--columns", columnsConfigurationPath]
        }
        if let metricsRefreshSeconds, metricsRefreshSeconds > 0 {
            arguments += ["--metrics-refresh", "\(metricsRefreshSeconds)s"]
        }
        if let advancedPerformance,
            advancedPerformance.validationIssues().isEmpty
        {
            arguments += [
                "--warm-cache-global-views",
                "\(advancedPerformance.globalWarmCacheViewLimit)",
                "--warm-cache-global-objects",
                "\(advancedPerformance.globalWarmCacheObjectLimit)",
                "--warm-cache-global-memory-percent",
                "\(advancedPerformance.globalWarmCacheMemoryPercent)",
                "--warm-cache-authority-views",
                "\(advancedPerformance.authorityWarmCacheViewLimit)",
                "--warm-cache-authority-objects",
                "\(advancedPerformance.authorityWarmCacheObjectLimit)",
                "--warm-cache-authority-memory-percent",
                "\(advancedPerformance.authorityWarmCacheMemoryPercent)",
                "--kubernetes-qps",
                "\(advancedPerformance.kubernetesQPS)",
                "--kubernetes-burst",
                "\(advancedPerformance.kubernetesBurst)",
                "--metrics-idle-provider-limit",
                "\(advancedPerformance.idleMetricProviderLimit)",
                "--metrics-idle-sample-limit",
                "\(advancedPerformance.idleMetricSampleLimit)",
                "--pod-metrics-cache-entry-limit",
                "\(advancedPerformance.exactPodMetricsEntryLimit)",
                "--pod-metrics-positive-sample-limit",
                "\(advancedPerformance.exactPodMetricsSampleLimit)",
                "--pod-metrics-detail-entry-limit",
                "\(advancedPerformance.exactPodMetricsDetailEntryLimit)",
                "--pod-metrics-get-concurrency",
                "\(advancedPerformance.exactPodMetricsGETConcurrency)",
                "--log-source-open-concurrency",
                "\(advancedPerformance.logSourceOpenConcurrency)",
            ]
        }
        if let normalizedLogLevel {
            arguments += ["--log-level", normalizedLogLevel]
        }
        return arguments
    }
}

private final class ProcessExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuations: [CheckedContinuation<Int32, Never>] = []

    func signal(status: Int32) {
        let pending: [CheckedContinuation<Int32, Never>] = lock.withLock {
            guard self.status == nil else { return [] }
            self.status = status
            defer { continuations.removeAll() }
            return continuations
        }
        for continuation in pending { continuation.resume(returning: status) }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let immediate: Int32? = lock.withLock {
                if let status { return status }
                continuations.append(continuation)
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }
}
