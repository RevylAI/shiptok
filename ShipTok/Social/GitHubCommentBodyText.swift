import Foundation

enum GitHubCommentBodyText {
    static func visibleMarkdown(fromBodyMarkdown bodyMarkdown: String) -> String {
        let markupFreeMarkdown = bodyMarkdown
            .replacing(#/<!--[\s\S]*?-->/#, with: "")
            .replacing(#/<br\s*\/?>/#.ignoresCase(), with: "\n")
            .replacing(#/!\[[^\]]*\]\([^)]*\)/#, with: "")
            .replacing(#/<\/?(a|abbr|b|blockquote|code|dd|del|details|div|dl|dt|em|h[1-6]|hr|i|img|ins|kbd|li|ol|p|picture|pre|s|samp|small|source|span|strong|sub|summary|sup|table|tbody|td|tfoot|th|thead|tr|tt|u|ul|var|video)\b[^>]*>/#.ignoresCase(), with: "")
        return markupFreeMarkdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap(visibleLine(fromMarkdownLine:))
            .joined(separator: "\n")
            .replacing(#/\n\s*\n/#, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func attributedText(fromVisibleMarkdown visibleMarkdown: String) -> AttributedString {
        let parsingOptions = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: visibleMarkdown, options: parsingOptions)) ?? AttributedString(visibleMarkdown)
    }

    private static func visibleLine(fromMarkdownLine markdownLine: Substring) -> String? {
        if markdownLine.wholeMatch(of: #/\s*<?https:\/\/(github\.com\/user-attachments\/assets|private-user-images\.githubusercontent\.com|user-images\.githubusercontent\.com)\/\S*\s*/#) != nil
            || markdownLine.wholeMatch(of: #/\s*(```|~~~).*/#) != nil
            || markdownLine.wholeMatch(of: #/\s*([-*_])(\s*\1){2,}\s*/#) != nil {
            return nil
        }
        if let headingMatch = markdownLine.wholeMatch(of: #/\s*\#{1,6}\s+(.+?)[\s\#]*/#) {
            return "**\(headingMatch.1)**"
        }
        if let taskListItemMatch = markdownLine.wholeMatch(of: #/(\s*)[-*+]\s+\[([ xX])\]\s+(.*)/#) {
            return "\(taskListItemMatch.1)\(taskListItemMatch.2 == " " ? "☐" : "☑") \(taskListItemMatch.3)"
        }
        if let bulletMatch = markdownLine.wholeMatch(of: #/(\s*)[-*+]\s+(.*)/#) {
            return "\(bulletMatch.1)• \(bulletMatch.2)"
        }
        if let quoteMatch = markdownLine.wholeMatch(of: #/\s*>\s?(.*)/#) {
            return "▍ \(quoteMatch.1)"
        }
        return String(markdownLine)
    }
}
