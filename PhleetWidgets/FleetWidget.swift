import SwiftUI
import WidgetKit

/// One reading of the fleet, and when it was taken.
struct FleetEntry: TimelineEntry {
    let date: Date
    let content: GlanceContent
}

/// Reads the fleet for the widget.
///
/// The widget signs in on its own, from the sign-in the app keeps in the app group, the same way
/// a shortcut does: one token minted for the read and kept nowhere. It never writes anything —
/// not to the server, and not to the credential.
///
/// Each reading asks to be replaced after a quarter of an hour. The system decides when it
/// really is, so what is on the widget says when it was read.
struct FleetProvider: TimelineProvider {

    /// How long a reading is offered for before another is asked for.
    static let refreshSeconds: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> FleetEntry {
        FleetEntry(date: Date(), content: .example)
    }

    func getSnapshot(in context: Context, completion: @escaping (FleetEntry) -> Void) {
        // The gallery shows an example: it must not sign in, and must not show one person's
        // fleet in a picker.
        if context.isPreview {
            completion(FleetEntry(date: Date(), content: .example))
            return
        }
        Task {
            let content = await GlanceContent.load(using: QuickActions.live())
            completion(FleetEntry(date: Date(), content: content))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FleetEntry>) -> Void) {
        Task {
            let content = await GlanceContent.load(using: QuickActions.live())
            let now = Date()
            completion(
                Timeline(
                    entries: [FleetEntry(date: now, content: content)],
                    policy: .after(now.addingTimeInterval(Self.refreshSeconds))
                )
            )
        }
    }
}

/// The fleet at a glance, on the home screen and the lock screen.
struct FleetWidget: Widget {

    static let kind = "FleetWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: FleetProvider()) { entry in
            FleetWidgetView(entry: entry)
        }
        .configurationDisplayName(Text("glance.widget.name"))
        .description(Text("glance.widget.description"))
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

@main
struct PhleetWidgets: WidgetBundle {
    var body: some Widget {
        FleetWidget()
    }
}
