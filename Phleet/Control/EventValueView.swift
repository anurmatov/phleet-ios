import SwiftUI
import UIKit

/// A history event of one exact run, opened to read its values in full.
struct RunEventRoute: Hashable {
    let run: WorkflowRun
    let event: WorkflowEvent
}

/// One history event: its preview from the history, and its complete values read on request.
///
/// Opening the screen reads nothing. Each field has its own explicit read, its own way to stop
/// it, and says plainly when the server has no value, cannot show it, or does not offer complete
/// values at all.
struct RunEventView: View {

    @State private var model: EventValuesModel

    init(model: EventValuesModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        List {
            Section {
                if let subject = model.event.subject {
                    Text(verbatim: subject)
                }
                LabeledContent {
                    Text(verbatim: String(model.event.eventId))
                } label: {
                    Text("event.number")
                }
                if let timestamp = model.event.timestamp {
                    LabeledContent {
                        Text(timestamp, format: Date.FormatStyle(date: .abbreviated, time: .standard))
                    } label: {
                        Text("event.time")
                    }
                }
            }

            ForEach(model.fields, id: \.self) { field in
                EventFieldSection(model: model, field: field)
            }
        }
        .navigationTitle(Text(verbatim: model.event.title))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            model.stopAll()
        }
    }
}

/// One field of an event: the history's preview, and the complete value once it is asked for.
struct EventFieldSection: View {

    let model: EventValuesModel
    let field: EventValueField

    var body: some View {
        Section {
            if let preview = model.event.preview(of: field), !preview.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("event.value.preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: preview)
                        .font(.footnote)
                        .lineLimit(3)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityIdentifier.eventValuePreview.identifier)
            }

            content
        } header: {
            Text(field.titleKey)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state(of: field) {
        case .idle:
            loadButton(field.loadKey)
        case .loading:
            HStack(spacing: 12) {
                ProgressView()
                Text("event.value.loading")
                    .font(.footnote)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityIdentifier.eventValueState.identifier)
            Button(role: .cancel) {
                model.stop(field)
            } label: {
                Label {
                    Text("event.value.stop")
                } icon: {
                    Image(systemName: "stop.circle")
                }
            }
            .accessibilityIdentifier(AccessibilityIdentifier.eventValueStop.identifier)
            .accessibilityLabel(AccessibilityIdentifier.eventValueStop.localizedLabel)
        case .stopped:
            stated("event.value.stopped", symbol: "stop.circle")
            loadButton("event.value.loadAgain")
        case .failed(let failure):
            stated(failure.messageKey, symbol: "exclamationmark.triangle")
            loadButton("event.value.loadAgain")
        case .loaded(let result):
            EventValueResultRows(result: result, eventId: model.event.eventId)
        }
    }

    private func loadButton(_ key: LocalizedStringKey) -> some View {
        Button {
            model.load(field)
        } label: {
            Label {
                Text(key)
            } icon: {
                Image(systemName: "doc.text.magnifyingglass")
            }
        }
        .accessibilityIdentifier(AccessibilityIdentifier.eventValueLoad.identifier)
    }
}

/// What the server answered for one field.
struct EventValueResultRows: View {

    let result: EventValueResult
    let eventId: Int

