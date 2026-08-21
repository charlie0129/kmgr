import Foundation
import Testing
@testable import KmgrCore

@MainActor
@Test func appPreferencesRoundTripAsOneVersionedDocument() throws {
    let suite = "kmgr-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppPreferencesStore(defaults: defaults)
    var preferences = AppPreferences()
    preferences.appearance = .dark
    preferences.logs = LogDisplayPreferences(
        recordLimit: 75_000,
        byteLimit: 32 << 20,
        renderBatchMilliseconds: 50,
        maximumRenderedUTF8Bytes: 24 << 20,
        maximumDisplayedLineUTF8Bytes: 8 << 10
    )
    preferences.diagnostics = DiagnosticsPreferences(
        completedOperationHistoryLimit: 4_000
    )
    preferences.nodeShell = NodeShellPreferences(
        globalImage: "registry.example/global-node-shell:1",
        clusterImagesByContextReference: [
            "context-ref-a": "registry.example/cluster-node-shell:2",
        ],
        startupTimeoutSeconds: 90
    )
    preferences.metricsRefreshSeconds = 30
    preferences.defaultNamespace = .allNamespaces
    preferences.restoreOpenClusterWindows = false
    preferences.confirmations.confirmWorkloadRestart = false
    preferences.resourceOperations.defaultDeleteConcurrency = 12
    preferences.columnsConfigurationPath = "~/Library/Application Support/kmgr/custom-columns.yaml"
    preferences.advancedPerformance = AdvancedPerformancePreferences(
        viewportOverscanScreensPerSide: 17,
        viewReleaseGraceSeconds: 45,
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
    )
    try store.save(preferences)

    let reloaded = AppPreferencesStore(defaults: defaults)
    #expect(reloaded.current.appearance == .dark)
    #expect(reloaded.current.logs.recordLimit == 75_000)
    #expect(reloaded.current.logs.byteLimit == 32 << 20)
    #expect(reloaded.current.logs.maximumRenderedUTF8Bytes == 24 << 20)
    #expect(reloaded.current.logs.maximumDisplayedLineUTF8Bytes == 8 << 10)
    #expect(reloaded.current.diagnostics.completedOperationHistoryLimit == 4_000)
    #expect(reloaded.current.nodeShell == preferences.nodeShell)
    #expect(reloaded.current.metricsRefreshSeconds == 30)
    #expect(reloaded.current.defaultNamespace == .allNamespaces)
    #expect(!reloaded.current.restoreOpenClusterWindows)
    #expect(!reloaded.current.confirmations.confirmWorkloadRestart)
    #expect(reloaded.current.resourceOperations.defaultDeleteConcurrency == 12)
    #expect(reloaded.current.columnsConfigurationPath.hasPrefix("/"))
    #expect(reloaded.current.advancedPerformance == preferences.advancedPerformance)
    #expect(reloaded.current.advancedPerformance.viewReleaseGraceSeconds == 45)
    #expect(reloaded.loadIssue == nil)

    let encoded = try #require(defaults.data(forKey: AppPreferencesStore.storageKey))
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["apiVersion"] as? String == AppPreferences.apiVersion)
    let encodedKeys = try #require(String(data: encoded, encoding: .utf8)).lowercased()
    #expect(!encodedKeys.contains("token"))
    #expect(!encodedKeys.contains("credential"))
}

@MainActor
@Test func unsupportedOrInvalidSavedPreferencesFallBackExplicitly() throws {
    let suite = "kmgr-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let encodedDefaults = try JSONEncoder().encode(AppPreferences())
    let preferencesObject = try #require(
        JSONSerialization.jsonObject(with: encodedDefaults) as? [String: Any]
    )
    defaults.set(
        try JSONSerialization.data(withJSONObject: [
            "apiVersion": "kmgr.preferences/v99",
            "preferences": preferencesObject,
        ]),
        forKey: AppPreferencesStore.storageKey
    )
    var store = AppPreferencesStore(defaults: defaults)
    #expect(store.current == AppPreferences())
    #expect(store.loadIssue?.reason == .unsupportedVersion)
    #expect(defaults.data(forKey: AppPreferencesStore.storageKey) == nil)

    defaults.set(Data("not-json".utf8), forKey: AppPreferencesStore.storageKey)
    store = AppPreferencesStore(defaults: defaults)
    #expect(store.current == AppPreferences())
    #expect(store.loadIssue?.reason == .invalidData)
    #expect(defaults.data(forKey: AppPreferencesStore.storageKey) == nil)
}

