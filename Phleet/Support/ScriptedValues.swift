import Foundation

/// Values the scripted orchestrator answers with that a UI test also needs to know.
///
/// Dependency-free and compiled into the UI-test target as well, like `LaunchArguments`, so a
/// test derives what it expects from the value the app is given instead of restating it.
enum ScriptedValues {

    /// A value of 100,000 Unicode scalars: characters outside the Basic Multilingual Plane,
    /// combining marks, line breaks, quotes and backslashes. Synthetic.
    static let largeUnicodeText: String = {
        let pattern: [Unicode.Scalar] = [
            "S", "e", "\u{0301}", " ", "\u{1F9ED}", " ", "\"", "\\", "\n", "\u{4E16}"
        ]
        var scalars = String.UnicodeScalarView()
        for index in 0..<100_000 {
            scalars.append(pattern[index % pattern.count])
        }
        return String(scalars)
    }()

    /// That value as a stored `json/plain` payload: a JSON string literal, quotes and escapes
    /// included. This, not the text it stands for, is what a complete read returns.
    static let largeUnicodeLiteral: String = String(
        decoding: (try? JSONEncoder().encode(largeUnicodeText)) ?? Data(),
        as: UTF8.self
    )
}
