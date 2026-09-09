// TAGGR/Views: Shared image loader for post media across feeds, previews, and account photos.
// Local physical-device builds cannot dereference raw.localhost bucket URLs, so they query bucket http_request via the configured IC API endpoint.
import ImageIO
import SwiftUI
import UIKit

private actor TaggrPostImageDecoder {
    func image(from data: Data, maximumPixelSize: Int?) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        guard let maximumPixelSize, maximumPixelSize > 0 else {
            return UIImage(data: data)
        }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}

enum TaggrPostImageCacheKind: Equatable {
    case standard
    case accountThumbnail
}

enum TaggrPostImageDataLoader {
    private static let imageDecoder = TaggrPostImageDecoder()

    @MainActor
    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()

    @MainActor
    private static let accountThumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()

    static func data(for attachment: TaggrPostImageAttachment, api: TaggrAPI, config: TaggrRuntimeConfig) async throws -> Data {
        let request = URLRequest(url: attachment.url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)

        if attachment.shouldLoadThroughAPI(config: config),
           let bucketId = attachment.bucketId,
           let offset = attachment.offset,
           let length = attachment.length {
            if let cached = validCachedImageData(for: request) {
                return cached
            }
            let data = try await api.bucketImage(bucketId: bucketId, offset: offset, length: length)
            let response = URLResponse(url: attachment.url, mimeType: nil, expectedContentLength: data.count, textEncodingName: nil)
            URLCache.shared.storeCachedResponse(CachedURLResponse(response: response, data: data), for: request)
            return data
        }

        if let cached = validCachedImageData(for: request) {
            return cached
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TaggrAPIError.backendUnavailable("image \(http.statusCode)")
        }
        URLCache.shared.storeCachedResponse(CachedURLResponse(response: response, data: data), for: request)
        return data
    }

    @MainActor
    static func cachedImage(for key: String, maximumPixelSize: Int?) -> UIImage? {
        cache(for: cacheKind(for: maximumPixelSize)).object(forKey: key as NSString)
    }

    @MainActor
    static func storeCachedImage(_ image: UIImage, for key: String, maximumPixelSize: Int?) {
        cache(for: cacheKind(for: maximumPixelSize)).setObject(
            image,
            forKey: key as NSString,
            cost: decodedImageCost(image)
        )
    }

    static func cacheKind(for maximumPixelSize: Int?) -> TaggrPostImageCacheKind {
        maximumPixelSize == 512 ? .accountThumbnail : .standard
    }

    static func cacheKey(for attachment: TaggrPostImageAttachment, maximumPixelSize: Int?) -> String {
        [
            attachment.id,
            attachment.url.absoluteString,
            maximumPixelSize.map(String.init) ?? "original",
        ].joined(separator: "|")
    }

    static func decodedImage(from data: Data, maximumPixelSize: Int?) async -> UIImage? {
        await imageDecoder.image(from: data, maximumPixelSize: maximumPixelSize)
    }

    @MainActor
    private static func cache(for kind: TaggrPostImageCacheKind) -> NSCache<NSString, UIImage> {
        switch kind {
        case .standard:
            imageCache
        case .accountThumbnail:
            accountThumbnailCache
        }
    }

    private static func validCachedImageData(for request: URLRequest) -> Data? {
        guard let data = URLCache.shared.cachedResponse(for: request)?.data,
              UIImage(data: data) != nil else {
            return nil
        }
        return data
    }

    private static func decodedImageCost(_ image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        let result = cgImage.bytesPerRow.multipliedReportingOverflow(by: cgImage.height)
        return result.overflow ? Int.max : max(result.partialValue, 1)
    }
}

struct TaggrPostImageLoaderView: View {
    let attachment: TaggrPostImageAttachment
    let contentMode: ContentMode
    private let maximumPixelSize: Int?
    private let onImageLoaded: ((CGSize) -> Void)?
    @Environment(TaggrAppCoordinator.self) private var state
    private let imageCacheKey: String
    @State private var uiImage: UIImage?
    @State private var failed = false
    @State private var loading = false

    init(
        attachment: TaggrPostImageAttachment,
        contentMode: ContentMode,
        maximumPixelSize: Int? = nil,
        onImageLoaded: ((CGSize) -> Void)? = nil
    ) {
        self.attachment = attachment
        self.contentMode = contentMode
        self.maximumPixelSize = maximumPixelSize
        self.onImageLoaded = onImageLoaded
        let key = TaggrPostImageDataLoader.cacheKey(
            for: attachment,
            maximumPixelSize: maximumPixelSize
        )
        self.imageCacheKey = key
        _uiImage = State(
            initialValue: TaggrPostImageDataLoader.cachedImage(
                for: key,
                maximumPixelSize: maximumPixelSize
            )
        )
    }

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .taggrPostImageContentMode(contentMode)
            } else if failed {
                Image(systemName: "photo")
                    .font(contentMode == .fit ? .largeTitle : .title2)
                    .foregroundStyle(TaggrTheme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: loadKey) {
            await load()
        }
    }

    private var loadKey: String {
        [
            imageCacheKey,
            state.runtimeConfig.apiBaseURL.absoluteString,
        ].joined(separator: "|")
    }

    @MainActor
    private func load() async {
        if let cachedImage = TaggrPostImageDataLoader.cachedImage(
            for: imageCacheKey,
            maximumPixelSize: maximumPixelSize
        ) {
            uiImage = cachedImage
            failed = false
            onImageLoaded?(cachedImage.size)
            return
        }
        guard !loading else { return }
        loading = true
        failed = false
        uiImage = nil
        defer { loading = false }

        do {
            let data = try await TaggrPostImageDataLoader.data(
                for: attachment,
                api: state.api,
                config: state.runtimeConfig
            )
            let decodedImage = await TaggrPostImageDataLoader.decodedImage(
                from: data,
                maximumPixelSize: maximumPixelSize
            )
            guard !Task.isCancelled else { return }
            guard let image = decodedImage else {
                failed = true
                return
            }
            TaggrPostImageDataLoader.storeCachedImage(
                image,
                for: imageCacheKey,
                maximumPixelSize: maximumPixelSize
            )
            uiImage = image
            onImageLoaded?(image.size)
        } catch {
            failed = true
        }
    }
}

private extension Image {
    @ViewBuilder
    func taggrPostImageContentMode(_ contentMode: ContentMode) -> some View {
        switch contentMode {
        case .fill:
            scaledToFill()
        case .fit:
            scaledToFit()
        @unknown default:
            scaledToFit()
        }
    }
}
