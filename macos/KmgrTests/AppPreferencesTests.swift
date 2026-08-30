import Foundation
import Testing
@testable import KmgrCore

@MainActor
@Test func appPreferencesRoundTripAsOneVersionedDocument() throws {
    let suite = "kmgr-tests-\(UUID().uuidString)"
    let defaults = try #require(TestUserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppPreferencesStore(defaults: defaults)
    var preferences = AppPreferences()
    preferences.appearance = .dark
    preferences.logs = LogDisplayPreferences(
        recordLimit: 75_000,
        byteLimit: 32 << 20,
        renderBatchMilliseconds: 50,
        maximumRenderedUTF8Bytes: 24 << 20,
        maximumDisplayedLineUTF8Bytes: 12 << 10
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
    )
    try store.save(preferences)

    let reloaded = AppPreferencesStore(defaults: defaults)
    #expect(reloaded.current.appearance == .dark)
    #expect(reloaded.current.logs.recordLimit == 75_000)
    #expect(reloaded.current.logs.byteLimit == 32 << 20)
    #expect(reloaded.current.logs.maximumRenderedUTF8Bytes == 24 << 20)
    #expect(reloaded.current.logs.maximumDisplayedLineUTF8Bytes == 12 << 10)
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
    let defaults = try #require(TestUserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let encodedDefaults = try JSONEncoder().encode(AppPreferences())
    let preferencesObject = try #require(
        JSONSerialization.jsonObject(with: encodedDefaults) as? [String: Any]
    )
    defaults.set(
        try JSONSerialization.data(withJSONObject: [
            "apiVersion": "",
            "preferences": preferencesObject,
        ]),
        forKey: AppPreferencesStore.storageKey
    )
    var store = AppPreferencesStore(defaults: defaults)
    #expect(store.current == AppPreferences())
    #expect(store.loadIssue?.reason == .invalidData)
    #expect(defaults.data(forKey: AppPreferencesStore.storageKey) == nil)

    defaults.set(Data("not-json".utf8), forKey: AppPreferencesStore.storageKey)
    store = AppPreferencesStore(defaults: defaults)
    #expect(store.current == AppPreferences())
    #expect(store.loadIssue?.reason == .invalidData)
    #expect(defaults.data(forKey: AppPreferencesStore.storageKey) == nil)

    defaults.set(["preferences": "not-encoded"], forKey: AppPreferencesStore.storageKey)
    store = AppPreferencesStore(defaults: defaults)
    #expect(store.current == AppPreferences())
    #expect(store.loadIssue?.reason == .invalidData)
    #expect(defaults.object(forKey: AppPreferencesStore.storageKey) == nil)
}

@MainActor
@Test func compatibleFuturePreferenceMetadataIsMigratedByFields() throws {
    let suite = "kmgr-tests-compatible-future-preferences-\(UUID().uuidString)"
    let defaults = try #require(TestUserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let preferences = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(AppPreferences()))
            as? [String: Any]
    )
    defaults.set(
        try JSONSerialization.data(withJSONObject: [
            "apiVersion": "some.future.preferences/v99",
            "preferences": preferences,
        ]),
        forKey: AppPreferencesStore.storageKey
    )

    let store = AppPreferencesStore(defaults: defaults)
    #expect(store.current == AppPreferences())
    #expect(store.loadIssue == nil)
    #expect(store.migrationNotice?.message.contains("migrated") == true)
    let rewritten = try #require(defaults.data(forKey: AppPreferencesStore.storageKey))
    let object = try #require(JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
    #expect(object["apiVersion"] as? String == AppPreferences.apiVersion)
}

@MainActor
@Test func currentPreferenceMetadataCanonicalizesPersistedPaths() throws {
    let suite = "kmgr-tests-canonical-preferences-\(UUID().uuidString)"
    let defaults = try #require(TestUserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    var preferences = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(AppPreferences()))
            as? [String: Any]
    )
    preferences["columnsConfigurationPath"] = "~/Library/Application Support/kmgr/columns.yaml"
    defaults.set(
        try JSONSerialization.data(withJSONObject: [
            "apiVersion": AppPreferences.apiVersion,
            "preferences": preferences,
        ]),
        forKey: AppPreferencesStore.storageKey
    )

    let store = AppPreferencesStore(defaults: defaults)
    #expect(store.loadIssue == nil)
    #expect(store.migrationNotice != nil)
    let rewritten = try #require(defaults.data(forKey: AppPreferencesStore.storageKey))
    let object = try #require(JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
    let rewrittenPreferences = try #require(object["preferences"] as? [String: Any])
    #expect(rewrittenPreferences["columnsConfigurationPath"] as? String ==
        AppPreferences.defaultColumnsConfigurationPath)
}

