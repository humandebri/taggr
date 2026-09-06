// TAGGR/Views: Shared full-screen composer for creating root posts, replies, and editing existing posts.

import PhotosUI
import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ComposePostView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @Environment(\.scenePhase) private var scenePhase
    let mode: PostComposerMode
    let dismiss: () -> Void
    @StateObject private var draft: PostDraftSession
    @StateObject private var imageImport = ImageImportCoordinator()
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var imageImportWarning: String?
    @State private var imageInsertionSegmentID: Int?
    @State private var documentID = UUID()
    @State private var creditCost: Int?
    @State private var creditCostUnavailable = false
    @State private var realmColors: [String: String] = [:]
    @State private var isSubmitting = false
    @State private var discardConfirmationPresented = false
    @FocusState private var focusedTextSegmentID: Int?

    init(mode: PostComposerMode, initialRealm: String? = nil, dismiss: @escaping () -> Void) {
        self.mode = mode
        self.dismiss = dismiss
        _draft = StateObject(
            wrappedValue: PostDraftSession(
                context: mode.draftContext,
                initialText: mode.initialText,
                initialRealm: initialRealm ?? mode.targetRealm ?? ""
            )
        )
    }

    var body: some View {
        ZStack {
            TaggrTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                ComposePostToolbar(
                    submitTitle: mode.submitTitle,
                    canSubmit: canSubmit,
                    isSubmitting: isSubmitting || state.isBusy,
                    cost: shouldShowCreditCost ? creditCost : nil,
                    costUnavailable: shouldShowCreditCost && creditCostUnavailable,
                    showsCost: shouldShowCreditCost,
                    realmName: $draft.realm,
                    appName: appRealmName,
                    availableRealms: selectableRealms,
                    realmColors: realmColors,
                    showsRealmPicker: showsRealmPicker,
                    showsDiscard: draft.hasChanges,
                    cancel: close,
                    discard: { discardConfirmationPresented = true },
                    submit: submit
                )

                Divider().overlay(TaggrTheme.panelRaised)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ComposePostDocumentEditor(
                            text: $draft.text,
                            draftImages: draft.images,
                            existingImages: existingImagesByID,
                            placeholder: mode.placeholder,
                            documentID: documentID,
                            focusedTextSegmentID: $focusedTextSegmentID,
                            imageInsertionSegmentID: $imageInsertionSegmentID,
                            removeImage: removeImageMarker,
                            moveImage: moveImageMarker,
                            moveImageToTextSegment: moveImageMarker
                        )
                        .disabled(!draft.isLoaded)
                        if let realmWarning {
                            ComposePostImageWarning(
                                text: realmWarning,
                                showCreateStorage: false,
                                createStorage: {}
                            )
                        }
                        if let warning = draft.restorationWarning {
                            ComposePostImageWarning(
                                text: warning,
                                showCreateStorage: false,
                                createStorage: {}
                            )
                        }
                        if draft.submissionNeedsVerification {
                            ComposePostImageWarning(
                                text: "The last post request may have been accepted, but its result was not confirmed. Check your recent posts before choosing what to do with this draft.",
                                showCreateStorage: false,
                                createStorage: {}
                            )
                            if mode.editingPost == nil {
                                Button("I confirmed it was posted", action: discardConfirmedSubmission)
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(TaggrTheme.clickable)
                                Button("Edit and retry", action: resumeSubmission)
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(TaggrTheme.clickable)
                            }
                        }
                        if let imageWarning {
                            ComposePostImageWarning(text: imageWarning, showCreateStorage: missingStorageForImages) {
                                openStorageSettings()
                            }
                        }
                        if let imageImportWarning {
                            ComposePostImageWarning(
                                text: imageImportWarning,
                                showCreateStorage: false,
                                createStorage: {}
                            )
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                }

                Divider().overlay(TaggrTheme.panelRaised)

                ComposePostAttachmentBar(
                    text: $draft.text,
                    selectedPhotos: $selectedPhotos,
                    youtubeTarget: youtubeDraftTarget,
                    insertYouTubeURL: insertYouTubeURL,
                    isSubmitting: state.isBusy || isSubmitting || imageImport.isImporting,
                    isImagePickerDisabled: state.isBusy || isSubmitting || imageImport.isImporting || !draft.isLoaded
                )
            }
        }
        .onChange(of: selectedPhotos) { _, items in
            loadPhotos(items)
        }
        .onChange(of: draft.text) { _, _ in
            draft.contentDidChange()
            draft.scheduleSave()
        }
        .onChange(of: draft.realm) { _, _ in
            draft.contentDidChange()
            draft.scheduleSave()
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
            guard !Task.isCancelled else { return }
            focusedTextSegmentID = 0
            await consumeCompletedYouTubeUpload()
        }
        .onChange(of: state.youtubeUpload.completionRevision) { _, _ in
            Task { await consumeCompletedYouTubeUpload() }
        }
        .task(id: creditCostRefreshKey) {
            await refreshCreditCost()
        }
        .task(id: realmMetadataKey) {
            guard showsRealmPicker else { return }
            realmColors = await state.postingRealmColors(selectableRealms)
        }
        .confirmationDialog(
            "Discard this draft?",
            isPresented: $discardConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Discard Draft", role: .destructive) {
                cancelImageImport()
                Task {
                    if hasYouTubeUploadForDraft {
                        await state.youtubeUpload.cancel()
                    }
                    await draft.discard()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var canSubmit: Bool {
        guard draft.isLoaded, state.currentUser != nil else { return false }
        guard !imageImport.isImporting,
              !draft.submissionNeedsVerification,
              !hasRunningYouTubeUpload,
              !state.hasPendingPostSubmission else { return false }
        let body = composedBody
        guard !body.isEmpty else { return false }
        guard imageWarning == nil else { return false }
        guard realmWarning == nil else { return false }
        guard let editingPost = mode.editingPost else { return true }
        return body != editingPost.body || selectedTargetRealm != editingPost.realm
    }

    private var composedBody: String {
        draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldShowCreditCost: Bool {
        !composedBody.isEmpty
    }

    private var creditCostRefreshKey: String {
        [
            mode.editingPost == nil ? "create" : "edit",
            composedBody,
            creditCostTags.joined(separator: ","),
            String((composedBody.utf8.count / 1024) + 1),
            state.runtimeConfig.canisterId,
            String(state.cache?.config?.postCost ?? -1),
            String(state.cache?.config?.pollCost ?? -1),
            String(state.cache?.config?.maxTagLength ?? -1),
        ].joined(separator: "|")
    }

    private var creditCostTags: [String] {
        let maxLength = state.cache?.config?.maxTagLength ?? TaggrPostCreditCost.defaultMaxTagLength
        return TaggrPostCreditCost.tags(in: composedBody, maxLength: maxLength)
    }

    private var appRealmName: String {
        state.cache?.config?.name?.uppercased() ?? "TAGGR"
    }

    private var showsRealmPicker: Bool {
        mode.allowsRealmSelection
    }

    private var realmWarning: String? {
        guard let post = mode.editingPost,
              post.parent == nil,
              let realm = selectedTargetRealm,
              !joinedRealm(realm) else {
            return nil
        }
        return "Choose Global or a realm you've joined before saving."
    }

    private func joinedRealm(_ realm: String) -> Bool {
        state.currentUser?.realms.contains {
            $0.caseInsensitiveCompare(realm) == .orderedSame
        } == true
    }

    private var editableImages: [TaggrEditablePostImage] {
        guard let post = mode.editingPost else { return [] }
        return post.editableImageAttachments(
            config: state.runtimeConfig,
            bodyText: composedBody
        )
    }

    private var existingImagesByID: [String: TaggrEditablePostImage] {
        editableImages.reduce(into: [:]) { images, image in
            images[image.attachment.id] = image
        }
    }

    private var selectableRealms: [String] {
        let selectedRealm = draft.realm.isEmpty || !joinedRealm(draft.realm) ? nil : draft.realm
        return state.orderedPostingRealms(selectedRealm: selectedRealm)
    }

    private var realmMetadataKey: String {
        selectableRealms.map { $0.uppercased() }.sorted().joined(separator: "|")
    }

    private var imageWarning: String? {
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
        let existingIDs = mode.editingPost.map { TaggrAppCoordinator.blobIDs(in: $0.files) } ?? []
        if references.contains(where: { !draftIDs.contains($0) && !existingIDs.contains($0) }) {
            return "You're referencing pictures that are not attached anymore. Please re-upload."
        }
        return nil
    }

    private var missingStorageForImages: Bool {
        !TaggrAppCoordinator.blobIDs(inMarkdown: composedBody).isEmpty && (state.currentUser?.bucket?.isEmpty ?? true)
    }

    private func submit() {
        let body = composedBody
        guard canSubmit, !isSubmitting else { return }
        let images = draft.images
        isSubmitting = true
        Task {
            guard await draft.markSubmissionNeedsVerification() else {
                isSubmitting = false
                return
            }
            let enqueued: Bool
            if let editingPost = mode.editingPost {
                enqueued = state.enqueueEditPost(
                    post: editingPost,
                    text: body,
                    realm: selectedTargetRealm,
                    images: images,
                    reloadMode: mode.selectedMode,
                    draft: draft
                )
            } else {
                enqueued = state.enqueuePostSubmission(
                    text: body,
                    parent: mode.parentPostID,
                    realm: selectedTargetRealm,
                    images: images,
                    reloadMode: mode.timelineModeAfterSubmit,
                    draft: draft
                )
            }
            isSubmitting = false
            guard enqueued else {
                await draft.clearSubmissionVerification()
                return
            }
            cancelImageImport()
            dismiss()
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
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

    private func cancelImageImport() {
        imageImport.cancel()
        selectedPhotos = []
        imageImportWarning = nil
    }

    private func removeImage(_ image: TaggrDraftImage, occurrence: Int) {
        Task { await draft.removeImage(image, occurrence: occurrence) }
    }

    private func removeImageMarker(_ occurrence: Int, blobID: String) {
        if let image = draft.images.first(where: { $0.id == blobID }) {
            removeImage(image, occurrence: occurrence)
        } else {
            Task { await draft.removeImageMarker(occurrence: occurrence) }
        }
    }

    private func moveImageMarker(_ occurrence: Int, before target: Int?) {
        Task { await draft.moveImageMarker(occurrence: occurrence, before: target) }
    }

    private func moveImageMarker(_ occurrence: Int, afterTextSegmentID: Int) {
        Task { await draft.moveImageMarker(occurrence: occurrence, afterTextSegmentID: afterTextSegmentID) }
    }

    private func discardConfirmedSubmission() {
        Task {
            cancelImageImport()
            await draft.discard()
            dismiss()
        }
    }

    private var youtubeDraftTarget: YouTubeDraftTarget? {
        draftNamespace.map { YouTubeDraftTarget(namespace: $0, context: mode.draftContext) }
    }

    private var hasRunningYouTubeUpload: Bool {
        state.youtubeUpload.isRunning && hasYouTubeUploadForDraft
    }

    private var hasYouTubeUploadForDraft: Bool {
        state.youtubeUpload.job?.target == youtubeDraftTarget
    }

    private func insertYouTubeURL(_ url: URL) {
        Task {
            let inserted = await draft.addExternalURL(url)
            if inserted, let youtubeDraftTarget {
                await state.youtubeUpload.acknowledgeCompletion(for: youtubeDraftTarget)
            }
        }
    }

    private func consumeCompletedYouTubeUpload() async {
        guard let youtubeDraftTarget,
              let url = state.youtubeUpload.completedURL(for: youtubeDraftTarget) else { return }
        if await draft.addExternalURL(url) {
            await state.youtubeUpload.acknowledgeCompletion(for: youtubeDraftTarget)
        }
    }

    private func resumeSubmission() {
        Task { await draft.clearSubmissionVerification() }
    }

    @MainActor
    private func refreshCreditCost() async {
        let body = composedBody
        guard !body.isEmpty else {
            creditCost = nil
            creditCostUnavailable = false
            return
        }
        creditCost = nil
        creditCostUnavailable = false
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        let cost = await state.postCreditCost(for: body, editing: mode.editingPost)
        if body == composedBody {
            creditCost = cost
            creditCostUnavailable = cost == nil
        }
    }

    private var selectedTargetRealm: String? {
        switch mode {
        case .reply:
            return mode.targetRealm
        case .newPost, .edit:
            return draft.realm.isEmpty ? nil : draft.realm
        }
    }

    private var draftNamespace: PostDraftNamespace? {
        state.currentUser.map {
            PostDraftNamespace(
                canisterID: state.runtimeConfig.canisterId,
                userID: $0.id
            )
        }
    }

    private var draftNamespaceID: String {
        draftNamespace.map { "\($0.canisterID):\($0.userID)" } ?? "signed-out"
    }

    private func close() {
        cancelImageImport()
        Task {
            await draft.flush()
            dismiss()
        }
    }

    private func openStorageSettings() {
        cancelImageImport()
        Task {
            await draft.flush()
            state.route = .settings
            dismiss()
        }
    }
}

private struct ComposePostToolbar: View {
    let submitTitle: String
    let canSubmit: Bool
    let isSubmitting: Bool
    let cost: Int?
    let costUnavailable: Bool
    let showsCost: Bool
    @Binding var realmName: String
    let appName: String
    let availableRealms: [String]
    let realmColors: [String: String]
    let showsRealmPicker: Bool
    let showsDiscard: Bool
    let cancel: () -> Void
    let discard: () -> Void
    let submit: () -> Void

    var body: some View {
        HStack {
            Button("Close", systemImage: "xmark", action: cancel)
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .foregroundStyle(TaggrTheme.text)
                .frame(width: 40, height: 40)
            if showsRealmPicker {
                ComposeRealmPicker(
                    selection: $realmName,
                    appName: appName,
                    realms: availableRealms,
                    realmColors: realmColors
                )
            }
            Spacer()
            if showsDiscard {
                Button("Discard Draft", systemImage: "trash", action: discard)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.red)
                    .frame(width: 36, height: 36)
            }
            if showsCost {
                ComposePostCreditCostBadge(cost: cost, unavailable: costUnavailable)
                    .padding(.trailing, 10)
            }
            Button(submitTitle, action: submit)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(canSubmit && !isSubmitting ? TaggrTheme.accentText : TaggrTheme.secondaryText)
                .padding(.horizontal, 18)
                .frame(height: 36)
                .background(canSubmit && !isSubmitting ? TaggrTheme.accent : TaggrTheme.panelRaised)
                .clipShape(Capsule())
                .disabled(!canSubmit || isSubmitting)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(TaggrTheme.background)
    }
}

private struct ComposeRealmPicker: View {
    @Binding var selection: String
    let appName: String
    let realms: [String]
    let realmColors: [String: String]
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(selection.isEmpty ? TaggrTheme.accent : realmColor(for: selection))
                    .frame(width: 8, height: 8)
                Text(selection.isEmpty ? appName : selection)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(TaggrTheme.clickable)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .frame(maxWidth: 150)
            .background(TaggrTheme.darkPanel)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    realmOption(name: appName, value: "", color: TaggrTheme.accent)
                    ForEach(realms, id: \.self) { realm in
                        realmOption(name: realm, value: realm, color: realmColor(for: realm))
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.visible)
            .frame(width: 220, height: min(CGFloat(realms.count + 1) * 44 + 16, 360))
            .background(TaggrTheme.darkPanel)
            .presentationCompactAdaptation(.popover)
        }
    }

    private func realmOption(name: String, value: String, color: Color) -> some View {
        Button {
            selection = value
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TaggrTheme.text)
                    .lineLimit(1)
                Spacer()
                if selection.caseInsensitiveCompare(value) == .orderedSame {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(TaggrTheme.clickable)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(
            selection.caseInsensitiveCompare(value) == .orderedSame ? .isSelected : []
        )
    }

    private func realmColor(for name: String) -> Color {
        Color(hex: realmColors[name.uppercased()]) ?? TaggrTheme.accent
    }
}

/// Keeps generated blob Markdown out of the editable text surface. The post is
/// still stored as Markdown, so web and older app clients remain compatible.
struct ComposePostDocumentEditor: View {
    @Binding var text: String
    let draftImages: [TaggrDraftImage]
    let existingImages: [String: TaggrEditablePostImage]
    let placeholder: String
    let documentID: UUID
    let focusedTextSegmentID: FocusState<Int?>.Binding
    @Binding var imageInsertionSegmentID: Int?
    let removeImage: (Int, String) -> Void
    let moveImage: (Int, Int?) -> Void
    let moveImageToTextSegment: (Int, Int) -> Void

    init(
        text: Binding<String>,
        draftImages: [TaggrDraftImage],
        existingImages: [String: TaggrEditablePostImage],
        placeholder: String,
        documentID: UUID,
        focusedTextSegmentID: FocusState<Int?>.Binding,
        imageInsertionSegmentID: Binding<Int?>,
        removeImage: @escaping (Int, String) -> Void,
        moveImage: @escaping (Int, Int?) -> Void,
        moveImageToTextSegment: @escaping (Int, Int) -> Void = { _, _ in }
    ) {
        _text = text
        self.draftImages = draftImages
        self.existingImages = existingImages
        self.placeholder = placeholder
        self.documentID = documentID
        self.focusedTextSegmentID = focusedTextSegmentID
        _imageInsertionSegmentID = imageInsertionSegmentID
        self.removeImage = removeImage
        self.moveImage = moveImage
        self.moveImageToTextSegment = moveImageToTextSegment
    }

    private var segments: [PostDraftDocument.Segment] {
        PostDraftDocument.segments(in: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(segments) { segment in
                switch segment {
                case .text(let id, let value):
                    textBlock(id: id, value: value)
                case .image(_, let occurrence, let markdown, let blobID):
                    imageBlock(occurrence: occurrence, markdown: markdown, blobID: blobID)
                }
            }
        }
    }

    private func textBlock(id: Int, value: String) -> some View {
        ComposePostTextSegmentEditor(
            segmentID: id,
            value: value,
            placeholder: segments.count == 1 ? placeholder : nil,
            focusedTextSegmentID: focusedTextSegmentID,
            updateText: { replacement in
                let updated = PostDraftDocument.replacingText(
                    in: text,
                    segmentID: id,
                    with: replacement
                )
                guard updated != text else { return }
                text = updated
            },
            activate: {
                imageInsertionSegmentID = id
            },
            dropImage: { item in
                guard accepts(item) else { return false }
                endTextEditing()
                moveImageToTextSegment(item.occurrence, id)
                return true
            }
        )
    }

    @ViewBuilder
    private func imageBlock(occurrence: Int, markdown: String, blobID: String) -> some View {
        let draftImage = draftImages.first { $0.id == blobID }
        let existingImage = existingImages[blobID]
        ZStack(alignment: .topTrailing) {
            if let draftImage, let uiImage = UIImage(data: draftImage.data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if let existingImage {
                TaggrPostImageLoaderView(
                    attachment: existingImage.attachment,
                    contentMode: .fit,
                    maximumPixelSize: 1_024
                )
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Label("Attached image", systemImage: "photo")
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(TaggrTheme.darkPanel)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Button("Remove image", systemImage: "xmark") {
                endTextEditing()
                removeImage(occurrence, blobID)
            }
            .labelStyle(.iconOnly)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Color.black.opacity(0.55))
            .clipShape(Circle())
            .padding(8)
        }
        .draggable(
            PostDraftImageDragItem(
                documentID: documentID,
                documentFingerprint: text.hashValue,
                occurrence: occurrence
            )
        )
        .dropDestination(for: PostDraftImageDragItem.self) { items, _ in
            guard let item = items.first, accepts(item), item.occurrence != occurrence else { return false }
            endTextEditing()
            moveImage(item.occurrence, occurrence)
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attached image. Drag to change its position.")
    }

    private func accepts(_ item: PostDraftImageDragItem) -> Bool {
        guard item.documentID == documentID,
              item.documentFingerprint == text.hashValue else { return false }
        return segments.contains { segment in
            if case .image(_, let occurrence, _, _) = segment {
                return occurrence == item.occurrence
            }
            return false
        }
    }

    private func endTextEditing() {
        focusedTextSegmentID.wrappedValue = nil
        imageInsertionSegmentID = nil
    }
}

private struct ComposePostTextSegmentEditor: View {
    let segmentID: Int
    let value: String
    let placeholder: String?
    let focusedTextSegmentID: FocusState<Int?>.Binding
    let updateText: (String) -> Void
    let activate: () -> Void
    let dropImage: (PostDraftImageDragItem) -> Bool
    @State private var inputText: String

    init(
        segmentID: Int,
        value: String,
        placeholder: String?,
        focusedTextSegmentID: FocusState<Int?>.Binding,
        updateText: @escaping (String) -> Void,
        activate: @escaping () -> Void,
        dropImage: @escaping (PostDraftImageDragItem) -> Bool
    ) {
        self.segmentID = segmentID
        self.value = value
        self.placeholder = placeholder
        self.focusedTextSegmentID = focusedTextSegmentID
        self.updateText = updateText
        self.activate = activate
        self.dropImage = dropImage
        _inputText = State(initialValue: value)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $inputText)
                .scrollContentBackground(.hidden)
                .font(.title3)
                .foregroundStyle(TaggrTheme.text)
                .frame(minHeight: inputText.isEmpty ? 70 : 120)
                .tint(TaggrTheme.clickable)
                .focused(focusedTextSegmentID, equals: segmentID)
                .onTapGesture(perform: activate)
                .dropDestination(for: PostDraftImageDragItem.self) { items, _ in
                    guard let item = items.first else { return false }
                    return dropImage(item)
                }
            if inputText.isEmpty, let placeholder {
                Text(placeholder)
                    .font(.title3)
                    .foregroundStyle(TaggrTheme.secondaryText)
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: inputText) { _, replacement in
            guard replacement != value else { return }
            updateText(replacement)
        }
        .onChange(of: value) { _, updatedValue in
            guard inputText != updatedValue else { return }
            inputText = updatedValue
        }
    }
}

struct PostDraftImageDragItem: Codable, Transferable {
    let documentID: UUID
    let documentFingerprint: Int
    let occurrence: Int

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .taggrPostDraftImage)
    }
}

private extension UTType {
    static let taggrPostDraftImage = UTType(exportedAs: "network.taggr.ios.post-draft-image")
}

private struct ComposePostCreditCostBadge: View {
    let cost: Int?
    let unavailable: Bool

    var body: some View {
        HStack(spacing: 6) {
            ComposeCreditsIcon()
                .frame(width: 18, height: 18)
            Text(unavailable ? "—" : cost.map { $0.formatted() } ?? "...")
                .font(.title3.weight(.bold))
        }
        .foregroundStyle(TaggrTheme.text)
        .accessibilityLabel(
            unavailable
                ? "Cost unavailable"
                : cost.map { "Cost \($0.formatted()) credits" } ?? "Calculating cost"
        )
    }
}

private struct ComposeCreditsIcon: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let w = proxy.size.width
                let h = proxy.size.height
                path.move(to: CGPoint(x: 0.70 * w, y: 0.00 * h))
                path.addCurve(to: CGPoint(x: 0.72 * w, y: 0.04 * h), control1: CGPoint(x: 0.72 * w, y: -0.01 * h), control2: CGPoint(x: 0.73 * w, y: 0.01 * h))
                path.addLine(to: CGPoint(x: 0.60 * w, y: 0.41 * h))
                path.addLine(to: CGPoint(x: 0.82 * w, y: 0.41 * h))
                path.addCurve(to: CGPoint(x: 0.85 * w, y: 0.47 * h), control1: CGPoint(x: 0.86 * w, y: 0.41 * h), control2: CGPoint(x: 0.88 * w, y: 0.45 * h))
                path.addLine(to: CGPoint(x: 0.34 * w, y: 0.98 * h))
                path.addCurve(to: CGPoint(x: 0.28 * w, y: 0.94 * h), control1: CGPoint(x: 0.30 * w, y: 1.02 * h), control2: CGPoint(x: 0.25 * w, y: 0.98 * h))
                path.addLine(to: CGPoint(x: 0.40 * w, y: 0.59 * h))
                path.addLine(to: CGPoint(x: 0.18 * w, y: 0.59 * h))
                path.addCurve(to: CGPoint(x: 0.15 * w, y: 0.53 * h), control1: CGPoint(x: 0.14 * w, y: 0.59 * h), control2: CGPoint(x: 0.12 * w, y: 0.55 * h))
                path.addLine(to: CGPoint(x: 0.66 * w, y: 0.02 * h))
                path.addCurve(to: CGPoint(x: 0.70 * w, y: 0.00 * h), control1: CGPoint(x: 0.67 * w, y: 0.01 * h), control2: CGPoint(x: 0.69 * w, y: 0.00 * h))
                path.closeSubpath()
            }
            .fill(TaggrTheme.text)
        }
    }
}

