import Foundation

/// A scripted backend selected by a launch argument, so the UI smoke tests can drive
/// scan → sign in → fleet, runs, and agent → thread → send → terminal without a network.
///
/// Compiled into the app unconditionally and selected at runtime. It is deliberately **not**
/// behind a second `#if DEBUG`: the codebase has exactly one build-gate branch, `make lint`
/// fails on a second, and a UI test runs against the app as built.
///
/// Everything it answers with is obviously synthetic.
struct LaunchDouble {

    let credentialStore: CredentialStore
    let legacyCredentialStore: LegacyCredentialStore
    let api: FleetAPIClient
    let stream: ConversationStream

    let controlAPI: ControlAPIClient
    let controlStream: ControlLiveStream
    let controlLogStream: AgentLogStream

    /// What the stand-in for the camera "scans". A simulator has no camera, so under the
    /// scripted backend the scan button applies this text instead of opening one.
    let scannedSetupCode: String

    /// A valid setup code for the scripted server. Obviously synthetic.
    static let scriptedSetupCode =
        #"{"phleet":"setup","v":2,"origin":"https://scripted.example.invalid","#
        + #""enrollmentCode":"scripted-enrollment.code"}"#

    /// A setup code from a dashboard that predates one sign-in. Obviously synthetic.
    static let olderSetupCode =
        #"{"phleet":"control-setup","v":1,"origin":"https://scripted.example.invalid","#
        + #""operatorToken":"scripted-operator-token"}"#

    /// Stands in for the notification system: permission is granted and a token arrives.
    let pushSystem: PushSystem

    @MainActor
    static func make(from arguments: [String]) -> LaunchDouble? {
        guard arguments.contains(LaunchArguments.scriptedBackend) else { return nil }

        let backend = ScriptedBackend(
            tallTranscript: arguments.contains(LaunchArguments.tallTranscript)
        )
        let controlBackend = ScriptedControlBackend()
        let scanned: String
        if arguments.contains(LaunchArguments.unreadableSetupCode) {
            scanned = "not a setup code"
        } else if arguments.contains(LaunchArguments.olderSetupCode) {
            scanned = LaunchDouble.olderSetupCode
        } else {
            scanned = LaunchDouble.scriptedSetupCode
        }
        return LaunchDouble(
            credentialStore: InMemoryCredentialStore(),
            legacyCredentialStore: InMemoryLegacyCredentialStore(),
            api: backend,
            stream: backend,
            controlAPI: controlBackend,
            controlStream: controlBackend,
            controlLogStream: controlBackend,
            scannedSetupCode: scanned,
            pushSystem: ScriptedPushSystem()
        )
    }
}

/// The scripted backend. One turn, one answer — on an optionally pre-populated thread.
final class ScriptedBackend: FleetAPIClient, ConversationStream {

    private let conversationId = "scripted-conversation"
    private var continuation: AsyncStream<ConversationStreamEvent>.Continuation?
    private var seq = 40
    private var seededCatchUp = false

    /// Answer catch-up with a back-and-forth long enough to overflow any viewport.
    ///
    /// Seeded through **catch-up** rather than as one long live reply, because open-at-newest
    /// can only be observed on a thread that is already tall when it opens. A tall reply that
    /// only arrives after the first send proves nothing about the scroll position on arrival.
    private let tallTranscript: Bool

    init(tallTranscript: Bool = false) {
        self.tallTranscript = tallTranscript
    }

    /// `openConversation` reports `nextSeq: 41`, and history before `retainedFloorSeq: 12` is
    /// pruned, so seq 12...40 is exactly the readable range: seeding it leaves no gap at either
    /// end. Each reply names its position so a test can assert *which* one is on screen —
    /// "something is visible" would pass at the top of the thread as readily as the bottom.
    private static let seededReplies: [(seq: Int, text: String)] = {
        let range = 12...40
        return range.map { seq in
            let index = seq - range.lowerBound + 1
            return (
                seq,
                "Seeded reply \(index) of \(range.count). Long enough to wrap onto a second "
                    + "line so that a handful of these overflow the viewport."
            )
        }
    }()

    // MARK: - FleetAPIClient

    func session(origin: URL, accessToken: String) async throws -> SessionResponse {
        SessionResponse(
            principalId: "scripted-principal",
            limits: .documentedDefaults,
            protocolVersion: ProtocolVersion.current
        )
    }