@MainActor
@Test func v14PreferencesMigrateWithoutTheRemovedTerminalFields() throws {
    let suite = "kmgr-tests-v14-preferences-\(UUID().uuidString)"
    let defaults = try #require(TestUserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    var preferencesObject = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(AppPreferences()))
            as? [String: Any]
    )
    preferencesObject["terminal"] = [
        "initialColumns": 132,
        "initialRows": 40,
    ]
    defaults.set(
        try JSONSerialization.data(withJSONObject: [
            "apiVersion": AppPreferences.previousAPIVersion,
            "preferences": preferencesObject,
        ]),
        forKey: AppPreferencesStore.storageKey
    )

    let store = AppPreferencesStore(defaults: defaults)
    #expect(store.loadIssue == nil)
    #expect(store.current == AppPreferences())

    let migratedData = try #require(
        defaults.data(forKey: AppPreferencesStore.storageKey)
    )
    let migrated = try #require(
        JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
    )
    #expect(migrated["apiVersion"] as? String == AppPreferences.apiVersion)
    let migratedPreferences = try #require(
        migrated["preferences"] as? [String: Any]
    )
    #expect(migratedPreferences["terminal"] == nil)
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
        projectionWorkerLimit: 33,
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
        "advancedPerformance.projectionWorkerLimit",
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

@Test func visibleLogLineLimitUsesTheFullByteRange() {
    var preferences = AppPreferences()
    preferences.logs.maximumDisplayedLineUTF8Bytes = 256
    #expect(!preferences.validationIssues().contains {
        $0.field == "logs.maximumDisplayedLineUTF8Bytes"
    })

    preferences.logs.maximumDisplayedLineUTF8Bytes = 16 << 20
    #expect(!preferences.validationIssues().contains {
        $0.field == "logs.maximumDisplayedLineUTF8Bytes"
    })

    preferences.logs.maximumDisplayedLineUTF8Bytes = 255
    #expect(preferences.validationIssues().contains {
        $0.field == "logs.maximumDisplayedLineUTF8Bytes"
    })

    preferences.logs.maximumDisplayedLineUTF8Bytes = (16 << 20) + 1
    #expect(preferences.validationIssues().contains {
        $0.field == "logs.maximumDisplayedLineUTF8Bytes"
    })
}

@Test func viewerTextBudgetCannotExceedRawLogBuffer() {
    var preferences = AppPreferences()
    preferences.logs.byteLimit = 16 << 20
    preferences.logs.maximumRenderedUTF8Bytes = 16 << 20
    #expect(!preferences.validationIssues().contains {
        $0.field == "logs.maximumRenderedUTF8Bytes"
    })

    preferences.logs.maximumRenderedUTF8Bytes = 17 << 20
    #expect(preferences.validationIssues().contains {
        $0.field == "logs.maximumRenderedUTF8Bytes"
    })
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
@Test func olderPreferenceSchemaFillsFieldsAddedLater() throws {
    let suite = "kmgr-tests-old-performance-schema-\(UUID().uuidString)"
    let defaults = try #require(TestUserDefaults(suiteName: suite))
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
    #expect(store.loadIssue == nil)
    #expect(store.migrationNotice != nil)
    let rewritten = try #require(defaults.data(forKey: AppPreferencesStore.storageKey))
    let object = try #require(JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
    #expect(object["apiVersion"] as? String == AppPreferences.apiVersion)
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
    let defaults = try #require(TestUserDefaults(suiteName: suite))
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

@MainActor
@Test func missingAddedPreferenceFieldIsFilledAndMigrated() throws {
    let suite = "kmgr-tests-missing-preference-field-\(UUID().uuidString)"
    let defaults = try #require(TestUserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let encoded = try JSONEncoder().encode(AppPreferences())
    var object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "restoreOpenClusterWindows")

    defaults.set(
        try JSONSerialization.data(withJSONObject: [
            "apiVersion": "kmgr.preferences/v1",
            "preferences": object,
        ]),
        forKey: AppPreferencesStore.storageKey
    )

    let store = AppPreferencesStore(defaults: defaults)
    #expect(store.current.restoreOpenClusterWindows)
    #expect(store.loadIssue == nil)
    #expect(store.migrationNotice != nil)
}

@MainActor
@Test func unknownPreferenceFieldResetsTheWholeDocument() throws {
    let suite = "kmgr-tests-unknown-preference-field-\(UUID().uuidString)"
    let defaults = try #require(TestUserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var preferences = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(AppPreferences()))
            as? [String: Any]
    )
    preferences["removedField"] = true
    defaults.set(
        try JSONSerialization.data(withJSONObject: [
            "apiVersion": AppPreferences.apiVersion,
            "preferences": preferences,
        ]),
        forKey: AppPreferencesStore.storageKey
    )

    let store = AppPreferencesStore(defaults: defaults)
    #expect(store.current == AppPreferences())
    #expect(store.loadIssue?.reason == .invalidData)
    #expect(defaults.data(forKey: AppPreferencesStore.storageKey) == nil)
}

