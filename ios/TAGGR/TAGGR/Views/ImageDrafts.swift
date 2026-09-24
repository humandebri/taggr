// TAGGR/Views: Normalizes locally selected post images before uploading them to the user's media bucket.

import CryptoKit
import Foundation
import ICNativeClient
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import libwebp

enum ImageImportFailureReason: Int, CaseIterable, Error, Sendable {
    case photoReadFailed
    case invalidImage
    case webPEncodingFailed
    case sizeLimitUnreachable

    fileprivate func summary(count: Int) -> String {
        switch self {
        case .photoReadFailed:
            return "\(count) could not be read"
        case .invalidImage:
            return "\(count) contained invalid or unsupported image data"
        case .webPEncodingFailed:
            return "\(count) could not be converted to WebP"
        case .sizeLimitUnreachable:
            return "\(count) could not fit the configured size limit"
        }
    }
}

struct ImageImportFailure: Equatable, Sendable {
    let index: Int
    let reason: ImageImportFailureReason
}

struct ImageImportBatchResult: Equatable, Sendable {
    let images: [TaggrDraftImage]
    let failures: [ImageImportFailure]

    var warning: String? {
        guard !failures.isEmpty else { return nil }
        let details = ImageImportFailureReason.allCases.compactMap { reason in
            let count = failures.count { $0.reason == reason }
            return count == 0 ? nil : reason.summary(count: count)
        }
        let noun = failures.count == 1 ? "image" : "images"
        return "\(failures.count) \(noun) could not be attached: \(details.joined(separator: "; "))."
    }
}

@MainActor
final class ImageImportCoordinator: ObservableObject {
    @Published private(set) var isImporting = false

    private var generation = 0
    private var task: Task<Void, Never>?

    @discardableResult
    func start(
        operation: @escaping @Sendable () async -> ImageImportBatchResult,
        completion: @escaping @MainActor (ImageImportBatchResult) async -> Void
    ) -> Task<Void, Never> {
        cancel()
        generation += 1
        let currentGeneration = generation
        isImporting = true
        let operationTask = Task { [weak self] in
            let result = await operation()
            guard let self,
                  !Task.isCancelled,
                  self.generation == currentGeneration else {
                return
            }
            await completion(result)
            guard !Task.isCancelled,
                  self.generation == currentGeneration else {
                return
            }
            self.isImporting = false
            self.task = nil
        }
        task = operationTask
        return operationTask
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        isImporting = false
    }
}

private struct NormalizedPostImage: Sendable {
    let data: Data
    let width: Int
    let height: Int
}

private enum IndexedImageImportResult: Sendable {
    case image(index: Int, image: TaggrDraftImage)
    case failure(ImageImportFailure)

    var index: Int {
        switch self {
        case .image(let index, _): index
        case .failure(let failure): failure.index
        }
    }
}

enum ImageDrafts {
    static let maxImagePixels = 16_777_216
    static let maxImageBytes = 460_800
    static let maxPostImagePixels = 3_000_000
    static let maxPostImageBytes = 200 * 1_024

    static func postImageMaximumBytes(serverLimit: Int?) -> Int {
        guard let serverLimit, serverLimit > 0 else {
            return maxPostImageBytes
        }
        return min(maxPostImageBytes, serverLimit)
    }

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

    static func importPhotos(
        _ items: [PhotosPickerItem],
        maxBytes: Int = maxPostImageBytes,
        maxConcurrent: Int = 2
    ) async -> ImageImportBatchResult {
        await importImages(count: items.count, maxBytes: maxBytes, maxConcurrent: maxConcurrent) { index in
            try await items[index].loadTransferable(type: Data.self)
        }
    }

    @MainActor
    static func itemProviderImportOperation(
        _ itemProviders: [NSItemProvider],
        maxConcurrent: Int = 2
    ) -> @Sendable (Int) async -> ImageImportBatchResult {
        let providers = itemProviders.map(ImageItemProvider.init)
        return { maxBytes in
            await importImages(count: providers.count, maxBytes: maxBytes, maxConcurrent: maxConcurrent) { index in
                try await providers[index]?.loadData()
            }
        }
    }

