import SwiftUI
import UIKit
import XCTest
@testable import Phleet

/// The complete-value screens: each state rendered across the Dynamic Type range, and the
/// reader's text checked as the system text view it is — selectable, holding the whole value,
/// and copied exactly as stored.
///
/// Synthetic values throughout. A render proves layout, not that a person can read it on a phone.
@MainActor
final class EventValueRenderingTests: XCTestCase {

    private let sizes: [DynamicTypeSize] = [
        .xSmall, .medium, .xxxLarge,
        .accessibility1, .accessibility3, .accessibility5
    ]

    private func assertRenders(
        _ view: some View,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for size in sizes {
            let renderer = ImageRenderer(
                content: view
                    .environment(\.dynamicTypeSize, size)
                    .frame(width: 390)
            )
            renderer.scale = 1

            guard let image = renderer.uiImage else {
                XCTFail("\(label) produced no render at \(size)", file: file, line: line)
                continue
            }
            XCTAssertGreaterThan(
                image.size.height,
                0,
                "\(label) collapsed to zero height at \(size)",
                file: file,
                line: line
            )
        }
    }

    private let run = WorkflowRun(
        workflowId: "pr-synthetic-42",
        runId: "run-1",
        workflowType: "UwePrImplementationWorkflow",
        namespace: "fleet"
    )

    private let event = WorkflowEvent(
        eventId: 9,
        eventType: "ActivityCompleted",
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        activityType: "DelegateToAgentActivity",
        agent: "builder",
        inputSummary: "An input preview long enough to wrap onto several lines at accessibility "
            + "sizes, cut short the way the history cuts it…",
        outputSummary: "An output preview"
    )

    // MARK: - Rows and states

    func testAHistoryRowRenders() {
        assertRenders(RunEventRow(event: event), "a history row")
    }

    func testTheHistorysPreviewGivesWayOnlyToTheCompleteValue() {
        let complete = EventValueResult.complete(
            values: [EventPayloadText(encoding: "text/plain", text: "whole")],
            sourceEventId: 9
        )
        XCTAssertFalse(EventFieldSection.showsPreview(in: .loaded(complete)))

        let others: [EventValuesModel.State] = [
            .idle, .loading, .stopped, .failed(.notOffered), .failed(.unreachable),
            .loaded(.absent), .loaded(.unsupported(.encoding)), .loaded(.tooLarge(limitBytes: 1_048_576))
        ]
        for state in others {
            XCTAssertTrue(
                EventFieldSection.showsPreview(in: state),
                "the preview went away with nothing in its place (\(state))"
            )
        }
    }

