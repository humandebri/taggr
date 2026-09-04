// TAGGR/Views: Post image grid, thumbnails, and preview UI for native timeline posts.
import Foundation
import SwiftUI

enum PostImageGrid {
    static let maxTimelineImages = 4

    static func columns(for count: Int) -> Int {
        displayedCount(for: count) <= 1 ? 1 : 2
    }

    static func visibleRows(for count: Int) -> Int {
        let count = displayedCount(for: count)
        guard count > 0 else { return 0 }
        return Int(ceil(Double(count) / Double(columns(for: count))))
    }

    static func displayedCount(for count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(count, maxTimelineImages)
    }

    static func visibleCount(for count: Int) -> Int {
        displayedCount(for: count)
    }

    static func hiddenCount(for count: Int) -> Int {
        max(count - maxTimelineImages, 0)
    }

    static func timelineAspectRatio(for count: Int) -> CGFloat {
        displayedCount(for: count) <= 2 ? 16.0 / 10.0 : 1.0
    }
}

enum PostImagePreviewPrefetchPolicy {
    static func attachments(_ attachments: [TaggrPostImageAttachment]) -> [TaggrPostImageAttachment] {
        var seenURLs = Set<URL>()
        return attachments.filter { seenURLs.insert($0.url).inserted }
    }
}

@MainActor
final class PostImagePrefetcher: ObservableObject {
    private var loadedURLs = Set<URL>()
    private var runningURLs = Set<URL>()
    private let maxConcurrentLoads = 6
    private var allImagesTask: Task<Void, Never>?

    func prefetch(
        _ attachments: [TaggrPostImageAttachment],
        api: TaggrAPI,
        config: TaggrRuntimeConfig
    ) {
        let candidates = attachments.filter { attachment in
            !loadedURLs.contains(attachment.url) && !runningURLs.contains(attachment.url)
        }
        for attachment in candidates.prefix(max(maxConcurrentLoads - runningURLs.count, 0)) {
            start(attachment, api: api, config: config)
        }
    }

    func prefetchAll(
        _ attachments: [TaggrPostImageAttachment],
        api: TaggrAPI,
        config: TaggrRuntimeConfig
    ) {
        allImagesTask?.cancel()
        let uniqueAttachments = PostImagePreviewPrefetchPolicy.attachments(attachments)
        allImagesTask = Task {
            await Self.loadAll(
                uniqueAttachments,
                api: api,
                config: config,
                maximumConcurrentLoads: maxConcurrentLoads
            )
        }
    }

    func cancelAll() {
        allImagesTask?.cancel()
        allImagesTask = nil
    }

    nonisolated private static func loadAll(
        _ attachments: [TaggrPostImageAttachment],
        api: TaggrAPI,
        config: TaggrRuntimeConfig,
        maximumConcurrentLoads: Int
    ) async {
        var iterator = attachments.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<min(maximumConcurrentLoads, attachments.count) {
                guard let attachment = iterator.next() else { break }
                group.addTask {
                    await load(attachment, api: api, config: config)
                }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, let attachment = iterator.next() else { continue }
                group.addTask {
                    await load(attachment, api: api, config: config)
                }
            }
        }
    }

    nonisolated private static func load(
        _ attachment: TaggrPostImageAttachment,
        api: TaggrAPI,
        config: TaggrRuntimeConfig
    ) async {
        guard !Task.isCancelled else { return }
        do {
            _ = try await TaggrPostImageDataLoader.data(for: attachment, api: api, config: config)
        } catch {
            // Visible image loading owns user-facing failure handling.
        }
    }

    private func start(
        _ attachment: TaggrPostImageAttachment,
        api: TaggrAPI,
        config: TaggrRuntimeConfig
    ) {
        let url = attachment.url
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
        if URLCache.shared.cachedResponse(for: request) != nil {
            loadedURLs.insert(url)
            return
        }

        runningURLs.insert(url)
        Task {
            do {
                _ = try await TaggrPostImageDataLoader.data(
                    for: attachment,
                    api: api,
                    config: config
                )
                loadedURLs.insert(url)
            } catch {
                // Visible image loading owns user-facing failure handling.
            }
            runningURLs.remove(url)
        }
    }
}

struct PostImageGridView: View {
    let attachments: [TaggrPostImageAttachment]
    let open: (TaggrPostImageAttachment) -> Void
    private let columnSpacing: CGFloat = 8
    private let rowSpacing: CGFloat = 8

