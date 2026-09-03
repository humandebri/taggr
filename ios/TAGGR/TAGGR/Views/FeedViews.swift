import PhotosUI
import SwiftUI
@preconcurrency import Translation

enum TimelineLayout {
    static let rowHorizontalPadding: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 14
}

struct FeedView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @StateObject private var imagePrefetcher = PostImagePrefetcher()
    @State private var selectedMode = TaggrFeedMode.hot
    @State private var showingComposer = false
    let scrollToTopRevision: Int

    init(scrollToTopRevision: Int = 0) {
        self.scrollToTopRevision = scrollToTopRevision
    }

    var body: some View {
        ZStack {
            TaggrTheme.background.ignoresSafeArea()
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        FeedHeader(
                            selectedMode: selectedMode,
                            changeMode: changeMode,
                            backAction: selectedMode.isFiltered ? { changeMode(.hot) } : nil
                        )
                        .id(FeedScrollAnchor.top)
                        if state.feed.isEmpty {
                            EmptyFeedView()
                        } else {
                            ForEach(state.feed) { post in
                                PostRow(post: post, onVisible: {
                                    prefetchVisibleResources(around: post)
                                }) {
                                    state.navigateToPost(post.id, from: selectedMode)
                                }
                            }
                            if state.canLoadMoreFeed {
                                TaggrLoadMoreView(loading: state.isLoadingMoreFeed) {
                                    Task { await state.loadMoreFeed(mode: selectedMode) }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: scrollToTopRevision) { _, _ in
                    withAnimation {
                        scrollProxy.scrollTo(FeedScrollAnchor.top, anchor: .top)
                    }
                }
            }
            if state.authSession != nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            Task { await openComposerOrAccountSetup() }
                        } label: {
                            Image(systemName: state.currentUser == nil ? "person.badge.plus" : "square.and.pencil")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(TaggrTheme.accentText)
                                .frame(width: 56, height: 56)
                                .background(TaggrTheme.accent)
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                        }
                        .accessibilityLabel(state.currentUser == nil ? "Create TAGGR user" : "Post")
                        .padding(.trailing, 18)
                        .padding(.bottom, 18)
                    }
                }
            }
        }
        .taggrInlineNavigationChrome()
        .onAppear(perform: syncSelectedModeWithRoute)
        .task(id: state.authSession?.principal) {
            await refreshCurrentUserIfNeeded()
        }
        .onChange(of: state.route) { _, _ in
            syncSelectedModeWithRoute()
        }
        .taggrRefreshable()
        .taggrBusyOverlay(Self.showsBusyOverlay(isBusy: state.isBusy, isLoadingMore: state.isLoadingMoreFeed))
        .fullScreenCover(isPresented: $showingComposer) {
            ComposePostView(
                mode: .newPost(selectedMode: selectedMode),
                initialRealm: state.initialPostingRealm(for: selectedMode)
            ) {
                showingComposer = false
            }
                .environment(state)
        }
    }

    func changeMode(_ mode: TaggrFeedMode) {
        selectedMode = mode
        state.navigateToFeed(mode)
    }

    func syncSelectedModeWithRoute() {
        guard let mode = Self.feedMode(from: state.route) else { return }
        selectedMode = mode
    }

    func refreshCurrentUserIfNeeded() async {
        guard state.authSession != nil, state.currentUser == nil else { return }
        await state.refreshCurrentUser()
    }

    func openComposerOrAccountSetup() async {
        await refreshCurrentUserIfNeeded()
        if state.currentUser == nil {
            state.route = .settings
        } else {
            showingComposer = true
        }
    }

    static func showsBusyOverlay(isBusy: Bool, isLoadingMore: Bool) -> Bool {
        isBusy && !isLoadingMore
    }

    static func feedMode(from route: TaggrRoute) -> TaggrFeedMode? {
        guard case .feed(let mode) = route else { return nil }
        return mode
    }

    func prefetchVisibleResources(around post: TaggrPost) {
        let attachments = FeedImagePrefetchPolicy.attachments(
            in: state.feed,
            around: post,
            currentUserId: state.currentUser?.id,
            config: state.runtimeConfig
        )
        imagePrefetcher.prefetch(attachments, api: state.api, config: state.runtimeConfig)
    }
}

private enum FeedScrollAnchor: Hashable {
    case top
}

extension TaggrFeedMode {
    var isFiltered: Bool {
        guard case .tags = self else { return false }
        return true
    }
}

