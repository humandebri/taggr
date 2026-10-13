// TAGGR/Views: Read-only photo browser for images attached to a user's public posts.
// Uses existing user_posts queries so profile and account entry points share one flow.
import SwiftUI

struct AccountPhotoPreviewCard: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var images: [TaggrAccountImage] = []
    @State private var sourcePosts: [Int: TaggrPost] = [:]
    @State private var selectedImage: TaggrAccountImage?
    @State private var page = 0
    @State private var pagingOffset = 0
    @State private var loading = false
    @State private var reachedEnd = false
    @State private var errorMessage: String?

    let handle: String

    private let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 3), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Photos")
                .font(.caption.bold())
                .foregroundStyle(TaggrTheme.secondaryText)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 12) {
                if loading && visibleImages.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 96)
                } else if visibleImages.isEmpty {
                    Label("No posted images", systemImage: "photo.on.rectangle")
                        .font(.subheadline)
                        .foregroundStyle(TaggrTheme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 96)
                } else {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(visibleImages) { image in
                            TaggrAccountImageThumbnail(
                                image: image,
                                accessibilityLabel: "Open image from post \(image.postId)"
                            ) {
                                selectedImage = image
                            }
                        }
                    }
                    Button("Show more", systemImage: "photo.on.rectangle.angled") {
                        state.route = .userPhotos(handle)
                    }
                    .font(.subheadline.bold())
                    .frame(minHeight: 44)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Button("Retry", systemImage: "arrow.clockwise") {
                        Task { await reload() }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TaggrTheme.panel)
            .clipShape(.rect(cornerRadius: 8))
        }
        .task(id: handle) {
            await reload()
        }
        .fullScreenCover(item: $selectedImage) { image in
            AccountImagePagerView(images: visibleImages, selectedImage: image)
        }
    }

    private var visibleImages: [TaggrAccountImage] {
        let visible = images.filter { image in
            sourcePosts[image.postId].map {
                state.canDisplayPost($0) && $0.contentRestriction(viewerID: state.currentUser?.id) == nil
            } ?? false
        }
        return Array(visible.prefix(TaggrAccountImagePaging.previewLimit))
    }

    private func reload() async {
        images = []
        sourcePosts = [:]
        selectedImage = nil
        page = 0
        pagingOffset = 0
        reachedEnd = false
        errorMessage = nil
        await loadPreview()
    }

    private func loadPreview() async {
        guard !loading, !handle.isEmpty else { return }
        loading = true
        defer { loading = false }

        do {
            while TaggrAccountImagePaging.shouldContinueLoadingPreview(
                visibleImageCount: visibleImages.count,
                reachedEnd: reachedEnd
            ) {
                let requestOffset = page == 0 ? 0 : pagingOffset
                let posts = try await state.loadUserPosts(handle: handle, page: page, offset: requestOffset)
                try Task.checkCancellation()
                let result = TaggrAccountImagePaging.append(
                    posts: posts,
                    to: images,
                    page: page,
                    pagingOffset: pagingOffset
                )
                for post in posts { sourcePosts[post.id] = post }
                images = result.images
                page = result.page
                pagingOffset = result.pagingOffset
                reachedEnd = result.reachedEnd
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct UserImageLibraryView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var images: [TaggrAccountImage] = []
    @State private var sourcePosts: [Int: TaggrPost] = [:]
    @State private var selectedImage: TaggrAccountImage?
    @State private var page = 0
    @State private var pagingOffset = 0
    @State private var loading = false
    @State private var reachedEnd = false

    let handle: String
    let title: String
    let backRoute: TaggrRoute

    private let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 3), count: 3)

    var body: some View {
        let groups = displayGroups
        ZStack {
            TaggrTheme.background.ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if images.isEmpty && !loading && reachedEnd {
                        ContentUnavailableView(
                            "No posted images",
                            systemImage: "photo.on.rectangle",
                            description: Text("Images attached to posts will appear here.")
                        )
                        .foregroundStyle(TaggrTheme.secondaryText)
                        .padding(.top, 80)
                    } else {
                        ForEach(groups) { group in
                            UserImageYearSection(
                                group: group,
                                columns: columns,
                                selectedImage: $selectedImage
                            )
                        }
                        if !reachedEnd {
                            TaggrLoadMoreView(loading: loading) {
                                Task { await loadNextPage() }
                            }
                        }
                    }
                }
                .padding(.horizontal, 3)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .taggrRefreshable {
                await reloadImages()
            }
        }
        .navigationTitle(title)
        .taggrInlineNavigationChrome()
        .taggrBusyOverlay(loading && images.isEmpty)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TaggrBackToolbarButton(title: "Profile") {
                    state.route = backRoute
                }
            }
        }
        .task(id: handle) {
            await reloadImages()
        }
        .fullScreenCover(item: $selectedImage) { image in
            AccountImagePagerView(images: groups.flatMap(\.images), selectedImage: image)
        }
    }

    private var displayGroups: [TaggrAccountImageYearGroup] {
        TaggrAccountImage.yearGroups(from: images.filter { image in
            sourcePosts[image.postId].map { state.canDisplayPost($0) && $0.contentRestriction(viewerID: state.currentUser?.id) == nil } ?? false
        })
    }

    private func reloadImages() async {
        resetPaging()
        await loadNextPage()
    }

    private func loadNextPage() async {
        guard !loading, !reachedEnd, !handle.isEmpty else { return }
        loading = true
        defer { loading = false }

        do {
            var shouldLoadAnotherPage = true
            while shouldLoadAnotherPage {
                let previousImageCount = images.count
                let requestOffset = page == 0 ? 0 : pagingOffset
                let posts = try await state.loadUserPosts(
                    handle: handle,
                    page: page,
                    offset: requestOffset
                )
                let result = TaggrAccountImagePaging.append(
                    posts: posts,
                    to: images,
                    page: page,
                    pagingOffset: pagingOffset
                )
                for post in posts { sourcePosts[post.id] = post }
                images = result.images
                page = result.page
                pagingOffset = result.pagingOffset
                reachedEnd = result.reachedEnd
                shouldLoadAnotherPage = TaggrAccountImagePaging.shouldContinueLoading(
                    previousImageCount: previousImageCount,
                    result: result
                )
            }
        } catch {
            guard !state.isCancellation(error) else { return }
            state.errorMessage = error.localizedDescription
            reachedEnd = true
        }
    }

    private func resetPaging() {
        images = []
        selectedImage = nil
        page = 0
        pagingOffset = 0
        loading = false
        reachedEnd = false
    }
}

private struct UserImageYearSection: View {
    let group: TaggrAccountImageYearGroup
    let columns: [GridItem]
    @Binding var selectedImage: TaggrAccountImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(group.year))
                .font(.largeTitle.bold())
                .foregroundStyle(TaggrTheme.text)
                .padding(.horizontal, 13)
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(group.images) { image in
                    TaggrAccountImageThumbnail(
                        image: image,
                        accessibilityLabel: "Open image from post \(image.postId)"
                    ) {
                        selectedImage = image
                    }
                }
            }
        }
    }
}