    var body: some View {
        switch result {
        case .complete(let values, let sourceEventId):
            if sourceEventId != eventId {
                // An identifier, not a quantity: no grouping separator.
                Text(verbatim: String(localized: "event.value.source \(String(sourceEventId))"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                valueRow(value, index: index, count: values.count)
            }
        case .absent:
            stated("event.value.absent", symbol: "minus.circle")
        case .unsupported(let reason):
            stated(reason.messageKey, symbol: "eye.slash")
        case .tooLarge(let limitBytes):
            stated("event.value.tooLarge \(limitBytes)", symbol: "externaldrive.badge.exclamationmark")
        }
    }

    private func heading(index: Int, count: Int) -> String {
        count == 1
            ? String(localized: "event.value.single")
            : String(localized: "event.value.position \(index + 1) \(count)")
    }

    @ViewBuilder
    private func valueRow(_ value: EventPayloadText, index: Int, count: Int) -> some View {
        let title = heading(index: index, count: count)
        if value.text.isEmpty {
            // Stored, and empty: a different fact from no value at all.
            stated("event.value.emptyText", symbol: "text.alignleft")
        } else {
            NavigationLink {
                EventValueReaderView(value: value, title: title)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                    Text(verbatim: value.encoding + " · "
                        + String(localized: "event.value.characters \(value.text.count)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier(AccessibilityIdentifier.eventValueOpen.identifier)
        }
    }
}

/// A plain statement in a value's place, with a symbol so it never relies on colour alone.
private func stated(_ key: LocalizedStringKey, symbol: String) -> some View {
    Label {
        Text(key)
            .font(.footnote)
    } icon: {
        Image(systemName: symbol)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(AccessibilityIdentifier.eventValueState.identifier)
}

/// One complete value, full screen: an outline, indented or exactly as stored.
///
/// The text views are the system's own, so a person selects any part of the value with the
/// ordinary handles and menu. Copy always takes the value exactly as stored, whichever way it is
/// shown. JSON is laid out only when the payload's encoding says it is JSON and the text parses
/// whole; anything else is shown as stored, and text that claims to be JSON and is not says so.
struct EventValueReaderView: View {

    enum Mode: Hashable, CaseIterable {
        case outline
        /// A JSON string's text, with its escapes resolved.
        case text
        case pretty
        case raw

        var titleKey: LocalizedStringKey {
            switch self {
            case .outline: return "eventReader.mode.outline"
            case .text: return "eventReader.mode.text"
            case .pretty: return "eventReader.mode.pretty"
            case .raw: return "eventReader.mode.raw"
            }
        }
    }

    let value: EventPayloadText
    let title: String

    /// `nil` while the JSON is being read, and for a value that is not JSON-encoded.
    @State private var reading: JSONReading?
    @State private var mode: Mode?
    @State private var copied = false

    private let copyKey: LocalizedStringKey = "eventReader.copy"
    private let copiedKey: LocalizedStringKey = "eventReader.copied"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if value.isJSONEncoded, reading == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let modes = Self.modes(for: reading)
                if modes.count > 1 {
                    Picker(
                        AccessibilityIdentifier.eventReaderMode.localizedLabel,
                        selection: selectedMode(in: modes)
                    ) {
                        ForEach(modes, id: \.self) { mode in
                            Text(mode.titleKey).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding()
                    .accessibilityIdentifier(AccessibilityIdentifier.eventReaderMode.identifier)
                }
                if let notice = Self.noticeKey(for: value, reading: reading) {
                    Label {
                        Text(notice)
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityIdentifier.eventReaderNotice.identifier)
                }
                content(resolvedMode(in: modes))
            }
        }
        .navigationTitle(Text(verbatim: title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    EventValueCopy.copy(value)
                    copied = true
                    AccessibilityNotification.Announcement(String(localized: "eventReader.copied"))
                        .post()
                } label: {
                    Label {
                        Text(copied ? copiedKey : copyKey)
                    } icon: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                .accessibilityIdentifier(AccessibilityIdentifier.eventReaderCopy.identifier)
                .accessibilityHint(AccessibilityIdentifier.eventReaderCopy.localizedLabel)
            }
        }
        .task {
            guard value.isJSONEncoded, reading == nil else { return }
            let text = value.text
            reading = await Task.detached(priority: .userInitiated) {
                JSONReading.read(text)
            }.value
        }
    }

    /// The chosen way to show the value, or the most readable one this value has.
    private func resolvedMode(in modes: [Mode]) -> Mode {
        if let mode, modes.contains(mode) { return mode }
        return modes[0]
    }

    private func selectedMode(in modes: [Mode]) -> Binding<Mode> {
        Binding(
            get: { resolvedMode(in: modes) },
            set: { mode = $0 }
        )
    }

    @ViewBuilder
    private func content(_ mode: Mode) -> some View {
        switch (mode, reading) {
        case (.outline, .outline(let outline)?):
            if let root = outline.root {
                JSONOutlineList(root: root)
            }
        case (.text, .outline(let outline)?):
            SelectableTextView(text: outline.root?.value ?? value.text, monospaced: false)
        case (.pretty, .outline(let outline)?):
            SelectableTextView(text: outline.pretty, monospaced: true)
        default:
            SelectableTextView(text: value.text, monospaced: value.isJSONEncoded)
        }
    }

    /// The ways a value can be shown, the most readable first.
    static func modes(for reading: JSONReading?) -> [Mode] {
        guard case .outline(let outline)? = reading else { return [.raw] }
        guard let root = outline.root else { return [.pretty, .raw] }
        switch root.kind {
        case .object, .array: return [.outline, .pretty, .raw]
        case .string: return [.text, .raw]
        case .number, .literal: return [.raw]
        }
    }

    /// Why a value is shown the way it is, when that needs saying.
    static func noticeKey(for value: EventPayloadText, reading: JSONReading?) -> LocalizedStringKey? {
        guard value.isJSONEncoded else { return "eventReader.notice.text" }
        switch reading {
        case .invalid?: return "eventReader.notice.invalid"
        case .tooDeep?: return "eventReader.notice.tooDeep"
        case .outline(let outline)? where outline.root == nil: return "eventReader.notice.tooMany"
        default: return nil
        }
    }
}

/// What the copy control puts on the pasteboard: the value exactly as stored. Never the pretty
/// text, the outline or a preview.
enum EventValueCopy {
    static func copy(_ value: EventPayloadText) {
        UIPasteboard.general.string = value.text
    }
}

/// A JSON document's members, collapsed until opened.
struct JSONOutlineList: View {

    let root: JSONNode

    private static let emptyObject: LocalizedStringKey = "json.object.empty"
    private static let emptyArray: LocalizedStringKey = "json.array.empty"

    var body: some View {
        if root.children.isEmpty {
            Text(root.kind == .object ? Self.emptyObject : Self.emptyArray)
                .foregroundStyle(.secondary)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            List {
                ForEach(root.children) { node in
                    JSONNodeView(node: node)
                }
            }
            .listStyle(.plain)
        }
    }
}

/// An object or array as the system's disclosure group, whose content is only built once it is
/// opened; a scalar as a row.
struct JSONNodeView: View {

    let node: JSONNode

    var body: some View {
        if node.isContainer, !node.children.isEmpty {
            DisclosureGroup {
                ForEach(node.children) { child in
                    JSONNodeView(node: child)
                }
            } label: {
                JSONNodeRow(node: node)
            }
        } else {
            JSONNodeRow(node: node)
        }
    }
}

/// One member or element: its name, and what it holds. A string opens to be read whole.
struct JSONNodeRow: View {

    let node: JSONNode

    /// How much of a string a row lays out. Four lines show far less; this keeps a very long
    /// string from being typeset whole just to be cut.
    static let rowCharacters = 1_000

    var body: some View {
        if node.kind == .string, !node.value.isEmpty {
            NavigationLink {
                JSONStringReaderView(title: name, text: node.value)
            } label: {
                summary
            }
        } else {
            summary
        }
    }

    private var name: String {
        if let key = node.key { return key }
        if let index = node.index { return "[\(index)]" }
        return ""
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: name)
                .font(.subheadline.weight(.semibold))
            Text(verbatim: valueLine)
                .font(node.isContainer ? Font.footnote : Font.body.monospaced())
                .foregroundStyle(node.isContainer ? Color.secondary : Color.primary)
                .lineLimit(node.kind == .string ? 4 : nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityIdentifier.eventReaderNode.identifier)
    }

    private var valueLine: String {
        switch node.kind {
        case .object: return String(localized: "json.object.count \(node.children.count)")
        case .array: return String(localized: "json.array.count \(node.children.count)")
        case .string:
            // A beginning to recognise it by; the row opens to the whole text.
            return node.value.isEmpty
                ? String(localized: "json.string.empty")
                : String(node.value.prefix(Self.rowCharacters))
        case .number, .literal: return node.value
        }
    }
}

/// One JSON string's text, whole and selectable.
struct JSONStringReaderView: View {

    let title: String
    let text: String

    var body: some View {
        SelectableTextView(text: text, monospaced: false)
            .navigationTitle(Text(verbatim: title))
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// The system text view, read-only: it scrolls, lays out long text lazily, follows Dynamic Type,
/// and gives VoiceOver its own text navigation. Selection, Select All and Copy are the system's.
///
/// No data detectors: a stored value is data, and nothing in it becomes a link or an action.
struct SelectableTextView: UIViewRepresentable {

    let text: String
    let monospaced: Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        Self.configure(view, text: text, monospaced: monospaced)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if !(view.text ?? "").unicodeScalars.elementsEqual(text.unicodeScalars) {
            view.text = text
        }
    }

    static func configure(_ view: UITextView, text: String, monospaced: Bool) {
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.dataDetectorTypes = []
        view.adjustsFontForContentSizeCategory = true
        view.font = monospaced
            ? UIFontMetrics(forTextStyle: .body).scaledFont(
                for: .monospacedSystemFont(
                    ofSize: UIFont.preferredFont(
                        forTextStyle: .body,
                        compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
                    ).pointSize,
                    weight: .regular
                )
            )
            : .preferredFont(forTextStyle: .body)
        view.textColor = .label
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.accessibilityIdentifier = AccessibilityIdentifier.eventReaderText.identifier
        view.text = text
    }
}

extension EventValueField {

    var titleKey: LocalizedStringKey {
        switch self {
        case .input: return "event.field.input"
        case .output: return "event.field.output"
        case .failure: return "event.field.failure"
        }
    }

    var loadKey: LocalizedStringKey {
        switch self {
        case .input: return "event.value.load.input"
        case .output: return "event.value.load.output"
        case .failure: return "event.value.load.failure"
        }
    }
}

extension EventValueUnsupportedReason {

    var messageKey: LocalizedStringKey {
        switch self {
        case .encoding: return "event.value.unsupported.encoding"
        case .invalidUTF8: return "event.value.unsupported.invalidUTF8"
        case .eventType: return "event.value.unsupported.eventType"
        case .encodedFailure: return "event.value.unsupported.encodedFailure"
        }
    }
}

extension EventValuesModel.Failure {

    var messageKey: LocalizedStringKey {
        switch self {
        case .notOffered: return "event.value.failure.notOffered"
        case .notFound: return "event.value.failure.notFound"
        case .historyUnavailable: return "event.value.failure.historyUnavailable"
        case .timedOut: return "event.value.failure.timedOut"
        case .unreadableAnswer: return "event.value.failure.unreadableAnswer"
        case .tokenRejected: return "event.value.failure.tokenRejected"
        case .accessDenied: return "event.value.failure.accessDenied"
        case .unreachable: return "event.value.failure.unreachable"
        case .refused: return "event.value.failure.refused"
        }
    }
}