enum FeedImagePrefetchPolicy {
    static let lookAheadPostCount = 6

    @MainActor
    static func attachments(
        in posts: [TaggrPost],
        around post: TaggrPost,
        currentUserId: Int?,
        config: TaggrRuntimeConfig = .current
    ) -> [TaggrPostImageAttachment] {
        guard let index = posts.firstIndex(where: { $0.id == post.id }) else { return [] }
        let end = min(posts.count, index + lookAheadPostCount + 1)
        return posts[index..<end].flatMap { candidate -> [TaggrPostImageAttachment] in
            guard candidate.contentRestriction(viewerID: currentUserId) == nil else { return [] }
            let attachments = TaggrPostPresentationCache.attachments(
                for: candidate,
                config: config,
                bodyText: candidate.timelineBody
            )
            let visibleCount = PostImageGrid.visibleCount(for: attachments.count)
            return Array(attachments.prefix(visibleCount))
        }
    }

}

@MainActor
enum TaggrPostPresentationCache {
    private final class AttachmentBox: NSObject {
        let values: [TaggrPostImageAttachment]

        init(_ values: [TaggrPostImageAttachment]) {
            self.values = values
        }
    }

    private static let attachmentCache: NSCache<NSString, AttachmentBox> = {
        let cache = NSCache<NSString, AttachmentBox>()
        cache.countLimit = 500
        return cache
    }()

    static func attachments(
        for post: TaggrPost,
        config: TaggrRuntimeConfig = .current,
        bodyText: String
    ) -> [TaggrPostImageAttachment] {
        let fileKey = post.files.keys.sorted().map { key in
            "\(key):\(post.files[key, default: []].map(\.value).map(String.init).joined(separator: ","))"
        }.joined(separator: "|")
        let key = "\(post.id)|\(config.canisterId)|\(config.apiBaseURL)|\(bodyText)|\(fileKey)" as NSString
        if let cached = attachmentCache.object(forKey: key) {
            return cached.values
        }
        let attachments = post.imageAttachments(config: config, bodyText: bodyText)
        attachmentCache.setObject(AttachmentBox(attachments), forKey: key)
        return attachments
    }
}

struct FeedHeader: View {
    let selectedMode: TaggrFeedMode
    let changeMode: (TaggrFeedMode) -> Void
    let backAction: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if let backAction {
                Button("Feed", systemImage: "chevron.left", action: backAction)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(TaggrTheme.clickable)
                    .frame(width: 34, height: 34)
                    .background(TaggrTheme.panelRaised)
                    .clipShape(Circle())
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Back to feed")
            }
            TaggrHashIconView(size: 34, cornerRadius: 8)
            Text(Self.title(for: selectedMode))
                .font(.headline.weight(.black))
                .foregroundStyle(TaggrTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .layoutPriority(1)
            Spacer(minLength: 2)
            if !selectedMode.isFiltered {
                HStack(spacing: 4) {
                    ChannelPill(title: "#hot", selected: selectedMode == .hot) { changeMode(.hot) }
                    ChannelPill(title: "#latest", selected: selectedMode == .latest) { changeMode(.latest) }
                    ChannelPill(title: "#personal", selected: selectedMode == .personal) { changeMode(.personal) }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(TaggrTheme.panel)
    }

    static func title(for mode: TaggrFeedMode) -> String {
        guard case .tags(let tokens) = mode else { return "TAGGR" }
        let title = tokens.map { token in
            token.hasPrefix("@") ? token : "#\(token)"
        }.joined(separator: "+")
        return title.isEmpty ? "TAGGR" : title
    }
}

struct ChannelPill: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(selected ? TaggrTheme.accentText : TaggrTheme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(selected ? TaggrTheme.accent : TaggrTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }
}

struct TaggrHashIconView: View {
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Image("TaggrHashIcon")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

struct EmptyFeedView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No posts")
                .font(.headline)
                .foregroundStyle(TaggrTheme.text)
            Text("Pull to refresh or switch channels.")
                .font(.subheadline)
                .foregroundStyle(TaggrTheme.secondaryText)
        }
        .padding(16)
    }
}