    func openConversation(
        origin: URL,
        accessToken: String,
        externalRef: String,
        agent: String,
        clientInstanceId: String
    ) async throws -> OpenConversationResponse {
        if agent == ScriptedControlBackend.chatOffAgent {
            throw FleetAPIError.refused(.agentUnavailable, status: 409, message: nil)
        }
        return OpenConversationResponse(
            conversationId: conversationId,
            agent: agent,
            nextSeq: 41,
            retainedFloorSeq: 12,
            protocolVersion: ProtocolVersion.current
        )
    }

    func catchUp(
        origin: URL,
        accessToken: String,
        conversationId: String,
        afterSeq: Int,
        limit: Int
    ) async throws -> CatchUpResponse {
        guard tallTranscript, !seededCatchUp else {
            return CatchUpResponse(
                events: [],
                nextAfterSeq: afterSeq,
                hasMore: false,
                protocolVersion: ProtocolVersion.current
            )
        }
        seededCatchUp = true

        let events = Self.seededReplies.map { seeded in
            ConversationEvent(
                eventId: "seeded-final-\(seeded.seq)",
                seq: seeded.seq,
                kind: .turnFinal,
                identity: EventIdentity(
                    conversationId: conversationId,
                    submissionId: "seeded-submission-\(seeded.seq)"
                ),
                payload: .turnFinal(
                    TurnFinalPayload(
                        text: seeded.text,
                        completion: .completed,
                        isPartial: false,
                        truncated: false,
                        mergedSubmissionIds: ["seeded-submission-\(seeded.seq)"]
                    )
                )
            )
        }

        return CatchUpResponse(
            events: events,
            nextAfterSeq: Self.seededReplies.last?.seq ?? afterSeq,
            hasMore: false,
            protocolVersion: ProtocolVersion.current
        )
    }

    func submit(
        origin: URL,
        accessToken: String,
        conversationId: String,
        body: SubmissionBody
    ) async throws -> SubmissionAcceptedResponse {
        let accepted = nextSeq()
        emitTurn(for: body.submissionId, acceptedSeq: accepted)
        return SubmissionAcceptedResponse(
            submissionId: body.submissionId,
            acceptedSeq: accepted,
            protocolVersion: ProtocolVersion.current
        )
    }

    func advanceCursor(
        origin: URL,
        accessToken: String,
        conversationId: String,
        body: CursorBody
    ) async throws -> CursorAcceptedResponse {
        CursorAcceptedResponse(protocolVersion: ProtocolVersion.current)
    }

    // MARK: - ConversationStream

    func frames(
        origin: URL,
        accessToken: String,
        conversationId: String,
        clientInstanceId: String,
        afterSeq: Int
    ) -> AsyncStream<ConversationStreamEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(
                .hello(
                    HelloFrame(
                        conversationId: conversationId,
                        nextSeq: 41,
                        retainedFloorSeq: 12,
                        limits: .documentedDefaults,
                        protocolVersion: ProtocolVersion.current
                    )
                )
            )
        }
    }

    // MARK: - Script

    private func nextSeq() -> Int {
        seq += 1
        return seq
    }

    private func emitTurn(for submissionId: String, acceptedSeq: Int) {
        let identity = EventIdentity(
            conversationId: conversationId,
            submissionId: submissionId
        )

        continuation?.yield(
            .event(
                ConversationEvent(
                    eventId: "scripted-accepted-" + submissionId,
                    seq: acceptedSeq,
                    kind: .submissionAccepted,
                    identity: identity,
                    payload: .submissionAccepted(SubmissionAcceptedPayload(disposition: .ran))
                )
            )
        )
        continuation?.yield(
            .event(
                ConversationEvent(
                    eventId: "scripted-started-" + submissionId,
                    seq: nextSeq(),
                    kind: .turnStarted,
                    identity: identity,
                    payload: .turnStarted(TurnStartedPayload())
                )
            )
        )
        continuation?.yield(
            .event(
                ConversationEvent(
                    eventId: "scripted-final-" + submissionId,
                    seq: nextSeq(),
                    kind: .turnFinal,
                    identity: identity,
                    payload: .turnFinal(
                        TurnFinalPayload(
                            text: "Scripted reply.",
                            completion: .completed,
                            isPartial: false,
                            truncated: false,
                            mergedSubmissionIds: [submissionId]
                        )
                    )
                )
            )
        )
    }
}

