// TAGGR: Persists post drafts and their images locally without involving canister APIs.

import Foundation
import SwiftUI

struct PostDraftContext: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case newPost
        case reply
        case edit
        case repost
    }

    let kind: Kind
    let postID: Int?

    static let newPost = PostDraftContext(kind: .newPost, postID: nil)

    static func reply(_ postID: Int) -> PostDraftContext {
        PostDraftContext(kind: .reply, postID: postID)
    }

    static func edit(_ postID: Int) -> PostDraftContext {
        PostDraftContext(kind: .edit, postID: postID)
    }

    static func repost(_ postID: Int) -> PostDraftContext {
        PostDraftContext(kind: .repost, postID: postID)
    }

    var storageKey: String {
        postID.map { "\(kind.rawValue)-\($0)" } ?? kind.rawValue
    }
}

struct PostDraftNamespace: Codable, Hashable, Sendable {
    let canisterID: String
    let userID: Int
}

struct StoredDraftImage: Codable, Equatable {
    let id: String
    let fileName: String
    let width: Int
    let height: Int
    let byteCount: Int
}

struct StoredPostDraft: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let text: String
    let realm: String
    let images: [StoredDraftImage]
    let submissionNeedsVerification: Bool?
    let updatedAt: Date
}

struct RestoredPostDraft {
    let text: String?
    let realm: String?
    let images: [TaggrDraftImage]
    let submissionNeedsVerification: Bool
    let warning: String?
}

/// A composer-only view of image Markdown. Posts remain Markdown-compatible on
/// the wire, while the editor treats each recognised local blob marker as an
/// immutable image block.
enum PostDraftDocument {
    enum Segment: Identifiable, Equatable {
        case text(id: Int, value: String)
        case image(id: Int, occurrence: Int, markdown: String, blobID: String)

        var id: Int {
            switch self {
            case .text(let id, _), .image(let id, _, _, _): id
            }
        }
    }

    private static let markerExpression = try! NSRegularExpression(
        pattern: #"!\[[^\]]*\]\(/blob/([^)]+)\)"#
    )

    static func segments(in text: String) -> [Segment] {
        let range = NSRange(text.startIndex..., in: text)
        let matches = markerExpression.matches(in: text, range: range)
        guard !matches.isEmpty else { return [.text(id: 0, value: text)] }

        var result: [Segment] = []
        var cursor = text.startIndex
        var id = 0
        for (occurrence, match) in matches.enumerated() {
            guard let markerRange = Range(match.range, in: text),
                  let blobRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            result.append(.text(id: id, value: String(text[cursor..<markerRange.lowerBound])))
            id += 1
            result.append(
                .image(
                    id: id,
                    occurrence: occurrence,
                    markdown: String(text[markerRange]),
                    blobID: String(text[blobRange])
                )
            )
            id += 1
            cursor = markerRange.upperBound
        }
        result.append(.text(id: id, value: String(text[cursor...])))
        return result
    }

    static func replacingText(in text: String, segmentID: Int, with replacement: String) -> String {
        segments(in: text).map { segment in
            switch segment {
            case .text(let id, _) where id == segmentID:
                return replacement
            case .text(_, let value):
                return value
            case .image(_, _, let markdown, _):
                return markdown
            }
        }
        .joined()
    }

    static func inserting(markdowns: [String], in text: String, afterTextSegmentID: Int?) -> String {
        guard !markdowns.isEmpty else { return text }
        let insertion = markdowns.joined(separator: "\n")
        guard let afterTextSegmentID else {
            return text.isEmpty ? insertion : text + "\n\n" + insertion
        }
        var inserted = false
        let result = segments(in: text).map { segment -> String in
            switch segment {
            case .text(let id, let value) where id == afterTextSegmentID:
                inserted = true
                return value + (value.isEmpty ? "" : "\n\n") + insertion + "\n\n"
            case .text(_, let value):
                return value
            case .image(_, _, let markdown, _):
                return markdown
            }
        }
        .joined()
        return inserted ? result : (text.isEmpty ? insertion : text + "\n\n" + insertion)
    }

