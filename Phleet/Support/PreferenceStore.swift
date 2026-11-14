import Foundation

/// The few small things this phone remembers that are not secrets: a switch, and how far each
/// thread had been read.
///
/// Never a credential, a token, or anything anyone wrote. Those have the Keychain, or are read
/// back from the server.
protocol PreferenceStore: AnyObject {
    func bool(forKey key: String) -> Bool
    func setBool(_ value: Bool, forKey key: String)
    func integers(forKey key: String) -> [String: Int]
    func setIntegers(_ value: [String: Int], forKey key: String)
    func remove(forKey key: String)
}

/// The app's own defaults.
final class UserDefaultsPreferenceStore: PreferenceStore {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func bool(forKey key: String) -> Bool {
        defaults.bool(forKey: key)
    }

    func setBool(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func integers(forKey key: String) -> [String: Int] {
        defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    func setIntegers(_ value: [String: Int], forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func remove(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

/// Remembers for one launch. What the scripted backend and the tests use, so nothing one run
/// chose is still there for the next.
final class InMemoryPreferenceStore: PreferenceStore {

    private var bools: [String: Bool] = [:]
    private var integerMaps: [String: [String: Int]] = [:]

    init() {}

    func bool(forKey key: String) -> Bool {
        bools[key] ?? false
    }

    func setBool(_ value: Bool, forKey key: String) {
        bools[key] = value
    }

    func integers(forKey key: String) -> [String: Int] {
        integerMaps[key] ?? [:]
    }

    func setIntegers(_ value: [String: Int], forKey key: String) {
        integerMaps[key] = value
    }

    func remove(forKey key: String) {
        bools[key] = nil
        integerMaps[key] = nil
    }
}

enum PreferenceKey {
    /// Whether a decision or a disruptive action asks for Face ID, Touch ID or the passcode first.
    static let confirmOwner = "phleet.confirmOwner"
    /// The highest position seen in each agent's thread, by agent name.
    static let seenThreadPositions = "phleet.chat.seenPositions"
}
