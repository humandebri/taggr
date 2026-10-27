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

struct ImageImportProgress: Equatable, Sendable {
    let completed: Int
    let total: Int
}

typealias ImageImportProgressHandler = @Sendable (ImageImportProgress) async -> Void

@MainActor
final class ImageImportCoordinator: ObservableObject {
    @Published private(set) var isImporting = false
    @Published private(set) var progress = ImageImportProgress(completed: 0, total: 0)

    private var generation = 0
    private var task: Task<Void, Never>?

    @discardableResult
    func start(
        count: Int = 0,
        operation: @escaping @Sendable (@escaping ImageImportProgressHandler) async -> ImageImportBatchResult,
        completion: @escaping @MainActor (ImageImportBatchResult) async -> Void
    ) -> Task<Void, Never> {
        cancel()
        generation += 1
        let currentGeneration = generation
        progress = ImageImportProgress(completed: 0, total: count)
        isImporting = true
        let operationTask = Task { [weak self] in
            let result = await operation { [weak self] progress in
                await self?.updateProgress(progress, generation: currentGeneration)
            }
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

    private func updateProgress(_ progress: ImageImportProgress, generation: Int) {
        guard isImporting, self.generation == generation else { return }
        self.progress = progress
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        isImporting = false
        progress = ImageImportProgress(completed: 0, total: 0)
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
    static let maxPostImageBytes = 150 * 1_024
    static let postImageWebPQuality = 50
    // Method 2 reduces encoding time while keeping size close to the default method 4.
    static let postImageWebPMethod: Int32 = 2

    static var defaultImportConcurrency: Int {
        let process = ProcessInfo.processInfo
        guard !process.isLowPowerModeEnabled,
              process.thermalState == .nominal,
              process.physicalMemory >= 4 * 1_024 * 1_024 * 1_024 else {
            return 2
        }
        return 3
    }

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
        maxConcurrent: Int = defaultImportConcurrency,
        onProgress: @escaping ImageImportProgressHandler = { _ in }
    ) async -> ImageImportBatchResult {
        await importImages(count: items.count, maxBytes: maxBytes, maxConcurrent: maxConcurrent, onProgress: onProgress) { index in
            try await items[index].loadTransferable(type: Data.self)
        }
    }

    @MainActor
    static func itemProviderImportOperation(
        _ itemProviders: [NSItemProvider],
        maxConcurrent: Int = defaultImportConcurrency
    ) -> @Sendable (Int, @escaping ImageImportProgressHandler) async -> ImageImportBatchResult {
        let providers = itemProviders.map(ImageItemProvider.init)
        return { maxBytes, onProgress in
            await importImages(count: providers.count, maxBytes: maxBytes, maxConcurrent: maxConcurrent, onProgress: onProgress) { index in
                try await providers[index]?.loadData()
            }
        }
    }

    static func importImages(
        count: Int,
        maxBytes: Int = maxPostImageBytes,
        maxConcurrent: Int = defaultImportConcurrency,
        onProgress: @escaping ImageImportProgressHandler = { _ in },
        loadData: @escaping @Sendable (Int) async throws -> Data?
    ) async -> ImageImportBatchResult {
        await onProgress(ImageImportProgress(completed: 0, total: count))
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
                await onProgress(ImageImportProgress(completed: results.count, total: count))
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
        var webPMethod: Int32?

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
            let method = webPMethod ?? preferredWebPMethod(
                rgba: rgba, width: image.width, height: image.height, maxBytes: maxBytes
            )
            webPMethod = method

            var encoded = bestWebP(
                rgba: rgba,
                width: image.width,
                height: image.height,
                maxBytes: maxBytes,
                method: method
            )
            // Use the original compression efficiency before reducing resolution.
            // Keep it for subsequent retries so detailed photos retain their previous dimensions.
            if case .tooLarge = encoded, method != 4 {
                webPMethod = 4
                encoded = bestWebP(
                    rgba: rgba,
                    width: image.width,
                    height: image.height,
                    maxBytes: maxBytes,
                    method: 4
                )
            }
            switch encoded {
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

    private static func preferredWebPMethod(rgba: Data, width: Int, height: Int, maxBytes: Int) -> Int32 {
        let sampleWidth = min(128, width)
        let sampleHeight = min(128, height)
        guard sampleWidth < width || sampleHeight < height else { return postImageWebPMethod }
        let startX = (width - sampleWidth) / 2
        let startY = (height - sampleHeight) / 2
        var sample = Data(count: sampleWidth * sampleHeight * 4)
        rgba.withUnsafeBytes { source in
            sample.withUnsafeMutableBytes { target in
                for row in 0..<sampleHeight {
                    target.baseAddress!.advanced(by: row * sampleWidth * 4).copyMemory(
                        from: source.baseAddress!.advanced(by: ((startY + row) * width + startX) * 4),
                        byteCount: sampleWidth * 4
                    )
                }
            }
        }
        // A small compression trial avoids paying for a full fast encode on dense images.
        // This estimate only selects a method; the full result still enforces the byte limit.
        guard let encoded = encodeWebP(
            rgba: sample, width: sampleWidth, height: sampleHeight,
            quality: postImageWebPQuality, method: postImageWebPMethod
        ) else { return 4 }
        let estimatedBytes = Double(encoded.count) * Double(width) * Double(height)
            / Double(sampleWidth * sampleHeight)
        return estimatedBytes <= Double(maxBytes) ? postImageWebPMethod : 4
    }

    private static func bestWebP(
        rgba: Data,
        width: Int,
        height: Int,
        maxBytes: Int,
        method: Int32
    ) -> WebPEncodingAttempt {
        postWebP(maxBytes: maxBytes) { quality in
            encodeWebP(rgba: rgba, width: width, height: height, quality: quality, method: method)
        }
    }

    static func postWebP(
        maxBytes: Int,
        encode: (Int) -> Data?
    ) -> WebPEncodingAttempt {
        guard let encoded = encode(postImageWebPQuality) else { return .failed }
        guard encoded.count <= maxBytes else {
            return .tooLarge(encoded.count)
        }
        return .fit(encoded)
    }

    private static func encodeWebP(
        rgba: Data,
        width: Int,
        height: Int,
        quality: Int,
        method: Int32
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
            var config = WebPConfig()
            guard WebPConfigPreset(&config, WEBP_PRESET_DEFAULT, Float(quality)) != 0 else { return nil }
            config.method = method
            var picture = WebPPicture()
            guard WebPPictureInit(&picture) != 0 else { return nil }
            defer { WebPPictureFree(&picture) }
            picture.width = Int32(width)
            picture.height = Int32(height)
            picture.writer = WebPMemoryWrite
            var writer = WebPMemoryWriter()
            WebPMemoryWriterInit(&writer)
            defer { WebPMemoryWriterClear(&writer) }
            return withUnsafeMutablePointer(to: &writer) { writerPointer in
                picture.custom_ptr = UnsafeMutableRawPointer(writerPointer)
                guard WebPPictureImportRGBA(&picture, baseAddress, Int32(bytesPerRow.partialValue)) != 0,
                      WebPEncode(&config, &picture) != 0,
                      let output = writerPointer.pointee.mem,
                      writerPointer.pointee.size > 0 else {
                    return nil
                }
                return Data(bytes: output, count: writerPointer.pointee.size)
            }
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
