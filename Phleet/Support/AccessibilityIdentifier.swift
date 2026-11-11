import Foundation

/// Every element the interface exposes to assistive technology and to UI tests.
///
/// The identifier is the stable hook UI tests query; the label is what a person hears. The
/// mapping between them is a fixed convention — `labelKey` is `"a11y." + rawValue` — so there
/// is nothing for a caller to invent and nothing for a view and a test to disagree about.
///
/// A few elements carry content that only exists at runtime — a transcript entry names its
/// speaker, its state and its text. Those use the case here for the *hook* and compose their
/// spoken label from the content, which is the only way one entry can read as one coherent
/// sentence. The catalog entry still has to exist, and `AccessibilityStringTests` still fails
/// the build without it.
enum AccessibilityIdentifier: String, CaseIterable {
    case rootTitle = "root.title"
    case rootPurpose = "root.purpose"

    case enrollmentAddressField = "enrollment.addressField"
    case enrollmentAddressMessage = "enrollment.addressMessage"
    case enrollmentCodeField = "enrollment.codeField"
    case enrollmentCodeMessage = "enrollment.codeMessage"
    case enrollmentConnect = "enrollment.connect"
    case enrollmentFormMessage = "enrollment.formMessage"
    case enrollmentRevokedNotice = "enrollment.revokedNotice"
    case enrollmentCredentialUnavailable = "enrollment.credentialUnavailable"

    case agentLabel = "agent.label"
    case agentPrincipal = "agent.principal"
    case agentServer = "agent.server"
    case agentOpenThread = "agent.openThread"

    case conversationTranscript = "conversation.transcript"
    case conversationEntry = "conversation.entry"
    case conversationMessageBody = "conversation.messageBody"
    case conversationAgentReply = "conversation.agentReply"
    case conversationReplyBody = "conversation.replyBody"
    case conversationSystemLine = "conversation.systemLine"
    case conversationReplayGap = "conversation.replayGap"
    case conversationProgress = "conversation.progress"
    case conversationComposer = "conversation.composer"
    case conversationComposerLimit = "conversation.composerLimit"
    case conversationMediaUnsupported = "conversation.mediaUnsupported"
    case conversationSend = "conversation.send"
    case conversationBanner = "conversation.banner"
    case conversationResume = "conversation.resume"
    case conversationOutcomeUnknown = "conversation.outcomeUnknown"
    case conversationSendAgain = "conversation.sendAgain"


    case controlSetupTitle = "controlSetup.title"
    case controlSetupAddressField = "controlSetup.addressField"
    case controlSetupAddressMessage = "controlSetup.addressMessage"
    case controlSetupClientIdField = "controlSetup.clientIdField"
    case controlSetupClientSecretField = "controlSetup.clientSecretField"
    case controlSetupServiceTokenMessage = "controlSetup.serviceTokenMessage"
    case controlSetupTokenField = "controlSetup.tokenField"
    case controlSetupConnect = "controlSetup.connect"
    case controlSetupFormMessage = "controlSetup.formMessage"
    case controlSetupCredentialUnavailable = "controlSetup.credentialUnavailable"

    case fleetStatus = "fleet.status"
    case fleetNoGates = "fleet.noGates"
    case fleetGate = "fleet.gate"
    case fleetNoAgents = "fleet.noAgents"
    case fleetAgent = "fleet.agent"
    case fleetUpdated = "fleet.updated"
    case fleetConnection = "fleet.connection"

    case gateSummary = "gate.summary"
    case gateComment = "gate.comment"
    case gateDecision = "gate.decision"
    case gateConfirm = "gate.confirm"
    case gateCancel = "gate.cancel"
    case gateNotice = "gate.notice"
    case gateFailure = "gate.failure"

    case agentDetailHealth = "agentDetail.health"
    case agentDetailTask = "agentDetail.task"
    case agentDetailFact = "agentDetail.fact"
    case agentDetailGone = "agentDetail.gone"

    case agentAction = "agentAction.action"
    case agentActionConfirm = "agentAction.confirm"
    case agentActionCancel = "agentAction.cancel"
    case agentActionNotice = "agentAction.notice"
    case agentActionState = "agentAction.state"

    case agentLogOpen = "agentLog.open"
    case agentLogLine = "agentLog.line"
    case agentLogState = "agentLog.state"
    case agentLogReload = "agentLog.reload"

    case runsUnconnected = "runs.unconnected"
    case runsRun = "runs.run"
    case runsStart = "runs.start"

    case runStatus = "run.status"
    case runGate = "run.gate"
    case runCancel = "run.cancel"
    case runCancelConfirm = "run.cancelConfirm"
    case runCancelKeep = "run.cancelKeep"
    case runCancelState = "run.cancelState"
    case runEvent = "run.event"

    case startType = "start.type"
    case startField = "start.field"
    case startSubmit = "start.submit"
    case startState = "start.state"
    case startDone = "start.done"
    case startClose = "start.close"

    case connectionAddress = "connection.address"
    case connectionMode = "connection.mode"
    case connectionRemove = "connection.remove"
    case connectionRemoveConfirm = "connection.removeConfirm"
    case connectionRemoveCancel = "connection.removeCancel"
    case connectionDone = "connection.done"

    /// The UI-test hook. Applied with `.accessibilityIdentifier(_:)`.
    var identifier: String { rawValue }

    /// The catalog key holding this element's spoken label.
    var labelKey: String { "a11y." + rawValue }

    /// The spoken label, resolved from the app bundle's string catalog.
    ///
    /// The single resolution path shared by views and tests. Views must apply this value, not
    /// `Text(labelKey)` — `Text(_: String)` is the verbatim initializer and would speak the raw
    /// key. Because the test asserts on this same property, the two cannot drift apart.
    var localizedLabel: String {
        String(localized: String.LocalizationValue(labelKey), bundle: .main)
    }
}
