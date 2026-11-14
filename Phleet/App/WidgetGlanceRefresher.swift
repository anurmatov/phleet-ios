import WidgetKit

/// The real nudge: asks the system to read the fleet again for every widget of this app.
struct WidgetGlanceRefresher: GlanceRefresher {
    func refresh() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