    var body: some View {
        let displayedCount = PostImageGrid.displayedCount(for: attachments.count)
        let visibleAttachments = Array(attachments.prefix(displayedCount))
        let hiddenCount = PostImageGrid.hiddenCount(for: attachments.count)
        GeometryReader { proxy in
            let halfWidth = (proxy.size.width - columnSpacing) / 2
            let halfHeight = (proxy.size.height - rowSpacing) / 2
            switch displayedCount {
            case 0:
                EmptyView()
            case 1:
                PostImageGridButton(
                    attachment: visibleAttachments[0],
                    index: 0,
                    total: attachments.count,
                    width: proxy.size.width,
                    height: proxy.size.height,
                    hiddenCount: hiddenCount,
                    showsOverflow: false,
                    open: open
                )
            case 2:
                HStack(spacing: columnSpacing) {
                    ForEach(0..<2, id: \.self) { index in
                        PostImageGridButton(
                            attachment: visibleAttachments[index],
                            index: index,
                            total: attachments.count,
                            width: halfWidth,
                            height: proxy.size.height,
                            hiddenCount: hiddenCount,
                            showsOverflow: false,
                            open: open
                        )
                    }
                }
            case 3:
                VStack(spacing: rowSpacing) {
                    PostImageGridButton(
                        attachment: visibleAttachments[0],
                        index: 0,
                        total: attachments.count,
                        width: proxy.size.width,
                        height: halfHeight,
                        hiddenCount: hiddenCount,
                        showsOverflow: false,
                        open: open
                    )
                    HStack(spacing: columnSpacing) {
                        ForEach(1..<3, id: \.self) { index in
                            PostImageGridButton(
                                attachment: visibleAttachments[index],
                                index: index,
                                total: attachments.count,
                                width: halfWidth,
                                height: halfHeight,
                                hiddenCount: hiddenCount,
                                showsOverflow: false,
                                open: open
                            )
                        }
                    }
                }
            default:
                VStack(spacing: rowSpacing) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: columnSpacing) {
                            ForEach(0..<2, id: \.self) { column in
                                let index = row * 2 + column
                                PostImageGridButton(
                                    attachment: visibleAttachments[index],
                                    index: index,
                                    total: attachments.count,
                                    width: halfWidth,
                                    height: halfHeight,
                                    hiddenCount: hiddenCount,
                                    showsOverflow: hiddenCount > 0 && index == displayedCount - 1,
                                    open: open
                                )
                            }
                        }
                    }
                }
            }
        }
        .background(TaggrTheme.background)
        .aspectRatio(PostImageGrid.timelineAspectRatio(for: attachments.count), contentMode: .fit)
        .overlay(alignment: .topTrailing) {
            if attachments.count > 1 {
                PostImageCountBadge(current: 1, total: attachments.count)
                    .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct PostImageGridButton: View {
    let attachment: TaggrPostImageAttachment
    let index: Int
    let total: Int
    let width: CGFloat
    let height: CGFloat
    let hiddenCount: Int
    let showsOverflow: Bool
    let open: (TaggrPostImageAttachment) -> Void

    var body: some View {
        Button {
            open(attachment)
        } label: {
            PostImageThumbnail(attachment: attachment)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .overlay {
                    if showsOverflow {
                        PostImageOverflowOverlay(hiddenCount: hiddenCount)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(width: width, height: height)
        .buttonStyle(.plain)
        .accessibilityLabel("Open image \(index + 1) of \(total)")
    }
}

private struct PostImageOverflowOverlay: View {
    let hiddenCount: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.56)
            Text("+\(hiddenCount)")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }
}

private struct PostImageCountBadge: View {
    let current: Int
    let total: Int

    var body: some View {
        Text("\(current) / \(total)")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.62))
            .clipShape(Capsule())
    }
}

private struct PostImageThumbnail: View {
    let attachment: TaggrPostImageAttachment

    var body: some View {
        TaggrPostImageLoaderView(attachment: attachment, contentMode: .fill)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TaggrTheme.panelRaised)
            .clipped()
    }
}

struct PostImagePreview: View {
    let attachments: [TaggrPostImageAttachment]
    @Environment(\.dismiss) private var dismiss

    init(attachments: [TaggrPostImageAttachment], selected: TaggrPostImageAttachment) {
        self.attachments = attachments
        self.selectedID = selected.id
    }

    private let selectedID: String

    var body: some View {
        TaggrImagePagerView(
            items: attachments,
            selectedID: selectedID,
            imageAttachment: { $0 },
            imageAccessibilityLabel: { _ in "Post image" },
            countLabel: { "\($0) / \($1)" },
            close: { dismiss() },
            topTrailingContent: { _ in EmptyView() },
            bottomContent: { _ in EmptyView() }
        )
    }
}
