import SwiftUI

/// The fleet's schedules: what each starts, when, and whether it is paused.
///
/// A schedule opens to the three things that can be done to it from a phone. Each takes two
/// taps, like every other action here; starting a run now is work that costs something, and
/// pausing a schedule silently stops work someone may be expecting.
struct SchedulesView: View {

    let model: SchedulesModel
    /// Read again after a run is started, so the Runs list shows it.
    let fleet: ControlPlaneModel

    var body: some View {
        List {
            if case .failed(let failure) = model.load {
                Section {
                    FleetStatusRow(symbolName: failure.symbolName, messageKey: failure.messageKey)
                }
            }

            Section {
                if model.schedules.isEmpty {
                    if model.load == .loading || model.load == .idle {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("schedules.empty")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(AccessibilityIdentifier.schedulesEmpty.identifier)
                    }
                } else {
                    ForEach(model.schedules) { schedule in
                        NavigationLink(value: ScheduleRoute(id: schedule.id)) {
                            ScheduleRow(schedule: schedule)
                        }
                        .accessibilityIdentifier(AccessibilityIdentifier.schedulesSchedule.identifier)
                        .accessibilityLabel(ScheduleRow.spokenLabel(for: schedule))
                    }
                }
            } footer: {
                Text("schedules.help")
            }
        }
        .navigationTitle(Text("schedules.title"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ScheduleRoute.self) { route in
            ScheduleDetailView(model: model, fleet: fleet, scheduleId: route.id)
        }
        .refreshable {
            await model.refresh()
        }
        .task {
            await model.refresh()
        }
    }
}

/// Where a schedule row leads. An identifier rather than the schedule itself, so the detail
/// screen reads its current state from the model instead of the row that was tapped.
struct ScheduleRoute: Hashable {
    let id: String
}

/// One schedule, in a line.
struct ScheduleRow: View {

    let schedule: FleetSchedule

    @ScaledMetric(relativeTo: .body) private var symbolColumn: CGFloat = 24

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: schedule.isPaused ? "pause.circle" : "clock.arrow.circlepath")
                .foregroundStyle(schedule.isPaused ? Color.orange : Color.secondary)
                .frame(width: symbolColumn)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: schedule.scheduleId)
                    .font(.body)
                Text(verbatim: Self.caption(for: schedule))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What it starts and when, and that it is paused when it is — in words, because the symbol
    /// that says so is invisible to VoiceOver.
    static func caption(for schedule: FleetSchedule) -> String {
        var parts: [String] = []
        if schedule.isPaused {
            parts.append(String(localized: "schedule.paused", bundle: .main))
        }
        if let type = schedule.workflowType, !type.isEmpty {
            parts.append(type)
        }
        if let cron = schedule.cronExpression, !cron.isEmpty {
            parts.append(cron)
        }
        return parts.isEmpty ? schedule.namespace : parts.joined(separator: " · ")
    }

    static func spokenLabel(for schedule: FleetSchedule) -> String {
        schedule.scheduleId + ". " + caption(for: schedule)
    }
}

/// One schedule in full, and what can be done to it.
struct ScheduleDetailView: View {

    let model: SchedulesModel
    let fleet: ControlPlaneModel
    let scheduleId: String

    @State private var chosen: ScheduleAction?
    @Environment(\.confirmOwner) private var confirmOwner

