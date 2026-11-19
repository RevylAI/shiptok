import Foundation

// What a weekly edition's and a feature's descriptions share: the first non-empty line, which is each format's own marker, a "## " title, the hook on the
// next non-empty line and the numbered list of pull requests (docs/shiptok-format.md).
enum PublishedIssueFormat {
    struct Description: Equatable {
        let markerLine: String
        let title: String
        let hook: String
        let pullRequestNumbers: [Int]
    }

    private static let titlePrefix = "## "
    private static let pullRequestCountRange = 1...30

    static func description(fromMarkdown markdown: String) -> Description? {
        let lines = markdown
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let markerLine = lines.first(where: { !$0.isEmpty }),
              let titleLineIndex = lines.firstIndex(where: { $0.hasPrefix(titlePrefix) })
        else { return nil }
        let title = lines[titleLineIndex].dropFirst(titlePrefix.count).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty,
              let hook = lines[(titleLineIndex + 1)...].first(where: { !$0.isEmpty }),
              !hook.hasPrefix("#")
        else { return nil }
        let pullRequestNumbers = lines.compactMap(pullRequestNumber(inListItem:))
        guard pullRequestCountRange.contains(pullRequestNumbers.count) else { return nil }
        // The title and hook are free text shown on cards and in toasts, so they're redacted here, once (AGENTS.md, "Signed Media URLs").
        return Description(
            markerLine: markerLine,
            title: PullRequestMediaExtraction.markdownWithoutCredentialMediaLinks(title),
            hook: PullRequestMediaExtraction.markdownWithoutCredentialMediaLinks(hook),
            pullRequestNumbers: pullRequestNumbers
        )
    }

    private static func pullRequestNumber(inListItem line: String) -> Int? {
        guard let periodIndex = line.firstIndex(of: "."), Int(line[..<periodIndex]) != nil else { return nil }
        let reference = line[line.index(after: periodIndex)...].trimmingCharacters(in: .whitespaces)
        guard reference.hasPrefix("#"), let number = Int(reference.dropFirst()), number > 0 else { return nil }
        return number
    }
}
