import Foundation

/// The one protocol string this build speaks.
///
/// The server compares this field **ordinally** and rejects a missing or `null` value on every
/// request body, so a single route that forgets it is a `400 unsupported_protocol` — and on the
/// enrollment route, a client that can never complete its first request. Every request type in
/// `WireBodies.swift` carries the constant from here rather than a per-call literal, which is
/// what makes "every body has it" a property of the types instead of a review checklist.
enum ProtocolVersion {

    /// The protocol version this build implements.
    static let current = "fleet.conversation.v1"

    /// Whether a value received from the server is the version this build speaks.
    ///
    /// Compared over UTF-8 code units rather than with `==`, because `String` equality is
    /// Unicode canonical equivalence and the server's check is ordinal. Two strings that
    /// compare equal in Swift but differ byte-for-byte would be accepted here and rejected
    /// there, which is the kind of disagreement that only shows up in production.
    static func isSupported(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.utf8.elementsEqual(current.utf8)
    }
}