struct PostRow: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let post: TaggrPost
    let open: () -> Void
    let onVisible: () -> Void
    @State private var previewImage: TaggrPostImageAttachment?
    @State private var repliesExpanded = false
    @State private var revealSensitive = false
    @State private var showFullBody = false
    @State private var translatedDisplayBody: String?
    @State private var isTranslating = false
    @State private var translationError: String?
    @State private var translationRequestID = 0

    init(post: TaggrPost, onVisible: @escaping () -> Void = {}, open: @escaping () -> Void) {
        self.post = post
        self.onVisible = onVisible
        self.open = open
    }

    @ViewBuilder
    var postBodyText: some View {
        let text = TaggrPostBodyView(
            text: visibleDisplayBody,
            maximumLines: isDetail ? nil : 10
        )
            .font(.body)
            .foregroundStyle(TaggrTheme.text)
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        if TaggrPostBodyView.containsInteractiveLink(in: visibleDisplayBody) {
            text
        } else {
            text
                .contentShape(Rectangle())
                .onTapGesture(perform: open)
                .accessibilityAddTraits(.isButton)
        }
    }

    @ViewBuilder
    var inlineTranslationView: some View {
        if let translatedDisplayBody {
            VStack(alignment: .leading, spacing: 4) {
                Text("Translated")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(TaggrTheme.clickable)
                TaggrMarkdownText(text: translatedDisplayBody)
                    .font(.subheadline)
                    .foregroundStyle(TaggrTheme.secondaryText)
                    .lineSpacing(2)
                    .lineLimit(nil)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
        } else if let translationError {
            Text(translationError)
                .font(.caption.weight(.semibold))
                .foregroundStyle(TaggrTheme.secondaryText)
        }
    }

    var body: some View {
        if #available(iOS 18.0, *) {
            postRowContent
                .modifier(InlinePostTranslationTask(
                    sourceText: visibleDisplayBody,
                    requestID: translationRequestID,
                    translatedText: $translatedDisplayBody,
                    isTranslating: $isTranslating,
                    errorMessage: $translationError
                ))
        } else {
            postRowContent
        }
    }

    var postRowContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: openAuthorProfile) {
                        Text(authorLabel)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(TaggrTheme.clickable)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .buttonStyle(.plain)
                    PostTimestampLabel(timestamp: post.timestamp)
                    Spacer(minLength: 8)
                    if let realm = post.realm, !realm.isEmpty {
                        Button {
                            openRealm(realm)
                        } label: {
                            PostRealmBadge(name: realm, colorHex: post.meta.realmColor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open realm \(realm)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let notice = safetyNotice {
                    PostSafetyNotice(notice: notice) {
                        revealSensitive = true
                    }
                } else {
                    if !visibleDisplayBody.isEmpty {
                        postBodyText
                        inlineTranslationView
                    }
                    if isShortened {
                        Button(action: showFullPost) {
                            Label("Show full post", systemImage: "chevron.down")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(TaggrTheme.clickable)
                        }
                        .buttonStyle(.plain)
                    }
                    let attachments = TaggrPostPresentationCache.attachments(
                        for: post,
                        config: state.runtimeConfig,
                        bodyText: visibleRawBody
                    )
                    if !attachments.isEmpty {
                        PostImageGridView(attachments: attachments) { attachment in
                            previewImage = attachment
                        }
                    }
                    PostExtensionView(post: post)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TimelineLayout.rowHorizontalPadding)
            .padding(.top, TimelineLayout.rowVerticalPadding)
            postEngagementBar
                .padding(.horizontal, TimelineLayout.rowHorizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, TimelineLayout.rowVerticalPadding)
            if repliesExpanded {
                PostRepliesAccordion(parent: post)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(TaggrTheme.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TaggrTheme.panelRaised.opacity(0.8))
                .frame(height: 1)
        }
        .fullScreenCover(item: $previewImage) { attachment in
            PostImagePreview(
                attachments: TaggrPostPresentationCache.attachments(
                    for: post,
                    config: state.runtimeConfig,
                    bodyText: visibleRawBody
                ),
                selected: attachment
            )
        }
        .onAppear(perform: onVisible)
        .onChange(of: visibleDisplayBody) { _, _ in
            resetTranslation()
        }
    }

    var rawBody: String {
        post.effectiveBody
    }

    var visibleRawBody: String {
        isDetail || showFullBody ? rawBody : post.timelineBody
    }

    var visibleDisplayBody: String {
        TaggrPostImages.textWithoutImageMarkdown(visibleRawBody)
    }

    var postEngagementBar: some View {
        PostEngagementBar(
            post: post,
            canTranslate: !visibleDisplayBody.isEmpty,
            isTranslated: translatedDisplayBody != nil,
            isTranslating: isTranslating,
            toggleTranslation: toggleTranslation,
            repliesExpanded: repliesExpanded,
            toggleReplies: toggleReplies
        )
    }

    var isShortened: Bool {
        !isDetail && !showFullBody && rawBody.contains(TaggrPost.timelineCutMarker)
    }

    var isDetail: Bool {
        if case .post(let id) = state.route {
            return id == post.id
        }
        return false
    }

    var safetyNotice: PostSafetyNoticeModel? {
        guard let restriction = post.contentRestriction(viewerID: state.currentUser?.id) else {
            return nil
        }
        if restriction.isRevealable && revealSensitive {
            return nil
        }
        switch restriction {
        case .encrypted:
            return PostSafetyNoticeModel(title: "Encrypted", detail: "This post is encrypted and cannot be rendered in this build.", actionTitle: nil)
        case .moderated:
            return PostSafetyNoticeModel(title: "Hidden by moderation", detail: "This post reached the downvote threshold.", actionTitle: nil)
        case .deleted(let hashes):
            return PostSafetyNoticeModel(title: "Post deleted", detail: hashes.map { String($0.prefix(16)) }.joined(separator: "\n"), actionTitle: nil)
        case .hidden:
            return PostSafetyNoticeModel(title: "Hidden", detail: "You hid this post.", actionTitle: "Show")
        case .nsfw:
            return PostSafetyNoticeModel(title: "NSFW", detail: "This post is marked as sensitive.", actionTitle: "Show")
        }
    }

    var replyCount: Int {
        post.replyCount
    }

    var authorLabel: String {
        state.authorDisplayName(for: post)
    }

    func toggleReplies() {
        guard replyCount > 0 else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            repliesExpanded.toggle()
        }
        if repliesExpanded {
            Task { await state.loadReplies(for: post) }
        }
    }

    func showFullPost() {
        showFullBody = true
        resetTranslation()
    }

    func toggleTranslation() {
        if translatedDisplayBody != nil {
            resetTranslation()
            return
        }
        translationError = nil
        isTranslating = true
        translationRequestID += 1
    }

    func resetTranslation() {
        translationRequestID = 0
        translatedDisplayBody = nil
        isTranslating = false
        translationError = nil
    }

    func openAuthorProfile() {
        let handle = state.authorProfileHandle(for: post) ?? "\(post.user)"
        state.navigateToProfile(handle)
    }

    func openRealm(_ realm: String) {
        state.navigateToRealm(realm)
    }
}

struct ReplyPostRow: View {
    let post: TaggrPost
    let open: () -> Void

    var body: some View {
        PostRow(post: post, open: open)
            .padding(.leading, 24)
    }
}

@available(iOS 18.0, *)
struct InlinePostTranslationTask: ViewModifier {
    let sourceText: String
    let requestID: Int
    @Binding var translatedText: String?
    @Binding var isTranslating: Bool
    @Binding var errorMessage: String?
    @State private var configuration: TranslationSession.Configuration?
    @State private var handledRequestID = 0
    @State private var activeRequestID = 0
    @State private var activeSourceText = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: requestID, initial: true) { _, newRequestID in
                guard newRequestID > 0 else {
                    activeRequestID = 0
                    activeSourceText = ""
                    configuration = nil
                    handledRequestID = 0
                    return
                }
                guard newRequestID != handledRequestID else { return }
                handledRequestID = newRequestID
                startTranslation()
            }
            .translationTask(configuration) { session in
                await translate(using: session)
            }
    }

    func startTranslation() {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            isTranslating = false
            return
        }
        translatedText = nil
        errorMessage = nil
        isTranslating = true
        activeRequestID = requestID
        activeSourceText = text
        if configuration == nil {
            configuration = TranslationSession.Configuration(source: nil, target: nil)
        } else {
            configuration?.invalidate()
        }
    }

    func translate(using session: TranslationSession) async {
        let requestID = activeRequestID
        let text = activeSourceText
        do {
            let response = try await session.translate(text)
            guard activeRequestID == requestID, activeSourceText == text else { return }
            translatedText = response.targetText
            errorMessage = nil
        } catch {
            guard activeRequestID == requestID, activeSourceText == text else { return }
            translatedText = nil
            errorMessage = "Translation unavailable"
        }
        isTranslating = false
    }
}

