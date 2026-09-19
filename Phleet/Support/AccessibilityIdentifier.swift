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
    case conversationAgentReply = "conversation.agentReply"
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
