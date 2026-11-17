import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

// Parses the ShipTok format (docs/shiptok-format.md): which media a pull request carries, its ShipTok tags, and which one shows first.
enum PullRequestMediaExtraction {
    static func mediaItems(
        descriptionMarkdown: String,
        descriptionHTML: String,
        descriptionLastEditedAt: Date,
        descriptionAuthor: GitHubActor?,
        comments: [(comment: PullRequestComment, bodyHTML: String)]
    ) -> [PullRequestMediaItem] {
        var deckOrderedMediaItems: [PullRequestMediaItem] = []
        var deckIndexByMediaItemID: [String: Int] = [:]

        func appendMediaItems(_ references: [MediaReference], sourceCommentID: String?, sourceCommentDatabaseID: Int? = nil, postedBy: GitHubActor?, sourceLastEditedAt: Date, isTagged: Bool) {
            for reference in references {
                let mediaItem = PullRequestMediaItem(
                    id: reference.mediaItemID,
                    kind: reference.kind,
                    url: reference.displayURL,
                    isShipTokVideo: reference.kind == .video && isTagged,
                    sourceCommentID: sourceCommentID,
                    sourceCommentDatabaseID: sourceCommentDatabaseID,
                    postedBy: postedBy,
                    sourceLastEditedAt: sourceLastEditedAt
                )
                guard let existingDeckIndex = deckIndexByMediaItemID[mediaItem.id] else {
                    deckIndexByMediaItemID[mediaItem.id] = deckOrderedMediaItems.count
                    deckOrderedMediaItems.append(mediaItem)
                    continue
                }
                let existingMediaItem = deckOrderedMediaItems[existingDeckIndex]
                if mediaItem.isShipTokVideo && (!existingMediaItem.isShipTokVideo || mediaItem.sourceLastEditedAt > existingMediaItem.sourceLastEditedAt) {
                    deckOrderedMediaItems[existingDeckIndex] = mediaItem
                }
            }
        }

        appendMediaItems(
            mediaReferences(inMarkdown: descriptionMarkdown, inHTML: descriptionHTML),
            sourceCommentID: nil,
            postedBy: descriptionAuthor,
            sourceLastEditedAt: descriptionLastEditedAt,
            isTagged: containsShipTokVideoTag(descriptionMarkdown)
        )
        for (comment, commentBodyHTML) in comments {
            appendMediaItems(
                mediaReferences(inMarkdown: comment.bodyMarkdown, inHTML: commentBodyHTML),
                sourceCommentID: comment.id,
                sourceCommentDatabaseID: comment.databaseID,
                postedBy: comment.author,
                sourceLastEditedAt: comment.lastEditedAt ?? comment.createdAt,
                isTagged: containsShipTokVideoTag(comment.bodyMarkdown)
            )
        }

        return mediaItemsWithHeroFirst(deckOrderedMediaItems)
    }

    // The newest tagged ShipTok video leads, else the first video, else the first item, and the rest keep deck order. Hiding people applies it again to what's left.
    static func mediaItemsWithHeroFirst(_ deckOrderedMediaItems: [PullRequestMediaItem]) -> [PullRequestMediaItem] {
        var newestTaggedVideo: PullRequestMediaItem?
        for mediaItem in deckOrderedMediaItems where mediaItem.isShipTokVideo {
            if let newestTaggedVideo, mediaItem.sourceLastEditedAt <= newestTaggedVideo.sourceLastEditedAt { continue }
            newestTaggedVideo = mediaItem
        }
        guard let heroMediaItem = newestTaggedVideo
            ?? deckOrderedMediaItems.first(where: { $0.kind == .video })
            ?? deckOrderedMediaItems.first
        else { return [] }
        return [heroMediaItem] + deckOrderedMediaItems.filter { $0.id != heroMediaItem.id }
    }

