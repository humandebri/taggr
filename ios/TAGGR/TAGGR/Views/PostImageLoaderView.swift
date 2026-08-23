// TAGGR/Views: Shared image loader for post media across feeds, previews, and account photos.
// Local physical-device builds cannot dereference raw.localhost bucket URLs, so they query bucket http_request via the configured IC API endpoint.
import SwiftUI
import UIKit

enum TaggrPostImageDataLoader {
    @MainActor
    private static let imageCache = NSCache<NSString, UIImage>()

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
    static func cachedImage(for key: String) -> UIImage? {
        imageCache.object(forKey: key as NSString)
    }

    @MainActor
    static func storeCachedImage(_ image: UIImage, for key: String) {
        imageCache.setObject(image, forKey: key as NSString)
    }

    private static func validCachedImageData(for request: URLRequest) -> Data? {
        guard let data = URLCache.shared.cachedResponse(for: request)?.data,
              UIImage(data: data) != nil else {
            return nil
        }
        return data
    }
}

struct TaggrPostImageLoaderView: View {
    let attachment: TaggrPostImageAttachment
    let contentMode: ContentMode
    private let onImageLoaded: ((CGSize) -> Void)?
    @Environment(TaggrAppCoordinator.self) private var state
    private let imageCacheKey: String
    @State private var uiImage: UIImage?
    @State private var failed = false
    @State private var loading = false

    init(
        attachment: TaggrPostImageAttachment,
        contentMode: ContentMode,
        onImageLoaded: ((CGSize) -> Void)? = nil
    ) {
        self.attachment = attachment
        self.contentMode = contentMode
        self.onImageLoaded = onImageLoaded
        let key = Self.imageCacheKey(for: attachment)
        self.imageCacheKey = key
        _uiImage = State(initialValue: TaggrPostImageDataLoader.cachedImage(for: key))
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

    private static func imageCacheKey(for attachment: TaggrPostImageAttachment) -> String {
        [
            attachment.id,
            attachment.url.absoluteString,
        ].joined(separator: "|")
    }

    @MainActor
    private func load() async {
        if let cachedImage = TaggrPostImageDataLoader.cachedImage(for: imageCacheKey) {
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
            guard let image = UIImage(data: data) else {
                failed = true
                return
            }
            TaggrPostImageDataLoader.storeCachedImage(image, for: imageCacheKey)
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