    static func importImages(
        count: Int,
        maxBytes: Int = maxPostImageBytes,
        maxConcurrent: Int = 2,
        loadData: @escaping @Sendable (Int) async throws -> Data?
    ) async -> ImageImportBatchResult {
        guard count > 0 else {
            return ImageImportBatchResult(images: [], failures: [])
        }
        let limit = max(1, min(maxConcurrent, count))
        let unordered = await withTaskGroup(
            of: IndexedImageImportResult.self,
            returning: [IndexedImageImportResult].self
        ) { group in
            var nextIndex = 0
            var results: [IndexedImageImportResult] = []
            results.reserveCapacity(count)

            func submit(_ index: Int) {
                group.addTask {
                    do {
                        guard let data = try await loadData(index),
                              !data.isEmpty else {
                            return .failure(
                                ImageImportFailure(index: index, reason: .photoReadFailed)
                            )
                        }
                        try Task.checkCancellation()
                        switch postImageResult(from: data, maxBytes: maxBytes) {
                        case .success(let image):
                            return .image(index: index, image: image)
                        case .failure(let reason):
                            return .failure(ImageImportFailure(index: index, reason: reason))
                        }
                    } catch {
                        return .failure(
                            ImageImportFailure(index: index, reason: .photoReadFailed)
                        )
                    }
                }
            }

            for _ in 0..<limit {
                submit(nextIndex)
                nextIndex += 1
            }
            while let result = await group.next() {
                results.append(result)
                if nextIndex < count {
                    submit(nextIndex)
                    nextIndex += 1
                }
            }
            return results
        }

        let ordered = unordered.sorted { $0.index < $1.index }
        return ImageImportBatchResult(
            images: ordered.compactMap {
                guard case .image(_, let image) = $0 else { return nil }
                return image
            },
            failures: ordered.compactMap {
                guard case .failure(let failure) = $0 else { return nil }
                return failure
            }
        )
    }

    enum WebPEncodingAttempt {
        case fit(Data)
        case tooLarge(Int)
        case failed
    }

    static func postImageResult(
        from data: Data,
        maxBytes: Int,
        maxPixels: Int = maxPostImagePixels
    ) -> Result<TaggrDraftImage, ImageImportFailureReason> {
        switch normalizedPostImage(from: data, maxBytes: maxBytes, maxPixels: maxPixels) {
        case .success(let normalized):
            return .success(
                TaggrDraftImage(
                    id: blobId(for: normalized.data),
                    data: normalized.data,
                    width: normalized.width,
                    height: normalized.height
                )
            )
        case .failure(let reason):
            return .failure(reason)
        }
    }

    private static func normalizedPostImage(
        from data: Data,
        maxBytes: Int,
        maxPixels: Int
    ) -> Result<NormalizedPostImage, ImageImportFailureReason> {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard maxBytes > 0,
              maxPixels > 0,
              let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else {
            return .failure(.invalidImage)
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation) else {
            return .failure(.invalidImage)
        }
        let sourcePixels = width.multipliedReportingOverflow(by: height)
        guard !sourcePixels.overflow else {
            return .failure(.invalidImage)
        }

        let sourceMaxDimension = max(width, height)
        var targetMaxDimension = sourcePixels.partialValue > maxPixels
            ? maxDimension(width: width, height: height, maxPixels: maxPixels)
            : sourceMaxDimension

        while targetMaxDimension > 0 {
            guard let image = thumbnail(from: source, targetMaxDimension: targetMaxDimension)?.cgImage else {
                return .failure(.invalidImage)
            }
            let outputPixels = image.width.multipliedReportingOverflow(by: image.height)
            guard !outputPixels.overflow else {
                return .failure(.invalidImage)
            }
            if outputPixels.partialValue > maxPixels {
                targetMaxDimension -= 1
                continue
            }
            guard let rgba = rgbaData(from: image) else {
                return .failure(.webPEncodingFailed)
            }

            switch bestWebP(
                rgba: rgba,
                width: image.width,
                height: image.height,
                maxBytes: maxBytes
            ) {
            case .fit(let encoded):
                return .success(
                    NormalizedPostImage(
                        data: encoded,
                        width: image.width,
                        height: image.height
                    )
                )
            case .failed:
                return .failure(.webPEncodingFailed)
            case .tooLarge(let byteCount):
                guard targetMaxDimension > 1 else {
                    return .failure(.sizeLimitUnreachable)
                }
                let fitScale = sqrt(Double(maxBytes) / Double(byteCount)) * 0.95
                let scaled = Int(floor(Double(targetMaxDimension) * min(0.85, fitScale)))
                targetMaxDimension = max(1, min(targetMaxDimension - 1, scaled))
            }
        }
        return .failure(.sizeLimitUnreachable)
    }

    private static func rgbaData(from image: CGImage) -> Data? {
        let bytesPerRow = image.width.multipliedReportingOverflow(by: 4)
        guard !bytesPerRow.overflow else { return nil }
        let byteCount = bytesPerRow.partialValue.multipliedReportingOverflow(by: image.height)
        guard !byteCount.overflow,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        var rgba = Data(count: byteCount.partialValue)
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow.partialValue,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .high
            context.setBlendMode(.copy)
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )

