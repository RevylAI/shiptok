import Foundation

// Reads a weekly edition's description, in the "Weekly editions" format of docs/shiptok-format.md.
enum WeeklyEditionFormat {
    static let labelName = "shiptok-weekly"
    static let weekTimeZone = TimeZone(identifier: "America/Los_Angeles")!

    struct Description: Equatable {
        let weekStartDate: Date
        let title: String
        let hook: String
        let pullRequestNumbers: [Int]
    }

    private static let markerPrefix = "<!-- shiptok:weekly week_start="
    private static let markerSuffix = " -->"
    private static let titlePrefix = "## "
    private static let pullRequestCountRange = 1...30
    private static let mondayWeekday = 2

    static var weekCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = weekTimeZone
        return calendar
    }

    static func description(fromMarkdown markdown: String) -> Description? {
        let lines = markdown
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let markerLine = lines.first(where: { !$0.isEmpty }),
              let weekStartDate = weekStartDate(inMarkerLine: markerLine),
              let titleLineIndex = lines.firstIndex(where: { $0.hasPrefix(titlePrefix) })
        else { return nil }
        let title = lines[titleLineIndex].dropFirst(titlePrefix.count).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty,
              let hook = lines[(titleLineIndex + 1)...].first(where: { !$0.isEmpty }),
              !hook.hasPrefix("#")
        else { return nil }
        let pullRequestNumbers = lines.compactMap(pullRequestNumber(inListItem:))
        guard pullRequestCountRange.contains(pullRequestNumbers.count) else { return nil }
        return Description(weekStartDate: weekStartDate, title: title, hook: hook, pullRequestNumbers: pullRequestNumbers)
    }

    private static func weekStartDate(inMarkerLine line: String) -> Date? {
        guard line.hasPrefix(markerPrefix), line.hasSuffix(markerSuffix) else { return nil }
        let dateParts = line.dropFirst(markerPrefix.count).dropLast(markerSuffix.count).split(separator: "-")
        guard dateParts.count == 3, let year = Int(dateParts[0]), let month = Int(dateParts[1]), let day = Int(dateParts[2]) else { return nil }
        let calendar = weekCalendar
        guard let weekStartDate = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: weekStartDate) == year,
              calendar.component(.month, from: weekStartDate) == month,
              calendar.component(.day, from: weekStartDate) == day,
              calendar.component(.weekday, from: weekStartDate) == mondayWeekday
        else { return nil }
        return weekStartDate
    }

    private static func pullRequestNumber(inListItem line: String) -> Int? {
        guard let periodIndex = line.firstIndex(of: "."), Int(line[..<periodIndex]) != nil else { return nil }
        let reference = line[line.index(after: periodIndex)...].trimmingCharacters(in: .whitespaces)
        guard reference.hasPrefix("#"), let number = Int(reference.dropFirst()), number > 0 else { return nil }
        return number
    }
}

extension WeeklyEdition {
    // "Nov 9–15", or "Oct 26–Nov 1" when the week spans two months.
    var weekDatesText: String {
        let calendar = WeeklyEditionFormat.weekCalendar
        let weekEndDate = calendar.date(byAdding: .day, value: 6, to: weekStartDate) ?? weekStartDate
        let monthAndDay = Date.FormatStyle(timeZone: WeeklyEditionFormat.weekTimeZone).month(.abbreviated).day()
        let weekEndText = calendar.component(.month, from: weekEndDate) == calendar.component(.month, from: weekStartDate)
            ? String(calendar.component(.day, from: weekEndDate))
            : weekEndDate.formatted(monthAndDay)
        return "\(weekStartDate.formatted(monthAndDay))–\(weekEndText)"
    }
}
