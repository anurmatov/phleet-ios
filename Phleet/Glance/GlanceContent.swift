import Foundation

/// What the widget shows: the fleet in a number, a line and a few names — or why it has none.
///
/// A value with nothing of WidgetKit in it, so that what the widget says in each case is decided
/// here and tested in the app's own test suite. The widget only draws it.
struct GlanceContent: Equatable, Sendable {

    enum State: Equatable, Sendable {
        /// The fleet was read.
        case current
        /// No sign-in this phone's extensions can read. The app has to be opened, or signed in.
        case signedOut
        /// The fleet did not answer. Nothing is known, which is not the same as nothing waiting.
        case unreachable
    }

    let state: State
    /// How many runs are waiting for a person.
    let waitingCount: Int
    /// The run that has waited longest, in the words the Fleet tab uses for it.
    let firstWaiting: String?
    /// Agents that are down or late, most urgent first.
    let needingAttention: [String]
    let agentCount: Int

    static let signedOut = GlanceContent(
        state: .signedOut, waitingCount: 0, firstWaiting: nil, needingAttention: [], agentCount: 0
    )

    static let unreachable = GlanceContent(
        state: .unreachable, waitingCount: 0, firstWaiting: nil, needingAttention: [], agentCount: 0
    )

    /// What a widget shows before it has ever been loaded, and in the widget gallery: obviously
    /// an example, with no real name in it.
    static let example = GlanceContent(
        state: .current,
        waitingCount: 2,
        firstWaiting: "Merge approval — example/project · PR #42",
        needingAttention: [],
        agentCount: 4
    )

    init(
        state: State,
        waitingCount: Int,
        firstWaiting: String?,
        needingAttention: [String],
        agentCount: Int
    ) {
        self.state = state
        self.waitingCount = waitingCount
        self.firstWaiting = firstWaiting
        self.needingAttention = needingAttention
        self.agentCount = agentCount
    }

    init(summary: QuickActions.FleetSummary) {
        self.init(
            state: .current,
            waitingCount: summary.waiting.count,
            firstWaiting: summary.waiting.first,
            needingAttention: summary.needingAttention,
            agentCount: summary.agentCount
        )
    }

    /// Why there is nothing to show. Every failure that is not "signed out" is "did not answer":
    /// the widget reads, so a refusal and a timeout leave it knowing the same thing.
    init(failure: QuickActions.Failure) {
        self = failure == .signedOut ? .signedOut : .unreachable
    }

    /// Whether anything on the widget asks for a person: a run waiting, or an agent down.
    var needsAttention: Bool {
        state == .current && (waitingCount > 0 || !needingAttention.isEmpty)
    }

    /// Reads the fleet once and says what the widget should show.
    static func load(using actions: QuickActions) async -> GlanceContent {
        do {
            return GlanceContent(summary: try await actions.fleetSummary())
        } catch let failure as QuickActions.Failure {
            return GlanceContent(failure: failure)
        } catch {
            return .unreachable
        }
    }

    // MARK: - Words

    /// The line under the number.
    var waitingLine: String {
        switch state {
        case .signedOut:
            return String(localized: "glance.signedOut", bundle: .main)
        case .unreachable:
            return String(localized: "glance.unreachable", bundle: .main)
        case .current:
            return waitingCount == 0
                ? String(localized: "glance.nothingWaiting", bundle: .main)
                : String(localized: "glance.waiting", bundle: .main)
        }
    }

    /// The line about agents: who is down, or that all are up. `nil` when there is nothing to
    /// say — no fleet was read, or it has no agents.
    var agentsLine: String? {
        guard state == .current, agentCount > 0 else { return nil }
        if needingAttention.isEmpty {
            return String(localized: "glance.agentsFine", bundle: .main)
        }
        return String(localized: "glance.agentsDown", bundle: .main) + " "
            + needingAttention.joined(separator: ", ")
    }

    /// One line for the smallest places: the lock screen's line of text, and VoiceOver.
    var summaryLine: String {
        switch state {
        case .signedOut, .unreachable:
            return waitingLine
        case .current:
            var parts = [waitingCount == 0 ? waitingLine : String(waitingCount) + " " + waitingLine]
            if !needingAttention.isEmpty {
                parts.append(
                    String(needingAttention.count) + " "
                        + String(localized: "glance.down", bundle: .main)
                )
            }
            return parts.joined(separator: " · ")
        }
    }
}

/// Asks the system to draw the widget again, when what it shows is known to have changed.
///
/// The widget reads the fleet on its own, on the system's schedule. This is only a nudge for the
/// moments the app already knows better: a gate was answered, the phone signed in or out.
protocol GlanceRefresher {
    func refresh()
}

/// Does nothing. What the tests and the scripted backend use.
struct NoGlanceRefresher: GlanceRefresher {
    func refresh() {}
}
