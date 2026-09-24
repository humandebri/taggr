import SwiftUI

struct PostDetailView: View {
    /// `.post` mirrors the PWA post page: a root post keeps its replies below it,
    /// while a reply opens inside its ancestor thread;
    /// `.thread` always shows the ancestor chain with the post last.
    enum Mode {
        case post
        case thread
    }

    @Environment(TaggrAppCoordinator.self) private var state
    @State private var selectedMode = TaggrFeedMode.hot
    var mode: Mode = .post

    var body: some View {
        ZStack {
            TaggrTheme.background.ignoresSafeArea()
            TopSafeAreaFill(color: TaggrTheme.panel)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    FeedHeader(selectedMode: selectedMode, changeMode: changeMode, backAction: nil)
                    if let focusedPost = state.focusedPost {
                        // A reply arrives with its ancestor chain loaded, so the Post route
                        // starts in the thread state instead of offering an entry into it.
                        let threadLayout = mode == .thread || state.postThread.count > 1
                        let posts = threadLayout
                            ? (state.postThread.isEmpty ? [focusedPost] : state.postThread)
                            : [focusedPost]
                        // Every thread post is drawn as its own row below, so an expanded
                        // reply list must skip it instead of drawing the post twice.
                        let threadPostIDs = Set(posts.map(\.id))
                        ForEach(posts) { post in
                            if !threadLayout {
                                PostRow(
                                    post: post,
                                    isDetail: true,
                                    startsWithRepliesExpanded: true
                                ) {
                                    state.navigateToPost(post.id)
                                }
                            } else if post.parent == nil {
                                PostRow(
                                    post: post,
                                    isDetail: post.id == focusedPost.id,
                                    hiddenReplyIDs: threadPostIDs
                                ) {
                                    state.navigateToPost(post.id)
                                }
                            } else {
                                ReplyPostRow(
                                    post: post,
                                    isDetail: post.id == focusedPost.id,
                                    hiddenReplyIDs: threadPostIDs
                                ) {
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
