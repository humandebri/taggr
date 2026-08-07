// TAGGR/Views: Normalizes locally selected post images before uploading them to the user's media bucket.

import CryptoKit
import Foundation
import ICNativeClient
import UIKit

enum ImageDrafts {
    static let maxImagePixels = 16_777_216
    static let maxImageBytes = 460_800

    static func blobId(for data: Data) -> String {
        Data(SHA256.hash(data: data)).prefix(4).icHexString
    }

    static func uniquedDraftImages(_ drafts: [TaggrDraftImage], existingIDs: Set<String>) -> [TaggrDraftImage] {
        var usedIDs = existingIDs
        return drafts.map { draft in
            let uniqueDraft = uniquedDraftImage(draft, usedIDs: usedIDs)
            usedIDs.insert(uniqueDraft.id)
            return uniqueDraft
        }
    }

    static func draftImage(from data: Data, maxBytes: Int = maxImageBytes) -> TaggrDraftImage? {
        guard let normalized = normalizedImageData(data, maxBytes: maxBytes),
              let image = UIImage(data: normalized) else {
            return nil
        }
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        return TaggrDraftImage(id: blobId(for: normalized), data: normalized, width: width, height: height)
    }

    static func draftImages(
        from sourceData: [Data],
        maxBytes: Int = maxImageBytes,
        maxConcurrent: Int = 2
    ) async -> [TaggrDraftImage] {
        guard !sourceData.isEmpty else { return [] }
        let limit = max(1, min(maxConcurrent, sourceData.count))
        return await withTaskGroup(of: (Int, TaggrDraftImage?).self) { group in
            var nextIndex = 0
            var results: [Int: TaggrDraftImage] = [:]

            func submit(_ index: Int) {
                let data = sourceData[index]
                group.addTask {
                    (index, draftImage(from: data, maxBytes: maxBytes))
                }
            }

            for _ in 0..<limit {
                submit(nextIndex)
                nextIndex += 1
            }

            while let (index, draft) = await group.next() {
                if let draft {
                    results[index] = draft
                }
                if nextIndex < sourceData.count {
                    submit(nextIndex)
                    nextIndex += 1
                }
            }

            return sourceData.indices.compactMap { results[$0] }
        }
    }

    static func normalizedImageData(_ data: Data, maxBytes: Int = maxImageBytes) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let pixels = Int(image.size.width * image.scale * image.size.height * image.scale)
        guard pixels <= maxImagePixels else { return nil }
        if data.count <= maxBytes { return data }
        var quality: CGFloat = 0.82
        while quality >= 0.35 {
            if let compressed = image.jpegData(compressionQuality: quality), compressed.count <= maxBytes {
                return compressed
            }
            quality -= 0.12
        }
        guard let compressed = image.jpegData(compressionQuality: 0.35),
              compressed.count <= maxBytes else {
            return nil
        }
        return compressed
    }

    private static func uniquedDraftImage(_ draft: TaggrDraftImage, usedIDs: Set<String>) -> TaggrDraftImage {
        guard usedIDs.contains(draft.id) else { return draft }
        let prefix = String(draft.id.prefix(6))
        for counter in 1...255 {
            let id = prefix + String(format: "%02x", counter)
            if !usedIDs.contains(id) {
                return TaggrDraftImage(id: id, data: draft.data, width: draft.width, height: draft.height)
            }
        }
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        return TaggrDraftImage(id: id, data: draft.data, width: draft.width, height: draft.height)
    }
}