    static func appendingExternalURL(_ url: URL, to text: String) -> String {
        let value = url.absoluteString
        guard !text.split(whereSeparator: \Character.isWhitespace).contains(Substring(value)) else {
            return text
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? value : trimmed + "\n\n" + value
    }

    static func removing(imageOccurrence: Int, from text: String) -> String {
        var removed = false
        return segments(in: text).map { segment in
            guard case .image(_, let occurrence, _, _) = segment,
                  occurrence == imageOccurrence,
                  !removed else {
                return segment.markdown
            }
            removed = true
            return ""
        }
        .joined()
    }

    static func containsImageMarker(blobID: String, in text: String) -> Bool {
        segments(in: text).contains { segment in
            guard case .image(_, _, _, let id) = segment else { return false }
            return id == blobID
        }
    }

    static func moving(imageOccurrence: Int, before targetOccurrence: Int?, in text: String) -> String {
        let document = segments(in: text)
        guard let sourceIndex = document.firstIndex(where: { segment in
            if case .image(_, let occurrence, _, _) = segment {
                return occurrence == imageOccurrence
            }
            return false
        }) else {
            return text
        }
        let source = document[sourceIndex]
        var remaining = document
        remaining.remove(at: sourceIndex)
        guard let targetOccurrence,
              let targetIndex = remaining.firstIndex(where: { segment in
                  if case .image(_, let occurrence, _, _) = segment {
                      return occurrence == targetOccurrence
                  }
                  return false
              }) else {
            return renderedMarkdown(remaining + [source])
        }
        remaining.insert(source, at: targetIndex)
        return renderedMarkdown(remaining)
    }

    static func moving(imageOccurrence: Int, afterTextSegmentID: Int, in text: String) -> String {
        let document = segments(in: text)
        guard let sourceIndex = document.firstIndex(where: { segment in
            if case .image(_, let occurrence, _, _) = segment {
                return occurrence == imageOccurrence
            }
            return false
        }) else {
            return text
        }
        let source = document[sourceIndex]
        var remaining = document
        remaining.remove(at: sourceIndex)
        guard let textIndex = remaining.firstIndex(where: { segment in
            if case .text(let id, _) = segment {
                return id == afterTextSegmentID
            }
            return false
        }) else {
            return text
        }
        remaining.insert(source, at: textIndex + 1)
        return renderedMarkdown(remaining)
    }

    private static func renderedMarkdown(_ document: [Segment]) -> String {
        var result = ""
        var previousNonemptySegmentWasImage = false

        for segment in document {
            switch segment {
            case .image(_, _, let markdown, _):
                result = result.trimmingTrailingNewlines
                if !result.isEmpty {
                    result += "\n\n"
                }
                result += markdown
                previousNonemptySegmentWasImage = true
            case .text(_, let value):
                guard !value.isEmpty else { continue }
                if previousNonemptySegmentWasImage {
                    let content = String(value.drop(while: \.isNewline))
                    guard !content.isEmpty else { continue }
                    result += "\n\n" + content
                } else {
                    result += value
                }
                previousNonemptySegmentWasImage = false
            }
        }
        return result
    }
}

private extension String {
    var trimmingTrailingNewlines: String {
        String(reversed().drop(while: \.isNewline).reversed())
    }
}

private extension PostDraftDocument.Segment {
    var markdown: String {
        switch self {
        case .text(_, let value): value
        case .image(_, _, let markdown, _): markdown
        }
    }
}

actor PostDraftStore {
    private let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appending(path: "TAGGR", directoryHint: .isDirectory)
        .appending(path: "Drafts", directoryHint: .isDirectory)
    }

    func load(
        namespace: PostDraftNamespace,
        context: PostDraftContext
    ) -> RestoredPostDraft {
        let directory = draftDirectory(namespace: namespace, context: context)
        let metadataURL = directory.appending(path: "draft.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            if fileManager.fileExists(atPath: directory.path) {
                try? fileManager.removeItem(at: directory)
            }
            return RestoredPostDraft(text: nil, realm: nil, images: [], submissionNeedsVerification: false, warning: nil)
        }

        let stored: StoredPostDraft
        do {
            let data = try Data(contentsOf: metadataURL)
            stored = try JSONDecoder().decode(StoredPostDraft.self, from: data)
            guard stored.schemaVersion == StoredPostDraft.currentSchemaVersion else {
                throw CocoaError(.coderReadCorrupt)
            }
        } catch {
            try? fileManager.removeItem(at: directory)
            return RestoredPostDraft(
                text: nil,
                realm: nil,
                images: [],
                submissionNeedsVerification: false,
                warning: "The saved draft could not be restored."
            )
        }

