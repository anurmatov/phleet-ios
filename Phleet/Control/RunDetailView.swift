import SwiftUI

/// One run: where it stands, what happened in it, and the one thing to do about it.
///
/// Opened with the run as it was tapped. While the run is in progress its current state is read
/// from the fleet model instead, so a phase change shows without leaving the screen; once it is
/// no longer listed as running, the snapshot is all there is and is shown as it was.
struct RunDetailView: View {

    let fleet: ControlPlaneModel
    let runs: RunsModel
    let snapshot: WorkflowRun

    @State private var isConfirmingCancel = false

    /// The live run while it is running, the snapshot otherwise.
    private var run: WorkflowRun {
        fleet.runs.first { $0.identity == snapshot.identity } ?? snapshot
    }

    /// A run that was running when tapped and is no longer listed has closed since.
    private var hasLeftTheRunningList: Bool {
        snapshot.isRunning && !fleet.runs.contains { $0.identity == snapshot.identity }
    }

    private var gate: PendingGate? {
        fleet.gates.first { $0.run.identity == snapshot.identity }
    }

    var body: some View {
        List {
            summarySection

            if let gate {
                Section {
                    NavigationLink(value: gate) {
                        Label {
                            Text(verbatim: gate.heading)
                        } icon: {
                            Image(systemName: "hand.raised")
                        }
                    }
                    .accessibilityIdentifier(AccessibilityIdentifier.runGate.identifier)
                } header: {
                    Text("run.gate.title")
                }
            }

            if run.isRunning && !hasLeftTheRunningList {
                cancelSection
            }

            historySection
        }
        .navigationTitle(Text(verbatim: RunSubject.text(for: snapshot)))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await runs.loadHistory(for: snapshot)
        }
        .task {
            await runs.loadHistory(for: snapshot)
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section {
            Label {
                Text(verbatim: statusLabel)
                    .font(.headline)
            } icon: {
                Image(systemName: hasLeftTheRunningList ? "questionmark.circle" : run.outcome.symbolName)
                    .foregroundStyle(run.outcome.tint)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(AccessibilityIdentifier.runStatus.identifier)
            .accessibilityLabel(
                AccessibilityIdentifier.runStatus.localizedLabel + ". " + statusLabel
            )

            fact("run.type", run.workflowType)
            if run.isRunning, let phase = run.phase, !phase.isEmpty {
                fact("gate.phase", phase)
            }
            if let startTime = run.startTime {
                LabeledContent {
                    Text(startTime, format: Self.momentFormat)
                } label: {
                    Text("run.started")
                }
            }
            if let closeTime = run.closeTime {
                LabeledContent {
                    Text(closeTime, format: Self.momentFormat)
                } label: {
                    Text("run.closed")
                }
            }
            fact("run.workflowId", run.workflowId)
        }
    }

    /// A date and a time in one piece of text, in the reader's own format.
    private static var momentFormat: Date.FormatStyle {
        Date.FormatStyle(date: .abbreviated, time: .shortened)
    }

    private var statusLabel: String {
        hasLeftTheRunningList
            ? String(localized: "run.outcome.noLongerRunning")
            : run.outcome.localizedLabel
    }

    @ViewBuilder
    private var cancelSection: some View {
        let state = runs.cancelState(for: snapshot)

        Section {
            if !runs.canAct {
                Label {
                    Text("run.cancel.readOnly").font(.footnote)
                } icon: {
                    Image(systemName: "lock")
                }
                .accessibilityElement(children: .combine)
            } else if state == .requested {
                Label {
                    Text("run.cancel.requested").font(.footnote)
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityIdentifier.runCancelState.identifier)
            } else if isConfirmingCancel {
                Button(role: .destructive) {
                    Task {
                        await runs.cancel(snapshot)
                        isConfirmingCancel = false
                        await fleet.refresh()
                    }
                } label: {
                    Text("run.cancel.confirm")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .disabled(state == .sending)
                .accessibilityIdentifier(AccessibilityIdentifier.runCancelConfirm.identifier)
                .accessibilityLabel(AccessibilityIdentifier.runCancelConfirm.localizedLabel)

                Button(role: .cancel) {
                    isConfirmingCancel = false
                } label: {
                    Text("run.cancel.keep")
                        .frame(maxWidth: .infinity)
                }
                .disabled(state == .sending)
                .accessibilityIdentifier(AccessibilityIdentifier.runCancelKeep.identifier)
                .accessibilityLabel(AccessibilityIdentifier.runCancelKeep.localizedLabel)
            } else {
                Button(role: .destructive) {
                    isConfirmingCancel = true
                } label: {
                    Label {
                        Text("run.cancel")
                    } icon: {
                        Image(systemName: "xmark.circle")
                    }
                }
                .accessibilityIdentifier(AccessibilityIdentifier.runCancel.identifier)
                .accessibilityLabel(AccessibilityIdentifier.runCancel.localizedLabel)
            }

            if case .failed(let failure)? = state {
                Label {
                    ActionFailureText(failure: failure)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityIdentifier.runCancelState.identifier)
            }
        } footer: {
            Text("run.cancel.help")
        }
    }

    @ViewBuilder
    private var historySection: some View {
        Section {
            switch runs.history(for: snapshot) {
            case .loaded(let events)?:
                if events.isEmpty {
                    Text("run.history.empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(events) { event in
                        RunEventRow(event: event)
                    }
                }
            case .failed?:
                Label {
                    Text("run.history.failed").font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .accessibilityElement(children: .combine)
            case .loading?, nil:
                ProgressView()
            }
        } header: {
            Text("run.history.title")
        }
    }

    private func fact(_ titleKey: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent {
            Text(verbatim: value)
        } label: {
            Text(titleKey)
        }
    }
}

/// One entry in a run's history.
struct RunEventRow: View {

    let event: WorkflowEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: event.isFailure ? "exclamationmark.triangle" : "circle.fill")
                .imageScale(.small)
                .foregroundStyle(event.isFailure ? Color.red : Color.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: event.title)
                    .font(.subheadline)

                if let subject = event.subject {
                    Text(verbatim: subject)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let detail = event.detail {
                    Text(verbatim: detail)
                        .font(.footnote)
                        .lineLimit(6)
                        .textSelection(.enabled)
                }
                if let timestamp = event.timestamp {
                    Text(timestamp, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityIdentifier.runEvent.identifier)
    }
}
