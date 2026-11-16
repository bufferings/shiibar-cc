import Foundation

/// A `UserDefaults` whose values live only in memory: every accessor the
/// code under test uses is overridden, so nothing reaches the defaults
/// database or a plist file (tests never touch machine state).
final class InMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Double, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Int, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func stringArray(forKey defaultName: String) -> [String]? { values[defaultName] as? [String] }
    override func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    override func double(forKey defaultName: String) -> Double { values[defaultName] as? Double ?? 0 }
}