@Test func appPreferenceValidationEnforcesConservativeBoundsAndSafetyInvariants() throws {
    var preferences = AppPreferences()
    preferences.logs.recordLimit = 10
    preferences.logs.byteLimit = 100
    preferences.logs.renderBatchMilliseconds = 1
    preferences.logs.maximumRenderedUTF8Bytes = 100
    preferences.logs.maximumDisplayedLineUTF8Bytes = 100
    preferences.diagnostics.completedOperationHistoryLimit = 100_001
    preferences.metricsRefreshSeconds = 1
    preferences.columnsConfigurationPath = "relative/columns.yaml"
    preferences.resourceOperations.defaultDeleteConcurrency = 17
    preferences.nodeShell.startupTimeoutSeconds = 0
    preferences.advancedPerformance = AdvancedPerformancePreferences(
        viewportOverscanScreensPerSide: 101,
        viewReleaseGraceSeconds: 301,
        globalWarmCacheViewLimit: 0,
        globalWarmCacheObjectLimit: 0,
        globalWarmCacheMemoryPercent: 0,
        authorityWarmCacheViewLimit: 0,
        authorityWarmCacheObjectLimit: 0,
        authorityWarmCacheMemoryPercent: 101,
        kubernetesQPS: .infinity,
        kubernetesBurst: 0,
        kubernetesListPageSize: 10_001,
        clusterConnectionTimeoutSeconds: 0,
        kubernetesRequestTimeoutSeconds: 3_601,
        idleMetricProviderLimit: 0,
        idleMetricSampleLimit: 0,
        exactPodMetricsEntryLimit: 0,
        exactPodMetricsSampleLimit: 0,
        exactPodMetricsDetailEntryLimit: 0,
        exactPodMetricsGETConcurrency: 0,
        logQueueRecordLimit: 262_145,
        logQueueByteLimit: 0,
        logSourceOpenConcurrency: 0
    )
    let fields = Set(preferences.validationIssues().map(\.field))
    #expect(fields == [
        "logs.recordLimit",
        "logs.byteLimit",
        "logs.renderBatchMilliseconds",
        "logs.maximumRenderedUTF8Bytes",
        "logs.maximumDisplayedLineUTF8Bytes",
        "diagnostics.completedOperationHistoryLimit",
        "metricsRefreshSeconds",
        "columnsConfigurationPath",
        "resourceOperations.defaultDeleteConcurrency",
        "nodeShell.startupTimeoutSeconds",
        "advancedPerformance.viewportOverscanScreensPerSide",
        "advancedPerformance.viewReleaseGraceSeconds",
        "advancedPerformance.globalWarmCacheViewLimit",
        "advancedPerformance.globalWarmCacheObjectLimit",
        "advancedPerformance.globalWarmCacheMemoryPercent",
        "advancedPerformance.authorityWarmCacheViewLimit",
        "advancedPerformance.authorityWarmCacheObjectLimit",
        "advancedPerformance.authorityWarmCacheMemoryPercent",
        "advancedPerformance.kubernetesQPS",
        "advancedPerformance.kubernetesBurst",
        "advancedPerformance.kubernetesListPageSize",
        "advancedPerformance.clusterConnectionTimeoutSeconds",
        "advancedPerformance.kubernetesRequestTimeoutSeconds",
        "advancedPerformance.idleMetricProviderLimit",
        "advancedPerformance.idleMetricSampleLimit",
        "advancedPerformance.exactPodMetricsEntryLimit",
        "advancedPerformance.exactPodMetricsSampleLimit",
        "advancedPerformance.exactPodMetricsDetailEntryLimit",
        "advancedPerformance.exactPodMetricsGETConcurrency",
        "advancedPerformance.logQueueRecordLimit",
        "advancedPerformance.logQueueByteLimit",
        "advancedPerformance.logSourceOpenConcurrency",
    ])
    #expect(ConfirmationPreferences.alwaysConfirmResourceDeletion)
    #expect(ConfirmationPreferences.alwaysConfirmActiveTerminalClose)
    #expect(ConfirmationPreferences.alwaysConfirmNonLoopbackPortForward)
    #expect(ConfirmationPreferences.alwaysShowClusterAndNamespaceIdentity)
    #expect(KeyboardShortcutReference.defaults.contains { $0.keys == "S" })
    #expect(KeyboardShortcutReference.defaults.contains { $0.keys == "⇧S" })
    #expect(KeyboardShortcutReference.defaults.contains {
        $0.keys == "⇧⌘N" && $0.action.contains("namespace")
    })
    #expect(AppPreferences().restoreOpenClusterWindows)
}