struct PostTimestampLabel: View {
    let timestamp: LosslessInt

    var body: some View {
        TimelineView(.periodic(from: .now, by: TaggrRelativeTime.refreshInterval(from: timestamp))) { context in
            Text(TaggrRelativeTime.string(from: timestamp, now: context.date))
                .font(.caption.weight(.semibold))
                .foregroundStyle(TaggrTheme.secondaryText)
                .lineLimit(1)
        }
        .accessibilityLabel(TaggrRelativeTime.string(from: timestamp))
    }
}

struct PostRealmBadge: View {
    let name: String
    let colorHex: String?

    var body: some View {
        Text("#\(name.lowercased())")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    var background: Color {
        Color(hex: colorHex) ?? TaggrTheme.panelRaised
    }
}

struct PostSafetyNoticeModel {
    let title: String
    let detail: String
    let actionTitle: String?
}

struct PostSafetyNotice: View {
    let notice: PostSafetyNoticeModel
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(notice.title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(TaggrTheme.text)
            Text(notice.detail)
                .font(.caption)
                .foregroundStyle(TaggrTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle = notice.actionTitle {
                Button(actionTitle, action: action)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TaggrTheme.clickable)
                    .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TaggrTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct PostExtensionView: View {
    let post: TaggrPost

    var body: some View {
        switch post.extensionKind {
        case .poll(let poll):
            PollExtensionView(post: post, poll: poll)
        case .repost(let id):
            RepostExtensionView(postId: id)
        case .proposal(let id):
            ProposalExtensionView(postId: post.id, proposalId: id)
        case .feature, .none:
            EmptyView()
        case .unknown:
            CompactNoticeView(title: "Unsupported extension", systemImage: "questionmark.square.dashed")
        }
    }
}

struct PollExtensionView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let post: TaggrPost
    let poll: TaggrPoll
    @State private var selectedOption: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Poll", systemImage: "chart.bar.xaxis")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TaggrTheme.secondaryText)
                Spacer()
                Text(totalVotes == 1 ? "1 vote" : "\(totalVotes) votes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TaggrTheme.secondaryText)
            }
            ForEach(Array(poll.options.enumerated()), id: \.offset) { index, option in
                PollOptionRow(
                    title: option,
                    votes: poll.votes[index]?.count ?? 0,
                    total: totalVotes,
                    selected: selectedOption == index,
                    selectable: canVote
                ) {
                    guard canVote else { return }
                    selectedOption = index
                }
            }
            if canVote {
                HStack(spacing: 10) {
                    Button("Vote") {
                        vote(anonymously: false)
                    }
                    .disabled(selectedOption == nil)
                    Button("Vote anonymously") {
                        vote(anonymously: true)
                    }
                    .disabled(selectedOption == nil)
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(TaggrTheme.clickable)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TaggrTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    var totalVotes: Int {
        poll.votes.values.reduce(0) { $0 + $1.count }
    }

    var canVote: Bool {
        guard let userId = state.currentUser?.id else { return false }
        if poll.deadline > 0, Date().timeIntervalSince1970 > Double(poll.deadline) {
            return false
        }
        if !poll.voters.contains(userId) {
            return true
        }
        let revoteHours = state.cache?.config?.pollRevoteDeadlineHours ?? 0
        guard revoteHours > 0 else { return false }
        let postAgeSeconds = Date().timeIntervalSince1970 - (Double(post.timestamp.value) / 1_000_000_000)
        return postAgeSeconds <= Double(revoteHours * 3600)
    }

    func vote(anonymously: Bool) {
        guard let selectedOption else { return }
        Task { await state.voteOnPoll(postId: post.id, option: selectedOption, anonymously: anonymously) }
    }
}

struct PollOptionRow: View {
    let title: String
    let votes: Int
    let total: Int
    let selected: Bool
    let selectable: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TaggrTheme.text)
                        .lineLimit(2)
                    Spacer()
                    Text("\(percentage)%")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(TaggrTheme.secondaryText)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(TaggrTheme.panelRaised)
                        Capsule()
                            .fill(selected ? TaggrTheme.accent : TaggrTheme.secondaryText.opacity(0.55))
                            .frame(width: geometry.size.width * CGFloat(percentage) / 100)
                    }
                }
                .frame(height: 6)
            }
            .padding(10)
            .background(selected ? TaggrTheme.accent.opacity(0.22) : TaggrTheme.panelRaised.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
    }

