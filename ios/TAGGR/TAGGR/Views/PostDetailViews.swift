import SwiftUI

struct PostDetailView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var selectedMode = TaggrFeedMode.hot

    var body: some View {
        ZStack {
            TaggrTheme.background.ignoresSafeArea()
            TopSafeAreaFill(color: TaggrTheme.panel)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    FeedHeader(selectedMode: selectedMode, changeMode: changeMode, backAction: nil)
                    if let focusedPost = state.focusedPost {
                        let posts = state.feed.isEmpty ? [focusedPost] : state.feed
                        ForEach(posts) { post in
                            if post.parent == nil {
                                PostRow(post: post) {
                                    state.navigateToPost(post.id)
                                }
                            } else {
                                ReplyPostRow(post: post) {
                                    state.navigateToPost(post.id)
                                }
                            }
                        }
                    } else {
                        EmptyPostDetailView()
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .taggrInlineNavigationChrome()
        .onAppear {
            selectedMode = state.returnFeedMode
        }
        .onChange(of: state.returnFeedMode) { _, mode in
            selectedMode = mode
        }
        .taggrRefreshable()
        .taggrBusyOverlay(state.isBusy)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TaggrBackToolbarButton(title: state.postReturnTitle) {
                    state.navigateBackFromPost()
                }
            }
        }
    }

    private func changeMode(_ mode: TaggrFeedMode) {
        selectedMode = mode
        state.navigateToFeed(mode)
    }
}

private struct EmptyPostDetailView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Post not found")
                .font(.headline)
                .foregroundStyle(TaggrTheme.text)
            Text("Pull to refresh or return to the timeline.")
                .font(.subheadline)
                .foregroundStyle(TaggrTheme.secondaryText)
        }
        .padding(16)
    }
}
