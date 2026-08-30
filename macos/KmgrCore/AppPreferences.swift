import CoreFoundation
import Foundation

public enum AppearancePreference: String, Codable, CaseIterable, Hashable, Sendable {
    case system
    case light
    case dark

    public var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

public enum DefaultNamespacePreference: String, Codable, CaseIterable, Hashable, Sendable {
    case contextDefault
    case allNamespaces

    public var title: String {
        switch self {
        case .contextDefault: "Kubeconfig context default"
        case .allNamespaces: "All namespaces"
        }
    }

    /// Namespace scope for a newly created workspace. Restored workspaces use
    /// their persisted scope instead, so changing this preference never
    /// silently retargets an existing window.
    public func initialSelection(contextDefaultNamespace: String) -> NamespaceSelection {
        switch self {
        case .contextDefault:
            let namespace = contextDefaultNamespace.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return .namespace(namespace.isEmpty ? "default" : namespace)
        case .allNamespaces:
            return NamespaceSelection()
        }
    }
}

public struct LogDisplayPreferences: Codable, Hashable, Sendable {
    public static let defaultMaximumRenderedUTF8Bytes = 16 << 20
    public static let defaultMaximumDisplayedLineUTF8Bytes = 16 << 10
    public static let maximumDisplayedLineUTF8BytesRange = 256...(16 << 20)

    public var recordLimit: Int
    public var byteLimit: Int
    public var renderBatchMilliseconds: Int
    public var maximumRenderedUTF8Bytes: Int
    public var maximumDisplayedLineUTF8Bytes: Int

    public init(
        recordLimit: Int = 20_000,
        byteLimit: Int = 16 << 20,
        renderBatchMilliseconds: Int = 40,
        maximumRenderedUTF8Bytes: Int = Self.defaultMaximumRenderedUTF8Bytes,
        maximumDisplayedLineUTF8Bytes: Int = Self.defaultMaximumDisplayedLineUTF8Bytes
    ) {
        self.recordLimit = recordLimit
        self.byteLimit = byteLimit
        self.renderBatchMilliseconds = renderBatchMilliseconds
        self.maximumRenderedUTF8Bytes = maximumRenderedUTF8Bytes
        self.maximumDisplayedLineUTF8Bytes = maximumDisplayedLineUTF8Bytes
    }
}

public struct DiagnosticsPreferences: Codable, Hashable, Sendable {
    public var completedOperationHistoryLimit: Int

    public init(completedOperationHistoryLimit: Int = 2_000) {
        self.completedOperationHistoryLimit = completedOperationHistoryLimit
    }
}

public struct NodeShellPreferences: Codable, Hashable, Sendable {
    public static let defaultImage = "alpine:latest"
    public static let defaultStartupTimeoutSeconds = 60
    public static let startupTimeoutSecondsRange = 1...3_600

    public var globalImage: String
    public var clusterImagesByContextReference: [String: String]
    public var startupTimeoutSeconds: Int

    public init(
        globalImage: String = Self.defaultImage,
        clusterImagesByContextReference: [String: String] = [:],
        startupTimeoutSeconds: Int = Self.defaultStartupTimeoutSeconds
    ) {
        self.globalImage = globalImage
        self.clusterImagesByContextReference = clusterImagesByContextReference
        self.startupTimeoutSeconds = startupTimeoutSeconds
    }

    public func effectiveImage(contextReference: String) -> String {
        clusterImagesByContextReference[contextReference] ?? globalImage
    }

    public mutating func setClusterImage(_ image: String?, contextReference: String) {
        if let image {
            clusterImagesByContextReference[contextReference] = image
        } else {
            clusterImagesByContextReference.removeValue(forKey: contextReference)
        }
    }

    fileprivate func validationIssues() -> [AppPreferenceIssue] {
        var issues: [AppPreferenceIssue] = []
        if !Self.isValidImage(globalImage) {
            issues.append(AppPreferenceIssue(
                field: "nodeShell.globalImage",
                message: "The default node-shell image must be a nonempty image reference of at most 1,024 UTF-8 bytes without whitespace or control characters."
            ))
        }
        if !Self.startupTimeoutSecondsRange.contains(startupTimeoutSeconds) {
            issues.append(AppPreferenceIssue(
                field: "nodeShell.startupTimeoutSeconds",
                message: "Node-shell startup timeout must be between 1 and 3,600 seconds."
            ))
        }
        if clusterImagesByContextReference.count > 1_000 {
            issues.append(AppPreferenceIssue(
                field: "nodeShell.clusterImagesByContextReference",
                message: "At most 1,000 per-cluster node-shell image overrides may be retained."
            ))
        }
        for (reference, image) in clusterImagesByContextReference {
            if reference.isEmpty || reference.utf8.count > 512 ||
                reference.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            {
                issues.append(AppPreferenceIssue(
                    field: "nodeShell.clusterImagesByContextReference",
                    message: "A per-cluster node-shell image override has an invalid context reference."
                ))
                break
            }
            if !Self.isValidImage(image) {
                issues.append(AppPreferenceIssue(
                    field: "nodeShell.clusterImagesByContextReference",
                    message: "A per-cluster node-shell image override has an invalid image reference."
                ))
                break
            }
        }
        return issues
    }

    public static func isValidImage(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed == value && value.utf8.count <= 1_024 &&
            !value.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0) ||
                    CharacterSet.controlCharacters.contains($0)
            }
    }
}

public struct TerminalPreferences: Codable, Hashable, Sendable {
    public static let initialColumnsRange = 80...300
    public static let initialRowsRange = 20...100

