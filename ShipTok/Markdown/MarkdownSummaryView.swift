import SwiftUI

enum MarkdownSummaryBlock {
    case heading(String)
    case paragraph(String)
    case bulletItem(String)
    case numberedItem(ordinal: String, text: String)
    case codeBlock(String)
    case tableRow([String])
    case alert(GitHubAlertType, [MarkdownSummaryBlock])
}

// The five alerts GitHub renders from a blockquote whose first line is "[!NOTE]" and the like (docs/shiptok-format.md, "Pull request descriptions").
enum GitHubAlertType: String {
    case note
    case tip
    case important
    case warning
    case caution

    var title: String {
        switch self {
        case .note: "Note"
        case .tip: "Tip"
        case .important: "Important"
        case .warning: "Warning"
        case .caution: "Caution"
        }
    }

    var systemImageName: String {
        switch self {
        case .note: "info.circle"
        case .tip: "lightbulb"
        case .important: "exclamationmark.bubble"
        case .warning: "exclamationmark.triangle"
        case .caution: "exclamationmark.octagon"
        }
    }

    var tint: Color {
        switch self {
        case .note: RevylBrandColor.textPrimary
        case .tip: RevylBrandColor.success
        case .important: RevylBrandColor.brandText
        case .warning: RevylBrandColor.warning
        case .caution: RevylBrandColor.danger
        }
    }
}

enum MarkdownSummaryParser {
    static func blocks(from markdown: String) -> [MarkdownSummaryBlock] {
        var blocks: [MarkdownSummaryBlock] = []
        var paragraphLines: [String] = []
        var codeBlockLines: [String]?
        var pendingAlert: (type: GitHubAlertType, lines: [String])?
        var previousLine = ""

        func appendPendingParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll()
        }

        func appendPendingAlert() {
            guard let finishedAlert = pendingAlert else { return }
            blocks.append(.alert(finishedAlert.type, Self.blocks(from: finishedAlert.lines.joined(separator: "\n"))))
            pendingAlert = nil
        }

        let shownMarkdown = CredentialMediaLinks.markdownWithoutCredentialMediaLinks(markdown)
            .replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in shownMarkdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            defer { previousLine = line }
            if pendingAlert != nil {
                if line.hasPrefix(">") {
                    pendingAlert?.lines.append(quotedText(in: line))
                    continue
                }
                appendPendingAlert()
            }
            if line.hasPrefix("```") {
                if let finishedCodeBlockLines = codeBlockLines {
                    if !finishedCodeBlockLines.isEmpty {
                        blocks.append(.codeBlock(finishedCodeBlockLines.joined(separator: "\n")))
                    }
                    codeBlockLines = nil
                } else {
                    appendPendingParagraph()
                    codeBlockLines = []
                }
                continue
            }
            if codeBlockLines != nil {
                codeBlockLines?.append(rawLine)
                continue
            }
            if !previousLine.hasPrefix(">"), let alertType = alertType(in: line) {
                appendPendingParagraph()
                pendingAlert = (alertType, [])
                continue
            }
            let readableLine = readableText(in: line)
            if line.hasPrefix("<") || isHorizontalRule(line) || isTableSeparatorRow(line) || readableLine.isEmpty {
                appendPendingParagraph()
            } else if let heading = heading(in: readableLine) {
                appendPendingParagraph()
                blocks.append(.heading(heading))
            } else if let bulletText = bulletText(in: readableLine) {
                appendPendingParagraph()
                blocks.append(.bulletItem(bulletText))
            } else if let numberedItem = numberedItem(in: readableLine) {
                appendPendingParagraph()
                blocks.append(numberedItem)
            } else if readableLine.hasPrefix("|") {
                appendPendingParagraph()
                blocks.append(.tableRow(readableLine.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
            } else {
                paragraphLines.append(readableLine.hasPrefix(">") ? readableLine.drop(while: { $0 == ">" || $0 == " " }).description : readableLine)
            }
        }
        appendPendingParagraph()
        appendPendingAlert()
        if let unfinishedCodeBlockLines = codeBlockLines, !unfinishedCodeBlockLines.isEmpty {
            blocks.append(.codeBlock(unfinishedCodeBlockLines.joined(separator: "\n")))
        }
        return blocks
    }

