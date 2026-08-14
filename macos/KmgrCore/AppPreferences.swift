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

    public init(
        recordLimit: Int = 20_000,
        byteLimit: Int = 16 << 20,
        renderBatchMilliseconds: Int = 40
    ) {
        self.recordLimit = recordLimit
        self.byteLimit = byteLimit
        self.renderBatchMilliseconds = renderBatchMilliseconds
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

public struct AppPreferences: Codable, Hashable, Sendable {
    public static let apiVersion = "kmgr.preferences/v1"

    public var appearance: AppearancePreference
    public var logs: LogDisplayPreferences
    public var metricsRefreshSeconds: Int
    public var defaultNamespace: DefaultNamespacePreference
    public var restoreOpenClusterWindows: Bool
    public var confirmations: ConfirmationPreferences
    public var columnsConfigurationPath: String

    public init(
        appearance: AppearancePreference = .system,
        logs: LogDisplayPreferences = LogDisplayPreferences(),
        metricsRefreshSeconds: Int = 15,
        defaultNamespace: DefaultNamespacePreference = .contextDefault,
        restoreOpenClusterWindows: Bool = true,
        confirmations: ConfirmationPreferences = ConfirmationPreferences(),
        columnsConfigurationPath: String = AppPreferences.defaultColumnsConfigurationPath
    ) {
        self.appearance = appearance
        self.logs = logs
        self.metricsRefreshSeconds = metricsRefreshSeconds
        self.defaultNamespace = defaultNamespace
        self.restoreOpenClusterWindows = restoreOpenClusterWindows
        self.confirmations = confirmations
        self.columnsConfigurationPath = columnsConfigurationPath
    }

    private enum CodingKeys: String, CodingKey {
        case appearance
        case logs
        case metricsRefreshSeconds
        case defaultNamespace
        case restoreOpenClusterWindows
        case confirmations
        case columnsConfigurationPath
    }

    /// Preferences documents predate the restoration toggle but share the v1
    /// schema. Preserve those users' settings and apply the documented
    /// default instead of rejecting the complete document for one absent key.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            appearance: try container.decode(AppearancePreference.self, forKey: .appearance),
            logs: try container.decode(LogDisplayPreferences.self, forKey: .logs),
            metricsRefreshSeconds: try container.decode(Int.self, forKey: .metricsRefreshSeconds),
            defaultNamespace: try container.decode(
                DefaultNamespacePreference.self,
                forKey: .defaultNamespace
            ),
            restoreOpenClusterWindows: try container.decodeIfPresent(
                Bool.self,
                forKey: .restoreOpenClusterWindows
            ) ?? true,
            confirmations: try container.decode(
                ConfirmationPreferences.self,
                forKey: .confirmations
            ),
            columnsConfigurationPath: try container.decode(
                String.self,
                forKey: .columnsConfigurationPath
            )
        )
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
        if !(5...300).contains(metricsRefreshSeconds) {
            issues.append(AppPreferenceIssue(
                field: "metricsRefreshSeconds",
                message: "Metrics refresh interval must be between 5 and 300 seconds."
            ))
        }
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

    public enum Activation: Hashable, Sendable {
        case immediate
        case newWorkspace
        case applicationRelaunch
    }

    public var activation: Activation {
        switch self {
        case .appearance, .logDisplay, .confirmations:
            .immediate
        case .defaultNamespace:
            .newWorkspace
        case .workspaceRestoration, .metricsRefresh, .columnsConfigurationPath:
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
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            loadIssue = AppPreferencesLoadIssue(
                reason: .invalidData,
                message: "Saved settings could not be decoded; conservative defaults are in use."
            )
            return
        }
        guard document.apiVersion == AppPreferences.apiVersion else {
            loadIssue = AppPreferencesLoadIssue(
                reason: .unsupportedVersion,
                message: "Saved settings use unsupported version \(document.apiVersion); conservative defaults are in use."
            )
            return
        }
        do {
            current = try document.preferences.validated()
        } catch {
            loadIssue = AppPreferencesLoadIssue(
                reason: .invalidValues,
                message: "Saved settings contain invalid limits; conservative defaults are in use."
            )
        }
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
        Self(keys: "/", action: "Filter current resource list"),
        Self(keys: "↑ / ↓ or K / J", action: "Move table selection"),
        Self(keys: "⇧↑ / ⇧↓ or ⇧-click", action: "Extend selection"),
        Self(keys: "⌘-click", action: "Toggle one selected object"),
        Self(keys: "⌘A", action: "Select all visible rows"),
        Self(keys: "Return", action: "Enter the selected object's subresource"),
        Self(keys: "⌘Return", action: "Open selected object details"),
        Self(keys: "⌘[ / ⌘]", action: "Back / Forward"),
        Self(keys: "Escape", action: "Close transient UI, leave edit mode, clear filter, or return focus"),
        Self(keys: "Y", action: "Open YAML for one object"),
        Self(keys: "E", action: "Open Events for one object"),
        Self(keys: "L", action: "Open logs"),
        Self(keys: "S", action: "Open Pod shell"),
        Self(keys: "P", action: "Start a Pod or Service port-forward"),
        Self(keys: "⌘⌫", action: "Delete selection"),
        Self(keys: "⌘S", action: "Save the active object edit"),
    ]
}
