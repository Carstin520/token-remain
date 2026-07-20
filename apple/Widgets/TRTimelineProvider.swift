import TokenRemainKit
import WidgetKit

/// Widget extensions are strictly read-only over the App Group. All derivation
/// happens in `TREntry` (unit-tested in the kit), so this provider stays trivial.
struct TRTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> TREntry {
        TREntry.placeholder(now: SnapshotComposer.previewNow)
    }

    func getSnapshot(in context: Context, completion: @escaping (TREntry) -> Void) {
        let now = Date()
        // The widget gallery preview shows the concept fixture rather than an empty
        // card, but the real timeline never invents data.
        completion(context.isPreview
            ? TREntry.placeholder(now: now)
            : TREntry(snapshot: SnapshotStore.shared.readOrEmpty(now: now), now: now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TREntry>) -> Void) {
        let now = Date()
        let entry = TREntry(snapshot: SnapshotStore.shared.readOrEmpty(now: now), now: now)
        // One entry is enough: countdowns render through Text(timerInterval:) /
        // Text(_, style: .timer), so the timeline stays sparse.
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(15 * 60))))
    }
}
