import Foundation

/// How one agent is doing, reduced to what a glance needs.
///
/// Derived from the orchestrator's `effectiveStatus`, which already folds heartbeat age into the
/// reported status. An unrecognised value is kept rather than guessed at: a status this build
/// has never heard of is shown as itself, never coloured as healthy.
enum AgentHealth: Equatable, Sendable {
    /// No heartbeat for long enough that the orchestrator calls it dead.
    case down
    /// Heartbeats are late.
    case stale
    /// Up, with a task in hand.
    case working
    /// Up, with nothing in hand.
    case idle
    /// Deliberately not running.
    case stopped
    /// Configured, never provisioned.
    case notProvisioned
    case unknown(String)

    /// Lower sorts first: what needs a person comes before what does not.
    var sortRank: Int {
        switch self {
        case .down: return 0
        case .stale: return 1
        case .working: return 2
        case .idle: return 3
        case .unknown: return 4
        case .stopped: return 5
        case .notProvisioned: return 6
        }
    }

    /// Whether this state is one a person should be drawn to.
    var needsAttention: Bool {
        switch self {
        case .down, .stale: return true
        case .working, .idle, .stopped, .notProvisioned, .unknown: return false
        }
    }

    static func derive(effectiveStatus: String?, currentTask: String?) -> AgentHealth {
        let status = (effectiveStatus ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch status.lowercased() {
        case "dead":
            return .down
        case "stale":
            return .stale
        case "active", "busy", "idle", "healthy":
            let task = (currentTask ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return task.isEmpty ? .idle : .working
        case "offline", "stopped":
            return .stopped
        case "not_provisioned":
            return .notProvisioned
        default:
            return .unknown(status)
        }
    }
}

/// One agent, as the orchestrator reports it.
///
/// Decoding is deliberately forgiving. Only the name is required; every other field is read if
/// it is there and well-formed and left empty otherwise, so a field this build does not
/// understand — or one a newer orchestrator reshaped — costs that one field, not the agent.
struct FleetAgent: Equatable, Sendable, Identifiable {
    let agentName: String
    let displayName: String?
    let model: String?
    let role: String?
    let currentTask: String?
    let effectiveStatus: String?
    let lastSeen: Date?
    let version: String?
    let queuedCount: Int
    let priorityQueuedCount: Int
    let backgroundTaskCount: Int

    var id: String { agentName }

    var health: AgentHealth {
        AgentHealth.derive(effectiveStatus: effectiveStatus, currentTask: currentTask)
    }

    /// The display name when there is one, the agent name otherwise.
    var title: String {
        guard let displayName,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return agentName }
        return displayName
    }

    /// The task in hand, or `nil` when there is none worth showing.
    var taskSummary: String? {
        guard let task = currentTask?.trimmingCharacters(in: .whitespacesAndNewlines),
              !task.isEmpty
        else { return nil }
        return task
    }

    init(
        agentName: String,
        displayName: String? = nil,
        model: String? = nil,
        role: String? = nil,
        currentTask: String? = nil,
        effectiveStatus: String? = nil,
        lastSeen: Date? = nil,
        version: String? = nil,
        queuedCount: Int = 0,
        priorityQueuedCount: Int = 0,
        backgroundTaskCount: Int = 0
    ) {
        self.agentName = agentName
        self.displayName = displayName
        self.model = model
        self.role = role
        self.currentTask = currentTask
        self.effectiveStatus = effectiveStatus
        self.lastSeen = lastSeen
        self.version = version
        self.queuedCount = queuedCount
        self.priorityQueuedCount = priorityQueuedCount
        self.backgroundTaskCount = backgroundTaskCount
    }

    /// Attention first, then by name. Stable for equal names because the name is the identity.
    static func glanceOrder(_ lhs: FleetAgent, _ rhs: FleetAgent) -> Bool {
        let left = lhs.health.sortRank
        let right = rhs.health.sortRank
        if left != right { return left < right }
        let byTitle = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return lhs.agentName < rhs.agentName
    }
}

extension FleetAgent: Decodable {

    private enum CodingKeys: String, CodingKey {
        case agentName, displayName, model, role, currentTask, effectiveStatus, lastSeen
        case version, queuedCount, priorityQueuedCount, backgroundTasks
    }

    /// Present only to be counted; nothing inside a background task is read.
    private struct Ignored: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .agentName)
        guard !name.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .agentName,
                in: container,
                debugDescription: "an agent needs a name"
            )
        }

        self.init(
            agentName: name,
            displayName: container.lenient(String.self, .displayName),
            model: container.lenient(String.self, .model),
            role: container.lenient(String.self, .role),
            currentTask: container.lenient(String.self, .currentTask),
            effectiveStatus: container.lenient(String.self, .effectiveStatus),
            lastSeen: container.lenient(String.self, .lastSeen).flatMap(ControlTimestamp.parse),
            version: container.lenient(String.self, .version),
            queuedCount: container.lenient(Int.self, .queuedCount) ?? 0,
            priorityQueuedCount: container.lenient(Int.self, .priorityQueuedCount) ?? 0,
            backgroundTaskCount: container.lenient([Ignored].self, .backgroundTasks)?.count ?? 0
        )
    }
}

/// One workflow run, as the orchestrator lists it.
///
/// The five identity fields are required, because a decision is addressed to exactly one run and
/// a run this build cannot address is not one it should offer a decision on. Everything else is
/// read leniently.
struct WorkflowRun: Hashable, Sendable {
    let workflowId: String
    let runId: String
    let workflowType: String
    let namespace: String
    let status: String
    let startTime: Date?
    let issueNumber: Int?
    let prNumber: Int?
    let repo: String?
    let phase: String?
    let gateRef: String?

