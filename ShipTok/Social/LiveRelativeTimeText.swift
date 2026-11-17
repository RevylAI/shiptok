import SwiftUI

struct LiveRelativeTimeText: View {
    private static let relativeDateTimeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter
    }()

    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Text(Self.relativeDateTimeFormatter.localizedString(for: date, relativeTo: max(timeline.date, date)))
        }
    }
}
