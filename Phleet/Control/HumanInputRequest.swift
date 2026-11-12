import Foundation

/// The one shipped human-input contract, not a generic form or an execution instruction.
struct HumanInputRequest: Equatable, Sendable {
    enum Mode: String, Sendable { case choice, text, preset = "approve-reject" }
    struct Choice: Equatable, Sendable, Identifiable {
        let id: String
        let label: String
    }
    enum Invalid: Error { case request, answer }

    let question: String
    let context: String
    let mode: Mode
    /// Agent name, or the parent's namespace/workflow/run, each kept literal.
    let origin: [String]
    let choices: [Choice]

    static func from(history: [WorkflowEvent], gate: PendingGate) throws -> Self {
        guard gate.isHumanInput, gate.run.isRunning, gate.run.phase == "request-input",
              !gate.run.runId.isEmpty, gate.run.gateRef == gate.run.runId else {
            throw Invalid.request
        }
        let starts = history.filter { $0.eventType == "WorkflowStarted" }
        guard starts.count == 1, let input = starts.first?.inputSummary,
              let object = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any],
              let rawMode = object["AnswerMode"] as? String, let mode = Mode(rawValue: rawMode),
              Set(object.keys) == Set(["Question", "Context", "AnswerMode", "Origin"] +
                                     (mode == .choice ? ["Choices"] : [])),
              let originObject = object["Origin"] as? [String: Any] else {
            throw Invalid.request
        }
        try refuseDuplicateKeys(in: input)
        let question = try text(object, "Question")
        let context = try text(object, "Context")
        let origin: [String]
        switch try text(originObject, "Kind") {
        case "agent":
            guard Set(originObject.keys) == ["Kind", "RequesterAgent"] else { throw Invalid.request }
            origin = [try text(originObject, "RequesterAgent")]
        case "parent":
            guard Set(originObject.keys) == ["Kind", "Namespace", "WorkflowId", "RunId"] else {
                throw Invalid.request
            }
            origin = try ["Namespace", "WorkflowId", "RunId"].map { try text(originObject, $0) }
        default: throw Invalid.request
        }
        var choices: [Choice] = []
        if mode == .choice {
            guard let items = object["Choices"] as? [[String: Any]], (2...8).contains(items.count) else {
                throw Invalid.request
            }
            for item in items {
                guard Set(item.keys) == ["Id", "Label"] else { throw Invalid.request }
                let id = try text(item, "Id")
                guard id.range(of: "\\A[a-z][a-z0-9_-]{0,31}\\z", options: .regularExpression) != nil,
                      !choices.contains(where: { $0.id == id }) else { throw Invalid.request }
                choices.append(Choice(id: id, label: try text(item, "Label")))
            }
        } else if mode == .preset {
            choices = [Choice(id: "approved", label: String(localized: "humanInput.approve")),
                       Choice(id: "rejected", label: String(localized: "humanInput.reject"))]
        }
        return Self(question: question, context: context, mode: mode, origin: origin, choices: choices)
    }

    /// Foundation's object decoder collapses duplicate keys. Check the already-valid JSON's
    /// string tokens as well, including escaped spellings of the same key, before trusting it.
    private static func refuseDuplicateKeys(in input: String) throws {
        let bytes = Array(input.utf8)
        var scopes: [Set<String>] = []
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 123: scopes.append([]) // {
            case 125: _ = scopes.popLast() // }
            case 34: // A complete JSON string, not braces or quotes inside a string value.
                let start = index
                index += 1
                while index < bytes.count {
                    if bytes[index] == 92 { index += 2; continue }
                    if bytes[index] == 34 { break }
                    index += 1
                }
                index += 1
                var next = index
                while next < bytes.count && [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count && bytes[next] == 58, !scopes.isEmpty {
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                    guard scopes[scopes.count - 1].insert(key).inserted else { throw Invalid.request }
                }
                continue
            default: break
            }
            index += 1
        }
    }

    private static func text(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Invalid.request }
        return value
    }

    func valid(value: String, comment: String) -> Bool {
        guard comment.utf16.count <= 2000 else { return false }
        if mode == .text {
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf16.count <= 2000
        }
        return choices.contains { $0.id == value }
    }

    func body(gate: PendingGate, value: String, comment: String) throws -> SignalRequestBody {
        guard gate.isHumanInput, gate.run.gateRef == gate.run.runId,
              valid(value: value, comment: comment) else { throw Invalid.answer }
        var answer = ["Value": value]
        if !comment.isEmpty { answer["Comment"] = comment }
        let payload = try JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])
        return SignalRequestBody(signalName: "request-input", workflowType: gate.run.workflowType,
                                 payload: String(decoding: payload, as: UTF8.self),
                                 runId: gate.run.runId, expectedGateRef: gate.run.gateRef)
    }
}

extension PendingGate {
    var isHumanInput: Bool {
        run.workflowType == "UweHumanInputWorkflow" && signal.name == "request-input"
    }
}