    public var initialColumns: Int
    public var initialRows: Int

    public init(
        initialColumns: Int = Int(TerminalSize.defaultShellWindow.columns),
        initialRows: Int = Int(TerminalSize.defaultShellWindow.rows)
    ) {
        self.initialColumns = initialColumns
        self.initialRows = initialRows
    }

    public var initialSize: TerminalSize {
        precondition(Self.initialColumnsRange.contains(initialColumns))
        precondition(Self.initialRowsRange.contains(initialRows))
        return TerminalSize(
            columns: UInt32(initialColumns),
            rows: UInt32(initialRows)
        )
    }

    fileprivate func validationIssues() -> [AppPreferenceIssue] {
        var issues: [AppPreferenceIssue] = []
        if !Self.initialColumnsRange.contains(initialColumns) {
            issues.append(AppPreferenceIssue(
                field: "terminal.initialColumns",
                message: "Initial terminal columns must be between \(Self.initialColumnsRange.lowerBound) and \(Self.initialColumnsRange.upperBound)."
            ))
        }
        if !Self.initialRowsRange.contains(initialRows) {
            issues.append(AppPreferenceIssue(
                field: "terminal.initialRows",
                message: "Initial terminal rows must be between \(Self.initialRowsRange.lowerBound) and \(Self.initialRowsRange.upperBound)."
            ))
        }
        return issues
    }
}

public struct ConfirmationPreferences: Codable, Hashable, Sendable {
    public var confirmWorkloadRestart: Bool
    public var confirmScaling: Bool

    public init(
        confirmWorkloadRestart: Bool = true,
        confirmScaling: Bool = false
    ) {
        self.confirmWorkloadRestart = confirmWorkloadRestart
        self.confirmScaling = confirmScaling
    }

    /// Destructive actions, network exposure, and target identity are safety
    /// boundaries, not user preferences. Settings provides no way to disable
    /// these protections.
    public static let alwaysConfirmResourceDeletion = true
    public static let alwaysConfirmActiveTerminalClose = true
    public static let alwaysConfirmNonLoopbackPortForward = true
    public static let alwaysShowClusterAndNamespaceIdentity = true

    public func requiresConfirmation(for mutation: PreferenceControlledMutation) -> Bool {
        switch mutation {
        case .workloadRestart:
            confirmWorkloadRestart
        case .scaling:
            confirmScaling
        }
    }
}

public struct ResourceOperationPreferences: Codable, Hashable, Sendable {
    public var defaultDeleteConcurrency: Int

    public init(
        defaultDeleteConcurrency: Int = Int(ResourceDeleteOptions.defaultMaxConcurrency)
    ) {
        self.defaultDeleteConcurrency = defaultDeleteConcurrency
    }

    fileprivate func validationIssues() -> [AppPreferenceIssue] {
        guard (1...Int(ResourceDeleteOptions.maximumMaxConcurrency)).contains(
            defaultDeleteConcurrency
        ) else {
            return [AppPreferenceIssue(
                field: "resourceOperations.defaultDeleteConcurrency",
                message: "Default delete concurrency must be between 1 and 16."
            )]
        }
        return []
    }
}

public enum PreferenceControlledMutation: Hashable, Sendable {
    case workloadRestart
    case scaling
}

public struct AdvancedPerformancePreferences: Codable, Hashable, Sendable {
    public static let defaultProjectionWorkerLimit = min(
        max(ProcessInfo.processInfo.activeProcessorCount, 1),
        8
    )
    public static let projectionWorkerLimitRange = 1...32
    public static let defaultViewReleaseGraceSeconds = 3
    public static let viewReleaseGraceSecondsRange = 1...300
    public static let defaultKubernetesListPageSize = 500
    public static let kubernetesListPageSizeRange = 1...10_000
    public static let defaultClusterConnectionTimeoutSeconds = 10
    public static let clusterConnectionTimeoutSecondsRange = 1...600
    public static let defaultKubernetesRequestTimeoutSeconds = 30
    public static let kubernetesRequestTimeoutSecondsRange = 1...3_600
    public static let defaultLogQueueRecordLimit = 4_096
    public static let logQueueRecordLimitRange = 1...262_144
    public static let defaultLogQueueByteLimit = 8 << 20
    public static let logQueueByteLimitRange = (1 << 20)...(512 << 20)

    public var viewportOverscanScreensPerSide: Int
    public var viewReleaseGraceSeconds: Int
    public var projectionWorkerLimit: Int
    public var globalWarmCacheViewLimit: Int
    public var globalWarmCacheObjectLimit: Int
    public var globalWarmCacheMemoryPercent: Int
    public var authorityWarmCacheViewLimit: Int
    public var authorityWarmCacheObjectLimit: Int
    public var authorityWarmCacheMemoryPercent: Int
    public var kubernetesQPS: Double
    public var kubernetesBurst: Int
    public var kubernetesListPageSize: Int
    public var clusterConnectionTimeoutSeconds: Int
    public var kubernetesRequestTimeoutSeconds: Int
    public var idleMetricProviderLimit: Int
    public var idleMetricSampleLimit: Int
    public var exactPodMetricsEntryLimit: Int
    public var exactPodMetricsSampleLimit: Int
    public var exactPodMetricsDetailEntryLimit: Int
    public var exactPodMetricsGETConcurrency: Int
    public var logQueueRecordLimit: Int
    public var logQueueByteLimit: Int
    public var logSourceOpenConcurrency: Int