            let pixels = buffer.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                let alpha = Int(pixels[offset + 3])
                guard alpha > 0, alpha < 255 else { continue }
                for channel in 0..<3 {
                    let value = (Int(pixels[offset + channel]) * 255 + alpha / 2) / alpha
                    pixels[offset + channel] = UInt8(min(255, value))
                }
            }
            return true
        }
        return rendered ? rgba : nil
    }

    private static func bestWebP(
        rgba: Data,
        width: Int,
        height: Int,
        maxBytes: Int
    ) -> WebPEncodingAttempt {
        highestQualityWebP(maxBytes: maxBytes) { quality in
            encodeWebP(rgba: rgba, width: width, height: height, quality: quality)
        }
    }

    static func highestQualityWebP(
        maxBytes: Int,
        encode: (Int) -> Data?
    ) -> WebPEncodingAttempt {
        guard let minimumQuality = encode(0) else { return .failed }
        guard minimumQuality.count <= maxBytes else {
            return .tooLarge(minimumQuality.count)
        }

        guard let maximumQuality = encode(100) else { return .failed }
        guard maximumQuality.count > maxBytes else {
            return .fit(maximumQuality)
        }

        var best = minimumQuality
        var low = 1
        var high = 99
        while low <= high {
            let quality = (low + high) / 2
            guard let encoded = encode(quality) else { return .failed }
            if encoded.count <= maxBytes {
                best = encoded
                low = quality + 1
            } else {
                high = quality - 1
            }
        }
        return .fit(best)
    }

    private static func encodeWebP(
        rgba: Data,
        width: Int,
        height: Int,
        quality: Int
    ) -> Data? {
        let bytesPerRow = width.multipliedReportingOverflow(by: 4)
        guard !bytesPerRow.overflow,
              width <= Int(Int32.max),
              height <= Int(Int32.max),
              bytesPerRow.partialValue <= Int(Int32.max) else {
            return nil
        }

        return rgba.withUnsafeBytes { buffer -> Data? in
            guard let baseAddress = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            var output: UnsafeMutablePointer<UInt8>?
            let size = WebPEncodeRGBA(
                baseAddress,
                Int32(width),
                Int32(height),
                Int32(bytesPerRow.partialValue),
                Float(quality),
                &output
            )
            guard size > 0, let output else { return nil }
            defer { WebPFree(output) }
            return Data(bytes: output, count: Int(size))
        }
    }

    static func normalizedImageData(
        _ data: Data,
        maxBytes: Int = maxImageBytes,
        maxPixels: Int = maxImagePixels
    ) -> Data? {
        guard maxBytes > 0,
              maxPixels > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else {
            return nil
        }

        let sourcePixels = width.multipliedReportingOverflow(by: height)
        guard !sourcePixels.overflow else { return nil }
        if sourcePixels.partialValue <= maxPixels, data.count <= maxBytes {
            return data
        }

        let sourceMaxDimension = max(width, height)
        var targetMaxDimension = sourcePixels.partialValue > maxPixels
            ? maxDimension(width: width, height: height, maxPixels: maxPixels)
            : sourceMaxDimension

        while targetMaxDimension > 0 {
            guard let image = thumbnail(
                from: source,
                targetMaxDimension: targetMaxDimension
            ) else {
                return nil
            }

            var smallestEncodedSize: Int?
            for quality: CGFloat in [0.82, 0.70, 0.58, 0.46, 0.35] {
                guard let compressed = image.jpegData(compressionQuality: quality) else { continue }
                if compressed.count <= maxBytes {
                    return compressed
                }
                smallestEncodedSize = compressed.count
            }

            guard let smallestEncodedSize else { return nil }
            let fitScale = sqrt(Double(maxBytes) / Double(smallestEncodedSize)) * 0.9
            let nextMaxDimension = Int(Double(targetMaxDimension) * min(0.85, fitScale))
            targetMaxDimension = min(targetMaxDimension - 1, nextMaxDimension)
        }
        return nil
    }

    private static func maxDimension(width: Int, height: Int, maxPixels: Int) -> Int {
        let scale = sqrt(Double(maxPixels) / (Double(width) * Double(height)))
        return max(1, Int(floor(Double(max(width, height)) * min(1, scale))))
    }

    private static func thumbnail(
        from source: CGImageSource,
        targetMaxDimension: Int
    ) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetMaxDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
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

// NSItemProvider supports asynchronous representation loading from background tasks.
private struct ImageItemProvider: @unchecked Sendable {
    let provider: NSItemProvider
    let typeIdentifier: String

    init?(_ provider: NSItemProvider) {
        guard let typeIdentifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) else { return nil }
        self.provider = provider
        self.typeIdentifier = typeIdentifier
    }

    func loadData() async throws -> Data? {
        let load = ImageItemProviderLoad()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                load.start(provider: provider, typeIdentifier: typeIdentifier, continuation: continuation)
            }
        } onCancel: {
            load.cancel()
        }
    }
}

private final class ImageItemProviderLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Error>?
    private var progress: Progress?
    private var isFinished = false
    private var isCancelled = false

    func start(
        provider: NSItemProvider,
        typeIdentifier: String,
        continuation: CheckedContinuation<Data?, Error>
    ) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()

        let progress = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] data, error in
            self?.finish(data: data, error: error)
        }

        lock.lock()
        if isCancelled {
            lock.unlock()
            progress.cancel()
        } else {
            if !isFinished { self.progress = progress }
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        isCancelled = true
        let continuation = continuation
        self.continuation = nil
        let progress = progress
        self.progress = nil
        lock.unlock()

        progress?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    private func finish(data: Data?, error: Error?) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        progress = nil
        lock.unlock()

        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: data)
        }
    }
}