@MainActor
@Test func missingExistingPreferenceFieldIsFilledAndMigrated() throws {
    let suite = "kmgr-tests-missing-baseline-preference-\(UUID().uuidString)"
    let defaults = try #require(TestUserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var preferences = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(AppPreferences()))
            as? [String: Any]
    )
    preferences.removeValue(forKey: "appearance")
    defaults.set(
        try JSONSerialization.data(withJSONObject: [
            "apiVersion": "kmgr.preferences/v1",
            "preferences": preferences,
        ]),
        forKey: AppPreferencesStore.storageKey
    )

    let store = AppPreferencesStore(defaults: defaults)
    #expect(store.current.appearance == .system)
    #expect(store.loadIssue == nil)
    #expect(store.migrationNotice != nil)
    #expect(defaults.data(forKey: AppPreferencesStore.storageKey) != nil)
}

@MainActor
@Test func nestedPreferenceTypeOrUnknownFieldResetsTheWholeDocument() throws {
    let suite = "kmgr-tests-incompatible-nested-preference-\(UUID().uuidString)"
    let defaults = try #require(TestUserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    var preferences = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(AppPreferences()))
            as? [String: Any]
    )
    var logs = try #require(preferences["logs"] as? [String: Any])
    logs["recordLimit"] = "many"
    preferences["logs"] = logs
    defaults.set(
        try JSONSerialization.data(withJSONObject: [
            "apiVersion": "future.metadata",
            "preferences": preferences,
        ]),
        forKey: AppPreferencesStore.storageKey
    )

    let store = AppPreferencesStore(defaults: defaults)
    #expect(store.current == AppPreferences())
    #expect(store.loadIssue?.reason == .invalidData)
    #expect(defaults.data(forKey: AppPreferencesStore.storageKey) == nil)

    var advanced = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(AppPreferences()))
            as? [String: Any]
    )
    var advancedObject = try #require(advanced["advancedPerformance"] as? [String: Any])
    advancedObject["removedField"] = true
    advanced["advancedPerformance"] = advancedObject
    defaults.set(
        try JSONSerialization.data(withJSONObject: [
            "apiVersion": AppPreferences.apiVersion,
            "preferences": advanced,
        ]),
        forKey: AppPreferencesStore.storageKey
    )

    let unknownStore = AppPreferencesStore(defaults: defaults)
    #expect(unknownStore.current == AppPreferences())
    #expect(unknownStore.loadIssue?.reason == .invalidData)
    #expect(defaults.data(forKey: AppPreferencesStore.storageKey) == nil)
}

@Test func keyboardShortcutReferenceMatchesRequiredBindings() {
    let shortcuts = Dictionary(
        uniqueKeysWithValues: KeyboardShortcutReference.defaults.map { ($0.keys, $0.action) }
    )
    for keys in [
        "⌘N", "⌘K", "/", "↑ / ↓ or K / J", "⇧↑ / ⇧↓ or ⇧-click",
        "⌘-click", "⌘A", "Return", "⌘Return", "P", "⌘P", "O", "⌘O", "D", "⌘[ / ⌘]", "Escape", "Y", "E",
        "L", "⇧L", "S", "F", "⌘F", "R", "⌘⌫", "⌘S",
    ] {
        #expect(shortcuts[keys] != nil, "Missing shortcut reference for \(keys)")
    }
    #expect(shortcuts["Return"]?.contains("subresource") == true)
    #expect(shortcuts["⌘Return"]?.contains("new workspace") == true)
    #expect(shortcuts["P"] == "Go to the selected object's parent")
    #expect(shortcuts["⌘P"]?.contains("parent in a new workspace") == true)
    #expect(shortcuts["O"] == "Show the selected Pod's Node")
    #expect(shortcuts["⌘O"]?.contains("Node in a new workspace") == true)
    #expect(shortcuts["D"] == "Open Details for the selected object")
    #expect(shortcuts["Y"] == "Open selected object YAML")
    #expect(shortcuts["E"] == "Edit selected object YAML")
    #expect(shortcuts["⇧L"] == "Open previous container logs")
    #expect(shortcuts["F"] == "Start a Pod or Service port-forward")
    #expect(shortcuts["⌘F"] == "Start a port-forward and show Port Forwards")
    #expect(shortcuts["R"] == "Rollout restart the selected workload")
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
