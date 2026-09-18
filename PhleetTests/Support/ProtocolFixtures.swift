import Foundation
import XCTest
@testable import Phleet

/// Anchors `Bundle(for:)` to the test bundle.
private final class FixtureAnchor {}

/// Recorded event sequences, read from `tests/fixtures/protocol`.
///
/// Synthetic throughout: no real host, device identifier, code or token appears in any of them.
/// They are copied into the test bundle as a folder reference, so a fixture added to the
/// directory is picked up without touching the project spec.
enum ProtocolFixture {

    /// Every fixture the replay tests sweep. Adding a file means adding it here, deliberately:
    /// a sweep that silently covers nothing is worse than no sweep.
    static let allNames = [
        "merged-injection",
        "host-error-closes-injected",
        "injected-before-host-known",
        "started-before-accepted",
        "queued-then-run",
        "queue-full",
        "outcome-unknown",
        "outcome-unknown-unrecognised-reason",
        "canceled-elsewhere",
        "ack-without-running-task",
        "merged-id-never-seen",
        "all-kinds"
    ]

    private struct Envelope: Decodable {
        let events: [ConversationEvent]
    }

    static func events(
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [ConversationEvent] {
        let bundle = Bundle(for: FixtureAnchor.self)
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "protocol")
            ?? bundle.url(forResource: name, withExtension: "json")

        guard let url else {
            XCTFail(
                "fixture \(name).json is not in the test bundle; check the resources phase in "
                    + "project.yml",
                file: file,
                line: line
            )
            return []
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Envelope.self, from: data).events
    }
}