        var images: [TaggrDraftImage] = []
        var missingIDs: [String] = []
        var referencedFiles = Set(["draft.json"])
        for image in stored.images {
            referencedFiles.insert(image.fileName)
            let imageURL = directory.appending(path: image.fileName)
            guard let data = try? Data(contentsOf: imageURL),
                  !data.isEmpty,
                  data.count == image.byteCount else {
                missingIDs.append(image.id)
                continue
            }
            images.append(
                TaggrDraftImage(
                    id: image.id,
                    data: data,
                    width: image.width,
                    height: image.height
                )
            )
        }
        removeOrphanedFiles(in: directory, keeping: referencedFiles)

        return RestoredPostDraft(
            text: removingImageMarkers(missingIDs, from: stored.text),
            realm: stored.realm,
            images: images,
            submissionNeedsVerification: stored.submissionNeedsVerification ?? false,
            warning: missingIDs.isEmpty
                ? nil
                : "Some draft images were unavailable and were removed."
        )
    }

    func save(
        namespace: PostDraftNamespace,
        context: PostDraftContext,
        text: String,
        realm: String,
        images: [TaggrDraftImage],
        submissionNeedsVerification: Bool = false
    ) throws {
        let directory = draftDirectory(namespace: namespace, context: context)
        try createProtectedDirectory(directory)

        var storedImages: [StoredDraftImage] = []
        var referencedFiles = Set(["draft.json"])
        for image in images {
            let fileName = "image-\(safePathComponent(image.id)).bin"
            let imageURL = directory.appending(path: fileName)
            if storedFileSize(at: imageURL) != image.data.count {
                try image.data.write(to: imageURL, options: .atomic)
                applyFileProtection(to: imageURL)
            }
            referencedFiles.insert(fileName)
            storedImages.append(
                StoredDraftImage(
                    id: image.id,
                    fileName: fileName,
                    width: image.width,
                    height: image.height,
                    byteCount: image.data.count
                )
            )
        }

        let stored = StoredPostDraft(
            schemaVersion: StoredPostDraft.currentSchemaVersion,
            text: text,
            realm: realm,
            images: storedImages,
            submissionNeedsVerification: submissionNeedsVerification,
            updatedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadataURL = directory.appending(path: "draft.json")
        try encoder.encode(stored).write(to: metadataURL, options: .atomic)
        applyFileProtection(to: metadataURL)
        removeOrphanedFiles(in: directory, keeping: referencedFiles)
    }

    func delete(namespace: PostDraftNamespace, context: PostDraftContext) {
        try? fileManager.removeItem(
            at: draftDirectory(namespace: namespace, context: context)
        )
    }

    private func draftDirectory(
        namespace: PostDraftNamespace,
        context: PostDraftContext
    ) -> URL {
        rootURL
            .appending(path: safePathComponent(namespace.canisterID), directoryHint: .isDirectory)
            .appending(path: String(namespace.userID), directoryHint: .isDirectory)
            .appending(path: context.storageKey, directoryHint: .isDirectory)
    }

    private func createProtectedDirectory(_ directory: URL) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var excludedURL = rootURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? excludedURL.setResourceValues(resourceValues)
        applyFileProtection(to: directory)
    }

    private func applyFileProtection(to url: URL) {
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private func removeOrphanedFiles(in directory: URL, keeping: Set<String>) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in contents where !keeping.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func storedFileSize(at url: URL) -> Int? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.intValue
    }

    private func safePathComponent(_ value: String) -> String {
        value.map { character in
            character.isLetter || character.isNumber || character == "-"
                ? character
                : "_"
        }
        .reduce(into: "") { $0.append($1) }
    }

    private func removingImageMarkers(_ ids: [String], from text: String) -> String {
        ids.reduce(text) { current, id in
            let escapedID = NSRegularExpression.escapedPattern(for: id)
            let pattern = #"!\[[^\]]*\]\(/blob/\#(escapedID)\)"#
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                return current
            }
            let range = NSRange(current.startIndex..., in: current)
            return expression.stringByReplacingMatches(
                in: current,
                range: range,
                withTemplate: ""
            )
        }
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class PostDraftSession: ObservableObject {
    private static let saveFailureWarning =
        "This draft could not be saved on this device."

    @Published var text: String
    @Published var realm: String
    @Published private(set) var images: [TaggrDraftImage] = []
    @Published private(set) var submissionNeedsVerification = false
    @Published private(set) var restorationWarning: String?
    @Published private(set) var isLoaded = false

    let context: PostDraftContext
    private let initialText: String
    private let initialRealm: String
    private var namespace: PostDraftNamespace?
    private var store: PostDraftStore?
    private var saveTask: Task<Void, Never>?

    init(
        context: PostDraftContext,
        initialText: String,
        initialRealm: String
    ) {
        self.context = context
        self.initialText = initialText
        self.initialRealm = initialRealm
        self.text = initialText
        self.realm = initialRealm
    }

    var hasChanges: Bool {
        text != initialText || realm != initialRealm || !images.isEmpty || submissionNeedsVerification
    }

    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !images.isEmpty ||
            (context.kind == .repost && submissionNeedsVerification)
    }

    func load(
        store: PostDraftStore,
        namespace: PostDraftNamespace
    ) async {
        if self.namespace == namespace, isLoaded {
            return
        }
        await flush()
        self.store = store
        self.namespace = namespace
        let restored = await store.load(namespace: namespace, context: context)
        text = restored.text ?? initialText
        realm = restored.realm ?? initialRealm
        images = restored.images
        submissionNeedsVerification = restored.submissionNeedsVerification
        restorationWarning = restored.warning
        isLoaded = true
    }

    func scheduleSave() {
        guard isLoaded else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            await self?.persistCurrentState()
        }
    }

    func addImages(_ addedImages: [TaggrDraftImage], afterTextSegmentID: Int? = nil) async {
        guard !addedImages.isEmpty else { return }
        submissionNeedsVerification = false
        images.append(contentsOf: addedImages)
        text = PostDraftDocument.inserting(
            markdowns: addedImages.map(\.markdown),
            in: text.trimmingCharacters(in: .whitespacesAndNewlines),
            afterTextSegmentID: afterTextSegmentID
        )
        await flush()
    }

    @discardableResult
    func addExternalURL(_ url: URL) async -> Bool {
        submissionNeedsVerification = false
        text = PostDraftDocument.appendingExternalURL(url, to: text)
        await flush()
        return restorationWarning != Self.saveFailureWarning
    }

    func removeImage(_ image: TaggrDraftImage, occurrence: Int) async {
        submissionNeedsVerification = false
        text = PostDraftDocument.removing(imageOccurrence: occurrence, from: text)
        if !PostDraftDocument.containsImageMarker(blobID: image.id, in: text) {
            images.removeAll { $0.id == image.id }
        }
        await flush()
    }

    func removeImageMarker(occurrence: Int) async {
        submissionNeedsVerification = false
        text = PostDraftDocument.removing(imageOccurrence: occurrence, from: text)
        await flush()
    }

    func moveImageMarker(occurrence: Int, before targetOccurrence: Int?) async {
        submissionNeedsVerification = false
        text = PostDraftDocument.moving(imageOccurrence: occurrence, before: targetOccurrence, in: text)
        await flush()
    }

    func moveImageMarker(occurrence: Int, afterTextSegmentID: Int) async {
        submissionNeedsVerification = false
        text = PostDraftDocument.moving(imageOccurrence: occurrence, afterTextSegmentID: afterTextSegmentID, in: text)
        await flush()
    }

    func flush() async {
        saveTask?.cancel()
        saveTask = nil
        await persistCurrentState()
    }

    func discard() async {
        saveTask?.cancel()
        saveTask = nil
        text = initialText
        realm = initialRealm
        images = []
        submissionNeedsVerification = false
        restorationWarning = nil
        if let store, let namespace {
            await store.delete(namespace: namespace, context: context)
        }
    }

    private func persistCurrentState() async {
        guard isLoaded, let store, let namespace else { return }
        if !hasChanges || !hasContent {
            await store.delete(namespace: namespace, context: context)
            return
        }
        do {
            try await store.save(
                namespace: namespace,
                context: context,
                text: text,
                realm: realm,
                images: images,
                submissionNeedsVerification: submissionNeedsVerification
            )
            if restorationWarning == Self.saveFailureWarning {
                restorationWarning = nil
            }
        } catch {
            restorationWarning = Self.saveFailureWarning
        }
    }

    @discardableResult
    func markSubmissionNeedsVerification() async -> Bool {
        submissionNeedsVerification = true
        await flush()
        return restorationWarning != Self.saveFailureWarning
    }

    func clearSubmissionVerification() async {
        guard submissionNeedsVerification else { return }
        submissionNeedsVerification = false
        await flush()
    }

    func contentDidChange() {
        guard submissionNeedsVerification else { return }
        submissionNeedsVerification = false
    }
}