    private static func alertType(in line: String) -> GitHubAlertType? {
        guard let alertMatch = line.wholeMatch(of: #/>\s*\[!([A-Za-z]+)\]\s*/#) else { return nil }
        return GitHubAlertType(rawValue: alertMatch.1.lowercased())
    }

    private static func quotedText(in line: String) -> String {
        let textAfterMarker = line.dropFirst()
        return String(textAfterMarker.hasPrefix(" ") ? textAfterMarker.dropFirst() : textAfterMarker)
    }

    private static func readableText(in line: String) -> String {
        line
            .replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        line.count >= 3 && (Set(line) == ["-"] || Set(line) == ["*"] || Set(line) == ["_"])
    }

    private static func isTableSeparatorRow(_ line: String) -> Bool {
        line.hasPrefix("|") && line.allSatisfy { "|-: ".contains($0) }
    }

    private static func heading(in line: String) -> String? {
        let headingMarkers = line.prefix(while: { $0 == "#" })
        if (1...6).contains(headingMarkers.count), line.dropFirst(headingMarkers.count).hasPrefix(" ") {
            return line.dropFirst(headingMarkers.count).trimmingCharacters(in: .whitespaces)
        }
        for boldMarker in ["**", "__"] where line.count > boldMarker.count * 2 && line.hasPrefix(boldMarker) {
            let lineWithoutTrailingColon = line.hasSuffix(":") ? String(line.dropLast()) : line
            let boldText = lineWithoutTrailingColon.dropFirst(boldMarker.count)
            guard boldText.hasSuffix(boldMarker) else { continue }
            let headingText = boldText.dropLast(boldMarker.count)
            if !headingText.isEmpty, !headingText.contains(boldMarker) {
                return headingText.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func bulletText(in line: String) -> String? {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") else { return nil }
        let itemText = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        for taskMarker in ["[ ] ", "[x] ", "[X] "] where itemText.hasPrefix(taskMarker) {
            return (taskMarker == "[ ] " ? "☐ " : "☑ ") + itemText.dropFirst(taskMarker.count)
        }
        return itemText
    }

    private static func numberedItem(in line: String) -> MarkdownSummaryBlock? {
        guard let periodIndex = line.firstIndex(of: ".") else { return nil }
        let ordinal = line[..<periodIndex]
        let remainder = line[line.index(after: periodIndex)...]
        guard !ordinal.isEmpty, ordinal.allSatisfy(\.isNumber), remainder.hasPrefix(" ") else { return nil }
        return .numberedItem(ordinal: String(ordinal), text: remainder.trimmingCharacters(in: .whitespaces))
    }
}

struct MarkdownSummaryView: View {
    let markdown: String

    private var visibleBlocks: [MarkdownSummaryBlock] {
        var visibleBlocks = MarkdownSummaryParser.blocks(from: markdown)
        while case .heading = visibleBlocks.last {
            visibleBlocks.removeLast()
        }
        return visibleBlocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(visibleBlocks.enumerated()), id: \.offset) { _, block in
                MarkdownSummaryBlockView(block: block)
            }
        }
    }
}

private struct MarkdownSummaryBlockView: View {
    let block: MarkdownSummaryBlock

    var body: some View {
        switch block {
        case .heading(let text):
            Text(inlineMarkdown(text))
                .font(.headline)
                .foregroundStyle(RevylBrandColor.textPrimary)
        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .font(.subheadline)
                .foregroundStyle(RevylBrandColor.textBody)
        case .tableRow(let cells):
            Text(inlineMarkdown(cells.joined(separator: "  ·  ")))
                .font(.subheadline)
                .foregroundStyle(RevylBrandColor.textBody)
        case .bulletItem(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(RevylBrandColor.brandText)
                Text(inlineMarkdown(text)).foregroundStyle(RevylBrandColor.textBody)
            }
            .font(.subheadline)
        case .numberedItem(let ordinal, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "\(ordinal).").foregroundStyle(RevylBrandColor.brandText)
                Text(inlineMarkdown(text)).foregroundStyle(RevylBrandColor.textBody)
            }
            .font(.subheadline)
        case .codeBlock(let code):
            Text(verbatim: code)
                .font(.caption.monospaced())
                .foregroundStyle(RevylBrandColor.textBody)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(RevylBrandColor.surfaceRaised))
        case .alert(let alertType, let alertBlocks):
            VStack(alignment: .leading, spacing: 6) {
                Label(alertType.title, systemImage: alertType.systemImageName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(alertType.tint)
                ForEach(Array(alertBlocks.enumerated()), id: \.offset) { _, alertBlock in
                    MarkdownSummaryBlockView(block: alertBlock)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(RevylBrandColor.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(alertType.tint.opacity(0.6), lineWidth: 1))
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        let parsingOptions = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: parsingOptions)) ?? AttributedString(text)
    }
}
