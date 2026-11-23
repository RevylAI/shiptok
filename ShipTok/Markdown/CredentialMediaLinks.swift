import Foundation
import UniformTypeIdentifiers

// Text the app shows or copies from a post never carries a link that opens a file for whoever holds it: a Revyl-hosted video's tokened link or a media URL signed in its query string (AGENTS.md, "Signed Media URLs").
enum CredentialMediaLinks {
    // Text shown or copied never carries a credential media link (AGENTS.md, "iOS App"): a linked label stays, and an image or bare link goes, keeping the prose punctuation after it. Only media targets count, so an ordinary link with a query string stays, while an image's reference definition counts whatever its URL looks like, since an upload's signed URL often has no file extension. A hosted video's token then goes from whatever text is left, however the links around it read (AGENTS.md, "Signed Media URLs").
    static func markdownWithoutCredentialMediaLinks(_ markdown: String) -> String {
        let imageReferencePattern = #/!\[([^\]]*)\](?:\[([^\]]*)\]|(?!\())/#
        func normalizedReferenceLabel(_ label: Substring) -> String {
            label.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        }
        func referenceLabel(of imageReference: Regex<(Substring, Substring, Substring?)>.Match) -> String {
            normalizedReferenceLabel(imageReference.2.flatMap { $0.isEmpty ? nil : $0 } ?? imageReference.1)
        }
        let imageReferenceLabels = Set(markdown.matches(of: imageReferencePattern).map { referenceLabel(of: $0) })
        var credentialImageReferenceLabels: Set<String> = []
        let markdownWithoutCredentialImageReferences = markdown
            .replacing(#/^\h{0,3}\[([^\]]+)\]:\h*<?([^\s<>]+)>?(?:\h+(?:"[^"]*"|'[^']*'|\([^)]*\)))?\h*(?:\R|$)/#.anchorsMatchLineEndings()) { definition in
                let label = normalizedReferenceLabel(definition.1)
                guard imageReferenceLabels.contains(label), let definitionURL = URL(string: String(definition.2)),
                      isCredentialMediaURL(definitionURL)
                else { return String(definition.0) }
                credentialImageReferenceLabels.insert(label)
                return ""
            }
            .replacing(imageReferencePattern) { imageReference in
                credentialImageReferenceLabels.contains(referenceLabel(of: imageReference)) ? "" : String(imageReference.0)
            }
        return markdownWithoutCredentialImageReferences
            .replacing(#/(!?)\[((?:!\[[^\]]*\]\([^)]*\)|[^\[\]])*)\]\(\s*<?([^\s<>()]+)>?(?:\s+"[^"]*")?\s*\)/#) { linkMatch in
                let isImageEmbed = !linkMatch.1.isEmpty
                guard let linkURL = URL(string: String(linkMatch.3)), isImageEmbed || isMediaLinkTarget(linkURL),
                      isCredentialMediaURL(linkURL)
                else { return String(linkMatch.0) }
                return isImageEmbed ? "" : String(linkMatch.2)
            }
            .replacing(#/<?(https?:\/\/[^\s<>()"'`]*[^\s<>()"'`.,;:!?])([.,;:!?]*)>?/#.ignoresCase()) { urlMatch in
                guard let url = URL(string: String(urlMatch.1)), isMediaLinkTarget(url), isCredentialMediaURL(url) else {
                    return String(urlMatch.0)
                }
                return String(urlMatch.2)
            }
            .replacing(#/([^\s<>()\[\]"'`]*[^\s<>()\[\]"'`.,;:!?])([.,;:!?]*)/#) { textRun in
                holdsHostedShipTokVideoToken(textRun.1) ? String(textRun.2) : String(textRun.0)
            }
    }

    // Wherever the hosted video route reads, relative or absolute, escaped or cased, and a token-shaped segment follows, a backend could take it for a hosted video's token. Escapes decode as the backend's would, leaving a malformed one as it is.
    private static func holdsHostedShipTokVideoToken(_ textRun: Substring) -> Bool {
        let decodedTextRun = textRun.replacing(#/%([0-9A-Fa-f]{2})/#) { escape in
            UInt8(escape.1, radix: 16).map { String(UnicodeScalar($0)) } ?? String(escape.0)
        }
        let pathSegments = decodedTextRun.lowercased().split(separator: "/")
        let hostedVideoRoute: [Substring] = ["api", "v1", "shiptok", "videos"]
        return pathSegments.indices.contains { routeStartIndex in
            let tokenIndex = routeStartIndex + hostedVideoRoute.count
            return tokenIndex < pathSegments.endIndex
                && pathSegments[routeStartIndex..<tokenIndex].elementsEqual(hostedVideoRoute)
                && pathSegments[tokenIndex].first.map { "abcdefghijklmnopqrstuvwxyz0123456789_-".contains($0) } == true
        }
    }

    // GitHub serves uploads from these endpoints, often without a file extension; any other link, the rest of GitHub's hosts included, is media only as a video or image file.
    private static func isMediaLinkTarget(_ url: URL) -> Bool {
        if pathContainsHostedShipTokVideoRoute(url) { return true }
        let host = url.host()?.lowercased()
        if host == "user-images.githubusercontent.com" || host == "private-user-images.githubusercontent.com"
            || (host == "github.com" && url.path.hasPrefix("/user-attachments/")) {
            return true
        }
        guard !url.pathExtension.isEmpty, let fileType = UTType(filenameExtension: url.pathExtension) else { return false }
        return fileType.conforms(to: .image) || fileType.conforms(to: .movie)
    }

    // A hosted video's tokened link and a media URL signed in its query string each open the file for whoever holds them, whatever the host.
    private static func isCredentialMediaURL(_ url: URL) -> Bool {
        pathContainsHostedShipTokVideoRoute(url) || url.query != nil
    }

    // Any link whose path holds the hosted video route, however it's escaped or cased, is taken for a hosted video's tokened link.
    private static func pathContainsHostedShipTokVideoRoute(_ url: URL) -> Bool {
        let lowercasedPathSegments = url.path(percentEncoded: false).lowercased().split(separator: "/")
        return ("/" + lowercasedPathSegments.joined(separator: "/") + "/").contains("/api/v1/shiptok/videos/")
    }
}
