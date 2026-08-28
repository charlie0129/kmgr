import Foundation

/// An in-memory `UserDefaults` implementation for tests.
///
/// A suite created with `UserDefaults(suiteName:)` is backed by a plist in the
/// user's Preferences directory. Removing its persistent domain only clears
/// the values; `cfprefsd` keeps the empty plist around (and can recreate it
/// while the test process is alive). Tests do not need that daemon-backed
/// behavior, so they use this small replacement instead.
public final class InMemoryUserDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private var registeredValues: [String: Any] = [:]

    public override init?(suiteName suitename: String?) {
        // Do not pass the suite through: even an empty suite can become a
        // persistent domain once a value is written.
        super.init(suiteName: nil)
    }

    public override func object(forKey defaultName: String) -> Any? {
        values[defaultName] ?? registeredValues[defaultName]
    }

    public override func set(_ value: Any?, forKey defaultName: String) {
        if let value {
            values[defaultName] = value
        } else {
            values.removeValue(forKey: defaultName)
        }
    }

    public override func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }

    public override func data(forKey defaultName: String) -> Data? {
        object(forKey: defaultName) as? Data
    }

    public override func persistentDomain(forName domainName: String) -> [String: Any]? {
        values.isEmpty ? nil : values
    }

    public override func dictionaryRepresentation() -> [String: Any] {
        registeredValues.merging(values) { _, value in value }
    }

    public override func setPersistentDomain(
        _ domain: [String: Any],
        forName domainName: String
    ) {
        values = domain
    }

    public override func removePersistentDomain(forName domainName: String) {
        values.removeAll(keepingCapacity: true)
    }

    public override func register(defaults registrationDictionary: [String: Any]) {
        for (key, value) in registrationDictionary where registeredValues[key] == nil {
            registeredValues[key] = value
        }
    }
}