    public init(
        viewportOverscanScreensPerSide: Int = 10,
        viewReleaseGraceSeconds: Int = AdvancedPerformancePreferences.defaultViewReleaseGraceSeconds,
        projectionWorkerLimit: Int = AdvancedPerformancePreferences.defaultProjectionWorkerLimit,
        globalWarmCacheViewLimit: Int = 24,
        globalWarmCacheObjectLimit: Int = 250_000,
        globalWarmCacheMemoryPercent: Int = 20,
        authorityWarmCacheViewLimit: Int = 8,
        authorityWarmCacheObjectLimit: Int = 100_000,
        authorityWarmCacheMemoryPercent: Int = 20,
        kubernetesQPS: Double = 40,
        kubernetesBurst: Int = 80,
        kubernetesListPageSize: Int = AdvancedPerformancePreferences.defaultKubernetesListPageSize,
        clusterConnectionTimeoutSeconds: Int = AdvancedPerformancePreferences.defaultClusterConnectionTimeoutSeconds,
        kubernetesRequestTimeoutSeconds: Int = AdvancedPerformancePreferences.defaultKubernetesRequestTimeoutSeconds,
        idleMetricProviderLimit: Int = 8,
        idleMetricSampleLimit: Int = 100_000,
        exactPodMetricsEntryLimit: Int = 100_000,
        exactPodMetricsSampleLimit: Int = 100_000,
        exactPodMetricsDetailEntryLimit: Int = 256,
        exactPodMetricsGETConcurrency: Int = 16,
        logQueueRecordLimit: Int = AdvancedPerformancePreferences.defaultLogQueueRecordLimit,
        logQueueByteLimit: Int = AdvancedPerformancePreferences.defaultLogQueueByteLimit,
        logSourceOpenConcurrency: Int = 16
    ) {
        self.viewportOverscanScreensPerSide = viewportOverscanScreensPerSide
        self.viewReleaseGraceSeconds = viewReleaseGraceSeconds
        self.projectionWorkerLimit = projectionWorkerLimit
        self.globalWarmCacheViewLimit = globalWarmCacheViewLimit
        self.globalWarmCacheObjectLimit = globalWarmCacheObjectLimit
        self.globalWarmCacheMemoryPercent = globalWarmCacheMemoryPercent
        self.authorityWarmCacheViewLimit = authorityWarmCacheViewLimit
        self.authorityWarmCacheObjectLimit = authorityWarmCacheObjectLimit
        self.authorityWarmCacheMemoryPercent = authorityWarmCacheMemoryPercent
        self.kubernetesQPS = kubernetesQPS
        self.kubernetesBurst = kubernetesBurst
        self.kubernetesListPageSize = kubernetesListPageSize
        self.clusterConnectionTimeoutSeconds = clusterConnectionTimeoutSeconds
        self.kubernetesRequestTimeoutSeconds = kubernetesRequestTimeoutSeconds
        self.idleMetricProviderLimit = idleMetricProviderLimit
        self.idleMetricSampleLimit = idleMetricSampleLimit
        self.exactPodMetricsEntryLimit = exactPodMetricsEntryLimit
        self.exactPodMetricsSampleLimit = exactPodMetricsSampleLimit
        self.exactPodMetricsDetailEntryLimit = exactPodMetricsDetailEntryLimit
        self.exactPodMetricsGETConcurrency = exactPodMetricsGETConcurrency
        self.logQueueRecordLimit = logQueueRecordLimit
        self.logQueueByteLimit = logQueueByteLimit
        self.logSourceOpenConcurrency = logSourceOpenConcurrency
    }