    // Text shown or copied never carries a credential media link (AGENTS.md, "iOS App"): a linked label stays, and an image or bare link goes.
    static func markdownWithoutCredentialMediaLinks(_ markdown: String) -> String {
        markdown
            .replacing(#/(!?)\[((?:!\[[^\]]*\]\([^)]*\)|[^\[\]])*)\]\(\s*<?(https?:\/\/[^\s<>()]+)>?(?:\s+"[^"]*")?\s*\)/#) { linkMatch in
                guard let linkURL = URL(string: String(linkMatch.3)), PullRequestMediaItem.isCredentialMediaURL(linkURL) else {
                    return String(linkMatch.0)
                }
                return linkMatch.1.isEmpty ? String(linkMatch.2) : ""
            }
            .replacing(#/<?(https?:\/\/[^\s<>()"'`]+)>?/#) { urlMatch in
                guard let url = URL(string: String(urlMatch.1)), PullRequestMediaItem.isCredentialMediaURL(url) else {
                    return String(urlMatch.0)
                }
                return ""
            }
    }

    static func containsShipTokVideoTag(_ markdown: String) -> Bool {
        containsShipTokHashtag(markdown)
            || markdown.range(of: #"<!--\s*shiptok:video(?:\s[^>]*?)?\s*-->"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private struct MediaReference {
        let mediaItemID: String
        let kind: PullRequestMediaItem.Kind
        let displayURL: URL
    }

    private static let videoFileExtensions: Set<String> = ["mp4", "mov", "webm", "m4v"]
    private static let playableVideoTypeIdentifiers = Set(AVURLAsset.audiovisualTypes().map(\.rawValue))
    private static let nonMediaImageHostSuffixes = [
        "shields.io", "badgen.net", "blacksmith.sh", "codecov.io", "github.githubassets.com",
        "avatars.githubusercontent.com", "vercel.com", "coderabbit.ai", "graphite.dev", "cursor.com", "dummyimage.com",
    ]
    private static let maximumIconSidePixels = 40

    private static func mediaReferences(inMarkdown markdown: String, inHTML bodyHTML: String) -> [MediaReference] {
        var references = mediaReferences(inHTML: bodyHTML)
        let urlPattern = #"https://[^\s<>()\"'`]+"#
        guard let expression = try? NSRegularExpression(pattern: urlPattern) else { return references }
        for match in expression.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)) {
            guard let range = Range(match.range, in: markdown),
                  let videoURL = URL(string: String(markdown[range])),
                  PullRequestMediaItem.isHostedShipTokVideoURL(videoURL),
                  hasVideoFileExtension(videoURL),
                  let reference = mediaReference(kind: .video, candidateURLTexts: [videoURL.absoluteString])
            else { continue }
            if let existingReferenceIndex = references.firstIndex(where: { $0.mediaItemID == reference.mediaItemID }) {
                references[existingReferenceIndex] = reference
            } else {
                references.append(reference)
            }
        }
        return references
    }

    private static func mediaReferences(inHTML bodyHTML: String) -> [MediaReference] {
        var references: [MediaReference] = []
        var openVideoHasSource: Bool?
        var isInsideVideoLink = false
        for tag in HTMLTagScanner.tags(in: bodyHTML) {
            switch (tag.name, tag.isEndTag) {
            case ("img", false):
                if isInsideVideoLink { continue }
                if let imageReference = imageReference(from: tag.attributes) {
                    references.append(imageReference)
                }
            case ("video", false):
                let videoReference = mediaReference(kind: .video, candidateURLTexts: [tag.attributes["src"], tag.attributes["data-canonical-src"]])
                if let videoReference {
                    references.append(videoReference)
                }
                openVideoHasSource = videoReference != nil
            case ("video", true):
                openVideoHasSource = nil
            case ("source", false) where openVideoHasSource == false:
                if let sourceReference = mediaReference(kind: .video, candidateURLTexts: [tag.attributes["src"]]) {
                    references.append(sourceReference)
                    openVideoHasSource = true
                }
            case ("a", false):
                isInsideVideoLink = false
                if let linkTarget = tag.attributes["href"].flatMap(URL.init(string:)), hasVideoFileExtension(linkTarget),
                   let linkedVideoReference = mediaReference(kind: .video, candidateURLTexts: [linkTarget.absoluteString]) {
                    references.append(linkedVideoReference)
                    isInsideVideoLink = true
                }
            case ("a", true):
                isInsideVideoLink = false
            default:
                break
            }
        }
        return references
    }

    private static func imageReference(from attributes: [String: String]) -> MediaReference? {
        if attributes["class", default: ""].split(separator: " ").contains("emoji") { return nil }
        for sideAttributeName in ["width", "height"] {
            let sideText = attributes[sideAttributeName, default: ""]
            if let sidePixels = Int(sideText.hasSuffix("px") ? String(sideText.dropLast(2)) : sideText), sidePixels <= maximumIconSidePixels {
                return nil
            }
        }
        let candidateURLTexts = [attributes["src"], attributes["data-canonical-src"]]
        let candidateURLs = candidateURLTexts.compactMap { $0.flatMap(URL.init(string:)) }
        if candidateURLs.contains(where: isNeverMediaURL) { return nil }
        let kind: PullRequestMediaItem.Kind
        if candidateURLs.contains(where: hasVideoFileExtension) {
            kind = .video
        } else if candidateURLs.contains(where: { $0.pathExtension.lowercased() == "gif" }) {
            kind = .animatedImage
        } else {
            kind = .image
        }
        return mediaReference(kind: kind, candidateURLTexts: candidateURLTexts)
    }

    private static func mediaReference(kind: PullRequestMediaItem.Kind, candidateURLTexts: [String?]) -> MediaReference? {
        let httpsURLs = candidateURLTexts.compactMap { $0.flatMap(URL.init(string:)) }.filter { $0.scheme?.lowercased() == "https" }
        if kind == .video, !httpsURLs.allSatisfy(isPlayableOnIOS) { return nil }
        guard let displayURL = httpsURLs.first,
              let identityURL = httpsURLs.last,
              var identityURLComponents = URLComponents(url: identityURL, resolvingAgainstBaseURL: false)
        else { return nil }
        // A media item's id never carries the signed query string, so a refetch swaps in a fresh URL under the same identity.
        identityURLComponents.query = nil
        identityURLComponents.fragment = nil
        guard let canonicalIdentity = identityURLComponents.string else { return nil }
        let mediaItemID = PullRequestMediaItem.isHostedShipTokVideoURL(identityURL)
            ? "shiptok-video:" + SHA256.hash(data: Data(canonicalIdentity.utf8)).map { String(format: "%02x", $0) }.joined()
            : canonicalIdentity
        return MediaReference(mediaItemID: mediaItemID, kind: kind, displayURL: displayURL)
    }

    private static func hasVideoFileExtension(_ url: URL) -> Bool {
        videoFileExtensions.contains(url.pathExtension.lowercased())
    }

    // A video iOS can't play (WebM, for example) would only ever be a broken hero, so it isn't media here.
    private static func isPlayableOnIOS(_ videoURL: URL) -> Bool {
        let fileExtension = videoURL.pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return true }
        guard let fileType = UTType(filenameExtension: fileExtension) else { return false }
        return playableVideoTypeIdentifiers.contains(fileType.identifier)
    }

    private static func isNeverMediaURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        return nonMediaImageHostSuffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
            || path.contains("/badge")
            || path.contains("favicon")
            || path.hasSuffix(".svg")
    }

    private static func containsShipTokHashtag(_ markdown: String) -> Bool {
        var searchRange = markdown.startIndex..<markdown.endIndex
        while let hashtagRange = markdown.range(of: "#shiptok", options: .caseInsensitive, range: searchRange) {
            let precedingCharacter = hashtagRange.lowerBound > markdown.startIndex ? markdown[markdown.index(before: hashtagRange.lowerBound)] : nil
            let followingCharacter = hashtagRange.upperBound < markdown.endIndex ? markdown[hashtagRange.upperBound] : nil
            if !isHashtagWordCharacter(precedingCharacter), !isHashtagWordCharacter(followingCharacter) {
                return true
            }
            searchRange = hashtagRange.upperBound..<markdown.endIndex
        }
        return false
    }

    private static func isHashtagWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_" || character == "#"
    }
}