@Test func nodeShellPreferencesChooseClusterOverrideAndRejectUnsafeValues() {
    var preferences = NodeShellPreferences(globalImage: "registry.example/global:1")
    #expect(preferences.effectiveImage(contextReference: "cluster-a")
        == "registry.example/global:1")
    preferences.setClusterImage(
        "registry.example/cluster:2",
        contextReference: "cluster-a"
    )
    #expect(preferences.effectiveImage(contextReference: "cluster-a")
        == "registry.example/cluster:2")
    preferences.setClusterImage(nil, contextReference: "cluster-a")
    #expect(preferences.effectiveImage(contextReference: "cluster-a")
        == "registry.example/global:1")
    #expect(NodeShellPreferences.isValidImage("registry.example/ns/image:tag"))
    #expect(!NodeShellPreferences.isValidImage(" registry.example/image:tag"))
    #expect(!NodeShellPreferences.isValidImage("registry.example/image\nsecret"))

    var app = AppPreferences()
    app.nodeShell.globalImage = "bad image"
    #expect(app.validationIssues().contains { $0.field == "nodeShell.globalImage" })
}

@MainActor
@Test func oldPreferenceSchemaIsResetWithoutDecodingLegacyFields() throws {
    let suite = "kmgr-tests-old-performance-schema-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    var preferences = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(AppPreferences()))
            as? [String: Any]
    )
    var advanced = try #require(preferences["advancedPerformance"] as? [String: Any])
    for key in [
        "idleMetricProviderLimit", "idleMetricSampleLimit",
        "exactPodMetricsEntryLimit", "exactPodMetricsSampleLimit",
        "exactPodMetricsDetailEntryLimit", "exactPodMetricsGETConcurrency",
        "logSourceOpenConcurrency",
    ] {
        advanced.removeValue(forKey: key)
    }
    preferences["advancedPerformance"] = advanced
    defaults.set(
        try JSONSerialization.data(withJSONObject: [
            "apiVersion": "kmgr.preferences/v2",
            "preferences": preferences,
        ]),
        forKey: AppPreferencesStore.storageKey
    )

    let store = AppPreferencesStore(defaults: defaults)
    #expect(store.current == AppPreferences())
    #expect(store.loadIssue?.reason == .unsupportedVersion)
    #expect(defaults.data(forKey: AppPreferencesStore.storageKey) == nil)
}

@Test func performanceCountsRejectValuesOutsideSigned32BitRange() {
    var preferences = AppPreferences()
    preferences.advancedPerformance.exactPodMetricsEntryLimit = Int(Int32.max) + 1
    #expect(preferences.validationIssues().contains {
        $0.field == "advancedPerformance.exactPodMetricsEntryLimit"
    })
}

@Test func viewReleaseGraceUsesBoundedWholeSeconds() {
    var preferences = AppPreferences()
    #expect(preferences.advancedPerformance.viewReleaseGraceSeconds == 3)
    for valid in [1, 300] {
        preferences.advancedPerformance.viewReleaseGraceSeconds = valid
        #expect(!preferences.validationIssues().contains {
            $0.field == "advancedPerformance.viewReleaseGraceSeconds"
        })
    }
    for invalid in [0, 301] {
        preferences.advancedPerformance.viewReleaseGraceSeconds = invalid
        #expect(preferences.validationIssues().contains {
            $0.field == "advancedPerformance.viewReleaseGraceSeconds"
        })
    }
}

@Test func defaultNamespacePreferenceSeedsOnlyNewWorkspaceScope() {
    #expect(
        DefaultNamespacePreference.contextDefault.initialSelection(
            contextDefaultNamespace: "team-a"
        ) == .namespace("team-a")
    )
    #expect(
        DefaultNamespacePreference.contextDefault.initialSelection(
            contextDefaultNamespace: ""
        ) == .namespace("default")
    )
    #expect(
        DefaultNamespacePreference.contextDefault.initialSelection(
            contextDefaultNamespace: "  "
        ) == .namespace("default")
    )
    #expect(
        DefaultNamespacePreference.allNamespaces.initialSelection(
            contextDefaultNamespace: "team-a"
        ) == NamespaceSelection()
    )
}