    public func validationIssues() -> [AppPreferenceIssue] {
        var issues: [AppPreferenceIssue] = []
        let maximumCrossPlatformInteger = Int(Int32.max)
        func validateCount(_ value: Int, field: String, title: String) {
            if !(1...maximumCrossPlatformInteger).contains(value) {
                issues.append(AppPreferenceIssue(
                    field: field,
                    message: "\(title) must be between 1 and \(maximumCrossPlatformInteger.formatted())."
                ))
            }
        }
        func validatePercent(_ value: Int, field: String, title: String) {
            if !(1...100).contains(value) {
                issues.append(AppPreferenceIssue(
                    field: field,
                    message: "\(title) must be between 1% and 100%."
                ))
            }
        }

        if !(0...100).contains(viewportOverscanScreensPerSide) {
            issues.append(AppPreferenceIssue(
                field: "advancedPerformance.viewportOverscanScreensPerSide",
                message: "List overscan must be between 0 and 100 screens per side."
            ))
        }
        if !Self.viewReleaseGraceSecondsRange.contains(viewReleaseGraceSeconds) {
            issues.append(AppPreferenceIssue(
                field: "advancedPerformance.viewReleaseGraceSeconds",
                message: "View release grace must be between 1 and 300 seconds."
            ))
        }
        if !Self.projectionWorkerLimitRange.contains(projectionWorkerLimit) {
            issues.append(AppPreferenceIssue(
                field: "advancedPerformance.projectionWorkerLimit",
                message: "Projection workers must be between 1 and 32."
            ))
        }

        validateCount(
            globalWarmCacheViewLimit,
            field: "advancedPerformance.globalWarmCacheViewLimit",
            title: "Global warm-cache query limit"
        )
        validateCount(
            globalWarmCacheObjectLimit,
            field: "advancedPerformance.globalWarmCacheObjectLimit",
            title: "Global warm-cache object limit"
        )
        validatePercent(
            globalWarmCacheMemoryPercent,
            field: "advancedPerformance.globalWarmCacheMemoryPercent",
            title: "Global warm-cache memory limit"
        )
        validateCount(
            authorityWarmCacheViewLimit,
            field: "advancedPerformance.authorityWarmCacheViewLimit",
            title: "Per-cluster warm-cache query limit"
        )
        validateCount(
            authorityWarmCacheObjectLimit,
            field: "advancedPerformance.authorityWarmCacheObjectLimit",
            title: "Per-cluster warm-cache object limit"
        )
        validatePercent(
            authorityWarmCacheMemoryPercent,
            field: "advancedPerformance.authorityWarmCacheMemoryPercent",
            title: "Per-cluster warm-cache memory limit"
        )
        let convertedQPS = Float(kubernetesQPS)
        if !kubernetesQPS.isFinite || kubernetesQPS <= 0 ||
            !convertedQPS.isFinite || convertedQPS <= 0
        {
            issues.append(AppPreferenceIssue(
                field: "advancedPerformance.kubernetesQPS",
                message: "Kubernetes QPS must be a finite positive 32-bit value."
            ))
        }
        validateCount(
            kubernetesBurst,
            field: "advancedPerformance.kubernetesBurst",
            title: "Kubernetes burst"
        )
        if !Self.kubernetesListPageSizeRange.contains(kubernetesListPageSize) {
            issues.append(AppPreferenceIssue(
                field: "advancedPerformance.kubernetesListPageSize",
                message: "Kubernetes LIST page size must be between 1 and 10,000 objects."
            ))
        }
        if !Self.clusterConnectionTimeoutSecondsRange.contains(
            clusterConnectionTimeoutSeconds
        ) {
            issues.append(AppPreferenceIssue(
                field: "advancedPerformance.clusterConnectionTimeoutSeconds",
                message: "Cluster connection timeout must be between 1 and 600 seconds."
            ))
        }
        if !Self.kubernetesRequestTimeoutSecondsRange.contains(
            kubernetesRequestTimeoutSeconds
        ) {
            issues.append(AppPreferenceIssue(
                field: "advancedPerformance.kubernetesRequestTimeoutSeconds",
                message: "Kubernetes request timeout must be between 1 and 3,600 seconds."
            ))
        }
        validateCount(
            idleMetricProviderLimit,
            field: "advancedPerformance.idleMetricProviderLimit",
            title: "Idle metric provider limit"
        )
        validateCount(
            idleMetricSampleLimit,
            field: "advancedPerformance.idleMetricSampleLimit",
            title: "Idle metric sample limit"
        )
        validateCount(
            exactPodMetricsEntryLimit,
            field: "advancedPerformance.exactPodMetricsEntryLimit",
            title: "Exact PodMetrics cache entry limit"
        )
        validateCount(
            exactPodMetricsSampleLimit,
            field: "advancedPerformance.exactPodMetricsSampleLimit",
            title: "Exact PodMetrics positive sample limit"
        )
        validateCount(
            exactPodMetricsDetailEntryLimit,
            field: "advancedPerformance.exactPodMetricsDetailEntryLimit",
            title: "Exact PodMetrics raw detail entry limit"
        )
        validateCount(
            exactPodMetricsGETConcurrency,
            field: "advancedPerformance.exactPodMetricsGETConcurrency",
            title: "Exact PodMetrics GET concurrency"
        )
        if !Self.logQueueRecordLimitRange.contains(logQueueRecordLimit) {
            issues.append(AppPreferenceIssue(
                field: "advancedPerformance.logQueueRecordLimit",
                message: "Log delivery queue records must be between 1 and 262,144 per stream."
            ))
        }
        if !Self.logQueueByteLimitRange.contains(logQueueByteLimit) {
            issues.append(AppPreferenceIssue(
                field: "advancedPerformance.logQueueByteLimit",
                message: "Log delivery queue data must be between 1 MiB and 512 MiB per stream."
            ))
        }
        validateCount(
            logSourceOpenConcurrency,
            field: "advancedPerformance.logSourceOpenConcurrency",
            title: "Log source open concurrency"
        )
        return issues
    }
}

public struct AppPreferences: Codable, Hashable, Sendable {
    public static let apiVersion = "kmgr.preferences/v14"

    public var appearance: AppearancePreference
    public var logs: LogDisplayPreferences
    public var metricsRefreshSeconds: Int
    public var defaultNamespace: DefaultNamespacePreference
    public var restoreOpenClusterWindows: Bool
    public var confirmations: ConfirmationPreferences
    public var resourceOperations: ResourceOperationPreferences
    public var columnsConfigurationPath: String
    public var diagnostics: DiagnosticsPreferences
    public var nodeShell: NodeShellPreferences
    public var terminal: TerminalPreferences
    public var advancedPerformance: AdvancedPerformancePreferences

    public init(
        appearance: AppearancePreference = .system,
        logs: LogDisplayPreferences = LogDisplayPreferences(),
        metricsRefreshSeconds: Int = 15,
        defaultNamespace: DefaultNamespacePreference = .contextDefault,
        restoreOpenClusterWindows: Bool = true,
        confirmations: ConfirmationPreferences = ConfirmationPreferences(),
        resourceOperations: ResourceOperationPreferences = ResourceOperationPreferences(),
        columnsConfigurationPath: String = AppPreferences.defaultColumnsConfigurationPath,
        diagnostics: DiagnosticsPreferences = DiagnosticsPreferences(),
        nodeShell: NodeShellPreferences = NodeShellPreferences(),
        terminal: TerminalPreferences = TerminalPreferences(),
        advancedPerformance: AdvancedPerformancePreferences = AdvancedPerformancePreferences()
    ) {
        self.appearance = appearance
        self.logs = logs
        self.metricsRefreshSeconds = metricsRefreshSeconds
        self.defaultNamespace = defaultNamespace
        self.restoreOpenClusterWindows = restoreOpenClusterWindows
        self.confirmations = confirmations
        self.resourceOperations = resourceOperations
        self.columnsConfigurationPath = columnsConfigurationPath
        self.diagnostics = diagnostics
        self.nodeShell = nodeShell
        self.terminal = terminal
        self.advancedPerformance = advancedPerformance
    }

    public static var defaultColumnsConfigurationPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(Product.name, isDirectory: true)
            .appendingPathComponent("columns.yaml", isDirectory: false)
            .path
    }

    public func validationIssues() -> [AppPreferenceIssue] {
        var issues: [AppPreferenceIssue] = []
        if !(1_000...1_000_000).contains(logs.recordLimit) {
            issues.append(AppPreferenceIssue(
                field: "logs.recordLimit",
                message: "Log record limit must be between 1,000 and 1,000,000."
            ))
        }
        if !((1 << 20)...(512 << 20)).contains(logs.byteLimit) {
            issues.append(AppPreferenceIssue(
                field: "logs.byteLimit",
                message: "Log byte limit must be between 1 MiB and 512 MiB."
            ))
        }
        if !(30...250).contains(logs.renderBatchMilliseconds) {
            issues.append(AppPreferenceIssue(
                field: "logs.renderBatchMilliseconds",
                message: "Log render batching must be between 30 and 250 milliseconds."
            ))
        }
        if !((1 << 20)...(512 << 20)).contains(logs.maximumRenderedUTF8Bytes) {
            issues.append(AppPreferenceIssue(
                field: "logs.maximumRenderedUTF8Bytes",
                message: "Viewer text budget must be between 1 MiB and 512 MiB."
            ))
        } else if ((1 << 20)...(512 << 20)).contains(logs.byteLimit),
            logs.maximumRenderedUTF8Bytes > logs.byteLimit
        {
            issues.append(AppPreferenceIssue(
                field: "logs.maximumRenderedUTF8Bytes",
                message: "Viewer text budget cannot exceed the raw log buffer."
            ))
        }
        if !LogDisplayPreferences.maximumDisplayedLineUTF8BytesRange.contains(
            logs.maximumDisplayedLineUTF8Bytes
        ) {
            issues.append(AppPreferenceIssue(
                field: "logs.maximumDisplayedLineUTF8Bytes",
                message: "Visible log line limit must be between 256 B and 16 MiB."
            ))
        }
        if !(0...100_000).contains(diagnostics.completedOperationHistoryLimit) {
            issues.append(AppPreferenceIssue(
                field: "diagnostics.completedOperationHistoryLimit",
                message: "Completed operation history must be between 0 and 100,000 entries."
            ))
        }
        issues.append(contentsOf: nodeShell.validationIssues())
        issues.append(contentsOf: terminal.validationIssues())
        issues.append(contentsOf: resourceOperations.validationIssues())
        if !(5...300).contains(metricsRefreshSeconds) {
            issues.append(AppPreferenceIssue(
                field: "metricsRefreshSeconds",
                message: "Metrics refresh interval must be between 5 and 300 seconds."
            ))
        }
        issues.append(contentsOf: advancedPerformance.validationIssues())
        let path = columnsConfigurationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty || !NSString(string: path).expandingTildeInPath.hasPrefix("/") {
            issues.append(AppPreferenceIssue(
                field: "columnsConfigurationPath",
                message: "Column configuration path must be an absolute path."
            ))
        }
        return issues
    }

    public func validated() throws -> AppPreferences {
        let issues = validationIssues()
        guard issues.isEmpty else { throw AppPreferencesValidationError(issues: issues) }
        var copy = self
        copy.columnsConfigurationPath = NSString(
            string: columnsConfigurationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        ).expandingTildeInPath
        return copy
    }
}

public enum AppPreferenceChange: CaseIterable, Hashable, Sendable {
    case appearance
    case logDisplay
    case confirmations
    case resourceOperations
    case defaultNamespace
    case workspaceRestoration
    case metricsRefresh
    case columnsConfigurationPath
    case operationHistory
    case nodeShell
    case terminal
    case nodeShellStartupTimeout
    case advancedPerformance
    case viewportOverscan

    public enum Activation: Hashable, Sendable {
        case immediate
        case newWorkspace
        case applicationRelaunch
    }

    public var activation: Activation {
        switch self {
        case .appearance, .logDisplay, .confirmations, .resourceOperations,
            .operationHistory, .nodeShell, .terminal:
            .immediate
        case .defaultNamespace, .viewportOverscan:
            .newWorkspace
        case .workspaceRestoration, .metricsRefresh, .columnsConfigurationPath,
            .nodeShellStartupTimeout, .advancedPerformance:
            .applicationRelaunch
        }
    }

    public var title: String {
        switch self {
        case .appearance: "Appearance"
        case .logDisplay: "Log display"
        case .confirmations: "Confirmation prompts"
        case .resourceOperations: "Resource operation defaults"
        case .defaultNamespace: "Default namespace"
        case .workspaceRestoration: "Open cluster window restoration"
        case .metricsRefresh: "Metrics refresh"
        case .columnsConfigurationPath: "Programmable columns path"
        case .operationHistory: "Completed operation history"
        case .nodeShell: "Node shell defaults"
        case .terminal: "Initial terminal size"
        case .nodeShellStartupTimeout: "Node shell startup timeout"
        case .advancedPerformance: "Advanced performance configuration"
        case .viewportOverscan: "List viewport overscan"
        }
    }
}

