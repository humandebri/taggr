import PhotosUI
import SwiftUI

struct PostEngagementBar: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let post: TaggrPost
    let canTranslate: Bool
    let isTranslated: Bool
    let isTranslating: Bool
    let toggleTranslation: () -> Void
    let repliesExpanded: Bool
    let toggleReplies: () -> Void
    @State private var showingReactionPicker = false
    @State private var showingActionPanel = false
    @State private var showingRepost = false
    @State private var showingReport = false
    @State private var editingPost: TaggrPost?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                reactionSummaryStrip
                    .frame(maxWidth: .infinity, alignment: .leading)

                fixedActionButtons
                Button {
                    showingReactionPicker = false
                    showingActionPanel.toggle()
                } label: {
                    PostActionIconLabel(kind: .menu, selected: showingActionPanel)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showingActionPanel ? "Hide post actions" : "Show post actions")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showingActionPanel {
                PostInlineActionPanel(
                    post: post,
                    signedIn: signedIn,
                    canReply: canReply,
                    bookmarked: bookmarked,
                    watching: watching,
                    hidden: hidden,
                    pinned: pinned,
                    canPin: canPin,
                    canEdit: canEdit,
                    canDelete: canDelete,
                    currentMode: currentMode,
                    repost: { showingRepost = true },
                    toggleBookmark: { Task { await state.toggleBookmark(postId: post.id) } },
                    toggleWatch: { Task { await state.toggleFollowingPost(postId: post.id) } },
                    toggleHide: { Task { await state.toggleHide(postId: post.id) } },
                    togglePin: { Task { await state.togglePinnedPost(postId: post.id) } },
                    edit: { editingPost = post },
                    delete: { showingDeleteConfirmation = true },
                    report: { showingReport = true }
                )
                .environment(state)
            }
        }
        .fullScreenCover(item: $editingPost) { post in
            ComposePostView(mode: .edit(post: post, selectedMode: currentMode)) {
                editingPost = nil
            }
                .environment(state)
        }
        .sheet(isPresented: $showingRepost) {
            RepostSheet(post: post, isPresented: $showingRepost)
                .environment(state)
        }
        .sheet(isPresented: $showingReport) {
            ReportPostSheet(post: post, isPresented: $showingReport)
                .environment(state)
        }
        .confirmationDialog("Delete post", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await state.deletePost(post) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    var reactionSummaryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(reactionEntries, id: \.id) { entry in
                    Button {
                        react(entry.id)
                    } label: {
                        ReactionCountPill(entry: entry)
                    }
                    .disabled(!canReact)
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(entry.emoji) reaction, \(entry.count)")
                }
                if post.tips.count > 0 {
                    PostActionIconLabel(kind: .coin, count: post.tips.count)
                }
                if post.reposts.count > 0 {
                    PostActionIconLabel(kind: .repost, count: post.reposts.count)
                }
            }
        }
    }

    var fixedActionButtons: some View {
        HStack(spacing: 6) {
            if canShowReactionButton {
                Button(action: showReactionOptions) {
                    PostActionIconLabel(kind: .add, selected: showingReactionPicker)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add reaction")
                .popover(
                    isPresented: $showingReactionPicker,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .bottom
                ) {
                    ReactionPickerView(options: reactionOptions, react: react)
                        .presentationCompactAdaptation(.popover)
                }
            }
            if #available(iOS 18.0, *), canTranslate {
                if isTranslating {
                    ProgressView()
                        .controlSize(.small)
                        .tint(TaggrTheme.clickable)
                        .frame(width: 34, height: 30)
                        .accessibilityLabel("Translating post")
                } else {
                    Button(action: toggleTranslation) {
                        PostActionIconLabel(kind: .translate, selected: isTranslated)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isTranslated ? "Hide translation" : "Translate post")
                }
            }
            if replyCount > 0 {
                Button(action: toggleReplies) {
                    PostActionIconLabel(kind: .comment, count: replyCount, selected: repliesExpanded)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(repliesExpanded ? "Hide replies" : "Show replies")
            }
        }
    }

    var signedIn: Bool {
        state.currentUser != nil
    }

    var replyCount: Int {
        post.replyCount
    }

    var bookmarked: Bool {
        state.currentUser?.bookmarks.contains(post.id) == true
    }

    var watching: Bool {
        guard let id = state.currentUser?.id else { return false }
        return post.watchers.contains(id)
    }

    var canEdit: Bool {
        state.currentUser?.id == post.user
    }

    var hidden: Bool {
        guard let id = state.currentUser?.id else { return false }
        return post.hiddenFor.contains(id)
    }

    var canPin: Bool {
        state.currentUser?.id == post.user
    }

    var pinned: Bool {
        state.currentUser?.pinnedPosts.contains(post.id) == true
    }

    var canDelete: Bool {
        state.currentUser?.id == post.user && post.hashes.isEmpty
    }

    var canReact: Bool {
        guard signedIn, post.meta.viewerBlocked != true else { return false }
        guard let user = state.currentUser else { return true }
        if post.user == user.id { return false }
        return !post.reactions.values.contains { $0.contains(user.id) }
    }

    var canShowReactionButton: Bool {
        guard post.meta.viewerBlocked != true, !reactionOptions.isEmpty else { return false }
        guard let user = state.currentUser else { return true }
        if post.user == user.id { return false }
        return !post.reactions.values.contains { $0.contains(user.id) }
    }

    var canReply: Bool {
        signedIn && post.meta.viewerBlocked != true
    }

    var currentMode: TaggrFeedMode {
        FeedView.feedMode(from: state.route) ?? .latest
    }

    var reactionOrder: [Int] {
        let configuredOrder = state.cache?.config?.reactions?.compactMap { $0.first } ?? []
        return configuredOrder.isEmpty ? TaggrReactionIcon.defaultOrder : configuredOrder
    }

    var reactionOptions: [(id: Int, emoji: String)] {
        reactionOrder.compactMap { id in
            TaggrReactionIcon.emoji(for: id).map { (id, $0) }
        }
    }

    var reactionEntries: [(id: Int, emoji: String, count: Int, reacted: Bool)] {
        let currentUserId = state.currentUser?.id
        let values = post.reactions.compactMap { key, users -> (id: Int, emoji: String, count: Int, reacted: Bool)? in
            guard let id = Int(key), let emoji = TaggrReactionIcon.emoji(for: id) else { return nil }
            return (id, emoji, users.count, currentUserId.map { users.contains($0) } ?? false)
        }
        let order = reactionOrder
        return values.sorted { lhs, rhs in
            let l = order.firstIndex(of: lhs.id) ?? Int.max
            let r = order.firstIndex(of: rhs.id) ?? Int.max
            return l == r ? lhs.id < rhs.id : l < r
        }
    }

    func react(_ id: Int) {
        guard canReact else {
            explainReactionRequirement()
            return
        }
        showingReactionPicker = false
        Task { await state.react(postId: post.id, reaction: id) }
    }

    func showReactionOptions() {
        if signedIn {
            showingReactionPicker.toggle()
        } else if state.authSession != nil {
            state.errorMessage = "Create a TAGGR user before reacting."
            state.route = .settings
        } else {
            state.startIdentitySignIn(reason: "Sign in before reacting.")
        }
    }

    func explainReactionRequirement() {
        if state.authSession == nil {
            state.errorMessage = "Sign in before reacting."
        } else if state.currentUser == nil {
            state.errorMessage = "Create a TAGGR user before reacting."
            state.route = .settings
        }
    }

}