/// The scripted orchestrator: three agents, one run waiting at a merge gate, a little history,
/// and two agents to chat with — one of which has had its chat turned off since the list was read.
///
/// Every action changes what the next read returns, the way the real thing does. Answering the
/// gate moves the run out of its phase; restarting the agent that is down brings it up; cancelling
/// the run closes it; starting a workflow adds a run. A smoke test can therefore watch the
/// *effect* of a tap rather than merely watch a request go out.
final class ScriptedControlBackend: ControlAPIClient, ControlLiveStream, AgentLogStream {

    static let gatePhase = "merge-approval"

    private var phase: String? = ScriptedControlBackend.gatePhase
    private var isCancelled = false
    private var plannerStatus = "dead"
    private var started: [WorkflowRun] = []
    private var continuation: AsyncStream<ControlLiveEvent>.Continuation?

    private var run: WorkflowRun {
        WorkflowRun(
            workflowId: "scripted-run",
            runId: "scripted-run-1",
            workflowType: "ScriptedWorkflow",
            namespace: "scripted",
            status: isCancelled ? "Canceled" : WorkflowRun.runningStatus,
            prNumber: 42,
            repo: "scripted/project",
            phase: phase,
            gateRef: phase == nil ? nil : "scripted-gate"
        )
    }

    private var running: [WorkflowRun] {
        (isCancelled ? [] : [run]) + started
    }

    // MARK: - ControlAPIClient

    func agents(_ connection: ControlConnection) async throws -> [FleetAgent] {
        [
            FleetAgent(
                agentName: "scripted-builder",
                displayName: "Scripted builder",
                currentTask: "Building the scripted change",
                effectiveStatus: "busy"
            ),
            FleetAgent(
                agentName: "scripted-reviewer",
                displayName: "Scripted reviewer",
                effectiveStatus: "idle"
            ),
            FleetAgent(
                agentName: "scripted-planner",
                displayName: "Scripted planner",
                effectiveStatus: plannerStatus
            )
        ]
    }

    func workflows(_ connection: ControlConnection) async throws -> [WorkflowRun] {
        running
    }