/// Describes when saved settings can safely take effect. Helper-owned
/// settings require a full application relaunch: restarting the helper in
/// place could otherwise make an in-flight Kubernetes mutation ambiguous.
public struct AppPreferencesDelta: Hashable, Sendable {
    public let changes: Set<AppPreferenceChange>

    public init(previous: AppPreferences, updated: AppPreferences) {
        var changes: Set<AppPreferenceChange> = []
        if previous.appearance != updated.appearance { changes.insert(.appearance) }
        if previous.logs != updated.logs { changes.insert(.logDisplay) }
        if previous.confirmations != updated.confirmations { changes.insert(.confirmations) }
        if previous.resourceOperations != updated.resourceOperations {
            changes.insert(.resourceOperations)
        }
        if previous.defaultNamespace != updated.defaultNamespace {
            changes.insert(.defaultNamespace)
        }
        if previous.restoreOpenClusterWindows != updated.restoreOpenClusterWindows {
            changes.insert(.workspaceRestoration)
        }
        if previous.metricsRefreshSeconds != updated.metricsRefreshSeconds {
            changes.insert(.metricsRefresh)
        }
        if previous.columnsConfigurationPath != updated.columnsConfigurationPath {
            changes.insert(.columnsConfigurationPath)
        }
        if previous.diagnostics != updated.diagnostics {
            changes.insert(.operationHistory)
        }
        if previous.nodeShell.globalImage != updated.nodeShell.globalImage ||
            previous.nodeShell.clusterImagesByContextReference !=
                updated.nodeShell.clusterImagesByContextReference
        {
            changes.insert(.nodeShell)
        }
        if previous.terminal != updated.terminal {
            changes.insert(.terminal)
        }
        if previous.nodeShell.startupTimeoutSeconds !=
            updated.nodeShell.startupTimeoutSeconds
        {
            changes.insert(.nodeShellStartupTimeout)
        }
        if previous.advancedPerformance.viewportOverscanScreensPerSide
            != updated.advancedPerformance.viewportOverscanScreensPerSide
        {
            changes.insert(.viewportOverscan)
        }
        var previousEnginePerformance = previous.advancedPerformance
        previousEnginePerformance.viewportOverscanScreensPerSide =
            updated.advancedPerformance.viewportOverscanScreensPerSide
        if previousEnginePerformance != updated.advancedPerformance {
            changes.insert(.advancedPerformance)
        }
        self.changes = changes
    }

    public var isEmpty: Bool { changes.isEmpty }

    public func contains(_ change: AppPreferenceChange) -> Bool {
        changes.contains(change)
    }

    public func changes(activated activation: AppPreferenceChange.Activation) -> [AppPreferenceChange] {
        AppPreferenceChange.allCases.filter {
            changes.contains($0) && $0.activation == activation
        }
    }

    public var requiresApplicationRelaunch: Bool {
        !changes(activated: .applicationRelaunch).isEmpty
    }
}

public struct AppPreferenceIssue: Error, Codable, Hashable, Sendable {
    public var field: String
    public var message: String

    public init(field: String, message: String) {
        self.field = field
        self.message = message
    }
}

public struct AppPreferencesValidationError: Error, LocalizedError, Hashable, Sendable {
    public var issues: [AppPreferenceIssue]

    public init(issues: [AppPreferenceIssue]) {
        self.issues = issues
    }

    public var errorDescription: String? {
        issues.first?.message ?? "The settings are invalid."
    }
}

public struct AppPreferencesLoadIssue: Error, LocalizedError, Hashable, Sendable {
    public enum Reason: String, Hashable, Sendable {
        case invalidData
        case invalidValues
    }

    public var reason: Reason
    public var message: String

    public init(reason: Reason, message: String) {
        self.reason = reason
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// A successful compatibility load is intentionally separate from
/// `AppPreferencesLoadIssue`: migration is useful information, not a load
/// failure. The application surfaces this as an informational notice once.
public struct AppPreferencesMigrationNotice: Hashable, Sendable {
    public let message: String

    public init(message: String = "Settings migrated to the current format.") {
        self.message = message
    }
}

@MainActor
public final class AppPreferencesStore {
    public static let storageKey = "kmgr.preferences.document"

    private struct Document: Codable {
        var apiVersion: String
        var preferences: AppPreferences
    }

    private let defaults: UserDefaults
    public private(set) var current: AppPreferences
    public private(set) var loadIssue: AppPreferencesLoadIssue?
    public private(set) var migrationNotice: AppPreferencesMigrationNotice?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        current = AppPreferences()
        loadIssue = nil
        migrationNotice = nil
        loadFromDefaults()
    }

    public func save(_ preferences: AppPreferences) throws {
        let validated = try preferences.validated()
        let document = Document(apiVersion: AppPreferences.apiVersion, preferences: validated)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(try encoder.encode(document), forKey: Self.storageKey)
        current = validated
        loadIssue = nil
        migrationNotice = nil
    }

    public func reset() {
        defaults.removeObject(forKey: Self.storageKey)
        current = AppPreferences()
        loadIssue = nil
        migrationNotice = nil
    }

    private func loadFromDefaults() {
        guard defaults.object(forKey: Self.storageKey) != nil else { return }
        guard let data = defaults.data(forKey: Self.storageKey) else {
            rejectSavedPreferences(AppPreferencesLoadIssue(
                reason: .invalidData,
                message: "Saved settings use an unsupported storage value; conservative defaults are in use."
            ))
            return
        }

        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            rejectSavedPreferences(AppPreferencesLoadIssue(
                reason: .invalidData,
                message: "Saved settings could not be decoded; conservative defaults are in use."
            ))
            return
        }

        guard let root = raw as? [String: Any] else {
            rejectSavedPreferences(AppPreferencesLoadIssue(
                reason: .invalidData,
                message: "Saved settings are not a document; conservative defaults are in use."
            ))
            return
        }

        guard let version = root["apiVersion"] as? String else {
            rejectSavedPreferences(AppPreferencesLoadIssue(
                reason: .invalidData,
                message: "Saved settings do not declare a compatible version; conservative defaults are in use."
            ))
            return
        }
        guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            rejectSavedPreferences(AppPreferencesLoadIssue(
                reason: .invalidData,
                message: "Saved settings do not declare a compatible version; conservative defaults are in use."
            ))
            return
        }