@Test func preferenceDeltaClassifiesLiveWorkspaceAndRelaunchChanges() {
    let previous = AppPreferences()
    var updated = previous
    updated.appearance = .dark
    updated.logs.recordLimit += 1_000
    updated.diagnostics.completedOperationHistoryLimit += 1
    updated.nodeShell.globalImage = "registry.example/node-shell:2"
    updated.nodeShell.startupTimeoutSeconds = 90
    updated.confirmations.confirmScaling.toggle()
    updated.resourceOperations.defaultDeleteConcurrency = 8
    updated.defaultNamespace = .allNamespaces
    updated.restoreOpenClusterWindows = false
    updated.metricsRefreshSeconds += 5
    updated.columnsConfigurationPath = "/tmp/kmgr-columns.yaml"
    updated.advancedPerformance.viewportOverscanScreensPerSide = 17
    updated.advancedPerformance.globalWarmCacheMemoryPercent = 30

    let delta = AppPreferencesDelta(previous: previous, updated: updated)

    #expect(delta.changes(activated: .immediate) == [
        .appearance, .logDisplay, .confirmations, .resourceOperations,
        .operationHistory, .nodeShell,
    ])
    #expect(delta.changes(activated: .newWorkspace) == [
        .defaultNamespace, .viewportOverscan,
    ])
    #expect(delta.changes(activated: .applicationRelaunch) == [
        .workspaceRestoration, .metricsRefresh, .columnsConfigurationPath,
        .nodeShellStartupTimeout, .advancedPerformance,
    ])
    #expect(delta.requiresApplicationRelaunch)
    #expect(!delta.isEmpty)
    #expect(AppPreferencesDelta(previous: updated, updated: updated).isEmpty)
}

@MainActor
@Test func invalidPersistedPerformanceSettingsAreRemovedAndReset() throws {
    let suite = "kmgr-tests-invalid-performance-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    var preferences = AppPreferences()
    preferences.advancedPerformance.globalWarmCacheMemoryPercent = 0
    let encodedPreferences = try JSONEncoder().encode(preferences)
    let preferencesObject = try #require(
        JSONSerialization.jsonObject(with: encodedPreferences) as? [String: Any]
    )
    defaults.set(
        try JSONSerialization.data(withJSONObject: [
            "apiVersion": AppPreferences.apiVersion,
            "preferences": preferencesObject,
        ]),
        forKey: AppPreferencesStore.storageKey
    )

    let store = AppPreferencesStore(defaults: defaults)
    #expect(store.current == AppPreferences())
    #expect(store.loadIssue?.reason == .invalidValues)
    #expect(defaults.data(forKey: AppPreferencesStore.storageKey) == nil)
}

@Test func incompleteCurrentPreferencesAreRejectedInsteadOfMigrated() throws {
    let encoded = try JSONEncoder().encode(AppPreferences())
    var object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "restoreOpenClusterWindows")

    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(AppPreferences.self, from: data)
    }
}

@Test func keyboardShortcutReferenceMatchesRequiredBindings() {
    let shortcuts = Dictionary(
        uniqueKeysWithValues: KeyboardShortcutReference.defaults.map { ($0.keys, $0.action) }
    )
    for keys in [
        "⌘N", "⌘K", "/", "↑ / ↓ or K / J", "⇧↑ / ⇧↓ or ⇧-click",
        "⌘-click", "⌘A", "Return", "D", "⌘[ / ⌘]", "Escape", "Y", "⇧Y", "E",
        "L", "⇧L", "S", "P", "⌘⌫", "⌘S",
    ] {
        #expect(shortcuts[keys] != nil, "Missing shortcut reference for \(keys)")
    }
    #expect(shortcuts["Return"]?.contains("subresource") == true)
    #expect(shortcuts["D"] == "Describe the selected object")
    #expect(shortcuts["Y"] == "Open selected object YAML in Details")
    #expect(shortcuts["⇧Y"] == "Open selected object YAML in a new window")
    #expect(shortcuts["E"] == "Open Events for one object")
    #expect(shortcuts["⇧L"] == "Open previous container logs")
}

@Test func confirmationPreferencesControlOnlyRestartAndScalingPrompts() {
    var preferences = ConfirmationPreferences()
    #expect(preferences.requiresConfirmation(for: .workloadRestart))
    #expect(!preferences.requiresConfirmation(for: .scaling))

    preferences.confirmWorkloadRestart = false
    preferences.confirmScaling = true
    #expect(!preferences.requiresConfirmation(for: .workloadRestart))
    #expect(preferences.requiresConfirmation(for: .scaling))
}