struct PostInlineActionPanel: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var replyDraftHasChanges = false
    @State private var clearReplyDraftRequest = 0
    let post: TaggrPost
    let signedIn: Bool
    let canReply: Bool
    let bookmarked: Bool
    let watching: Bool
    let hidden: Bool
    let pinned: Bool
    let canPin: Bool
    let canEdit: Bool
    let canDelete: Bool
    let currentMode: TaggrFeedMode
    let repost: () -> Void
    let toggleBookmark: () -> Void
    let toggleWatch: () -> Void
    let toggleHide: () -> Void
    let togglePin: () -> Void
    let edit: () -> Void
    let delete: () -> Void
    let report: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if canReply {
                InlineReplyComposer(
                    post: post,
                    selectedMode: currentMode,
                    clearRequest: clearReplyDraftRequest,
                    hasDraftChanges: $replyDraftHasChanges
                )
                    .environment(state)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ShareLink(item: TaggrNavigation.universalURL(for: .post(post.id))) {
                        PostExpandedActionButtonLabel(title: "Share", kind: .share)
                    }
                    .buttonStyle(.plain)

                    PostExpandedActionButton(title: "Report", kind: .report, destructive: true, action: report)
                    if signedIn {
                        PostExpandedActionButton(title: watching ? "Unwatch" : "Watch", kind: watching ? .unwatch : .watch, selected: watching, action: toggleWatch)
                        PostExpandedActionButton(title: "Repost", kind: .repost, action: repost)
                        PostExpandedActionButton(title: bookmarked ? "Remove bookmark" : "Bookmark", kind: bookmarked ? .unbookmark : .bookmark, selected: bookmarked, action: toggleBookmark)
                        PostExpandedActionButton(title: hidden ? "Unhide" : "Hide", kind: hidden ? .unhide : .hide, selected: hidden, action: toggleHide)
                        if canPin {
                            PostExpandedActionButton(title: pinned ? "Unpin" : "Pin", kind: .pin, selected: pinned, action: togglePin)
                        }
                        if canEdit {
                            PostExpandedActionButton(title: "Edit", kind: .edit, action: edit)
                        }
                        if canDelete {
                            PostExpandedActionButton(title: "Delete", kind: .delete, destructive: true, action: delete)
                        }
                        if canReply {
                            PostExpandedActionButton(
                                title: "Clear Draft",
                                kind: .delete,
                                destructive: true,
                                enabled: replyDraftHasChanges
                            ) {
                                clearReplyDraftRequest += 1
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            if !post.reactions.isEmpty {
                PostReactionDetailsView(post: post)
                    .environment(state)
            }
        }
        .padding(10)
        .background(TaggrTheme.panel.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct PostExpandedActionButton: View {
    let title: String
    let kind: PostActionIconKind
    var selected = false
    var destructive = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PostExpandedActionButtonLabel(
                title: title,
                kind: kind,
                selected: selected,
                destructive: destructive,
                enabled: enabled
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
    }
}

struct PostExpandedActionButtonLabel: View {
    let title: String
    let kind: PostActionIconKind
    var selected = false
    var destructive = false
    var enabled = true

    var body: some View {
        PWAActionIcon(kind: kind, color: foreground)
            .accessibilityHidden(true)
            .frame(width: 44, height: 44)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }

    var foreground: Color {
        if !enabled {
            return TaggrTheme.secondaryText
        }
        if destructive {
            return .red
        }
        return selected ? TaggrTheme.accent : TaggrTheme.clickable
    }

    var background: Color {
        TaggrTheme.darkPanel
    }
}

struct InlineReplyComposer: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @Environment(\.scenePhase) private var scenePhase
    let post: TaggrPost
    let selectedMode: TaggrFeedMode
    let clearRequest: Int
    @Binding var hasDraftChanges: Bool
    @StateObject private var draft: PostDraftSession
    @StateObject private var imageImport = ImageImportCoordinator()
    @StateObject private var quoteEditor = ComposeQuoteEditor()
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var imageImportWarning: String?
    @State private var imageInsertionSegmentID: Int?
    @State private var documentID = UUID()
    @State private var isSubmitting = false
    @State private var clearConfirmationPresented = false
    @State private var focusedTextSegmentID: Int?

    init(
        post: TaggrPost,
        selectedMode: TaggrFeedMode,
        clearRequest: Int,
        hasDraftChanges: Binding<Bool>
    ) {
        self.post = post
        self.selectedMode = selectedMode
        self.clearRequest = clearRequest
        _hasDraftChanges = hasDraftChanges
        _draft = StateObject(
            wrappedValue: PostDraftSession(
                context: .reply(post.id),
                initialText: "",
                initialRealm: post.realm ?? ""
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ComposePostDocumentEditor(
                text: $draft.text,
                draftImages: draft.images,
                existingImages: [:],
                placeholder: "Reply here...",
                documentID: documentID,
                focusedTextSegmentID: $focusedTextSegmentID,
                imageInsertionSegmentID: $imageInsertionSegmentID,
                removeImage: removeImageMarker,
                moveImage: moveImageMarker,
                moveImageToTextSegment: moveImageMarker
            )
            .environmentObject(quoteEditor)
            .disabled(!draft.isLoaded)
            .padding(8)
            .background(TaggrTheme.darkPanel)
            .clipShape(RoundedRectangle(cornerRadius: 7))

            if let warning = draft.restorationWarning {
                ComposePostImageWarning(
                    text: warning,
                    showCreateStorage: false,
                    createStorage: {}
                )
            }
            if draft.submissionNeedsVerification,
               !isSubmitting,
               !state.isPostSubmissionPending(.reply(post.id)) {
                ComposePostImageWarning(
                    text: "The last reply request may have been accepted, but its result was not confirmed. Check the thread before choosing what to do with this draft.",
                    showCreateStorage: false,
                    createStorage: {}
                )
                Button("I confirmed it was posted", action: discardConfirmedSubmission)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(TaggrTheme.clickable)
                Button("Edit and retry", action: resumeSubmission)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(TaggrTheme.clickable)
            }
            if let imageWarning {
                ComposePostImageWarning(
                    text: imageWarning,
                    showCreateStorage: missingStorageForImages,
                    createStorage: openStorageSettings
                )
            }
            if let imageImportWarning {
                ComposePostImageWarning(
                    text: imageImportWarning,
                    showCreateStorage: false,
                    createStorage: {}
                )
            }
            HStack(alignment: .center, spacing: 8) {
                ComposePostAttachmentBar(
                    text: $draft.text,
                    selectedPhotos: $selectedPhotos,
                    youtubeTarget: youtubeDraftTarget,
                    insertYouTubeURL: insertYouTubeURL,
                    isSubmitting: isSubmitting || state.isBusy || imageImport.isImporting,
                    isImagePickerDisabled: isSubmitting || state.isBusy || imageImport.isImporting || !draft.isLoaded,
                    horizontalPadding: 0,
                    verticalPadding: 0,
                    itemSpacing: 6,
                    background: .clear
                )
                .environmentObject(quoteEditor)

                Button("Submit") {
                    submit()
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(canSubmit ? TaggrTheme.accentText : TaggrTheme.secondaryText)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(canSubmit ? TaggrTheme.accent : TaggrTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .disabled(!canSubmit)
            }
        }
        .onChange(of: selectedPhotos) { _, items in
            loadPhotos(items)
        }
        .onChange(of: draft.text) { _, _ in
            draft.contentDidChange()
            draft.scheduleSave()
        }
        .onChange(of: draft.hasChanges) { _, hasChanges in
            hasDraftChanges = hasChanges
        }
        .onChange(of: clearRequest) { _, _ in
            clearConfirmationPresented = true
        }
        .onAppear {
            hasDraftChanges = draft.hasChanges
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            Task { await draft.flush() }
        }
        .onDisappear {
            cancelImageImport()
            Task { await draft.flush() }
        }
        .task(id: draftNamespaceID) {
            guard let namespace = draftNamespace else { return }
            await draft.load(store: state.postDraftStore, namespace: namespace)
            await consumeCompletedYouTubeUpload()
        }
        .onChange(of: state.youtubeUpload.completionRevision) { _, _ in
            Task { await consumeCompletedYouTubeUpload() }
        }
        .confirmationDialog(
            "Clear this draft?",
            isPresented: $clearConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Clear Draft", role: .destructive) {
                cancelImageImport()
                Task {
                    if hasYouTubeUploadForDraft {
                        await state.youtubeUpload.cancel()
                    }
                    await draft.discard()
                    focusedTextSegmentID = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    var composedBody: String {
        draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSubmit: Bool {
        draft.isLoaded && state.currentUser != nil && !composedBody.isEmpty && imageWarning == nil
            && !draft.submissionNeedsVerification
            && !imageImport.isImporting && !isSubmitting && !state.isBusy && !hasRunningYouTubeUpload
            && !state.hasPendingPostSubmission
    }

    var imageWarning: String? {
        if draft.images.contains(where: { !composedBody.contains($0.markdown) }) {
            return "Attached image marker was edited. Remove and attach the image again."
        }
        let references = TaggrAppCoordinator.blobIDs(inMarkdown: composedBody)
        let hasAttachedImages = !references.isEmpty || !draft.images.isEmpty
        guard hasAttachedImages else { return nil }
        if state.currentUser?.bucket?.isEmpty ?? true {
            return "Attaching images requires a personal storage canister."
        }
        let draftIDs = Set(draft.images.map(\.id))
        if references.contains(where: { !draftIDs.contains($0) }) {
            return "You're referencing pictures that are not attached anymore. Please re-upload."
        }
        return nil
    }

    var missingStorageForImages: Bool {
        !TaggrAppCoordinator.blobIDs(inMarkdown: composedBody).isEmpty && (state.currentUser?.bucket?.isEmpty ?? true)
    }

    func openStorageSettings() {
        cancelImageImport()
        Task {
            await draft.flush()
            state.route = .settings
        }
    }

    func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty, !imageImport.isImporting else { return }
        let insertionSegmentID = imageInsertionSegmentID
        focusedTextSegmentID = nil
        imageInsertionSegmentID = nil
        imageImportWarning = nil
        let maxBytes = ImageDrafts.postImageMaximumBytes(
            serverLimit: state.cache?.config?.maxBlobSizeBytes
        )
        imageImport.start(
            operation: {
                await ImageDrafts.importPhotos(items, maxBytes: maxBytes)
            },
            completion: { result in
                selectedPhotos = []
                imageImportWarning = result.warning
                let loaded = ImageDrafts.uniquedDraftImages(
                    result.images,
                    existingIDs: Set(draft.images.map(\.id))
                )
                if !loaded.isEmpty {
                    await draft.addImages(loaded, afterTextSegmentID: insertionSegmentID)
                }
            }
        )
    }

    func cancelImageImport() {
        imageImport.cancel()
        selectedPhotos = []
        imageImportWarning = nil
    }

    func removeImage(_ image: TaggrDraftImage, occurrence: Int) {
        Task { await draft.removeImage(image, occurrence: occurrence) }
    }

    func removeImageMarker(_ occurrence: Int, blobID: String) {
        if let image = draft.images.first(where: { $0.id == blobID }) {
            removeImage(image, occurrence: occurrence)
        } else {
            Task { await draft.removeImageMarker(occurrence: occurrence) }
        }
    }

    func moveImageMarker(_ occurrence: Int, before target: Int?) {
        Task { await draft.moveImageMarker(occurrence: occurrence, before: target) }
    }

    func moveImageMarker(_ occurrence: Int, afterTextSegmentID: Int) {
        Task { await draft.moveImageMarker(occurrence: occurrence, afterTextSegmentID: afterTextSegmentID) }
    }

    func discardConfirmedSubmission() {
        Task {
            cancelImageImport()
            await draft.discard()
            focusedTextSegmentID = nil
        }
    }

    func resumeSubmission() {
        Task { await draft.clearSubmissionVerification() }
    }

    func submit() {
        guard canSubmit else { return }
        let body = composedBody
        let images = draft.images
        isSubmitting = true
        Task {
            guard await draft.markSubmissionNeedsVerification() else {
                isSubmitting = false
                return
            }
            let enqueued = state.enqueuePostSubmission(
                text: body,
                parent: post.id,
                realm: post.realm,
                images: images,
                reloadMode: selectedMode,
                draft: draft
            )
            isSubmitting = false
            guard enqueued else {
                await draft.clearSubmissionVerification()
                return
            }
            cancelImageImport()
            focusedTextSegmentID = nil
        }
    }

    var draftNamespace: PostDraftNamespace? {
        state.currentUser.map {
            PostDraftNamespace(
                canisterID: state.runtimeConfig.canisterId,
                userID: $0.id
            )
        }
    }

    var draftNamespaceID: String {
        draftNamespace.map { "\($0.canisterID):\($0.userID)" } ?? "signed-out"
    }

    var youtubeDraftTarget: YouTubeDraftTarget? {
        draftNamespace.map { YouTubeDraftTarget(namespace: $0, context: .reply(post.id)) }
    }

    var hasRunningYouTubeUpload: Bool {
        state.youtubeUpload.isRunning && hasYouTubeUploadForDraft
    }

    var hasYouTubeUploadForDraft: Bool {
        state.youtubeUpload.job?.target == youtubeDraftTarget
    }

    func insertYouTubeURL(_ url: URL) {
        Task {
            let inserted = await draft.addExternalURL(url)
            if inserted, let youtubeDraftTarget {
                await state.youtubeUpload.acknowledgeCompletion(for: youtubeDraftTarget)
            }
        }
    }

    func consumeCompletedYouTubeUpload() async {
        guard let youtubeDraftTarget,
              let url = state.youtubeUpload.completedURL(for: youtubeDraftTarget) else { return }
        if await draft.addExternalURL(url) {
            await state.youtubeUpload.acknowledgeCompletion(for: youtubeDraftTarget)
        }
    }
}

struct ReactionCountPill: View {
    let entry: (id: Int, emoji: String, count: Int, reacted: Bool)

    var body: some View {
        Text("\(entry.emoji) \(entry.count)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(entry.reacted ? TaggrTheme.accentText : TaggrTheme.text)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(entry.reacted ? TaggrTheme.accent : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(
                        entry.reacted ? TaggrTheme.accent : TaggrTheme.panelRaised.opacity(0.7),
                        lineWidth: 1
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

enum PostActionIconKind {
    case add
    case bookmark
    case comment
    case repost
    case coin
    case delete
    case edit
    case hide
    case menu
    case pin
    case reply
    case report
    case share
    case translate
    case unbookmark
    case unhide
    case unwatch
    case watch
}

struct PostActionIconLabel: View {
    let kind: PostActionIconKind
    var count: Int?
    var selected = false

    var body: some View {
        HStack(spacing: 4) {
            PWAActionIcon(kind: kind, color: foreground)
                .accessibilityHidden(true)
            if let count {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(foreground)
            }
        }
        .padding(.horizontal, count == nil ? 8 : 9)
        .frame(height: 30)
        .frame(minWidth: 34)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(RoundedRectangle(cornerRadius: 7))
    }

    var foreground: Color {
        selected ? TaggrTheme.accentText : TaggrTheme.clickable
    }

    var background: Color {
        if selected {
            return TaggrTheme.accent
        }
        if kind == .menu {
            return TaggrTheme.panelRaised.opacity(0.55)
        }
        return Color.clear
    }
}

struct PWAActionIcon: View {
    let kind: PostActionIconKind
    let color: Color

    var body: some View {
        ZStack {
            switch kind {
            case .add:
                Circle()
                    .stroke(color, lineWidth: 1.5)
                Rectangle()
                    .fill(color)
                    .frame(width: 9, height: 1.4)
                Rectangle()
                    .fill(color)
                    .frame(width: 1.4, height: 9)
            case .bookmark:
                bookmarkPath()
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            case .unbookmark:
                bookmarkPath()
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                Path { path in
                    path.move(to: CGPoint(x: 6.2, y: 6.2))
                    path.addLine(to: CGPoint(x: 10.8, y: 10.8))
                    path.move(to: CGPoint(x: 10.8, y: 6.2))
                    path.addLine(to: CGPoint(x: 6.2, y: 10.8))
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            case .comment:
                RoundedRectangle(cornerRadius: 5)
                    .fill(color)
                    .frame(width: 17, height: 13)
                    .offset(y: -1)
                Path { path in
                    path.move(to: CGPoint(x: 5, y: 9))
                    path.addLine(to: CGPoint(x: 2, y: 15))
                    path.addLine(to: CGPoint(x: 9, y: 11))
                    path.closeSubpath()
                }
                .fill(color)
                HStack(spacing: 2.2) {
                    Circle().fill(TaggrTheme.background).frame(width: 2.2, height: 2.2)
                    Circle().fill(TaggrTheme.background).frame(width: 2.2, height: 2.2)
                    Circle().fill(TaggrTheme.background).frame(width: 2.2, height: 2.2)
                }
                .offset(y: -1)
            case .repost:
                Path { path in
                    path.move(to: CGPoint(x: 3, y: 6))
                    path.addCurve(to: CGPoint(x: 11.5, y: 4.5), control1: CGPoint(x: 4.9, y: 2.7), control2: CGPoint(x: 9.6, y: 2.5))
                    path.move(to: CGPoint(x: 13, y: 10))
                    path.addCurve(to: CGPoint(x: 4.5, y: 11.5), control1: CGPoint(x: 11.1, y: 13.3), control2: CGPoint(x: 6.4, y: 13.5))
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                Path { path in
                    path.move(to: CGPoint(x: 11.5, y: 2.1))
                    path.addLine(to: CGPoint(x: 15.5, y: 4.6))
                    path.addLine(to: CGPoint(x: 11.5, y: 7.1))
                    path.closeSubpath()
                    path.move(to: CGPoint(x: 4.5, y: 13.9))
                    path.addLine(to: CGPoint(x: 0.5, y: 11.4))
                    path.addLine(to: CGPoint(x: 4.5, y: 8.9))
                    path.closeSubpath()
                }
                .fill(color)
            case .coin:
                Circle()
                    .stroke(color, lineWidth: 1.5)
                Text("$")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(color)
                    .offset(y: -0.5)
            case .delete:
                Path { path in
                    path.move(to: CGPoint(x: 4, y: 5))
                    path.addLine(to: CGPoint(x: 4.5, y: 14))
                    path.addLine(to: CGPoint(x: 12.5, y: 14))
                    path.addLine(to: CGPoint(x: 13, y: 5))
                    path.move(to: CGPoint(x: 2.5, y: 4))
                    path.addLine(to: CGPoint(x: 14.5, y: 4))
                    path.move(to: CGPoint(x: 6, y: 4))
                    path.addLine(to: CGPoint(x: 6.7, y: 2))
                    path.addLine(to: CGPoint(x: 10.3, y: 2))
                    path.addLine(to: CGPoint(x: 11, y: 4))
                    path.move(to: CGPoint(x: 7, y: 7))
                    path.addLine(to: CGPoint(x: 7, y: 12))
                    path.move(to: CGPoint(x: 10, y: 7))
                    path.addLine(to: CGPoint(x: 10, y: 12))
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
            case .edit:
                Path { path in
                    path.move(to: CGPoint(x: 3, y: 13.5))
                    path.addLine(to: CGPoint(x: 6.3, y: 12.7))
                    path.addLine(to: CGPoint(x: 13.6, y: 5.4))
                    path.addLine(to: CGPoint(x: 10.6, y: 2.4))
                    path.addLine(to: CGPoint(x: 3.3, y: 9.7))
                    path.closeSubpath()
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
            case .hide:
                eyePath()
                    .stroke(color, style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
                Circle()
                    .stroke(color, lineWidth: 1.2)
                    .frame(width: 5.5, height: 5.5)
            case .menu:
                VStack(spacing: 3) {
                    Capsule().fill(color).frame(width: 15, height: 1.8)
                    Capsule().fill(color).frame(width: 15, height: 1.8)
                    Capsule().fill(color).frame(width: 15, height: 1.8)
                }
            case .pin:
                Path { path in
                    path.move(to: CGPoint(x: 5, y: 2.5))
                    path.addLine(to: CGPoint(x: 12.5, y: 10))
                    path.move(to: CGPoint(x: 8, y: 1.8))
                    path.addLine(to: CGPoint(x: 4.3, y: 5.5))
                    path.move(to: CGPoint(x: 11.8, y: 9))
                    path.addLine(to: CGPoint(x: 8.1, y: 12.7))
                    path.move(to: CGPoint(x: 7.7, y: 10.7))
                    path.addLine(to: CGPoint(x: 3, y: 15))
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.45, lineCap: .round, lineJoin: .round))
            case .reply:
                Path { path in
                    path.move(to: CGPoint(x: 7, y: 4))
                    path.addLine(to: CGPoint(x: 3, y: 8))
                    path.addLine(to: CGPoint(x: 7, y: 12))
                    path.move(to: CGPoint(x: 3.5, y: 8))
                    path.addLine(to: CGPoint(x: 10, y: 8))
                    path.addCurve(to: CGPoint(x: 14, y: 12), control1: CGPoint(x: 12.5, y: 8), control2: CGPoint(x: 14, y: 9.5))
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.55, lineCap: .round, lineJoin: .round))
            case .report:
                Path { path in
                    path.move(to: CGPoint(x: 4, y: 14))
                    path.addLine(to: CGPoint(x: 4, y: 2.5))
                    path.addLine(to: CGPoint(x: 12.5, y: 5))
                    path.addLine(to: CGPoint(x: 4, y: 7.5))
                    path.move(to: CGPoint(x: 9.2, y: 5))
                    path.addLine(to: CGPoint(x: 9.2, y: 8.5))
                    path.move(to: CGPoint(x: 9.2, y: 11))
                    path.addLine(to: CGPoint(x: 9.2, y: 11.2))
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.45, lineCap: .round, lineJoin: .round))
            case .share:
                Circle().fill(color).frame(width: 4.2, height: 4.2).offset(x: 4.8, y: -5.2)
                Circle().fill(color).frame(width: 4.2, height: 4.2).offset(x: -5.2, y: 0)
                Circle().fill(color).frame(width: 4.2, height: 4.2).offset(x: 5.1, y: 5.4)
                Path { path in
                    path.move(to: CGPoint(x: 6.5, y: 5.9))
                    path.addLine(to: CGPoint(x: 12, y: 3.1))
                    path.move(to: CGPoint(x: 6.5, y: 9.9))
                    path.addLine(to: CGPoint(x: 12, y: 12.6))
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            case .translate:
                Text("A")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(color)
                    .offset(x: -3.2, y: -3.2)
                Path { path in
                    path.move(to: CGPoint(x: 4, y: 11.8))
                    path.addLine(to: CGPoint(x: 13.2, y: 11.8))
                    path.move(to: CGPoint(x: 9.7, y: 8.2))
                    path.addLine(to: CGPoint(x: 13.2, y: 11.8))
                    path.addLine(to: CGPoint(x: 9.7, y: 15.2))
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            case .unhide:
                eyePath()
                    .stroke(color, style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
                slashPath()
                    .stroke(color, style: StrokeStyle(lineWidth: 1.45, lineCap: .round))
            case .unwatch:
                bellPath()
                    .stroke(color, style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
                slashPath()
                    .stroke(color, style: StrokeStyle(lineWidth: 1.45, lineCap: .round))
            case .watch:
                bellPath()
                    .stroke(color, style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: 17, height: 17)
    }

    func bookmarkPath() -> Path {
        Path { path in
            path.move(to: CGPoint(x: 4, y: 2.5))
            path.addLine(to: CGPoint(x: 13, y: 2.5))
            path.addLine(to: CGPoint(x: 13, y: 14.2))
            path.addLine(to: CGPoint(x: 8.5, y: 11.5))
            path.addLine(to: CGPoint(x: 4, y: 14.2))
            path.closeSubpath()
        }
    }

    func eyePath() -> Path {
        Path { path in
            path.move(to: CGPoint(x: 1.8, y: 8.5))
            path.addCurve(to: CGPoint(x: 8.5, y: 4.3), control1: CGPoint(x: 3.5, y: 5.7), control2: CGPoint(x: 5.7, y: 4.3))
            path.addCurve(to: CGPoint(x: 15.2, y: 8.5), control1: CGPoint(x: 11.3, y: 4.3), control2: CGPoint(x: 13.5, y: 5.7))
            path.addCurve(to: CGPoint(x: 8.5, y: 12.7), control1: CGPoint(x: 13.5, y: 11.3), control2: CGPoint(x: 11.3, y: 12.7))
            path.addCurve(to: CGPoint(x: 1.8, y: 8.5), control1: CGPoint(x: 5.7, y: 12.7), control2: CGPoint(x: 3.5, y: 11.3))
        }
    }

    func bellPath() -> Path {
        Path { path in
            path.move(to: CGPoint(x: 4.2, y: 11.8))
            path.addLine(to: CGPoint(x: 12.8, y: 11.8))
            path.addCurve(to: CGPoint(x: 11, y: 8.3), control1: CGPoint(x: 11.9, y: 10.8), control2: CGPoint(x: 11, y: 10.1))
            path.addLine(to: CGPoint(x: 11, y: 6.5))
            path.addCurve(to: CGPoint(x: 6, y: 6.5), control1: CGPoint(x: 11, y: 3.6), control2: CGPoint(x: 6, y: 3.6))
            path.addLine(to: CGPoint(x: 6, y: 8.3))
            path.addCurve(to: CGPoint(x: 4.2, y: 11.8), control1: CGPoint(x: 6, y: 10.1), control2: CGPoint(x: 5.1, y: 10.8))
            path.move(to: CGPoint(x: 7, y: 13.1))
            path.addCurve(to: CGPoint(x: 10, y: 13.1), control1: CGPoint(x: 7.7, y: 14.3), control2: CGPoint(x: 9.3, y: 14.3))
        }
    }

    func slashPath() -> Path {
        Path { path in
            path.move(to: CGPoint(x: 14, y: 3))
            path.addLine(to: CGPoint(x: 3, y: 14))
        }
    }
}

struct ReactionPickerView: View {
    let options: [(id: Int, emoji: String)]
    let react: (Int) -> Void
    let columns = Array(repeating: GridItem(.fixed(38), spacing: 6), count: 5)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(options, id: \.id) { option in
                Button {
                    react(option.id)
                } label: {
                    Text(option.emoji)
                        .font(.title3)
                        .frame(width: 38, height: 38)
                        .background(TaggrTheme.panelRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("React \(option.emoji)")
            }
        }
        .padding(8)
        .background(TaggrTheme.panel)
        .presentationBackground(TaggrTheme.panel)
    }
}

struct RepostSheet: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @Environment(\.scenePhase) private var scenePhase
    let post: TaggrPost
    @Binding var isPresented: Bool
    @StateObject private var draft: PostDraftSession
    @State private var isSubmitting = false

    init(post: TaggrPost, isPresented: Binding<Bool>) {
        self.post = post
        _isPresented = isPresented
        _draft = StateObject(
            wrappedValue: PostDraftSession(
                context: .repost(post.id),
                initialText: "",
                initialRealm: post.realm ?? ""
            )
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button("Cancel") { isPresented = false }
                    .foregroundStyle(TaggrTheme.secondaryText)
                Spacer()
                Button("Repost") { submit() }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(isSubmitting ? TaggrTheme.secondaryText : TaggrTheme.accentText)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(isSubmitting ? TaggrTheme.panelRaised : TaggrTheme.accent)
                    .clipShape(Capsule())
                    .disabled(!draft.isLoaded || isSubmitting || state.isBusy || state.hasPendingPostSubmission)
            }
            TextEditor(text: draftText)
                .scrollContentBackground(.hidden)
                .foregroundStyle(TaggrTheme.text)
                .frame(minHeight: 110)
                .padding(8)
                .background(TaggrTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if let warning = draft.restorationWarning {
                ComposePostImageWarning(text: warning, showCreateStorage: false, createStorage: {})
            }
            if draft.submissionNeedsVerification {
                ComposePostImageWarning(
                    text: "The last repost request may have been accepted, but its result was not confirmed. Check the post before retrying.",
                    showCreateStorage: false,
                    createStorage: {}
                )
                HStack(spacing: 16) {
                    Button("I confirmed it was reposted", action: discardConfirmedSubmission)
                    Button("Edit and retry") {
                        Task { await draft.clearSubmissionVerification() }
                    }
                }
                .font(.footnote.weight(.bold))
                .foregroundStyle(TaggrTheme.clickable)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            TaggrPostBodyView(
                text: post.displayBody,
                maximumLines: 4,
                textStyle: .subheadline,
                textColor: TaggrTheme.secondaryText,
                lineSpacing: 0
            )
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
        .padding(16)
        .background(TaggrTheme.background)
        .presentationDetents([.medium])
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            Task { await draft.flush() }
        }
        .onDisappear {
            Task { await draft.flush() }
        }
        .task(id: draftNamespaceID) {
            guard let namespace = draftNamespace else { return }
            await draft.load(store: state.postDraftStore, namespace: namespace)
        }
    }

    func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            guard await draft.markSubmissionNeedsVerification() else {
                isSubmitting = false
                return
            }
            let enqueued = state.enqueueRepost(
                postId: post.id,
                text: draft.text,
                realm: draft.realm.isEmpty ? nil : draft.realm,
                draft: draft
            )
            isSubmitting = false
            guard enqueued else {
                await draft.clearSubmissionVerification()
                return
            }
            isPresented = false
        }
    }

    private var draftNamespace: PostDraftNamespace? {
        state.currentUser.map {
            PostDraftNamespace(canisterID: state.runtimeConfig.canisterId, userID: $0.id)
        }
    }

    private var draftNamespaceID: String {
        draftNamespace.map { "\($0.canisterID):\($0.userID)" } ?? "signed-out"
    }

    private var draftText: Binding<String> {
        Binding(
            get: { draft.text },
            set: { value in
                draft.text = value
                draft.contentDidChange()
                draft.scheduleSave()
            }
        )
    }

    private func discardConfirmedSubmission() {
        Task {
            await draft.discard()
            isPresented = false
        }
    }
}

struct ReportPostSheet: View {
    let post: TaggrPost
    @Binding var isPresented: Bool

    var body: some View {
        ContentReportSheet(userID: post.user, postID: post.id, isPresented: $isPresented)
    }
}

struct ContentReportSheet: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let userID: Int
    let postID: Int?
    @Binding var isPresented: Bool
    @State private var reason = ""
    @State private var requestID = UUID()
    @State private var isSubmitting = false
    @State private var received = false
    @State private var resultMessage: String?

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button("Cancel") { isPresented = false }.disabled(isSubmitting)
                Spacer()
                Button("Send report") { submit() }
                    .disabled(!canSubmit || isSubmitting)
                    .accessibilityIdentifier("sendContentReport")
            }
            Text("Send a report to the iOS operator. No tokens or credits are required. Reports are reviewed manually; they do not automatically hide content.")
                .font(.footnote)
            TextEditor(text: $reason)
                .accessibilityIdentifier("contentReportReason")
                .disabled(isSubmitting)
                .scrollContentBackground(.hidden)
                .foregroundStyle(TaggrTheme.text)
                .frame(minHeight: 160)
                .padding(8)
                .background(TaggrTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if isSubmitting { ProgressView("Sending…") }
            Spacer()
        }
        .padding(16)
        .background(TaggrTheme.background)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isSubmitting)
        .onChange(of: reason) { _, _ in requestID = UUID() }
        .alert(received ? "Report received" : "Report not sent", isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
            Button("OK") { if received { isPresented = false } }
        } message: { Text(resultMessage ?? "") }
    }

    private var canSubmit: Bool {
        !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && reason.unicodeScalars.count <= 2000
    }

    private func submit() {
        guard canSubmit, !isSubmitting else { return }
        isSubmitting = true
        let report = TaggrContentReport(id: requestID.uuidString, canisterID: state.runtimeConfig.canisterId, userID: userID, postID: postID, reason: reason)
        Task {
            defer { isSubmitting = false }
            do {
                try await state.safety.sendReport(report)
                received = true
                resultMessage = "The operator received your report."
            } catch { resultMessage = error.localizedDescription }
        }
    }
}