        // The envelope itself is part of the persisted contract. Preference
        // fields may be omitted (they are filled from today's defaults), but
        // a document without a preferences object is not identifiable as an
        // AppPreferences document and must fail closed.
        guard let rawPreferences = root["preferences"] else {
            rejectSavedPreferences(AppPreferencesLoadIssue(
                reason: .invalidData,
                message: "Saved settings do not contain a preferences object; conservative defaults are in use."
            ))
            return
        }
        guard rawPreferences is [String: Any] else {
            rejectSavedPreferences(AppPreferencesLoadIssue(
                reason: .invalidData,
                message: "Saved settings preferences must be an object; conservative defaults are in use."
            ))
            return
        }

        let template: Any
        do {
            guard let encodedTemplate = Self.encodedTemplate else {
                throw PreferenceCompatibilityIssue("the current settings schema could not be encoded")
            }
            template = try JSONSerialization.jsonObject(
                with: encodedTemplate,
                options: [.fragmentsAllowed]
            )
        } catch {
            // This is a programming error rather than user data, but keeping
            // the boundary conservative avoids ever activating an unvalidated
            // preference object if the model/template drift apart.
            rejectSavedPreferences(AppPreferencesLoadIssue(
                reason: .invalidData,
                message: "Saved settings could not be validated; conservative defaults are in use."
            ))
            return
        }

        let normalized: Any
        var didFillMissingFields = false
        do {
            var path = ""
            normalized = try Self.normalize(
                root,
                against: template,
                path: &path,
                didFillMissingFields: &didFillMissingFields
            )
        } catch let issue as PreferenceCompatibilityIssue {
            rejectSavedPreferences(AppPreferencesLoadIssue(
                reason: .invalidData,
                message: "Saved settings are incompatible (\(issue.message)); conservative defaults are in use."
            ))
            return
        } catch {
            rejectSavedPreferences(AppPreferencesLoadIssue(
                reason: .invalidData,
                message: "Saved settings could not be decoded; conservative defaults are in use."
            ))
            return
        }

        guard var normalizedRoot = normalized as? [String: Any] else {
            rejectSavedPreferences(AppPreferencesLoadIssue(
                reason: .invalidData,
                message: "Saved settings are not a compatible document; conservative defaults are in use."
            ))
            return
        }
        // The version is metadata, not a dispatch table. Every successful
        // load is emitted in the one current format.
        normalizedRoot["apiVersion"] = AppPreferences.apiVersion

        let normalizedData: Data
        do {
            normalizedData = try JSONSerialization.data(withJSONObject: normalizedRoot)
        } catch {
            rejectSavedPreferences(AppPreferencesLoadIssue(
                reason: .invalidData,
                message: "Saved settings could not be normalized; conservative defaults are in use."
            ))
            return
        }

        let document: Document
        let didCanonicalizeValues: Bool
        do {
            document = try JSONDecoder().decode(Document.self, from: normalizedData)
            let decodedPreferences = document.preferences
            current = try decodedPreferences.validated()
            didCanonicalizeValues = current != decodedPreferences
        } catch let error as AppPreferencesValidationError {
            rejectSavedPreferences(AppPreferencesLoadIssue(
                reason: .invalidValues,
                message: "Saved settings contain invalid limits (\(error.localizedDescription)); conservative defaults are in use."
            ))
            return
        } catch {
            rejectSavedPreferences(AppPreferencesLoadIssue(
                reason: .invalidData,
                message: "Saved settings contain fields with incompatible types; conservative defaults are in use."
            ))
            return
        }

