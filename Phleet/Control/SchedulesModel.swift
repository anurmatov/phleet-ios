import Foundation
import Observation

/// The fleet's schedules, and the three things that can be done to one from here: pause it,
/// let it run again, and start one run now.
///
/// Read when the screen opens and on pull-to-refresh. Creating, editing and deleting a schedule
/// stay on the web dashboard: they need a cron expression and a workflow input, which is
/// long-form editing.
@MainActor
@Observable
final class SchedulesModel {

    enum Load: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(ControlPlaneModel.Failure)
    }

    enum ActionState: Equatable, Sendable {
        case sending(ScheduleAction)
        /// The orchestrator accepted the request.
        case done(ScheduleAction)
        case failed(ScheduleAction, ControlPlaneModel.ActionFailure)
    }

    private let api: ControlAPIClient
    private let connection: ControlConnection

    private(set) var load: Load = .idle
    private(set) var schedules: [FleetSchedule] = []

    /// The last action sent to each schedule, by `FleetSchedule.id`.
    private(set) var actionStates: [String: ActionState] = [:]

    init(api: ControlAPIClient, connection: ControlConnection) {
        self.api = api
        self.connection = connection
    }

    /// Reads the schedules. A failed read keeps what was on screen.
    func refresh() async {
        if load == .idle {
            load = .loading
        }
        do {
            schedules = try await api.schedules(connection).sorted(by: Self.listOrder)
            load = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            load = .failed(ControlPlaneModel.Failure.from(error))
        }
    }

    func schedule(id: String) -> FleetSchedule? {
        schedules.first { $0.id == id }
    }

    func actionState(for schedule: FleetSchedule) -> ActionState? {
        actionStates[schedule.id]
    }

    /// Sends one action to one schedule, then reads the list again: whether a schedule is paused
    /// is the orchestrator's to say, not this screen's to assume.
    @discardableResult
    func perform(_ action: ScheduleAction, on schedule: FleetSchedule) async -> Bool {
        if case .sending? = actionStates[schedule.id] { return false }

        actionStates[schedule.id] = .sending(action)
        do {
            try await api.performScheduleAction(
                connection,
                namespace: schedule.namespace,
                scheduleId: schedule.scheduleId,
                action: action
            )
        } catch {
            actionStates[schedule.id] = .failed(action, ControlPlaneModel.ActionFailure.from(error))
            return false
        }
        actionStates[schedule.id] = .done(action)
        await refresh()
        return true
    }

    func clearActionState(for schedule: FleetSchedule) {
        if case .sending? = actionStates[schedule.id] { return }
        actionStates[schedule.id] = nil
    }

    /// By identifier, then namespace: the order is the same on every read.
    private static func listOrder(_ lhs: FleetSchedule, _ rhs: FleetSchedule) -> Bool {
        let byId = lhs.scheduleId.localizedCaseInsensitiveCompare(rhs.scheduleId)
        if byId != .orderedSame { return byId == .orderedAscending }
        return lhs.namespace < rhs.namespace
    }
}

extension ScheduleAction {

    /// What is worth offering for a schedule: pause one that runs, resume one that is paused,
    /// and start a run now either way.
    static func available(for schedule: FleetSchedule) -> [ScheduleAction] {
        schedule.isPaused ? [.unpause, .trigger] : [.trigger, .pause]
    }

    var titleKey: String {
        switch self {
        case .pause: return "scheduleAction.pause"
        case .unpause: return "scheduleAction.unpause"
        case .trigger: return "scheduleAction.trigger"
        }
    }

    var localizedTitle: String {
        String(localized: String.LocalizationValue(titleKey), bundle: .main)
    }

    var symbolName: String {
        switch self {
        case .pause: return "pause.circle"
        case .unpause: return "play.circle"
        case .trigger: return "bolt.circle"
        }
    }
}
