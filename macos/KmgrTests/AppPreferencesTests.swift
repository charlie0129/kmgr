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
        renderBatchMilliseconds: 50
    )
    preferences.metricsRefreshSeconds = 30
    preferences.defaultNamespace = .allNamespaces
    preferences.restoreOpenClusterWindows = false
    preferences.confirmations.confirmWorkloadRestart = false
    preferences.columnsConfigurationPath = "~/Library/Application Support/kmgr/custom-columns.yaml"
    try store.save(preferences)

    let reloaded = AppPreferencesStore(defaults: defaults)
    #expect(reloaded.current.appearance == .dark)
    #expect(reloaded.current.logs.recordLimit == 75_000)
    #expect(reloaded.current.logs.byteLimit == 32 << 20)
    #expect(reloaded.current.metricsRefreshSeconds == 30)
    #expect(reloaded.current.defaultNamespace == .allNamespaces)
    #expect(!reloaded.current.restoreOpenClusterWindows)
    #expect(!reloaded.current.confirmations.confirmWorkloadRestart)
    #expect(reloaded.current.columnsConfigurationPath.hasPrefix("/"))
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

    defaults.set(Data("not-json".utf8), forKey: AppPreferencesStore.storageKey)
    store = AppPreferencesStore(defaults: defaults)
    #expect(store.current == AppPreferences())
    #expect(store.loadIssue?.reason == .invalidData)
}

@Test func appPreferenceValidationEnforcesConservativeBoundsAndSafetyInvariants() throws {
    var preferences = AppPreferences()
    preferences.logs.recordLimit = 10
    preferences.logs.byteLimit = 100
    preferences.logs.renderBatchMilliseconds = 1
    preferences.metricsRefreshSeconds = 1
    preferences.columnsConfigurationPath = "relative/columns.yaml"
    let fields = Set(preferences.validationIssues().map(\.field))
    #expect(fields == [
        "logs.recordLimit",
        "logs.byteLimit",
        "logs.renderBatchMilliseconds",
        "metricsRefreshSeconds",
        "columnsConfigurationPath",
    ])
    #expect(ConfirmationPreferences.alwaysConfirmResourceDeletion)
    #expect(ConfirmationPreferences.alwaysConfirmActiveTerminalClose)
    #expect(ConfirmationPreferences.alwaysConfirmNonLoopbackPortForward)
    #expect(ConfirmationPreferences.alwaysShowClusterAndNamespaceIdentity)
    #expect(KeyboardShortcutReference.defaults.contains { $0.keys == "S" })
    #expect(KeyboardShortcutReference.defaults.contains {
        $0.keys == "⇧⌘N" && $0.action.contains("namespace")
    })
    #expect(AppPreferences().restoreOpenClusterWindows)
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
    updated.confirmations.confirmScaling.toggle()
    updated.defaultNamespace = .allNamespaces
    updated.restoreOpenClusterWindows = false
    updated.metricsRefreshSeconds += 5
    updated.columnsConfigurationPath = "/tmp/kmgr-columns.yaml"

    let delta = AppPreferencesDelta(previous: previous, updated: updated)

    #expect(delta.changes(activated: .immediate) == [
        .appearance, .logDisplay, .confirmations,
    ])
    #expect(delta.changes(activated: .newWorkspace) == [.defaultNamespace])
    #expect(delta.changes(activated: .applicationRelaunch) == [
        .workspaceRestoration, .metricsRefresh, .columnsConfigurationPath,
    ])
    #expect(delta.requiresApplicationRelaunch)
    #expect(!delta.isEmpty)
    #expect(AppPreferencesDelta(previous: updated, updated: updated).isEmpty)
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
