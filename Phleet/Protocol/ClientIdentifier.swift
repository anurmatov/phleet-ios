import Foundation

/// The single identifier rule, implemented once and shared — exactly as the server does.
///
/// `externalRef`, `submissionId`, `idempotencyKey` and `clientInstanceId` are all the same
/// shape: `[A-Za-z0-9_-]`, 1 to 128 characters, compared ordinally. Four local copies of one
/// rule is four places for it to drift.
enum ClientIdentifier {

    /// The longest identifier the server accepts.
    ///
    /// `GET /v1/session` also reports this as `limits.identifierMaxLength`. The constant here is
    /// what the client generates against; the reported limit is what a *server* enforces, and
    /// the two are asserted equal at session time rather than one silently winning.
    static let maximumLength = 128

    /// Whether `value` satisfies the identifier rule.
    static func isValid(_ value: String) -> Bool {
        let units = Array(value.utf8)
        guard !units.isEmpty, units.count <= maximumLength else { return false }
        return units.allSatisfy(isAllowedByte)
    }

    /// A fresh identifier, for a `submissionId`, an `idempotencyKey` or this install's
    /// `clientInstanceId`.
    ///
    /// A UUID string is `[0-9A-F-]`, which the rule already permits, so there is nothing to
    /// encode or strip.
    static func random() -> String {
        UUID().uuidString
    }

    private static func isAllowedByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return true
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return true
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return true
        case UInt8(ascii: "_"), UInt8(ascii: "-"): return true
        default: return false
        }
    }
}