struct ComposePostImageWarning: View {
    let text: String
    let showCreateStorage: Bool
    let createStorage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)
            if showCreateStorage {
                Button {
                    createStorage()
                } label: {
                    Label("Create storage", systemImage: "externaldrive.badge.plus")
                        .font(.footnote.weight(.bold))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TaggrTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

enum TaggrPostCreditCost {
    static let defaultMaxTagLength = 30

    static func estimate(body: String, baseCost: Int, tagCost: Int) -> Int {
        let sizeMultiplier = (body.utf8.count / 1024) + 1
        return max(baseCost, 0) * sizeMultiplier + max(tagCost, 0)
    }

    static func estimateEdit(
        body: String,
        post: TaggrPost,
        baseCost: Int,
        tagCost: Int,
        pollCost: Int?
    ) -> Int? {
        guard let historicalPatchBytes = historicalPatchBytes(in: post) else { return nil }
        let newPatchBytes = body == post.body
            ? 0
            : TaggrEditPatch.fullReplacement(from: body, to: post.body).utf8.count
        let pollSurcharge: Int
        if case .poll = post.extensionKind {
            guard let pollCost else { return nil }
            pollSurcharge = pollCost
        } else {
            pollSurcharge = 0
        }
        let sizeMultiplier = ((body.utf8.count + historicalPatchBytes + newPatchBytes) / 1024) + 1
        return baseCost * sizeMultiplier + tagCost + pollSurcharge
    }

    private static func historicalPatchBytes(in post: TaggrPost) -> Int? {
        var total = 0
        for values in post.patches {
            guard values.count >= 2, let patch = values[1].stringValue else { return nil }
            total += patch.utf8.count
        }
        return total
    }
    static func tags(in input: String, maxLength: Int) -> [String] {
        var seen = Set<String>()
        return tokens(in: input, prefixes: ["#", "$"], maxLength: maxLength)
            .map { $0.lowercased() }
            .filter { seen.insert($0).inserted }
    }

    private static func tokens(in input: String, prefixes: Set<Character>, maxLength: Int) -> [String] {
        var tokens: [String] = []
        var token = ""
        var tokenFound = false
        var whitespaceSeen = true

        for character in input {
            if whitespaceSeen && prefixes.contains(character) {
                tokenFound = true
            } else if tokenFound {
                if character.isLetter || character.isNumber || character == "-" || character == "_" {
                    token.append(character)
                } else {
                    appendToken(token, maxLength: maxLength, to: &tokens)
                    token = ""
                    tokenFound = false
                }
            }
            whitespaceSeen = character == " " || character == "\n" || character == "\t"
        }

        appendToken(token, maxLength: maxLength, to: &tokens)
        return tokens
    }

    private static func appendToken(_ token: String, maxLength: Int, to tokens: inout [String]) {
        let length = token.count
        guard length > 0, length <= maxLength, !token.allSatisfy(\.isNumber) else { return }
        tokens.append(token)
    }
}
