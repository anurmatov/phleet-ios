import Foundation
import XCTest
@testable import Phleet

/// Anchors `Bundle(for:)` to the test bundle.
private final class ControlFixtureAnchor {}

/// Orchestrator responses, read from `tests/fixtures/control`.
///
/// Synthetic throughout, and written from the orchestrator's source rather than captured from a
/// running one: the field names and shapes are the ones its serializer produces, the values are
/// invented. Each file also carries something this build must survive — an unknown field, a
/// field of the wrong type, an element that cannot be addressed.
enum ControlFixture {

    static func data(
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Data {
        let bundle = Bundle(for: ControlFixtureAnchor.self)
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "control")
            ?? bundle.url(forResource: name, withExtension: "json")

        guard let url else {
            XCTFail(
                "fixture \(name).json is not in the test bundle; check the resources phase in "
                    + "project.yml",
                file: file,
                line: line
            )
            return Data()
        }
        return try Data(contentsOf: url)
    }

    static func text(
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        String(decoding: try data(name, file: file, line: line), as: UTF8.self)
    }

    static func agents() throws -> [FleetAgent] {
        try JSONDecoder().decode(LossyList<FleetAgent>.self, from: data("agents")).items
    }

    static func runs() throws -> [WorkflowRun] {
        try JSONDecoder().decode(LossyList<WorkflowRun>.self, from: data("workflows")).items
    }

    static func closedRuns() throws -> [WorkflowRun] {
        try JSONDecoder().decode(LossyList<WorkflowRun>.self, from: data("closed")).items
    }

    static func history() throws -> [WorkflowEvent] {
        try JSONDecoder().decode(LossyList<WorkflowEvent>.self, from: data("history")).items
    }

    static func workflowTypes() throws -> [WorkflowType] {
        try JSONDecoder().decode(LossyList<WorkflowType>.self, from: data("workflow-types")).items
    }

    static func registry() throws -> [String: [SignalDefinition]] {
        try JSONDecoder()
            .decode([String: LossyList<SignalDefinition>].self, from: data("signals"))
            .mapValues { $0.items }
    }
}

extension ControlConnection {

    /// A connection that can decide, behind a proxy. Every value is obviously synthetic.
    static let fixture = ControlConnection(
        origin: URL(string: "https://fleet.example.invalid")!,
        serviceToken: AccessServiceToken(clientId: "client-id-1", clientSecret: "client-secret-1"),
        operatorToken: "operator-token-1"
    )

    /// The same connection with no operator token.
    static let readOnlyFixture = ControlConnection(
        origin: URL(string: "https://fleet.example.invalid")!,
        serviceToken: AccessServiceToken(clientId: "client-id-1", clientSecret: "client-secret-1"),
        operatorToken: nil
    )
}
