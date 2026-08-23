// TAGGR: Persists post drafts and their images locally without involving canister APIs.

import Foundation
import SwiftUI

struct PostDraftContext: Codable, Hashable {
    enum Kind: String, Codable {
        case newPost
        case reply
        case edit
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

    var storageKey: String {
        postID.map { "\(kind.rawValue)-\($0)" } ?? kind.rawValue
    }
}

struct PostDraftNamespace: Hashable {
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
    let updatedAt: Date
}

struct RestoredPostDraft {
    let text: String?
    let realm: String?
    let images: [TaggrDraftImage]
    let warning: String?
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
            return RestoredPostDraft(text: nil, realm: nil, images: [], warning: nil)
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
        images: [TaggrDraftImage]
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
        text != initialText || realm != initialRealm || !images.isEmpty
    }

    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty
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

    func addImages(_ addedImages: [TaggrDraftImage]) async {
        guard !addedImages.isEmpty else { return }
        images.append(contentsOf: addedImages)
        let insertion = addedImages.map(\.markdown).joined(separator: "\n")
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = body.isEmpty ? insertion : body + "\n\n" + insertion
        await flush()
    }

    func removeImage(_ image: TaggrDraftImage) async {
        images.removeAll { $0.id == image.id }
        text = text
            .replacingOccurrences(of: image.markdown + "\n", with: "")
            .replacingOccurrences(of: "\n" + image.markdown, with: "")
            .replacingOccurrences(of: image.markdown, with: "")
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
        if let store, let namespace {
            await store.delete(namespace: namespace, context: context)
        }
        text = initialText
        realm = initialRealm
        images = []
        restorationWarning = nil
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
                images: images
            )
            if restorationWarning == Self.saveFailureWarning {
                restorationWarning = nil
            }
        } catch {
            restorationWarning = Self.saveFailureWarning
        }
    }
}
