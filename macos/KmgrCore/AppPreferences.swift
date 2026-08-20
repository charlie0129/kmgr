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
    public var recordLimit: Int
    public var byteLimit: Int
    public var renderBatchMilliseconds: Int
    public var maximumDisplayedLineUTF8Bytes: Int

    public init(
        recordLimit: Int = 20_000,
        byteLimit: Int = 16 << 20,
        renderBatchMilliseconds: Int = 40,
        maximumDisplayedLineUTF8Bytes: Int = 4 << 10
    ) {
        self.recordLimit = recordLimit
        self.byteLimit = byteLimit
        self.renderBatchMilliseconds = renderBatchMilliseconds
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

    public var globalImage: String
    public var clusterImagesByContextReference: [String: String]

    public init(
        globalImage: String = Self.defaultImage,
        clusterImagesByContextReference: [String: String] = [:]
    ) {
        self.globalImage = globalImage
        self.clusterImagesByContextReference = clusterImagesByContextReference
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

public enum PreferenceControlledMutation: Hashable, Sendable {
    case workloadRestart
    case scaling
}

public struct AdvancedPerformancePreferences: Codable, Hashable, Sendable {
    public var viewportOverscanScreensPerSide: Int
    public var globalWarmCacheViewLimit: Int
    public var globalWarmCacheObjectLimit: Int
    public var globalWarmCacheMemoryPercent: Int
    public var authorityWarmCacheViewLimit: Int
    public var authorityWarmCacheObjectLimit: Int
    public var authorityWarmCacheMemoryPercent: Int
    public var kubernetesQPS: Double
    public var kubernetesBurst: Int
    public var idleMetricProviderLimit: Int
    public var idleMetricSampleLimit: Int
    public var exactPodMetricsEntryLimit: Int
    public var exactPodMetricsSampleLimit: Int
    public var exactPodMetricsDetailEntryLimit: Int
    public var exactPodMetricsGETConcurrency: Int
    public var logSourceOpenConcurrency: Int

    public init(
        viewportOverscanScreensPerSide: Int = 10,
        globalWarmCacheViewLimit: Int = 24,
        globalWarmCacheObjectLimit: Int = 250_000,
        globalWarmCacheMemoryPercent: Int = 20,
        authorityWarmCacheViewLimit: Int = 8,
        authorityWarmCacheObjectLimit: Int = 100_000,
        authorityWarmCacheMemoryPercent: Int = 20,
        kubernetesQPS: Double = 40,
        kubernetesBurst: Int = 80,
        idleMetricProviderLimit: Int = 8,
        idleMetricSampleLimit: Int = 100_000,
        exactPodMetricsEntryLimit: Int = 100_000,
        exactPodMetricsSampleLimit: Int = 100_000,
        exactPodMetricsDetailEntryLimit: Int = 256,
        exactPodMetricsGETConcurrency: Int = 16,
        logSourceOpenConcurrency: Int = 16
    ) {
        self.viewportOverscanScreensPerSide = viewportOverscanScreensPerSide
        self.globalWarmCacheViewLimit = globalWarmCacheViewLimit
        self.globalWarmCacheObjectLimit = globalWarmCacheObjectLimit
        self.globalWarmCacheMemoryPercent = globalWarmCacheMemoryPercent
        self.authorityWarmCacheViewLimit = authorityWarmCacheViewLimit
        self.authorityWarmCacheObjectLimit = authorityWarmCacheObjectLimit
        self.authorityWarmCacheMemoryPercent = authorityWarmCacheMemoryPercent
        self.kubernetesQPS = kubernetesQPS
        self.kubernetesBurst = kubernetesBurst
        self.idleMetricProviderLimit = idleMetricProviderLimit
        self.idleMetricSampleLimit = idleMetricSampleLimit
        self.exactPodMetricsEntryLimit = exactPodMetricsEntryLimit
        self.exactPodMetricsSampleLimit = exactPodMetricsSampleLimit
        self.exactPodMetricsDetailEntryLimit = exactPodMetricsDetailEntryLimit
        self.exactPodMetricsGETConcurrency = exactPodMetricsGETConcurrency
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
        validateCount(
            logSourceOpenConcurrency,
            field: "advancedPerformance.logSourceOpenConcurrency",
            title: "Log source open concurrency"
        )
        return issues
    }
}

public struct AppPreferences: Codable, Hashable, Sendable {
    public static let apiVersion = "kmgr.preferences/v6"

    public var appearance: AppearancePreference
    public var logs: LogDisplayPreferences
    public var metricsRefreshSeconds: Int
    public var defaultNamespace: DefaultNamespacePreference
    public var restoreOpenClusterWindows: Bool
    public var confirmations: ConfirmationPreferences
    public var columnsConfigurationPath: String
    public var diagnostics: DiagnosticsPreferences
    public var nodeShell: NodeShellPreferences
    public var advancedPerformance: AdvancedPerformancePreferences

    public init(
        appearance: AppearancePreference = .system,
        logs: LogDisplayPreferences = LogDisplayPreferences(),
        metricsRefreshSeconds: Int = 15,
        defaultNamespace: DefaultNamespacePreference = .contextDefault,
        restoreOpenClusterWindows: Bool = true,
        confirmations: ConfirmationPreferences = ConfirmationPreferences(),
        columnsConfigurationPath: String = AppPreferences.defaultColumnsConfigurationPath,
        diagnostics: DiagnosticsPreferences = DiagnosticsPreferences(),
        nodeShell: NodeShellPreferences = NodeShellPreferences(),
        advancedPerformance: AdvancedPerformancePreferences = AdvancedPerformancePreferences()
    ) {
        self.appearance = appearance
        self.logs = logs
        self.metricsRefreshSeconds = metricsRefreshSeconds
        self.defaultNamespace = defaultNamespace
        self.restoreOpenClusterWindows = restoreOpenClusterWindows
        self.confirmations = confirmations
        self.columnsConfigurationPath = columnsConfigurationPath
        self.diagnostics = diagnostics
        self.nodeShell = nodeShell
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
        if !((1 << 10)...(1 << 20)).contains(logs.maximumDisplayedLineUTF8Bytes) {
            issues.append(AppPreferenceIssue(
                field: "logs.maximumDisplayedLineUTF8Bytes",
                message: "Displayed log line limit must be between 1 KiB and 1 MiB."
            ))
        }
        if !(0...100_000).contains(diagnostics.completedOperationHistoryLimit) {
            issues.append(AppPreferenceIssue(
                field: "diagnostics.completedOperationHistoryLimit",
                message: "Completed operation history must be between 0 and 100,000 entries."
            ))
        }
        issues.append(contentsOf: nodeShell.validationIssues())
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
    case defaultNamespace
    case workspaceRestoration
    case metricsRefresh
    case columnsConfigurationPath
    case operationHistory
    case nodeShell
    case advancedPerformance
    case viewportOverscan

    public enum Activation: Hashable, Sendable {
        case immediate
        case newWorkspace
        case applicationRelaunch
    }

    public var activation: Activation {
        switch self {
        case .appearance, .logDisplay, .confirmations, .operationHistory, .nodeShell:
            .immediate
        case .defaultNamespace, .viewportOverscan:
            .newWorkspace
        case .workspaceRestoration, .metricsRefresh, .columnsConfigurationPath,
            .advancedPerformance:
            .applicationRelaunch
        }
    }

    public var title: String {
        switch self {
        case .appearance: "Appearance"
        case .logDisplay: "Log display"
        case .confirmations: "Confirmation prompts"
        case .defaultNamespace: "Default namespace"
        case .workspaceRestoration: "Open cluster window restoration"
        case .metricsRefresh: "Metrics refresh"
        case .columnsConfigurationPath: "Programmable columns path"
        case .operationHistory: "Completed operation history"
        case .nodeShell: "Node shell defaults"
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
        if previous.nodeShell != updated.nodeShell {
            changes.insert(.nodeShell)
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
        case unsupportedVersion
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

@MainActor
public final class AppPreferencesStore {
    public static let storageKey = "kmgr.preferences.document"

    private struct Document: Codable {
        var apiVersion: String
        var preferences: AppPreferences
    }

    private struct Envelope: Decodable {
        var apiVersion: String
    }

    private let defaults: UserDefaults
    public private(set) var current: AppPreferences
    public private(set) var loadIssue: AppPreferencesLoadIssue?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        current = AppPreferences()
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
    }

    public func reset() {
        defaults.removeObject(forKey: Self.storageKey)
        current = AppPreferences()
        loadIssue = nil
    }

    private func loadFromDefaults() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        let decoder = JSONDecoder()
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            rejectSavedPreferences(AppPreferencesLoadIssue(
                reason: .invalidData,
                message: "Saved settings could not be decoded; conservative defaults are in use."
            ))
            return
        }
        guard envelope.apiVersion == AppPreferences.apiVersion else {
            rejectSavedPreferences(AppPreferencesLoadIssue(
                reason: .unsupportedVersion,
                message: "Saved settings use unsupported version \(envelope.apiVersion); conservative defaults are in use."
            ))
            return
        }
        let document: Document
        do {
            document = try decoder.decode(Document.self, from: data)
        } catch {
            rejectSavedPreferences(AppPreferencesLoadIssue(
                reason: .invalidData,
                message: "Saved settings could not be decoded; conservative defaults are in use."
            ))
            return
        }
        do {
            current = try document.preferences.validated()
        } catch {
            rejectSavedPreferences(AppPreferencesLoadIssue(
                reason: .invalidValues,
                message: "Saved settings contain invalid limits; conservative defaults are in use."
            ))
        }
    }

    private func rejectSavedPreferences(_ issue: AppPreferencesLoadIssue) {
        defaults.removeObject(forKey: Self.storageKey)
        current = AppPreferences()
        loadIssue = issue
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
        Self(keys: "⌘-click", action: "Toggle one selected object"),
        Self(keys: "⌘A", action: "Select all visible rows"),
        Self(keys: "Return", action: "Enter the selected object's subresource"),
        Self(keys: "D", action: "Describe the selected object"),
        Self(keys: "⌘[ / ⌘]", action: "Back / Forward"),
        Self(keys: "Escape", action: "Close transient UI, leave edit mode, clear filter, or return focus"),
        Self(keys: "Y", action: "Open selected object YAML in Details"),
        Self(keys: "\u{21E7}Y", action: "Open selected object YAML in a new window"),
        Self(keys: "E", action: "Open Events for one object"),
        Self(keys: "L", action: "Open logs"),
        Self(keys: "\u{21E7}L", action: "Open previous container logs"),
        Self(keys: "S", action: "Open Pod or Node shell"),
        Self(keys: "⇧S", action: "Configure Pod or Node shell"),
        Self(keys: "P", action: "Start a Pod or Service port-forward"),
        Self(keys: "⌘⌫", action: "Delete selection"),
        Self(keys: "⌘S", action: "Save the active object edit"),
    ]
}
