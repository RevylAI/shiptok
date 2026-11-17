import SwiftUI

enum MarkdownSummaryBlock: Hashable {
    case heading(String)
    case paragraph(String)
    case bulletItem(String)
    case numberedItem(ordinal: String, text: String)
    case codeBlock(String)
    case tableRow([String])
}

enum MarkdownSummaryParser {
    static func blocks(from markdown: String) -> [MarkdownSummaryBlock] {
        var blocks: [MarkdownSummaryBlock] = []
        var paragraphLines: [String] = []
        var codeBlockLines: [String]?

        func appendPendingParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll()
        }

        let markdownWithoutHTMLComments = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        for rawLine in markdownWithoutHTMLComments.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
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
        if let unfinishedCodeBlockLines = codeBlockLines, !unfinishedCodeBlockLines.isEmpty {
            blocks.append(.codeBlock(unfinishedCodeBlockLines.joined(separator: "\n")))
        }
        return blocks
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
    var maximumBlockCount: Int?
    var includesHeadings = true
    var includesTables = true

    private var visibleBlocks: [MarkdownSummaryBlock] {
        let includedBlocks = MarkdownSummaryParser.blocks(from: markdown).filter { block in
            switch block {
            case .heading: includesHeadings
            case .tableRow: includesTables
            case .paragraph, .bulletItem, .numberedItem, .codeBlock: true
            }
        }
        var visibleBlocks = maximumBlockCount.map { Array(includedBlocks.prefix($0)) } ?? includedBlocks
        while case .heading = visibleBlocks.last {
            visibleBlocks.removeLast()
        }
        return visibleBlocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(visibleBlocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownSummaryBlock) -> some View {
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
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        let parsingOptions = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: parsingOptions)) ?? AttributedString(text)
    }
}
