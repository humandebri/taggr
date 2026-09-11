// TAGGR/Views: PWA-compatible block rendering for post bodies.
import Foundation
import SwiftUI

@MainActor
struct TaggrPostBodyView: View {
    let text: String
    let maximumLines: Int?
    let textStyle: UIFont.TextStyle
    let textColor: UIColor
    let lineSpacing: CGFloat
    let accessibilityIdentifier: String?
    let openPost: (() -> Void)?
    let onTruncationChange: (Bool) -> Void

    init(
        text: String,
        maximumLines: Int? = nil,
        textStyle: UIFont.TextStyle = .body,
        textColor: Color = TaggrTheme.text,
        lineSpacing: CGFloat = 3,
        accessibilityIdentifier: String? = nil,
        openPost: (() -> Void)? = nil,
        onTruncationChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.text = text
        self.maximumLines = maximumLines
        self.textStyle = textStyle
        self.textColor = UIColor(textColor)
        self.lineSpacing = lineSpacing
        self.accessibilityIdentifier = accessibilityIdentifier
        self.openPost = openPost
        self.onTruncationChange = onTruncationChange
    }

    var body: some View {
        let blocks = TaggrPostBodyParser.blocks(in: text)
        if blocks.contains(where: { if case .youtube = $0 { true } else { false } }) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .markdown(let markdown):
                        interactiveText(markdown, maximumLines: nil)
                    case .youtube(let preview):
                        YouTubePreviewView(preview: preview)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { onTruncationChange(false) }
        } else {
            interactiveText(text, maximumLines: maximumLines)
        }
    }

    private func interactiveText(_ content: String, maximumLines: Int?) -> some View {
        TaggrInteractiveMarkdownText(
            text: content,
            maximumLines: maximumLines,
            textStyle: textStyle,
            textColor: textColor,
            lineSpacing: lineSpacing,
            accessibilityIdentifier: accessibilityIdentifier,
            openPost: openPost,
            onTruncationChange: onTruncationChange
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func containsInteractiveLink(in text: String) -> Bool {
        TaggrPostBodyParser.blocks(in: text).contains { block in
            switch block {
            case .markdown(let markdown):
                return TaggrMarkdownText.containsInteractiveLink(in: markdown)
            case .youtube:
                return true
            }
        }
    }
}

enum TaggrPostContentBlock {
    case markdown(String)
    case youtube(TaggrYouTubePreview)
}

@MainActor
enum TaggrPostBodyParser {
    private static let youtubeExpression = try! NSRegularExpression(
        pattern: #"https?://(?:www\.)?(?:youtube\.com/watch\?[^ \n\)]*v=|youtu\.be/)([A-Za-z0-9_-]{6,})(?:[?&][^ \n\)]*)?"#
    )

    static func blocks(in rawText: String) -> [TaggrPostContentBlock] {
        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var seenYouTubeIDs = Set<String>()
        return paragraphs(in: normalized).flatMap { paragraph in
            blocks(in: paragraph, seenYouTubeIDs: &seenYouTubeIDs)
        }
    }

    private static func paragraphs(in text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var paragraphs: [String] = []
        var current: [String] = []
        var fencedCodeMarker: (character: Character, length: Int)?

        for lineSubstring in lines {
            let line = String(lineSubstring)
            if let openingMarker = fencedCodeMarker {
                current.append(line)
                if isClosingFence(line, for: openingMarker) {
                    fencedCodeMarker = nil
                }
                continue
            }

            if let marker = openingFenceMarker(in: line) {
                fencedCodeMarker = marker
                current.append(line)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                appendCurrent(to: &paragraphs, current: &current)
            } else {
                current.append(line)
            }
        }
        appendCurrent(to: &paragraphs, current: &current)
        return paragraphs
    }

    private static func blocks(
        in paragraph: String,
        seenYouTubeIDs: inout Set<String>
    ) -> [TaggrPostContentBlock] {
        let protectedRanges = TaggrMarkdownText.markdownProtectedRanges(in: paragraph)
        let matches = youtubeExpression.matches(
            in: paragraph,
            range: NSRange(paragraph.startIndex..<paragraph.endIndex, in: paragraph)
        )
        var blocks: [TaggrPostContentBlock] = []
        var cursor = paragraph.startIndex

        for match in matches {
            guard let range = Range(match.range, in: paragraph),
                  !protectedRanges.contains(where: { $0.overlaps(range) }),
                  let idRange = Range(match.range(at: 1), in: paragraph),
                  let url = URL(string: String(paragraph[range])) else {
                continue
            }
            let id = String(paragraph[idRange])
            let prefix = String(paragraph[cursor..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                blocks.append(.markdown(prefix))
            }
            if seenYouTubeIDs.insert(id).inserted {
                blocks.append(.youtube(TaggrYouTubePreview(id: id, url: url)))
            }
            cursor = range.upperBound
        }

        let suffix = String(paragraph[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !suffix.isEmpty {
            blocks.append(.markdown(suffix))
        }
        return blocks.isEmpty ? [.markdown(paragraph)] : blocks
    }

    private static func appendCurrent(to paragraphs: inout [String], current: inout [String]) {
        guard !current.isEmpty else { return }
        paragraphs.append(current.joined(separator: "\n"))
        current.removeAll(keepingCapacity: true)
    }

    private static func openingFenceMarker(in line: String) -> (character: Character, length: Int)? {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return nil }
        let trimmed = line.dropFirst(indentation)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let length = trimmed.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        return (marker, length)
    }

    private static func isClosingFence(
        _ line: String,
        for opening: (character: Character, length: Int)
    ) -> Bool {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return false }
        let trimmed = line.dropFirst(indentation)
        let length = trimmed.prefix(while: { $0 == opening.character }).count
        guard length >= opening.length else { return false }
        return trimmed.dropFirst(length).allSatisfy(\.isWhitespace)
    }
}
