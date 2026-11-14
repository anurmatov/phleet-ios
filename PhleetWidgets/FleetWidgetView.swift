import SwiftUI
import WidgetKit

/// The widget, in each of the places it can sit.
///
/// It says three things at most: how many runs are waiting, which agents are down, and when
/// that was read. When it cannot say them it says why in words — a widget with a zero on it
/// because it could not sign in would be read as "nothing is waiting".
///
/// Every state has a symbol as well as its words, and nothing is told by colour alone: the lock
/// screen draws all of this in one tint.
struct FleetWidgetView: View {

    let entry: FleetEntry

    @Environment(\.widgetFamily) private var family

    private var content: GlanceContent { entry.content }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                inline
            case .accessoryCircular:
                circular
            case .accessoryRectangular:
                rectangular
            case .systemMedium:
                medium
            default:
                small
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    // MARK: - Home screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            headline
            Text(verbatim: content.waitingLine)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let agents = content.agentsLine {
                Text(verbatim: agents)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            readAt
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                headline
                Text(verbatim: content.waitingLine)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                readAt
            }

            VStack(alignment: .leading, spacing: 6) {
                if let first = content.firstWaiting {
                    Text(verbatim: first)
                        .font(.footnote)
                        .lineLimit(3)
                }
                if let agents = content.agentsLine {
                    Text(verbatim: agents)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The number when there is one to give, a symbol when there is not.
    @ViewBuilder
    private var headline: some View {
        switch content.state {
        case .current:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: String(content.waitingCount))
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                if !content.needingAttention.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                }
            }
        case .signedOut:
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.largeTitle)
        case .unreachable:
            Image(systemName: "wifi.slash")
                .font(.largeTitle)
        }
    }

    /// When this was read. The system redraws the widget on its own schedule, so the time is
    /// the only thing that says how old the number is.
    private var readAt: some View {
        Text(entry.date, style: .time)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    // MARK: - Lock screen

    private var inline: some View {
        Label {
            Text(verbatim: content.summaryLine)
        } icon: {
            Image(systemName: stateSymbol)
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            switch content.state {
            case .current:
                VStack(spacing: 0) {
                    Text(verbatim: String(content.waitingCount))
                        .font(.title2)
                        .fontWeight(.semibold)
                    if !content.needingAttention.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                    }
                }
            case .signedOut, .unreachable:
                Image(systemName: stateSymbol)
                    .font(.title3)
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(verbatim: content.state == .current && content.waitingCount > 0
                    ? String(content.waitingCount) + " " + content.waitingLine
                    : content.waitingLine)
            } icon: {
                Image(systemName: stateSymbol)
            }
            .font(.headline)

            if let agents = content.agentsLine {
                Text(verbatim: agents)
                    .font(.caption)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Words and symbols

    private var stateSymbol: String {
        switch content.state {
        case .signedOut: return "person.crop.circle.badge.questionmark"
        case .unreachable: return "wifi.slash"
        case .current:
            if !content.needingAttention.isEmpty { return "exclamationmark.triangle.fill" }
            return content.waitingCount > 0 ? "hand.raised.fill" : "checkmark.circle"
        }
    }

    /// Everything the widget shows, as one sentence.
    private var spokenLabel: String {
        var parts = [content.summaryLine]
        if let first = content.firstWaiting {
            parts.append(first)
        }
        if let agents = content.agentsLine {
            parts.append(agents)
        }
        return parts.joined(separator: ". ")
    }
}
