import SwiftUI

/// Every run worth knowing about: in progress, stopped without finishing, and finished.
///
/// Runs in progress come from the fleet model, which already keeps them fresh. Closed runs are
/// read when this screen opens and on pull-to-refresh: they change slowly, and the orchestrator
/// asks its workflow engine for them on every call.
struct RunsView: View {

    let fleet: ControlPlaneModel
    let runs: RunsModel
    /// The fleet's schedules, or `nil` where there is no link to offer.
    var schedules: SchedulesModel?

    @State private var isStarting = false
    @State private var query = ""

    var body: some View {
        List {
            if case .failed(let failure) = runs.closedLoad {
                Section {
                    FleetStatusRow(symbolName: failure.symbolName, messageKey: failure.messageKey)
                }
            }

            section("runs.running.title", empty: "runs.running.empty", runs: fleet.runningRuns)
            section("runs.stopped.title", empty: "runs.stopped.empty", runs: runs.stopped)
            section("runs.finished.title", empty: "runs.finished.empty", runs: runs.finished)

            windowSection
        }
        .navigationTitle(Text("runs.title"))
        .searchable(text: $query, prompt: Text("runs.search.prompt"))
        .navigationDestination(for: WorkflowRun.self) { run in
            RunDetailView(fleet: fleet, runs: runs, snapshot: run)
        }
        .navigationDestination(for: SchedulesRoute.self) { _ in
            if let schedules {
                SchedulesView(model: schedules, fleet: fleet)
            }
        }
        .navigationDestination(for: PendingGate.self) { gate in
            GateDecisionView(model: fleet, gate: gate)
        }
        .refreshable {
            await fleet.refresh()
            await runs.refreshClosed()
        }
        .toolbar {
            if schedules != nil {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: SchedulesRoute()) {
                        Image(systemName: "calendar.badge.clock")
                    }
                    .accessibilityIdentifier(AccessibilityIdentifier.schedulesOpen.identifier)
                    .accessibilityLabel(AccessibilityIdentifier.schedulesOpen.localizedLabel)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    runs.resetStart()
                    isStarting = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier(AccessibilityIdentifier.runsStart.identifier)
                .accessibilityLabel(AccessibilityIdentifier.runsStart.localizedLabel)
            }
        }
        .sheet(isPresented: $isStarting) {
            StartWorkflowView(runs: runs) {
                isStarting = false
                Task { await fleet.refresh() }
            }
        }
        .onAppear {
            fleet.start()
        }
        .task {
            await runs.refreshClosed()
        }
    }

    /// How far back closed runs are read. A longer window is a heavier read for the
    /// orchestrator's workflow engine, so the last day stays the default.
    private var windowSection: some View {
        Section {
            Picker(selection: windowBinding) {
                ForEach(RunsModel.windowChoices, id: \.self) { hours in
                    Text(Self.windowKey(hours: hours)).tag(hours)
                }
            } label: {
                Text("runs.window.title")
            }
            .accessibilityIdentifier(AccessibilityIdentifier.runsWindow.identifier)
        } footer: {
            Text("runs.window.help")
        }
    }

    private var windowBinding: Binding<Int> {
        let runs = self.runs
        return Binding(
            get: { runs.windowHours },
            set: { hours in Task { await runs.setWindow(hours: hours) } }
        )
    }

    // Typed explicitly so each is looked up in the catalog rather than shown as its own key.
    private static func windowKey(hours: Int) -> LocalizedStringKey {
        hours <= 24 ? "runs.window.day" : "runs.window.threeDays"
    }

    private func section(
        _ titleKey: LocalizedStringKey,
        empty emptyKey: LocalizedStringKey,
        runs all: [WorkflowRun]
    ) -> some View {
        let listed = all.filter { ListSearch.matches($0, query: query) }
        return Section {
            if listed.isEmpty {
                // Nothing here at all, or nothing here that matches what was typed: two
                // different facts, said differently.
                Text(all.isEmpty ? emptyKey : "runs.search.empty")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(listed, id: \.identity) { run in
                    NavigationLink(value: run) {
                        RunRow(run: run)
                    }
                    .accessibilityIdentifier(AccessibilityIdentifier.runsRun.identifier)
                    .accessibilityLabel(RunRow.spokenLabel(for: run))
                }
            }
        } header: {
            Text(titleKey)
        }
    }
}

/// Where the schedules link leads.
struct SchedulesRoute: Hashable {}

/// One run, in a line: how it stands, and what it is about.
struct RunRow: View {

    let run: WorkflowRun

    /// One column for the outcome symbol, so the subjects beside them line up.
    @ScaledMetric(relativeTo: .body) private var symbolColumn: CGFloat = 24

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: run.outcome.symbolName)
                .foregroundStyle(run.outcome.tint)
                .frame(width: symbolColumn)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: RunSubject.text(for: run))
                    .font(.body)
                Text(verbatim: Self.caption(for: run))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The workflow type, and the phase while running or the outcome once closed.
    static func caption(for run: WorkflowRun) -> String {
        let state: String
        if run.isRunning, let phase = run.phase, !phase.isEmpty {
            state = phase
        } else {
            state = run.outcome.localizedLabel
        }
        return run.workflowType + " · " + state
    }

    static func spokenLabel(for run: WorkflowRun) -> String {
        RunSubject.text(for: run) + ". " + caption(for: run)
    }
}

extension WorkflowRun.Outcome {

    /// A reinforcement of the symbol, never the only signal.
    var tint: Color {
        switch self {
        case .failed: return .red
        case .canceled: return .orange
        case .completed: return .green
        case .running, .other: return .secondary
        }
    }
}
