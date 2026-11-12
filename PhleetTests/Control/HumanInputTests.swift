import XCTest
@testable import Phleet

final class HumanInputTests: XCTestCase {
    static func gate(runId: String = "request-run", ref: String = "request-run") -> PendingGate {
        PendingGate(
            run: WorkflowRun(workflowId: "human-input-sample", runId: runId,
                             workflowType: "UweHumanInputWorkflow", namespace: "fleet",
                             phase: "request-input", gateRef: ref),
            signal: SignalDefinition(name: "request-input", label: "Answer request",
                                     buttons: [], validPhases: ["request-input"])
        )
    }

    static func history(mode: String = "choice", parent: Bool = false) throws -> [WorkflowEvent] {
        var request: [String: Any] = [
            "Question": "  Which \"answer\"?\n{{input.secret}} 🧭",
            "Context": "**literal**, not Markdown\n<script>no execution</script>",
            "AnswerMode": mode,
            "Origin": parent
                ? ["Kind": "parent", "Namespace": "fleet", "WorkflowId": "parent", "RunId": "parent-run"]
                : ["Kind": "agent", "RequesterAgent": "agent1"]
        ]
        if mode == "choice" {
            request["Choices"] = [["Id": "option_b", "Label": "Second\n🧭"],
                                  ["Id": "option_a", "Label": "First {{literal}}"]]
        }
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        return [WorkflowEvent(eventId: 1, eventType: "WorkflowStarted",
                              inputSummary: String(decoding: data, as: UTF8.self))]
    }

    func testAllModesKeepLiteralContentAndOrderedIds() throws {
        for mode in ["choice", "text", "approve-reject"] {
            let request = try HumanInputRequest.from(history: Self.history(mode: mode), gate: Self.gate())
            XCTAssertEqual(request.question, "  Which \"answer\"?\n{{input.secret}} 🧭")
            XCTAssertTrue(request.context.contains("<script>"))
            XCTAssertEqual(request.origin, ["agent1"])
            XCTAssertEqual(request.mode.rawValue, mode)
            XCTAssertFalse(request.valid(value: "", comment: ""))
        }
        let choice = try HumanInputRequest.from(history: Self.history(), gate: Self.gate())
        XCTAssertEqual(choice.choices.map(\.id), ["option_b", "option_a"])
        let preset = try HumanInputRequest.from(history: Self.history(mode: "approve-reject", parent: true), gate: Self.gate())
        XCTAssertEqual(preset.choices.map(\.id), ["approved", "rejected"])
        XCTAssertEqual(preset.origin, ["fleet", "parent", "parent-run"])
    }

    func testAnswerLimitsCountUTF16AndPreserveRawTextAndComment() throws {
        let request = try HumanInputRequest.from(history: Self.history(mode: "text"), gate: Self.gate())
        XCTAssertFalse(request.valid(value: " \n ", comment: ""))
        XCTAssertTrue(request.valid(value: String(repeating: "🧭", count: 1000), comment: ""))
        XCTAssertFalse(request.valid(value: String(repeating: "🧭", count: 1001), comment: ""))
        XCTAssertFalse(request.valid(value: "yes", comment: String(repeating: "🧭", count: 1001)))
        let body = try request.body(gate: Self.gate(), value: "  answer\n🧭  ", comment: " \nunchanged\" ")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.payload.utf8)) as? [String: String])
        XCTAssertEqual(payload, ["Value": "  answer\n🧭  ", "Comment": " \nunchanged\" "])
        XCTAssertEqual(body.runId, "request-run")
        XCTAssertEqual(body.expectedGateRef, "request-run")
        XCTAssertEqual(body.signalName, "request-input")
    }

    func testMalformedHistoryAndWrongGateRefuse() throws {
        let history = try Self.history()
        for invalid in [[], history + history, [WorkflowEvent(eventId: 1, eventType: "WorkflowStarted", inputSummary: "{}")]] {
            XCTAssertThrowsError(try HumanInputRequest.from(history: invalid, gate: Self.gate()))
        }
        XCTAssertThrowsError(try HumanInputRequest.from(history: history, gate: Self.gate(ref: "old")))
        let original = try XCTUnwrap(history.first?.inputSummary)
        for malformed in [
            original.replacingOccurrences(of: "\"Question\":", with: "\"Question\":\"duplicate\",\"Question\":"),
            original.replacingOccurrences(of: "\"Kind\":", with: "\"Kind\":\"agent\",\"Kind\":"),
            original.replacingOccurrences(of: "option_a", with: "option_b"),
            original.replacingOccurrences(of: "option_a", with: "INVALID"),
            original.replacingOccurrences(of: "\"choice\"", with: "\"unknown\""),
            original.replacingOccurrences(of: "\"Question\"", with: "\"question\""),
            original.replacingOccurrences(of: "\"RequesterAgent\"", with: "\"Recipient\"")
        ] {
            XCTAssertThrowsError(try HumanInputRequest.from(history: [
                WorkflowEvent(eventId: 1, eventType: "WorkflowStarted", inputSummary: malformed)
            ], gate: Self.gate()))
        }
    }

    func testChoiceUsesOnlyDeclaredIdsNotLabels() throws {
        let request = try HumanInputRequest.from(history: Self.history(), gate: Self.gate())
        XCTAssertTrue(request.valid(value: "option_b", comment: ""))
        XCTAssertFalse(request.valid(value: "Second\n🧭", comment: ""))
        XCTAssertFalse(request.valid(value: "approved", comment: ""))
    }
}
