// TAGGR/Views: Read-only photo browser for images attached to a user's public posts.
// Uses existing user_posts queries so profile and account entry points share one flow.
import SwiftUI

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
                        ForEach(displayGroups) { group in
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
            AccountImagePagerView(images: displayImages, selectedImage: image)
        }
    }

    private var displayGroups: [TaggrAccountImageYearGroup] {
        TaggrAccountImage.yearGroups(from: images.filter { image in
            sourcePosts[image.postId].map { state.canDisplayPost($0) && $0.contentRestriction(viewerID: state.currentUser?.id) == nil } ?? false
        })
    }

    private var displayImages: [TaggrAccountImage] {
        displayGroups.flatMap(\.images)
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
