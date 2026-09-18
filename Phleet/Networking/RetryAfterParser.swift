import Foundation

/// One integer, one format, both transports.
///
/// The rate-limit delay arrives as `Retry-After` on an HTTP `429` and as the *entire* close
/// reason on a `4429`, and in both cases it is a non-negative decimal integer of seconds. A
/// missing or unparseable value is the backoff cap, never zero — treating an unreadable
/// rate-limit signal as "retry immediately" turns the signal into a retry storm, which is the
/// precise thing the server was asking the client to stop doing.
enum RetryAfterParser {

    /// Used when the value is absent, malformed or negative. Equal to the backoff cap.
    static let defaultSeconds = 30

    static func seconds(from value: String?) -> Int {
        guard let value else { return defaultSeconds }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultSeconds }

        // Digits only: no sign, no whitespace, no decimal point, no HTTP-date. A `-5` must not
        // parse to -5 and a `2.5` must not parse to 2.
        guard trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return defaultSeconds }
        guard let parsed = Int(trimmed) else { return defaultSeconds }

        return parsed
    }
}