    var body: some View {
        Group {
            if let schedule = model.schedule(id: scheduleId) {
                detail(schedule)
            } else {
                ContentUnavailableView {
                    Label {
                        Text("schedule.gone.title")
                    } icon: {
                        Image(systemName: "calendar.badge.exclamationmark")
                    }
                } description: {
                    Text("schedule.gone.description")
                }
                .accessibilityIdentifier(AccessibilityIdentifier.scheduleGone.identifier)
            }
        }
        .navigationTitle(Text(verbatim: model.schedule(id: scheduleId)?.scheduleId ?? ""))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ schedule: FleetSchedule) -> some View {
        let state = model.actionState(for: schedule)

        return List {
            Section {
                Label {
                    Text(schedule.isPaused ? "schedule.state.paused" : "schedule.state.active")
                        .font(.headline)
                } icon: {
                    Image(systemName: schedule.isPaused ? "pause.circle" : "clock.arrow.circlepath")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityIdentifier.scheduleState.identifier)

                if let type = schedule.workflowType, !type.isEmpty {
                    fact("schedule.workflowType", type)
                }
                if let cron = schedule.cronExpression, !cron.isEmpty {
                    fact("schedule.cron", cron)
                }
                fact("schedule.namespace", schedule.namespace)
                if let note = schedule.note, !note.isEmpty {
                    Text(verbatim: note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if let chosen {
                    confirmation(chosen, schedule: schedule, isSending: isSending(state))
                } else {
                    ForEach(ScheduleAction.available(for: schedule), id: \.self) { action in
                        Button {
                            model.clearActionState(for: schedule)
                            chosen = action
                        } label: {
                            Label {
                                Text(verbatim: action.localizedTitle)
                            } icon: {
                                Image(systemName: action.symbolName)
                            }
                        }
                        .disabled(isSending(state))
                        .accessibilityIdentifier(AccessibilityIdentifier.scheduleAction.identifier)
                    }
                }

                if let state {
                    ScheduleActionStateRow(state: state)
                }
            } header: {
                Text("agentAction.title")
            } footer: {
                Text("schedule.action.help")
            }
        }
    }

    private func isSending(_ state: SchedulesModel.ActionState?) -> Bool {
        if case .sending? = state { return true }
        return false
    }

    @ViewBuilder
    private func confirmation(
        _ action: ScheduleAction,
        schedule: FleetSchedule,
        isSending: Bool
    ) -> some View {
        Button {
            Task {
                guard await confirmOwner(String(localized: "confirmOwner.reason.action")) else {
                    return
                }
                let accepted = await model.perform(action, on: schedule)
                chosen = nil
                if accepted && action == .trigger {
                    await fleet.refresh()
                }
            }
        } label: {
            Text(verbatim: action.localizedTitle + ": " + schedule.scheduleId)
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .disabled(isSending)
        .accessibilityIdentifier(AccessibilityIdentifier.scheduleActionConfirm.identifier)
        .accessibilityLabel(
            AccessibilityIdentifier.scheduleActionConfirm.localizedLabel + ". "
                + action.localizedTitle
        )

        Button(role: .cancel) {
            chosen = nil
        } label: {
            Text("agentAction.cancel")
                .frame(maxWidth: .infinity)
        }
        .disabled(isSending)
        .accessibilityIdentifier(AccessibilityIdentifier.scheduleActionCancel.identifier)
        .accessibilityLabel(AccessibilityIdentifier.scheduleActionCancel.localizedLabel)
    }

    private func fact(_ titleKey: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent {
            Text(verbatim: value)
        } label: {
            Text(titleKey)
        }
    }
}

/// The last action sent to a schedule: in flight, accepted, or why not.
struct ScheduleActionStateRow: View {

    let state: SchedulesModel.ActionState

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: headline).font(.footnote)
                if case .failed(_, let failure) = state {
                    ActionFailureText(failure: failure)
                }
            }
        } icon: {
            Image(systemName: symbolName)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityIdentifier.scheduleActionState.identifier)
    }

    private var headline: String {
        switch state {
        case .sending(let action):
            return String(localized: "agentAction.state.sending") + " " + action.localizedTitle
        case .done(let action):
            return String(localized: "agentAction.state.requested") + " " + action.localizedTitle
        case .failed(let action, _):
            return String(localized: "agentAction.state.failed") + " " + action.localizedTitle
        }
    }

    private var symbolName: String {
        switch state {
        case .sending: return "ellipsis.circle"
        case .done: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
}
