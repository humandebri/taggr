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
                                    Task {
                                        guard case .feed = state.route else { return }
                                        await state.loadMoreFeed(mode: selectedMode)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onChange(of: selectedMode) { _, _ in
                    scrollProxy.scrollTo(FeedScrollAnchor.top, anchor: .top)
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
            in: state.feed.filter { state.canDisplayPost($0) },
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
            let visibleCount = PostImageGrid.displayedCount(for: attachments.count)
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
    @Environment(TaggrAppCoordinator.self) private var state
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
            Button("Search", systemImage: "magnifyingglass") { state.navigate(to: .search("")) }
                .labelStyle(.iconOnly)
                .frame(minWidth: 30, minHeight: 34)
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
    let isDetail: Bool
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
    @State private var bodyIsTruncated = false

    init(post: TaggrPost, isDetail: Bool = false, onVisible: @escaping () -> Void = {}, open: @escaping () -> Void) {
        self.isDetail = isDetail
        self.post = post
        self.onVisible = onVisible
        self.open = open
    }

    @ViewBuilder
    var postBodyText: some View {
        let text = TaggrPostBodyView(
            text: visibleDisplayBody,
            maximumLines: isDetail || showFullBody ? nil : 10,
            textStyle: .body,
            textColor: TaggrTheme.text,
            lineSpacing: 3,
            accessibilityIdentifier: "post-\(post.id)-body",
            openPost: open,
            onTruncationChange: updateBodyTruncation
        )
            .frame(maxWidth: .infinity, alignment: .leading)
        text
    }

    @ViewBuilder
    var inlineTranslationView: some View {
        if let translatedDisplayBody {
            VStack(alignment: .leading, spacing: 4) {
                Text("Translated")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(TaggrTheme.clickable)
                Text(verbatim: translatedDisplayBody)
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
        if !state.canDisplayPost(post) {
            if isDetail { Text("Post unavailable in the iOS app.").padding() }
        } else if #available(iOS 18.0, *) {
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
                    Button(action: open) {
                        PostTimestampLabel(timestamp: post.timestamp)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Open post from \(TaggrRelativeTime.string(from: post.timestamp))")
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
                UserAttributeBadgesView(
                    badges: TaggrUserBadge.decoded(from: post.meta.authorBadges)
                )
                if let notice = safetyNotice {
                    PostSafetyNotice(notice: notice) {
                        revealSensitive = true
                    }
                } else {
                    if !visibleDisplayBody.isEmpty {
                        postBodyText
                        inlineTranslationView
                    }
                    if !showFullBody, isShortened || bodyIsTruncated {
                        Button(action: showFullPost) {
                            Label("Show full post", systemImage: "chevron.down")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(TaggrTheme.clickable)
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
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
                    PostExtensionView(post: post, isDetail: isDetail, openPost: open)
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
            bodyIsTruncated = false
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
            toggleReplies: toggleReplies,
            showRepliesAfterSubmission: showRepliesAfterSubmission
        )
    }

    var isShortened: Bool {
        !isDetail && !showFullBody && rawBody.contains(TaggrPost.timelineCutMarker)
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
            return PostSafetyNoticeModel(title: "NSFW", detail: "This post is unavailable in the iOS app.", actionTitle: nil)
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

    func showRepliesAfterSubmission() {
        if !repliesExpanded {
            withAnimation(.easeInOut(duration: 0.18)) {
                repliesExpanded = true
            }
        }
        Task { await state.loadReplies(postID: post.id) }
    }

    func showFullPost() {
        showFullBody = true
        bodyIsTruncated = false
        resetTranslation()
    }

    func updateBodyTruncation(_ isTruncated: Bool) {
        guard bodyIsTruncated != isTruncated else { return }
        bodyIsTruncated = isTruncated
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
    var isDetail = false
    let open: () -> Void

    var body: some View {
        PostRow(post: post, isDetail: isDetail, open: open)
            .padding(.leading, 24)
    }
}

@available(iOS 18.0, *)
struct TaggrPostTranslationBatch {
    let lines: [String]
    /// Fenced code is code, not prose: those lines stay verbatim and never reach the session.
    let verbatimLineIndices: Set<Int>
    /// Structural markers are displayed but never sent through translation, so they cannot be dropped.
    let displayPrefixes: [Int: String]

    // Translating the visible text instead of the raw body keeps Markdown syntax and link
    // destinations away from the session, which would otherwise mangle them into stray brackets.
    @MainActor
    init(sourceText: String) {
        let split = Self.splitSourceText(sourceText)
        lines = split.lines
        verbatimLineIndices = split.verbatimLineIndices
        displayPrefixes = split.displayPrefixes
    }

    init(
        lines: [String],
        verbatimLineIndices: Set<Int> = [],
        displayPrefixes: [Int: String] = [:]
    ) {
        self.lines = lines
        self.verbatimLineIndices = verbatimLineIndices
        self.displayPrefixes = displayPrefixes
    }

    var isEmpty: Bool {
        translatableIndices.isEmpty
    }

    var requests: [TranslationSession.Request] {
        translatableIndices.map {
            TranslationSession.Request(sourceText: lines[$0], clientIdentifier: String($0))
        }
    }

    // The translation session joins the segments it is handed, so translating a whole body in one
    // request drops the author's line breaks and paragraph spacing. Translating each display line
    // separately and rejoining them keeps the structure the reader sees in the original post.
    func translatedBody(from responses: [TranslationSession.Response]) -> String? {
        var translations: [Int: String] = [:]
        for response in responses {
            guard let identifier = response.clientIdentifier,
                  let index = Int(identifier),
                  translatableIndices.contains(index),
                  translations[index] == nil else {
                continue
            }
            translations[index] = response.targetText
        }
        guard translations.count == translatableIndices.count else { return nil }
        return lines.indices.map {
            displayPrefixes[$0, default: ""] + (translations[$0] ?? lines[$0])
        }.joined(separator: "\n")
    }

    private var translatableIndices: [Int] {
        lines.indices.filter {
            !verbatimLineIndices.contains($0) && !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Splits the body into display lines, resolving Markdown per paragraph and keeping fenced code
    /// verbatim. Resolving the whole body in one pass flattens the author's structure (the renderer
    /// carries block breaks as intents, not newlines), while resolving one line at a time leaves
    /// syntax from multi-line constructs (`**bold`, links) inside the text sent to the session.
    @MainActor
    private static func splitSourceText(
        _ text: String
    ) -> (lines: [String], verbatimLineIndices: Set<Int>, displayPrefixes: [Int: String]) {
        var lines: [String] = []
        var verbatimLineIndices: Set<Int> = []
        var displayPrefixes: [Int: String] = [:]
        var paragraph: [String] = []
        var fencedMarker: (character: Character, length: Int)?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let resolved = TaggrInteractiveMarkdownText.translationText(
                from: paragraph.joined(separator: "\n")
            )
            for resolvedLine in resolved.components(separatedBy: "\n") {
                let split = structuralPrefixAndText(from: resolvedLine)
                if !split.prefix.isEmpty { displayPrefixes[lines.count] = split.prefix }
                lines.append(split.text)
            }
            paragraph.removeAll(keepingCapacity: true)
        }

        for line in displayLines(from: text) {
            if let marker = fencedMarker {
                if TaggrPostBodyParser.isClosingFence(line, for: marker) {
                    fencedMarker = nil
                } else {
                    verbatimLineIndices.insert(lines.count)
                    lines.append(line)
                }
                continue
            }
            if let marker = TaggrPostBodyParser.openingFenceMarker(in: line) {
                flushParagraph()
                fencedMarker = marker
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                lines.append("")
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return (lines, verbatimLineIndices, displayPrefixes)
    }

    private static func structuralPrefixAndText(from line: String) -> (prefix: String, text: String) {
        var remainder = line[...]
        var prefix = ""
        while remainder.hasPrefix("│ ") {
            prefix += "│ "
            remainder.removeFirst(2)
        }
        if remainder.hasPrefix("• ") {
            prefix += "• "
            remainder.removeFirst(2)
        } else {
            let digits = remainder.prefix(while: { $0.isNumber })
            let orderedPrefix = "\(digits). "
            if !digits.isEmpty, remainder.hasPrefix(orderedPrefix) {
                prefix += orderedPrefix
                remainder.removeFirst(orderedPrefix.count)
            }
        }
        return (prefix, String(remainder))
    }

    private static func displayLines(from text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
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
    @State private var activeBatch: TaggrPostTranslationBatch?

    func body(content: Content) -> some View {
        content
            .onChange(of: requestID, initial: true) { _, newRequestID in
                guard newRequestID > 0 else {
                    // Keep the configuration: a discarded configuration would be
                    // recreated with the same value on the next request, and an
                    // unchanged configuration does not re-run the translation task.
                    activeRequestID = 0
                    activeBatch = nil
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
        let batch = TaggrPostTranslationBatch(
            sourceText: sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !batch.isEmpty else {
            isTranslating = false
            return
        }
        translatedText = nil
        errorMessage = nil
        isTranslating = true
        activeRequestID = requestID
        activeBatch = batch
        if configuration == nil {
            configuration = TranslationSession.Configuration(source: nil, target: nil)
        } else {
            // Invalidate to translate new content with the same language pair.
            configuration?.invalidate()
        }
    }

    func translate(using session: TranslationSession) async {
        let requestID = activeRequestID
        guard requestID > 0, let batch = activeBatch, !batch.lines.isEmpty else { return }
        var translated: String?
        do {
            let responses = try await session.translations(from: batch.requests)
            translated = batch.translatedBody(from: responses)
        } catch {
            translated = nil
        }
        guard activeRequestID == requestID, activeBatch?.lines == batch.lines else { return }
        translatedText = translated
        errorMessage = translated == nil ? "Translation unavailable" : nil
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
    var isDetail = false
    var openPost: () -> Void = {}

    var body: some View {
        switch post.extensionKind {
        case .poll(let poll):
            PollExtensionView(post: post, poll: poll)
        case .repost(let id):
            RepostExtensionView(postId: id)
        case .proposal(let id):
            ProposalExtensionView(postId: post.id, proposalId: id, isDetail: isDetail, openPost: openPost)
        case .feature, .none:
            EmptyView()
        case .unknown:
            CompactNoticeView(title: "Unsupported extension", systemImage: "questionmark.square.dashed")
        }
    }
}

struct RepostExtensionView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let postId: Int
    @State private var embeddedPost: TaggrPost?

    var body: some View {
        Group {
            if let embeddedPost, state.canDisplayPost(embeddedPost), embeddedPost.contentRestriction(viewerID: state.currentUser?.id) == nil {
                RepostEmbeddedBodyView(
                    text: embeddedPost.displayBody,
                    authorName: embeddedPost.meta.authorName ?? "@\(embeddedPost.user)",
                    badges: TaggrUserBadge.decoded(from: embeddedPost.meta.authorBadges)
                ) {
                    state.navigateToPost(embeddedPost.id)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if embeddedPost != nil {
                CompactNoticeView(title: "Repost unavailable", systemImage: "eye.slash")
            } else {
                CompactNoticeView(title: "Loading repost", systemImage: "arrow.2.squarepath")
                    .task(id: postId) {
                        embeddedPost = await state.loadEmbeddedPost(postId)
                    }
            }
        }
    }
}

/// The embedded card of a repost. A reposted post often exceeds the four
/// preview lines, so the card offers the same expansion the timeline rows do.
/// The header and the preview body stay the navigation target; the expansion
/// toggle sits outside them because SwiftUI does not render a Button nested in
/// a Button label.
struct RepostEmbeddedBodyView: View {
    let text: String
    var authorName: String
    var badges: [TaggrUserBadge]
    var maximumLines = 4
    var openPost: (() -> Void)?

    @State private var isExpanded = false
    @State private var isTruncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Repost", systemImage: "arrow.2.squarepath")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(TaggrTheme.secondaryText)
                        Text(authorName)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(TaggrTheme.clickable)
                        UserAttributeBadgesView(badges: badges)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                TaggrPostBodyView(
                    text: text,
                    maximumLines: isExpanded ? nil : maximumLines,
                    textStyle: .subheadline,
                    textColor: TaggrTheme.secondaryText,
                    lineSpacing: 0,
                    accessibilityIdentifier: "repost-embedded-body",
                    openPost: openPost,
                    onTruncationChange: updateTruncation
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TaggrTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if !isExpanded, isTruncated {
                Button(action: expand) {
                    Label("Show full post", systemImage: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(TaggrTheme.clickable)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("repost-show-full-post")
            }
        }
    }

    private func open() {
        openPost?()
    }

    private func expand() {
        isExpanded = true
        isTruncated = false
    }

    private func updateTruncation(_ value: Bool) {
        guard isTruncated != value else { return }
        isTruncated = value
    }
}

struct ProposalExtensionView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let postId: Int
    let proposalId: Int
    var isDetail = false
    var openPost: () -> Void = {}

    var body: some View {
        Button(action: open) {
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

    // A timeline row opens the post like any other post. Only the post page itself, where the
    // row is no longer the way into the replies, links on to the proposal.
    private func open() {
        if isDetail {
            state.navigate(to: .proposal(proposalId))
        } else {
            openPost()
        }
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
