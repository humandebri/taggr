// TAGGR/Views: Shared full-screen pager for feed and account images.
// Keeps paging, close behavior, and photo hit testing identical across entry points.
import SwiftUI

struct TaggrImagePagerView<Item: Identifiable, TopTrailingContent: View, BottomContent: View>: View where Item.ID == String {
    let items: [Item]
    let imageAttachment: (Item) -> TaggrPostImageAttachment
    let imageAccessibilityLabel: (Item) -> String
    let countLabel: (Int, Int) -> String
    let close: () -> Void
    let topTrailingContent: (Item) -> TopTrailingContent
    let bottomContent: (Item) -> BottomContent
    @Environment(TaggrAppCoordinator.self) private var state
    @StateObject private var imagePrefetcher = PostImagePrefetcher()
    @State private var selection: String

    init(
        items: [Item],
        selectedID: String,
        imageAttachment: @escaping (Item) -> TaggrPostImageAttachment,
        imageAccessibilityLabel: @escaping (Item) -> String,
        countLabel: @escaping (Int, Int) -> String,
        close: @escaping () -> Void,
        @ViewBuilder topTrailingContent: @escaping (Item) -> TopTrailingContent,
        @ViewBuilder bottomContent: @escaping (Item) -> BottomContent
    ) {
        self.items = items
        self.imageAttachment = imageAttachment
        self.imageAccessibilityLabel = imageAccessibilityLabel
        self.countLabel = countLabel
        self.close = close
        self.topTrailingContent = topTrailingContent
        self.bottomContent = bottomContent
        _selection = State(initialValue: selectedID)
    }

    var body: some View {
        ZStack {
            TabView(selection: $selection) {
                ForEach(items) { item in
                    TaggrImagePagerPage(
                        attachment: imageAttachment(item),
                        accessibilityLabel: imageAccessibilityLabel(item),
                        close: close
                    )
                    .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if let selectedItem {
                TaggrImagePagerChrome(
                    currentIndex: selectedIndex + 1,
                    total: items.count,
                    countLabel: countLabel,
                    close: close,
                    topTrailingContent: { topTrailingContent(selectedItem) },
                    bottomContent: { bottomContent(selectedItem) }
                )
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            imagePrefetcher.prefetchAll(
                PostImagePreviewPrefetchPolicy.attachments(items.map(imageAttachment)),
                api: state.api,
                config: state.runtimeConfig
            )
        }
        .onDisappear {
            imagePrefetcher.cancelAll()
        }
    }

    private var selectedIndex: Int {
        items.firstIndex { $0.id == selection } ?? 0
    }

    private var selectedItem: Item? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }
}

private struct TaggrImagePagerPage: View {
    let attachment: TaggrPostImageAttachment
    let accessibilityLabel: String
    let close: () -> Void

    var body: some View {
        GeometryReader { proxy in
            TaggrImagePagerPhoto(
                attachment: attachment,
                accessibilityLabel: accessibilityLabel,
                availableSize: proxy.size,
                close: close
            )
        }
    }
}

private struct TaggrImagePagerPhoto: View {
    private static let maximumZoomScale: CGFloat = 4

    let attachment: TaggrPostImageAttachment
    let accessibilityLabel: String
    let availableSize: CGSize
    let close: () -> Void
    @State private var imageSize: CGSize?
    @State private var zoomScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @GestureState private var pinchScale: CGFloat = 1
    @GestureState private var dragTranslation: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black
                .contentShape(Rectangle())
                .onTapGesture(perform: close)

            let displayedSize = imageSize.map(fittedSize(for:)) ?? availableSize
            TaggrPostImageLoaderView(
                attachment: attachment,
                contentMode: .fit,
                onImageLoaded: updateImageSize
            )
            .frame(width: displayedSize.width, height: displayedSize.height)
            .scaleEffect(effectiveZoomScale)
            .offset(effectivePanOffset)
            .contentShape(Rectangle())
            // The displayed image consumes taps; black space around its fitted bounds closes the pager.
            .onTapGesture {}
            .onTapGesture(count: 2, perform: toggleZoom)
            .simultaneousGesture(magnificationGesture)
            .highPriorityGesture(panGesture)
            .allowsHitTesting(imageSize != nil)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Pinch to zoom. Drag to pan when enlarged.")
        }
        .onChange(of: attachment.id) { _, _ in resetZoom() }
    }

    private var effectiveZoomScale: CGFloat {
        clampedZoomScale(zoomScale * pinchScale)
    }

    private var effectivePanOffset: CGSize {
        clampedPanOffset(
            CGSize(
                width: panOffset.width + dragTranslation.width,
                height: panOffset.height + dragTranslation.height
            ),
            scale: effectiveZoomScale
        )
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .updating($pinchScale) { value, state, _ in
                state = value
            }
            .onEnded { value in
                setZoomScale(zoomScale * value)
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: zoomScale > 1 ? 0 : .infinity)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                guard zoomScale > 1 else { return }
                panOffset = clampedPanOffset(
                    CGSize(
                        width: panOffset.width + value.translation.width,
                        height: panOffset.height + value.translation.height
                    ),
                    scale: zoomScale
                )
            }
    }

    private func toggleZoom() {
        setZoomScale(zoomScale > 1 ? 1 : 2.5)
    }

    private func setZoomScale(_ scale: CGFloat) {
        zoomScale = clampedZoomScale(scale)
        if zoomScale == 1 {
            panOffset = .zero
        } else {
            panOffset = clampedPanOffset(panOffset, scale: zoomScale)
        }
    }

    private func resetZoom() {
        zoomScale = 1
        panOffset = .zero
    }

    private func clampedZoomScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, 1), Self.maximumZoomScale)
    }

    private func clampedPanOffset(_ offset: CGSize, scale: CGFloat) -> CGSize {
        guard let imageSize else { return .zero }
        let fittedImageSize = fittedSize(for: imageSize)
        let maximumX = max((fittedImageSize.width * scale - availableSize.width) / 2, 0)
        let maximumY = max((fittedImageSize.height * scale - availableSize.height) / 2, 0)
        return CGSize(
            width: min(max(offset.width, -maximumX), maximumX),
            height: min(max(offset.height, -maximumY), maximumY)
        )
    }

    private func updateImageSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        imageSize = size
    }

    private func fittedSize(for imageSize: CGSize) -> CGSize {
        let inset: CGFloat = 18
        let maximumWidth = max(availableSize.width - inset * 2, 1)
        let maximumHeight = max(availableSize.height - inset * 2, 1)
        let scale = min(maximumWidth / imageSize.width, maximumHeight / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}

private struct TaggrImagePagerChrome<TopTrailingContent: View, BottomContent: View>: View {
    let currentIndex: Int
    let total: Int
    let countLabel: (Int, Int) -> String
    let close: () -> Void
    let topTrailingContent: () -> TopTrailingContent
    let bottomContent: () -> BottomContent

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Close image", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .font(.body.bold())
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.55))
                    .clipShape(.circle)
                Spacer()
                if total > 1 {
                    Button(action: close) {
                        Text(countLabel(currentIndex, total))
                            .font(.footnote.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(Color.black.opacity(0.55))
                            .clipShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close image viewer")
                }
                Spacer()
                topTrailingContent()
                    .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            Spacer()

            Button(action: close) {
                bottomContent()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close image viewer")
        }
    }
}