    func testACompleteValueRendersWhereItWasAskedFor() {
        let values = [
            EventPayloadText(encoding: "json/plain", text: #"{"a":{"b":[1,2,3]},"c":"text"}"#),
            EventPayloadText(encoding: "json/plain", text: #""a string\nof two lines""#),
            EventPayloadText(encoding: "json/plain", text: #"{"truncated":"#),
            EventPayloadText(encoding: "text/plain", text: SyntheticText.unicode(scalars: 100_000))
        ]
        for value in values {
            assertRenders(
                EventValueExcerptRow(value: value, title: "Complete value", position: nil),
                "a value's beginning (\(value.encoding), \(value.text.prefix(12)))"
            )
            assertRenders(
                EventValueExcerptRow(value: value, title: "Value 1 of 2", position: "Value 1 of 2"),
                "one of several values (\(value.encoding))"
            )
        }
    }

    func testEveryStateOfAFieldRenders() async {
        let failures: [EventValuesModel.Failure] = [
            .notOffered, .notFound, .historyUnavailable, .timedOut, .unreadableAnswer,
            .tokenRejected, .accessDenied, .unreachable, .refused("invalid_request")
        ]
        let results: [EventValueResult] = [
            .complete(values: [EventPayloadText(encoding: "json/plain", text: #"{"a":1}"#)], sourceEventId: 9),
            .complete(
                values: [
                    EventPayloadText(encoding: "json/plain", text: #""first""#),
                    EventPayloadText(encoding: "text/plain", text: "")
                ],
                sourceEventId: 5
            ),
            .absent,
            .unsupported(.encoding), .unsupported(.invalidUTF8),
            .unsupported(.eventType), .unsupported(.encodedFailure),
            .tooLarge(limitBytes: 1_048_576)
        ]

        var states: [(String, EventValuesModel)] = []

        let idle = RunsModel(api: FakeControlAPI(), connection: .fixture).eventValues(of: event, in: run)
        states.append(("idle", idle))

        for result in results {
            let api = FakeControlAPI()
            api.eventValueResult = .success(result)
            let model = RunsModel(api: api, connection: .fixture).eventValues(of: event, in: run)
            model.load(.input)
            await model.settle(.input)
            XCTAssertEqual(model.state(of: .input), .loaded(result))
            states.append(("\(result)", model))
        }
        for failure in failures {
            let api = FakeControlAPI()
            let error = Self.error(for: failure)
            api.onEventValue = { _ in throw error }
            let model = RunsModel(api: api, connection: .fixture).eventValues(of: event, in: run)
            model.load(.input)
            await model.settle(.input)
            XCTAssertEqual(model.state(of: .input), .failed(failure))
            states.append(("\(failure)", model))
        }

        let slow = FakeControlAPI()
        slow.onEventValue = { _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return .absent
        }
        let loading = RunsModel(api: slow, connection: .fixture).eventValues(of: event, in: run)
        loading.load(.input)
        states.append(("loading", loading))

        for (label, model) in states {
            assertRenders(
                VStack(alignment: .leading) { EventFieldSection(model: model, field: .input) },
                "the input field (\(label))"
            )
        }

        loading.stop(.input)
        XCTAssertEqual(loading.state(of: .input), .stopped)
        assertRenders(
            VStack(alignment: .leading) { EventFieldSection(model: loading, field: .input) },
            "the input field (stopped)"
        )
    }

    nonisolated private static func error(for failure: EventValuesModel.Failure) -> Error {
        switch failure {
        case .notOffered: return ControlAPIError.refused(status: 404, message: nil)
        case .notFound: return ControlAPIError.refused(status: 404, message: "not_found")
        case .historyUnavailable: return ControlAPIError.refused(status: 503, message: "history_unavailable")
        case .timedOut: return ControlAPIError.refused(status: 503, message: "history_timeout")
        case .unreadableAnswer: return EventValueAnswerError.inconsistent
        case .tokenRejected: return ControlAPIError.unauthorized
        case .accessDenied: return ControlAPIError.accessDenied
        case .unreachable: return ControlAPIError.transport("offline")
        case .refused(let code): return ControlAPIError.refused(status: 400, message: code)
        }
    }

    func testEveryKindOfJSONEntryRenders() throws {
        guard case .outline(let outline) = JSONReading.read(
            #"{"object":{"k":1},"list":[],"text":"line one\nline two","empty":"","n":1.10,"t":true,"z":null}"#
        ), let root = outline.root else {
            return XCTFail("the fixture is not JSON")
        }
        for node in root.children {
            assertRenders(JSONNodeRow(node: node), "a JSON entry (\(node.key ?? ""))")
        }
    }

    func testTheNumberedWordsResolveFromTheCatalog() {
        // A missing entry resolves to its own key, which would show "event.value.position 2 3".
        // Counts follow the reader's number format; an event number is an identifier and does not.
        XCTAssertEqual(String(localized: "event.value.position \(2) \(3)"), "Value 2 of 3")
        XCTAssertEqual(
            String(localized: "event.value.characters \(100_000)"),
            "\(100_000.formatted()) characters"
        )
        XCTAssertEqual(
            String(localized: "event.value.source \(String(12345))"),
            "Read from event 12345, which scheduled this activity."
        )
        XCTAssertEqual(String(localized: "json.object.count \(3)"), "Object (3)")
        XCTAssertEqual(String(localized: "json.array.count \(0)"), "List (0)")
        XCTAssertTrue(
            String(localized: "event.value.tooLarge \(1_048_576)")
                .contains("\(1_048_576.formatted()) bytes")
        )
    }

    // MARK: - The reader

    func testTheReaderOffersOnlyTheWaysThisValueCanBeShown() {
        func modes(_ text: String) -> [EventValueReaderView.Mode] {
            EventValueReaderView.modes(for: JSONReading.read(text))
        }
        XCTAssertEqual(modes(#"{"a":[1,2]}"#), [.outline, .pretty, .raw])
        XCTAssertEqual(modes("[]"), [.outline, .pretty, .raw])
        XCTAssertEqual(modes(#""a string""#), [.text, .raw])
        XCTAssertEqual(modes("12345678901234567890"), [.raw])
        XCTAssertEqual(modes(#"{"truncated":"#), [.raw], "malformed JSON is never laid out")
        XCTAssertEqual(EventValueReaderView.modes(for: nil), [.raw], "text that is not JSON-encoded")
        let many = "[" + Array(repeating: "0", count: JSONReading.maximumNodes + 1)
            .joined(separator: ",") + "]"
        XCTAssertEqual(modes(many), [.pretty, .raw])
    }

    func testTheReaderSaysWhyAValueIsShownAsStored() {
        let json = EventPayloadText(encoding: "json/plain", text: "{}")
        let plain = EventPayloadText(encoding: "text/plain", text: "{}")
        XCTAssertEqual(
            EventValueReaderView.noticeKey(for: plain, reading: nil),
            LocalizedStringKey("eventReader.notice.text"),
            "text that looks like JSON but is stored as text is not laid out as JSON"
        )
        XCTAssertEqual(
            EventValueReaderView.noticeKey(for: json, reading: .invalid),
            LocalizedStringKey("eventReader.notice.invalid")
        )
        XCTAssertEqual(
            EventValueReaderView.noticeKey(for: json, reading: .tooDeep),
            LocalizedStringKey("eventReader.notice.tooDeep")
        )
        XCTAssertEqual(
            EventValueReaderView.noticeKey(for: json, reading: .outline(JSONOutline(root: nil, pretty: "[]"))),
            LocalizedStringKey("eventReader.notice.tooMany")
        )
        XCTAssertNil(EventValueReaderView.noticeKey(for: json, reading: JSONReading.read("{}")))
    }

    /// The whole reader, hosted in a window as it is on screen: a stored JSON string of 100,000
    /// scalars opens as the text it stands for, in the system text view, whole, and selecting
    /// all of it copies all of it.
    func testTheReaderShowsALargeValueWholeInTheSystemTextView() async throws {
        let original = SyntheticText.unicode(scalars: 100_000)
        let literal = String(decoding: try JSONEncoder().encode(original), as: UTF8.self)
        let host = UIHostingController(
            rootView: NavigationStack {
                EventValueReaderView(
                    value: EventPayloadText(encoding: "json/plain", text: literal),
                    title: "Complete value"
                )
            }
        )
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        // The JSON is read off the main thread once the reader appears.
        var found: UITextView?
        for _ in 0..<200 where found == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            host.view.layoutIfNeeded()
            found = Self.textViews(in: host.view).first
        }
        let view = try XCTUnwrap(found, "the reader never showed its text")

        XCTAssertEqual(view.accessibilityIdentifier, AccessibilityIdentifier.eventReaderText.identifier)
        XCTAssertTrue(view.isSelectable)
        XCTAssertFalse(view.isEditable)
        XCTAssertTrue(
            SyntheticText.scalarsEqual(view.text, original),
            "the reader did not show the whole text the JSON string stands for"
        )

        view.selectedRange = NSRange(location: 0, length: (view.text as NSString).length)
        UIPasteboard.general.string = "something else"
        view.copy(nil)
        XCTAssertTrue(
            SyntheticText.scalarsEqual(UIPasteboard.general.string, original),
            "selecting all in the reader did not copy the whole value"
        )
    }

    private static func textViews(in view: UIView) -> [UITextView] {
        ([view as? UITextView].compactMap { $0 }) + view.subviews.flatMap { textViews(in: $0) }
    }

    func testCopyTakesTheValueExactlyAsStored() {
        let original = SyntheticText.unicode(scalars: 100_000)
        UIPasteboard.general.string = "something else"
        EventValueCopy.copy(EventPayloadText(encoding: "json/plain", text: original))
        XCTAssertTrue(
            SyntheticText.scalarsEqual(UIPasteboard.general.string, original),
            "the copy is not the whole original value"
        )
    }

    func testTheReaderTextIsTheSystemsSelectableTextViewHoldingTheWholeValue() throws {
        let original = SyntheticText.unicode(scalars: 100_000)
        let view = UITextView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        SelectableTextView.configure(view, text: original, monospaced: true)

        XCTAssertFalse(view.isEditable, "a stored value is not edited here")
        XCTAssertTrue(view.isFindInteractionEnabled, "the text cannot be searched")
        XCTAssertTrue(view.isSelectable, "the text is not selectable")
        XCTAssertTrue(view.isScrollEnabled)
        XCTAssertEqual(view.dataDetectorTypes, [], "a stored value must not become links or actions")
        XCTAssertTrue(view.adjustsFontForContentSizeCategory, "the text does not follow Dynamic Type")
        XCTAssertEqual(view.accessibilityIdentifier, AccessibilityIdentifier.eventReaderText.identifier)
        XCTAssertTrue(SyntheticText.scalarsEqual(view.text, original), "the view holds less than the value")

        // The text view's own selection and Copy: everything selected, everything copied.
        let window = (UIApplication.shared.connectedScenes.first as? UIWindowScene)
            .map { UIWindow(windowScene: $0) }
        window?.addSubview(view)
        defer { view.removeFromSuperview() }

        let length = (original as NSString).length
        view.selectedRange = NSRange(location: 0, length: length)
        XCTAssertEqual(view.selectedRange.length, length)
        UIPasteboard.general.string = "something else"
        view.copy(nil)
        XCTAssertTrue(
            SyntheticText.scalarsEqual(UIPasteboard.general.string, original),
            "selecting all and copying did not copy the whole value"
        )

        // A part of it, as a person drags the handles.
        view.selectedRange = NSRange(location: 1, length: 4)
        view.copy(nil)
        let part = (original as NSString).substring(with: NSRange(location: 1, length: 4))
        XCTAssertTrue(SyntheticText.scalarsEqual(UIPasteboard.general.string, part))
    }
}
