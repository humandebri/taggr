// TAGGR/Views: Native Markdown text rendering for user-authored content and compact previews.
import Foundation
import SwiftUI

@MainActor
struct TaggrMarkdownText: View {
    let text: String
    private final class PresentationBox: NSObject {
        let attributed: AttributedString
        let hasInteractiveLink: Bool

        init(attributed: AttributedString, hasInteractiveLink: Bool) {
            self.attributed = attributed
            self.hasInteractiveLink = hasInteractiveLink
        }
    }

    private static let presentationCache: NSCache<NSString, PresentationBox> = {
        let cache = NSCache<NSString, PresentationBox>()
        cache.countLimit = 500
        return cache
    }()
    private static let markdownProtectedExpression: NSRegularExpression = {
        do {
            return try NSRegularExpression(
                pattern: #"(!?\[[^\]]*\]\([^)]+\)|```[\s\S]*?```|`[^`]*`)"#
            )
        } catch {
            preconditionFailure("Invalid built-in Markdown protection expression: \(error)")
        }
    }()

    var body: some View {
        Text(Self.presentation(for: text).attributed)
    }

    static func attributedMarkdown(from text: String) -> AttributedString {
        presentation(for: text).attributed
    }

    private static func uncachedAttributedMarkdown(from text: String) -> AttributedString {
        // Foundation's Markdown parser covers inline emphasis, code, links, and
        // block intents without adding a parser dependency to the native app.
        guard var attributed = try? AttributedString(markdown: text) else {
            return AttributedString(text)
        }
        sanitizeLinks(in: &attributed)
        return attributed
    }

    private static func sanitizeLinks(in attributed: inout AttributedString) {
        for run in attributed.runs {
            guard let url = run.link,
                  !isSafeLink(url) else {
                continue
            }
            attributed[run.range].link = nil
        }
    }

    private static func isSafeLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme)
    }

    static func linkTagsAndUsers(_ text: String) -> String {
        let protected = markdownProtectedRanges(in: text)
        var result = ""
        var cursor = text.startIndex
        for range in protected {
            result += linkTokens(in: String(text[cursor..<range.lowerBound]))
            result += String(text[range])
            cursor = range.upperBound
        }
        result += linkTokens(in: String(text[cursor...]))
        return result
    }

    static func containsInteractiveLink(in text: String) -> Bool {
        presentation(for: text).hasInteractiveLink
    }

    private static func presentation(for text: String) -> PresentationBox {
        let key = text as NSString
        if let cached = presentationCache.object(forKey: key) {
            return cached
        }
        let linkedText = linkTagsAndUsers(text)
        let hasMarkdownLink = markdownProtectedRanges(in: text).contains(where: { range in
            let protected = String(text[range])
            return protected.hasPrefix("[") || protected.hasPrefix("![")
        })
        let presentation = PresentationBox(
            attributed: uncachedAttributedMarkdown(from: linkedText),
            hasInteractiveLink: hasMarkdownLink || linkedText != text
        )
        presentationCache.setObject(presentation, forKey: key)
        return presentation
    }

    private static func markdownProtectedRanges(in text: String) -> [Range<String.Index>] {
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return markdownProtectedExpression
            .matches(in: text, range: nsRange)
            .compactMap { Range($0.range, in: text) }
    }

    private static func linkTokens(in text: String) -> String {
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if isTokenStart(character),
               isBoundary(before: index, in: text),
               let tokenRange = tokenRange(startingAt: index, in: text) {
                let token = String(text[tokenRange])
                output += markdownLink(for: token)
                index = tokenRange.upperBound
            } else {
                output.append(character)
                index = text.index(after: index)
            }
        }
        return output
    }

    private static func markdownLink(for token: String) -> String {
        let value = String(token.dropFirst())
        let escaped = token.replacingOccurrences(of: "]", with: "\\]")
        switch token.first {
        case "@":
            return "[\(escaped)](https://\(TaggrNavigation.canonicalHost)/user/\(value))"
        case "/":
            return "[\(escaped)](https://\(TaggrNavigation.canonicalHost)/realm/\(value))"
        case "#", "$":
            return "[\(escaped)](https://\(TaggrNavigation.canonicalHost)/#/feed/\(value))"
        default:
            return token
        }
    }

    private static func isTokenStart(_ character: Character) -> Bool {
        ["@", "#", "$", "/"].contains(character)
    }

    private static func isBoundary(before index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return true }
        let previous = text[text.index(before: index)]
        return previous.isWhitespace || previous == "("
    }

    private static func tokenRange(startingAt start: String.Index, in text: String) -> Range<String.Index>? {
        let marker = text[start]
        var end = text.index(after: start)
        guard end < text.endIndex, isTokenBody(text[end]) else { return nil }
        if marker == "$", !text[end].isLetter { return nil }
        var validEnd: String.Index?
        while end < text.endIndex, isTokenBody(text[end]) {
            if isTokenTail(text[end]) {
                validEnd = text.index(after: end)
            }
            end = text.index(after: end)
        }
        guard let validEnd else { return nil }
        return start..<validEnd
    }

    private static func isTokenBody(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_"
    }

    private static func isTokenTail(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