    /// The orchestrator's own spelling. Compared exactly, as the dashboard does.
    static let runningStatus = "Running"

    var isRunning: Bool { status == Self.runningStatus }

    init(
        workflowId: String,
        runId: String,
        workflowType: String,
        namespace: String,
        status: String = WorkflowRun.runningStatus,
        startTime: Date? = nil,
        issueNumber: Int? = nil,
        prNumber: Int? = nil,
        repo: String? = nil,
        phase: String? = nil,
        gateRef: String? = nil
    ) {
        self.workflowId = workflowId
        self.runId = runId
        self.workflowType = workflowType
        self.namespace = namespace
        self.status = status
        self.startTime = startTime
        self.issueNumber = issueNumber
        self.prNumber = prNumber
        self.repo = repo
        self.phase = phase
        self.gateRef = gateRef
    }
}

extension WorkflowRun: Decodable {

    private enum CodingKeys: String, CodingKey {
        case workflowId, runId, workflowType, namespace, status, startTime
        case issueNumber, prNumber, repo, phase, gateRef
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            workflowId: try container.decode(String.self, forKey: .workflowId),
            runId: try container.decode(String.self, forKey: .runId),
            workflowType: try container.decode(String.self, forKey: .workflowType),
            namespace: try container.decode(String.self, forKey: .namespace),
            status: try container.decode(String.self, forKey: .status),
            startTime: container.lenient(String.self, .startTime)
                .flatMap(ControlTimestamp.parse),
            issueNumber: container.lenient(Int.self, .issueNumber),
            prNumber: container.lenient(Int.self, .prNumber),
            repo: container.lenient(String.self, .repo),
            phase: container.lenient(String.self, .phase),
            gateRef: container.lenient(String.self, .gateRef)
        )
    }
}

/// One answer a person can give at a gate.
struct SignalButton: Hashable, Sendable {
    let label: String
    /// A JSON object, as text. Sent as given unless a comment is merged into it.
    let payload: String
    let requiresComment: Bool

    init(label: String, payload: String, requiresComment: Bool = false) {
        self.label = label
        self.payload = payload
        self.requiresComment = requiresComment
    }
}

extension SignalButton: Decodable {

    private enum CodingKeys: String, CodingKey {
        case label, payload, requiresComment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            label: try container.decode(String.self, forKey: .label),
            payload: try container.decode(String.self, forKey: .payload),
            requiresComment: container.lenient(Bool.self, .requiresComment) ?? false
        )
    }
}

/// A signal a workflow type accepts, and the phases in which it is waiting for one.
struct SignalDefinition: Hashable, Sendable {
    let name: String
    let label: String
    let buttons: [SignalButton]
    /// `nil` means the orchestrator does not say when this signal is expected.
    let validPhases: [String]?

    init(name: String, label: String, buttons: [SignalButton], validPhases: [String]? = nil) {
        self.name = name
        self.label = label
        self.buttons = buttons
        self.validPhases = validPhases
    }
}

extension SignalDefinition: Decodable {

    private enum CodingKeys: String, CodingKey {
        case name, label, buttons, validPhases
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        self.init(
            name: name,
            label: container.lenient(String.self, .label) ?? name,
            buttons: try container.decode(LossyList<SignalButton>.self, forKey: .buttons).items,
            validPhases: container.lenient([String].self, .validPhases)
        )
    }
}

/// A list that keeps every element it can read and drops the ones it cannot.
///
/// One agent with a malformed field must not blank the whole fleet, and one workflow this build
/// cannot address must not hide the gates on every other.
struct LossyList<Element: Decodable>: Decodable {

    let items: [Element]
    /// How many elements were dropped. Zero in the ordinary case; kept so a test can say so.
    let droppedCount: Int

    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var items: [Element] = []
        var dropped = 0
        while !container.isAtEnd {
            if let item = try? container.decode(Element.self) {
                items.append(item)
            } else {
                // A failed decode does not advance the container, so the element is consumed
                // explicitly — otherwise this loop never ends.
                _ = try container.decode(Skipped.self)
                dropped += 1
            }
        }
        self.items = items
        self.droppedCount = dropped
    }
}

extension KeyedDecodingContainer {

    /// A field that is absent, null, or of the wrong shape reads as `nil` rather than failing
    /// the value it belongs to.
    func lenient<Value: Decodable>(_ type: Value.Type, _ key: Key) -> Value? {
        try? decodeIfPresent(type, forKey: key)
    }
}

/// Reads the orchestrator's timestamps.
///
/// They carry seven fractional digits and a numeric offset. The fraction is split off and added
/// back by hand, so the parse does not depend on how many digits a formatter happens to accept.
enum ControlTimestamp {

    static func parse(_ raw: String) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var fraction: Double = 0

        if let dot = text.firstIndex(of: ".") {
            let digitsStart = text.index(after: dot)
            let digitsEnd = text[digitsStart...].firstIndex { !("0"..."9").contains($0) }
                ?? text.endIndex
            let digits = text[digitsStart..<digitsEnd]
            guard !digits.isEmpty, let value = Double("0." + String(digits)) else { return nil }
            fraction = value
            text.removeSubrange(dot..<digitsEnd)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let whole = formatter.date(from: text) else { return nil }
        return whole.addingTimeInterval(fraction)
    }
}
