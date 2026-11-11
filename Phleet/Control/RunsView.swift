import SwiftUI

/// Every run worth knowing about: in progress, stopped without finishing, and finished.
///
/// Runs in progress come from the fleet model, which already keeps them fresh. Closed runs are
/// read when this screen opens and on pull-to-refresh: they change slowly, and the orchestrator
/// asks its workflow engine for them on every call.
struct RunsView: View {

    let fleet: ControlPlaneModel
    let runs: RunsModel

    @State private var isStarting = false

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
        }
        .navigationTitle(Text("runs.title"))
        .navigationDestination(for: WorkflowRun.self) { run in
            RunDetailView(fleet: fleet, runs: runs, snapshot: run)
        }
        .navigationDestination(for: PendingGate.self) { gate in
            GateDecisionView(model: fleet, gate: gate)
        }
        .refreshable {
            await fleet.refresh()
            await runs.refreshClosed()
        }
        .toolbar {
            if runs.canAct {
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

    private func section(
        _ titleKey: LocalizedStringKey,
        empty emptyKey: LocalizedStringKey,
        runs listed: [WorkflowRun]
    ) -> some View {
        Section {
            if listed.isEmpty {
                Text(emptyKey)
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

/// One run, in a line: how it stands, and what it is about.
struct RunRow: View {

    let run: WorkflowRun

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: run.outcome.symbolName)
                .foregroundStyle(run.outcome.tint)
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
