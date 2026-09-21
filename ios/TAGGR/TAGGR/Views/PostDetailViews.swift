import SwiftUI

struct PostDetailView: View {
    /// `.post` mirrors the PWA post page (the post first, its replies below);
    /// `.thread` mirrors the PWA thread page (the ancestor chain, post last).
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
                        let posts = threadPosts(focusedPost: focusedPost)
                        // Every thread post is drawn as its own row below, so an expanded
                        // reply list must skip it instead of drawing the post twice.
                        let threadPostIDs = Set(posts.map(\.id))
                        ForEach(posts) { post in
                            switch mode {
                            case .post:
                                // The PWA post page keeps a `◀ REPLY` link into the ancestor
                                // thread; a reply opened here needs the same way back.
                                if Self.showsThreadEntry(for: post) {
                                    Button {
                                        state.navigateToThread(post.id)
                                    } label: {
                                        Label("Show thread", systemImage: "arrow.turn.up.left")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(TaggrTheme.clickable)
                                            .frame(minHeight: 44, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, TimelineLayout.rowHorizontalPadding)
                                    .accessibilityIdentifier("postThreadEntry")
                                    .accessibilityHint("Opens the whole thread this reply belongs to")
                                }
                                PostRow(
                                    post: post,
                                    isDetail: true,
                                    startsWithRepliesExpanded: true
                                ) {
                                    state.navigateToPost(post.id)
                                }
                            case .thread where post.parent == nil:
                                PostRow(
                                    post: post,
                                    isDetail: post.id == focusedPost.id,
                                    hiddenReplyIDs: threadPostIDs
                                ) {
                                    state.navigateToPost(post.id)
                                }
                            case .thread:
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

    /// A reply opened as a single post keeps the PWA's `◀ REPLY` link into its thread.
    static func showsThreadEntry(for post: TaggrPost) -> Bool {
        post.parent != nil
    }

    private func threadPosts(focusedPost: TaggrPost) -> [TaggrPost] {
        switch mode {
        case .post:
            return [focusedPost]
        case .thread:
            return state.postThread.isEmpty ? [focusedPost] : state.postThread
        }
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