private struct HTMLTag {
    let name: String
    let isEndTag: Bool
    let attributes: [String: String]
}

private enum HTMLTagScanner {
    static func tags(in html: String) -> [HTMLTag] {
        let bytes = Array(html.utf8)
        var tags: [HTMLTag] = []
        var index = 0
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "<") else {
                index += 1
                continue
            }
            if bytes[index...].starts(with: Array("<!--".utf8)) {
                index = indexAfterComment(in: bytes, from: index + 4)
                continue
            }
            var cursor = index + 1
            let isEndTag = cursor < bytes.count && bytes[cursor] == UInt8(ascii: "/")
            if isEndTag { cursor += 1 }
            let nameStart = cursor
            while cursor < bytes.count, isTagNameByte(bytes[cursor]) { cursor += 1 }
            guard cursor > nameStart, isASCIILetter(bytes[nameStart]) else {
                index += 1
                continue
            }
            let name = String(decoding: bytes[nameStart..<cursor], as: UTF8.self).lowercased()
            var attributes: [String: String] = [:]
            while cursor < bytes.count, bytes[cursor] != UInt8(ascii: ">") {
                if isWhitespace(bytes[cursor]) || bytes[cursor] == UInt8(ascii: "/") {
                    cursor += 1
                    continue
                }
                let attributeNameStart = cursor
                while cursor < bytes.count, !isWhitespace(bytes[cursor]), ![UInt8(ascii: "="), UInt8(ascii: ">"), UInt8(ascii: "/")].contains(bytes[cursor]) {
                    cursor += 1
                }
                guard cursor > attributeNameStart else {
                    cursor += 1
                    continue
                }
                let attributeName = String(decoding: bytes[attributeNameStart..<cursor], as: UTF8.self).lowercased()
                while cursor < bytes.count, isWhitespace(bytes[cursor]) { cursor += 1 }
                var attributeValue = ""
                if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "=") {
                    cursor += 1
                    while cursor < bytes.count, isWhitespace(bytes[cursor]) { cursor += 1 }
                    if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "\"") || bytes[cursor] == UInt8(ascii: "'") {
                        let quote = bytes[cursor]
                        let valueStart = cursor + 1
                        cursor = valueStart
                        while cursor < bytes.count, bytes[cursor] != quote { cursor += 1 }
                        attributeValue = String(decoding: bytes[valueStart..<min(cursor, bytes.count)], as: UTF8.self)
                        cursor += 1
                    } else {
                        let valueStart = cursor
                        while cursor < bytes.count, !isWhitespace(bytes[cursor]), bytes[cursor] != UInt8(ascii: ">") { cursor += 1 }
                        attributeValue = String(decoding: bytes[valueStart..<cursor], as: UTF8.self)
                    }
                }
                if attributes[attributeName] == nil {
                    attributes[attributeName] = decodingCharacterReferences(in: attributeValue)
                }
            }
            tags.append(HTMLTag(name: name, isEndTag: isEndTag, attributes: attributes))
            index = cursor + 1
        }
        return tags
    }

    private static func indexAfterComment(in bytes: [UInt8], from start: Int) -> Int {
        var cursor = start
        while cursor + 2 < bytes.count {
            if bytes[cursor] == UInt8(ascii: "-"), bytes[cursor + 1] == UInt8(ascii: "-"), bytes[cursor + 2] == UInt8(ascii: ">") {
                return cursor + 3
            }
            cursor += 1
        }
        return bytes.count
    }

    private static func decodingCharacterReferences(in text: String) -> String {
        guard text.contains("&") else { return text }
        var decoded = ""
        var remaining = Substring(text)
        while let ampersandIndex = remaining.firstIndex(of: "&") {
            decoded += remaining[..<ampersandIndex]
            let afterAmpersand = remaining[remaining.index(after: ampersandIndex)...]
            guard let semicolonIndex = afterAmpersand.prefix(10).firstIndex(of: ";"),
                  let character = character(forReference: afterAmpersand[..<semicolonIndex])
            else {
                decoded += "&"
                remaining = afterAmpersand
                continue
            }
            decoded.append(character)
            remaining = afterAmpersand[afterAmpersand.index(after: semicolonIndex)...]
        }
        decoded += remaining
        return decoded
    }

    private static func character(forReference reference: Substring) -> Character? {
        switch reference {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default:
            guard reference.hasPrefix("#") else { return nil }
            let digits = reference.dropFirst()
            let scalarValue = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
            return scalarValue.flatMap(Unicode.Scalar.init).map(Character.init)
        }
    }

    private static func isTagNameByte(_ byte: UInt8) -> Bool {
        isASCIILetter(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-")
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r") || byte == 0x0C
    }
}
