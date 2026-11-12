import Foundation

/// Derives the name shown for a server from its address.
///
/// `displayName` is not a third thing to type or scan. It is the host, with a leading `www.`
/// removed and a non-standard port kept, because the port is the part two otherwise-identical
/// addresses differ by.
enum ServerDisplayName {
    static func derive(from components: URLComponents) -> String {
        guard var host = components.host, !host.isEmpty else { return "" }

        let prefix = "www."
        if host.lowercased().hasPrefix(prefix) {
            host.removeFirst(prefix.count)
        }
        if let port = components.port {
            return host + ":" + String(port)
        }
        return host
    }

    /// The name for a stored origin, or the origin itself when it has no host to name.
    static func derive(fromOrigin origin: String) -> String {
        guard let components = URLComponents(string: origin) else { return origin }
        let name = derive(from: components)
        return name.isEmpty ? origin : name
    }
}
