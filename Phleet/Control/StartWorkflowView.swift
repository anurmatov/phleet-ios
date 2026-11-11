import SwiftUI

/// Pick a workflow type, fill in what it asks for, start it.
///
/// Only inputs a phone form can honestly offer are shown — text, numbers and switches. A type
/// that needs anything richer is better started from the dashboard, and says so.
struct StartWorkflowView: View {

    let runs: RunsModel
    let finish: () -> Void

    var body: some View {
        NavigationStack {
            List {
                switch runs.typesLoad {
                case .idle, .loading:
                    ProgressView()
                case .failed(let failure):
                    FleetStatusRow(symbolName: failure.symbolName, messageKey: failure.messageKey)
                case .loaded:
                    if runs.types.isEmpty {
                        Text("start.types.empty")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(runs.types) { type in
                            NavigationLink(value: type) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: type.name)
                                        .font(.body)
                                    if let description = type.description, !description.isEmpty {
                                        Text(verbatim: description)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .accessibilityIdentifier(AccessibilityIdentifier.startType.identifier)
                        }
                    }
                }
            }
            .navigationTitle(Text("start.title"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: WorkflowType.self) { type in
                StartWorkflowForm(runs: runs, workflowType: type, finish: finish)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        finish()
                    } label: {
                        Text("start.close")
                    }
                    .accessibilityIdentifier(AccessibilityIdentifier.startClose.identifier)
                    .accessibilityLabel(AccessibilityIdentifier.startClose.localizedLabel)
                }
            }
            .task {
                await runs.loadTypes()
            }
        }
    }
}

/// The inputs for one workflow type.
struct StartWorkflowForm: View {

    let runs: RunsModel
    let workflowType: WorkflowType
    let finish: () -> Void

    @State private var text: [String: String] = [:]
    @State private var toggles: [String: Bool] = [:]

    private var isSending: Bool { runs.startState == .sending }

    var body: some View {
        List {
            Section {
                if workflowType.fields.isEmpty {
                    Text("start.fields.none")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(workflowType.fields) { field in
                        fieldRow(field)
                    }
                }
            } header: {
                Text("start.fields.title")
            } footer: {
                Text("start.fields.help")
            }

            Section {
                if case .started(let workflowId) = runs.startState {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("start.state.started").font(.footnote)
                            Text(verbatim: workflowId)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityIdentifier.startState.identifier)

                    Button {
                        finish()
                    } label: {
                        Text("start.done")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier(AccessibilityIdentifier.startDone.identifier)
                    .accessibilityLabel(AccessibilityIdentifier.startDone.localizedLabel)
                } else {
                    Button {
                        Task { await runs.start(workflowType, text: text, toggles: toggles) }
                    } label: {
                        Text("start.submit")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSending)
                    .accessibilityIdentifier(AccessibilityIdentifier.startSubmit.identifier)
                    .accessibilityLabel(AccessibilityIdentifier.startSubmit.localizedLabel)

                    failure
                }
            }
        }
        .navigationTitle(Text(verbatim: workflowType.name))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            runs.resetStart()
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: WorkflowInputField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch field.kind {
            case .toggle:
                Toggle(isOn: toggleBinding(field.name)) {
                    Text(verbatim: field.name)
                }
            case .text, .number:
                Text(verbatim: field.isRequired ? field.name + " *" : field.name)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextField(prompt(for: field), text: textBinding(field.name), axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(field.kind == .number ? .numbersAndPunctuation : .default)
            }
            if let help = field.help, !help.isEmpty {
                Text(verbatim: help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier(AccessibilityIdentifier.startField.identifier)
    }

    // Typed explicitly so it is looked up in the catalog rather than shown as its own key.
    private func prompt(for field: WorkflowInputField) -> LocalizedStringKey {
        field.isRequired ? "start.field.required" : "start.field.optional"
    }

    @ViewBuilder
    private var failure: some View {
        switch runs.startState {
        case .invalid(let error):
            Label {
                Text(verbatim: Self.message(for: error)).font(.footnote)
            } icon: {
                Image(systemName: "text.badge.xmark")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityIdentifier.startState.identifier)
        case .failed(let failure):
            Label {
                ActionFailureText(failure: failure)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityIdentifier.startState.identifier)
        case .idle, .sending, .started:
            EmptyView()
        }
    }

    static func message(for error: StartWorkflowError) -> String {
        switch error {
        case .missingRequired(let name):
            return String(localized: "start.invalid.missing") + " " + name
        case .notANumber(let name):
            return String(localized: "start.invalid.number") + " " + name
        }
    }

    private func textBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { text[name] ?? "" },
            set: { text[name] = $0 }
        )
    }

    private func toggleBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { toggles[name] ?? false },
            set: { toggles[name] = $0 }
        )
    }
}