    func signalRegistry(
        _ connection: ControlConnection
    ) async throws -> [String: [SignalDefinition]] {
        [
            "ScriptedWorkflow": [
                SignalDefinition(
                    name: "merge-approval",
                    label: "merge approval",
                    buttons: [
                        SignalButton(label: "Approve Merge", payload: #"{"Decision":"approved"}"#),
                        SignalButton(
                            label: "Request Changes",
                            payload: #"{"Decision":"changes_requested"}"#,
                            requiresComment: true
                        )
                    ],
                    validPhases: [ScriptedControlBackend.gatePhase]
                )
            ]
        ]
    }

    func sendSignal(
        _ connection: ControlConnection,
        namespace: String,
        workflowId: String,
        body: SignalRequestBody
    ) async throws {
        phase = "merging"
        continuation?.yield(.frame(.workflows(running)))
    }

    func performAgentAction(
        _ connection: ControlConnection,
        agentName: String,
        action: AgentAction
    ) async throws {
        guard agentName == "scripted-planner" else { return }
        switch action {
        case .restart, .start: plannerStatus = "idle"
        case .stop: plannerStatus = "offline"
        case .cancelTask: break
        }
    }

    func closedRuns(_ connection: ControlConnection, hours: Int) async throws -> [WorkflowRun] {
        var closed = [
            WorkflowRun(
                workflowId: "scripted-finished",
                runId: "scripted-finished-1",
                workflowType: "ScriptedWorkflow",
                namespace: "scripted",
                status: "Completed",
                prNumber: 40,
                repo: "scripted/project"
            ),
            WorkflowRun(
                workflowId: "scripted-failed",
                runId: "scripted-failed-1",
                workflowType: "ScriptedWorkflow",
                namespace: "scripted",
                status: "Failed",
                prNumber: 41,
                repo: "scripted/project"
            )
        ]
        if isCancelled {
            closed.insert(run, at: 0)
        }
        return closed
    }

    func runHistory(
        _ connection: ControlConnection,
        namespace: String,
        workflowId: String
    ) async throws -> [WorkflowEvent] {
        [
            WorkflowEvent(eventId: 1, eventType: "WorkflowStarted"),
            WorkflowEvent(
                eventId: 2,
                eventType: "ActivityCompleted",
                activityType: "DelegateToAgentActivity",
                agent: "scripted-builder",
                outputSummary: "Scripted output"
            ),
            WorkflowEvent(
                eventId: 3,
                eventType: "ActivityFailed",
                activityType: "DelegateToAgentActivity",
                agent: "scripted-reviewer",
                failureMessage: "Scripted failure"
            )
        ]
    }

    func cancelRun(
        _ connection: ControlConnection,
        namespace: String,
        workflowId: String,
        runId: String
    ) async throws {
        if workflowId == "scripted-run" {
            isCancelled = true
        } else {
            started.removeAll { $0.workflowId == workflowId }
        }
        continuation?.yield(.frame(.workflows(running)))
    }

    func workflowTypes(_ connection: ControlConnection) async throws -> [WorkflowType] {
        [
            WorkflowType(
                name: "ScriptedWorkflow",
                description: "A scripted workflow",
                namespace: "scripted",
                taskQueue: "scripted",
                fields: [
                    WorkflowInputField(name: "topic", kind: .text, isRequired: true, help: nil),
                    WorkflowInputField(name: "urgent", kind: .toggle, isRequired: false, help: nil)
                ]
            )
        ]
    }

    func startWorkflow(
        _ connection: ControlConnection,
        body: StartWorkflowBody
    ) async throws -> String {
        let workflowId = "scripted-started-\(started.count + 1)"
        started.append(
            WorkflowRun(
                workflowId: workflowId,
                runId: workflowId + "-run",
                workflowType: body.workflowType,
                namespace: body.namespace,
                phase: "implementation"
            )
        )
        continuation?.yield(.frame(.workflows(running)))
        return workflowId
    }

    func registerPushDevice(
        _ connection: ControlConnection,
        deviceId: String,
        token: String
    ) async throws {}

    func unregisterPushDevice(_ connection: ControlConnection, deviceId: String) async throws {}

    func registerDevice(
        _ connection: ControlConnection,
        enrollmentCode: String,
        deviceName: String?
    ) async throws -> RegisteredDevice {
        RegisteredDevice(deviceId: "scripted-device", deviceSecret: "scripted-secret")
    }

    func mintToken(
        _ connection: ControlConnection,
        deviceId: String,
        deviceSecret: String
    ) async throws -> MintTokenResponse {
        MintTokenResponse(accessToken: "scripted-token", expiresInSeconds: 900)
    }

    func revokeDevice(_ connection: ControlConnection, deviceId: String) async throws {}

    /// Listed, and refused when its thread is opened: chat was turned off after the list was read.
    static let chatOffAgent = "scripted-quiet"

    func chatAgents(_ connection: ControlConnection) async throws -> ChatAgentList {
        ChatAgentList(
            available: true,
            agents: [
                ChatAgent(agentName: "scripted-builder", displayName: "Scripted builder"),
                ChatAgent(
                    agentName: ScriptedControlBackend.chatOffAgent,
                    displayName: "Scripted quiet"
                )
            ]
        )
    }

    // MARK: - ControlLiveStream

    func frames(_ connection: ControlConnection) -> AsyncStream<ControlLiveEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    // MARK: - AgentLogStream

    func log(_ connection: ControlConnection, agentName: String) -> AsyncStream<AgentLogEvent> {
        AsyncStream { continuation in
            continuation.yield(.text("scripted log line one\nscripted log line two\n"))
            continuation.yield(.text("scripted log line three"))
        }
    }
}

/// The scripted notification system. The person always says yes, and Apple always answers.
///
/// A simulator may or may not hand out a device token, and a UI test cannot answer the system's
/// permission prompt reliably, so under the scripted backend neither is asked for real.
@MainActor
final class ScriptedPushSystem: PushSystem {

    static let deviceToken = String(repeating: "ab", count: 32)

    var onDeviceToken: ((String) -> Void)?
    var onRegistrationFailed: (() -> Void)?
    var onOpened: ((PushDestination) -> Void)?

    func requestPermission() async -> PushPermission { .granted }

    func registerForRemoteNotifications() {
        // Later, not now: the real token also arrives after the call that asked for it returns.
        Task { @MainActor in
            self.onDeviceToken?(ScriptedPushSystem.deviceToken)
        }
    }

    func unregisterForRemoteNotifications() {}
}