    var percentage: Int {
        guard total > 0 else { return 0 }
        return Int((Double(votes) / Double(total) * 100).rounded())
    }
}

struct RepostExtensionView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let postId: Int
    @State private var embeddedPost: TaggrPost?

    var body: some View {
        Group {
            if let embeddedPost {
                Button {
                    state.navigateToPost(embeddedPost.id)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Repost", systemImage: "arrow.2.squarepath")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(TaggrTheme.secondaryText)
                        Text(embeddedPost.meta.authorName ?? "@\(embeddedPost.user)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(TaggrTheme.clickable)
                        TaggrPostBodyView(text: embeddedPost.displayBody, maximumLines: 4)
                            .font(.subheadline)
                            .foregroundStyle(TaggrTheme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TaggrTheme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            } else {
                CompactNoticeView(title: "Loading repost", systemImage: "arrow.2.squarepath")
                    .task(id: postId) {
                        embeddedPost = await state.loadEmbeddedPost(postId)
                    }
            }
        }
    }
}

struct ProposalExtensionView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let postId: Int
    let proposalId: Int

    var body: some View {
        Button {
            state.navigateToPost(postId)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checklist")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(TaggrTheme.clickable)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Proposal")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(TaggrTheme.text)
                    Text("#\(proposalId)")
                        .font(.caption)
                        .foregroundStyle(TaggrTheme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(TaggrTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

struct YouTubePreviewView: View {
    let preview: TaggrYouTubePreview

    var body: some View {
        YouTubeEmbedView(preview: preview)
    }
}

struct TaggrYouTubePreview: Identifiable {
    let id: String
    let url: URL
    private final class PreviewBox: NSObject {
        let values: [TaggrYouTubePreview]

        init(_ values: [TaggrYouTubePreview]) {
            self.values = values
        }
    }

    private static let expression: NSRegularExpression = {
        do {
            return try NSRegularExpression(
                pattern: #"(https?://(?:www\.)?(?:youtube\.com/watch\?[^ \n\)]*v=|youtu\.be/)([A-Za-z0-9_-]{6,}))"#
            )
        } catch {
            preconditionFailure("Invalid built-in YouTube expression: \(error)")
        }
    }()
    @MainActor private static let previewCache: NSCache<NSString, PreviewBox> = {
        let cache = NSCache<NSString, PreviewBox>()
        cache.countLimit = 500
        return cache
    }()

    var thumbnailURL: URL {
        URL(string: "https://img.youtube.com/vi/\(id)/hqdefault.jpg")!
    }

    @MainActor
    static func previews(in text: String) -> [TaggrYouTubePreview] {
        let key = text as NSString
        if let cached = previewCache.object(forKey: key) {
            return cached.values
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        let previews: [TaggrYouTubePreview] = expression.matches(in: text, range: nsRange).compactMap { match in
            guard let urlRange = Range(match.range(at: 1), in: text),
                  let idRange = Range(match.range(at: 2), in: text),
                  let url = URL(string: String(text[urlRange])) else {
                return nil
            }
            let id = String(text[idRange])
            guard !seen.contains(id) else { return nil }
            seen.insert(id)
            return TaggrYouTubePreview(id: id, url: url)
        }
        previewCache.setObject(PreviewBox(previews), forKey: key)
        return previews
    }
}

struct CompactNoticeView: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.bold))
            .foregroundStyle(TaggrTheme.secondaryText)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TaggrTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct PostRepliesAccordion: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let parent: TaggrPost

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.loadingReplyPostIDs.contains(parent.id) {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                    Text("Loading replies")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TaggrTheme.secondaryText)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .padding(.leading, 46)
            } else if let replies = state.repliesByPostID[parent.id] {
                ForEach(replies) { reply in
                    ReplyPostRow(post: reply) {
                        state.navigateToPost(reply.id)
                    }
                }
            }
        }
    }
}

enum TaggrReactionIcon {
    static let defaultOrder = [11, 10, 50, 51, 52, 53, 100, 12, 1]

    static func emoji(for id: Int) -> String? {
        switch id {
        case 1:
            return "❌"
        case 50:
            return "🔥"
        case 51:
            return "😂"
        case 52:
            return "💯"
        case 53:
            return "🚀"
        case 100:
            return "⭐️"
        case 101:
            return "🏴‍☠️"
        case 10:
            return "❤️"
        case 11:
            return "👍"
        case 12:
            return "😢"
        default:
            return nil
        }
    }
}