        let needsMigration = version != AppPreferences.apiVersion ||
            didFillMissingFields || didCanonicalizeValues
        if needsMigration {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                defaults.set(try encoder.encode(
                    Document(apiVersion: AppPreferences.apiVersion, preferences: current)
                ), forKey: Self.storageKey)
                migrationNotice = AppPreferencesMigrationNotice()
            } catch {
                // `current` is already validated and remains safe in memory;
                // retain the source bytes so a transient defaults failure does
                // not discard a user's settings.
                migrationNotice = AppPreferencesMigrationNotice(
                    message: "Settings were read using the current format, but could not be rewritten."
                )
            }
        }
    }

    private func rejectSavedPreferences(_ issue: AppPreferencesLoadIssue) {
        defaults.removeObject(forKey: Self.storageKey)
        current = AppPreferences()
        loadIssue = issue
        migrationNotice = nil
    }

    private static let encodedTemplate: Data? = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // If a future field makes the template unencodable, the loader fails
        // closed rather than accepting an unvalidated preference object.
        return try? encoder.encode(
            Document(apiVersion: AppPreferences.apiVersion, preferences: AppPreferences())
        )
    }()

    private static func normalize(
        _ raw: Any,
        against template: Any,
        path: inout String,
        didFillMissingFields: inout Bool
    ) throws -> Any {
        if let templateObject = template as? [String: Any] {
            guard let rawObject = raw as? [String: Any] else {
                throw PreferenceCompatibilityIssue(
                    "\(path.isEmpty ? "document" : path) must be an object"
                )
            }
            // Empty dictionaries in this model are maps whose keys are user
            // supplied context references, not schema fields. Their value
            // types are checked by the final Codable decode.
            if templateObject.isEmpty {
                return rawObject
            }
            let knownKeys = Set(templateObject.keys)
            if let unknown = rawObject.keys.first(where: { !knownKeys.contains($0) }) {
                throw PreferenceCompatibilityIssue(
                    "unknown field \(path.isEmpty ? unknown : "\(path).\(unknown)")"
                )
            }
            var result = rawObject
            for key in templateObject.keys.sorted() {
                let previousPath = path
                path = previousPath.isEmpty ? key : "\(previousPath).\(key)"
                if let value = rawObject[key] {
                    result[key] = try normalize(
                        value,
                        against: templateObject[key]!,
                        path: &path,
                        didFillMissingFields: &didFillMissingFields
                    )
                } else {
                    result[key] = templateObject[key]
                    didFillMissingFields = true
                }
                path = previousPath
            }
            return result
        }

        if let templateArray = template as? [Any] {
            guard let rawArray = raw as? [Any] else {
                throw PreferenceCompatibilityIssue(
                    "\(path.isEmpty ? "value" : path) must be an array"
                )
            }
            // There are currently no array-valued preferences. Keep the
            // compatibility walker future-proof: a non-empty default array
            // supplies an element schema, while an empty array is checked by
            // the final Codable decode (which knows the concrete element
            // type). Missing arrays are still filled by the object branch.
            guard let elementTemplate = templateArray.first else {
                return rawArray
            }
            var result: [Any] = []
            result.reserveCapacity(rawArray.count)
            for (index, value) in rawArray.enumerated() {
                let previousPath = path
                path = "\(previousPath)[\(index)]"
                result.append(try normalize(
                    value,
                    against: elementTemplate,
                    path: &path,
                    didFillMissingFields: &didFillMissingFields
                ))
                path = previousPath
            }
            return result
        }

        guard Self.isJSONValue(raw, compatibleWith: template) else {
            throw PreferenceCompatibilityIssue(
                "\(path.isEmpty ? "value" : path) has an incompatible type"
            )
        }
        return raw
    }

    private static func isJSONValue(_ value: Any, compatibleWith template: Any) -> Bool {
        if template is String { return value is String }
        if template is Bool {
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }
        if let expected = template as? NSNumber {
            guard let actual = value as? NSNumber,
                CFGetTypeID(actual) != CFBooleanGetTypeID()
            else { return false }
            // JSON has one numeric value type. Foundation may represent an
            // integral Double as an integer NSNumber (and vice versa) after a
            // round trip. The final Codable decode enforces whether the
            // destination property is an Int or a Double, so this preflight
            // only rejects non-numbers, Booleans, and non-finite values.
            _ = expected
            return actual.doubleValue.isFinite
        }
        return value is NSNull && template is NSNull
    }

    private struct PreferenceCompatibilityIssue: Error {
        let message: String

        init(_ message: String) { self.message = message }
    }
}

public struct KeyboardShortcutReference: Hashable, Sendable {
    public var keys: String
    public var action: String

    public init(keys: String, action: String) {
        self.keys = keys
        self.action = action
    }

    public static let defaults: [Self] = [
        Self(keys: "⌘N", action: "New Cluster Window"),
        Self(keys: "⌘K", action: "Command Palette"),
        Self(keys: "⇧⌘N", action: "Choose workspace namespace"),
        Self(keys: "/", action: "Filter current resource list"),
        Self(keys: "↑ / ↓ or K / J", action: "Move table selection"),
        Self(keys: "⇧↑ / ⇧↓ or ⇧-click", action: "Extend selection"),
        Self(
            keys: "⌘-click",
            action: "Toggle a table row, or open a sidebar resource in a new workspace"
        ),
        Self(keys: "⌘A", action: "Select all visible rows"),
        Self(keys: "Return", action: "Enter the selected object's subresource"),
        Self(keys: "⌘Return", action: "Enter the selected subresource in a new workspace"),
        Self(keys: "P", action: "Go to the selected object's parent"),
        Self(keys: "⌘P", action: "Go to the selected object's parent in a new workspace"),
        Self(keys: "O", action: "Show the selected Pod's Node"),
        Self(keys: "⌘O", action: "Show the selected Pod's Node in a new workspace"),
        Self(keys: "D", action: "Open Details for the selected object"),
        Self(keys: "⌘[ / ⌘]", action: "Back / Forward"),
        Self(keys: "Escape", action: "Close transient UI, leave edit mode, clear filter, or return focus"),
        Self(keys: "Y", action: "Open selected object YAML"),
        Self(keys: "E", action: "Edit selected object YAML"),
        Self(keys: "L", action: "Open logs"),
        Self(keys: "\u{21E7}L", action: "Open previous container logs"),
        Self(keys: "S", action: "Open Pod or Node shell"),
        Self(keys: "⇧S", action: "Configure Pod or Node shell"),
        Self(keys: "F", action: "Start a Pod or Service port-forward"),
        Self(keys: "⌘F", action: "Start a port-forward and show Port Forwards"),
        Self(keys: "R", action: "Rollout restart the selected workload"),
        Self(keys: "⌘⌫", action: "Delete selection"),
        Self(keys: "⌘S", action: "Save the active object edit"),
    ]
}
