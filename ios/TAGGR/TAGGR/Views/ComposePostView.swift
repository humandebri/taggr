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
    @StateObject private var editingController = ComposeEditingController()
    @State private var editorVisible = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var imageImportWarning: String?
    @State private var imageInsertionSegmentID: Int?
    @State private var documentID = UUID()
    @State private var creditCost: Int?
    @State private var creditCostUnavailable = false
    @State private var realmColors: [String: String] = [:]
    @State private var isSubmitting = false
    @State private var discardConfirmationPresented = false
    @State private var focusedTextSegmentID: Int?

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
                            draftImages: Binding(get: { draft.images }, set: { draft.restoreEditorImages($0) }),
                            existingImages: existingImagesByID,
                            placeholder: mode.placeholder,
                            documentID: documentID,
                            focusedTextSegmentID: $focusedTextSegmentID,
                            imageInsertionSegmentID: $imageInsertionSegmentID,
                            removeImage: removeImageMarker,
                            moveImage: moveImageMarker,
                            moveImageToTextSegment: moveImageMarker
                        )
                        .disabled(!draft.isLoaded || imageImport.isImporting || isSubmitting)
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
        .environmentObject(editingController)
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
        .onAppear { editorVisible = true }
        .onDisappear {
            editorVisible = false
            editingController.disconnect()
            cancelImageImport()
            Task { await draft.flush() }
        }
        .task(id: draftNamespaceID) {
            cancelImageImport()
            editingController.disconnect()
            documentID = UUID()
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
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard imageWarning == nil else { return false }
        guard realmWarning == nil else { return false }
        guard let editingPost = mode.editingPost else { return true }
        return body != editingPost.body || selectedTargetRealm != editingPost.realm
    }

    private var composedBody: String {
        draft.text
    }

    private var shouldShowCreditCost: Bool {
        !composedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

                    draft: draft
                )
            } else {
                enqueued = state.enqueuePostSubmission(
                    text: body,
                    parent: mode.parentPostID,
                    realm: selectedTargetRealm,
                    images: images,

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
        guard let snapshot = editingController.imageSnapshot ?? editingController.capture(suspend: true) else { return }
        editingController.imageSnapshot = snapshot
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
                editingController.imageSnapshot = nil
                selectedPhotos = []
                imageImportWarning = result.warning
                let loaded = ImageDrafts.uniquedDraftImages(
                    result.images,
                    existingIDs: Set(draft.images.map(\.id))
                )
                guard draft.text == snapshot.text, editingController.matches(snapshot) else {
                    editingController.restore(snapshot)
                    return
                }
                if loaded.isEmpty {
                    editingController.restore(snapshot)
                } else {
                    let inserted = PostDraftDocument.insertingImages(loaded.map(\.markdown), in: snapshot.text, at: snapshot.selection.location)
                    editingController.apply(
                        ComposeMarkdownEdit(text: inserted.text, selection: NSRange(location: inserted.cursor, length: 0)), replacing: snapshot,
                        images: snapshot.images + loaded
                    )
                    await draft.flush()
                }
            }
        )
    }

    private func cancelImageImport() {
        imageImport.cancel()
        if let snapshot = editingController.imageSnapshot { editingController.restore(snapshot) }
        editingController.imageSnapshot = nil
        selectedPhotos = []
        imageImportWarning = nil
    }

    private func removeImageMarker(_ occurrence: Int, blobID _: String) {
        editingController.removeImage(occurrence: occurrence)
        Task { await draft.flush() }
    }

    private func moveImageMarker(_ occurrence: Int, before target: Int?) {
        editingController.moveImage(occurrence: occurrence, before: target)
        Task { await draft.flush() }
    }

    private func moveImageMarker(_ occurrence: Int, afterTextSegmentID: Int) {
        editingController.moveImage(occurrence: occurrence, afterTextSegmentID: afterTextSegmentID)
        Task { await draft.flush() }
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

    private func insertExternalURLInEditor(_ url: URL) async -> Bool {
        guard editorVisible, draft.isLoaded else { return false }
        editingController.connect(documentID: documentID, text: $draft.text,
                                  images: Binding(get: { draft.images }, set: { draft.restoreEditorImages($0) }), focus: $focusedTextSegmentID)
        guard editingController.insertExternalURL(url) else { return false }
        return await draft.saveEditorChanges()
    }

    private func insertYouTubeURL(_ url: URL) {
        Task {
            let inserted = await insertExternalURLInEditor(url)
            if inserted, let youtubeDraftTarget {
                await state.youtubeUpload.acknowledgeCompletion(for: youtubeDraftTarget)
            }
        }
    }

    private func consumeCompletedYouTubeUpload() async {
        guard let youtubeDraftTarget,
              let url = state.youtubeUpload.completedURL(for: youtubeDraftTarget) else { return }
        if await insertExternalURLInEditor(url) {
            await state.youtubeUpload.acknowledgeCompletion(for: youtubeDraftTarget)
        }
    }

    private func resumeSubmission() {
        Task { await draft.clearSubmissionVerification() }
    }

    @MainActor
    private func refreshCreditCost() async {
        let body = composedBody
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
    @EnvironmentObject private var editingController: ComposeEditingController
    @Binding var text: String
    @Binding var draftImages: [TaggrDraftImage]
    let existingImages: [String: TaggrEditablePostImage]
    let placeholder: String
    let documentID: UUID
    let focusedTextSegmentID: Binding<Int?>
    @Binding var imageInsertionSegmentID: Int?
    let removeImage: (Int, String) -> Void
    let moveImage: (Int, Int?) -> Void
    let moveImageToTextSegment: (Int, Int) -> Void

    init(
        text: Binding<String>,
        draftImages: Binding<[TaggrDraftImage]>,
        existingImages: [String: TaggrEditablePostImage],
        placeholder: String,
        documentID: UUID,
        focusedTextSegmentID: Binding<Int?>,
        imageInsertionSegmentID: Binding<Int?>,
        removeImage: @escaping (Int, String) -> Void,
        moveImage: @escaping (Int, Int?) -> Void,
        moveImageToTextSegment: @escaping (Int, Int) -> Void = { _, _ in }
    ) {
        _text = text
        _draftImages = draftImages
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
        .onAppear { connectEditor() }
        .onChange(of: documentID) { _, _ in connectEditor() }
        .onChange(of: text) { _, _ in connectEditor() }
        .onChange(of: draftImages) { _, _ in connectEditor() }
        .onDisappear { editingController.disconnect() }
    }

    private func connectEditor() {
        editingController.connect(documentID: documentID, text: $text, images: $draftImages, focus: focusedTextSegmentID)
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
                if imageInsertionSegmentID != id { imageInsertionSegmentID = id }
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
    @EnvironmentObject private var editingController: ComposeEditingController
    let segmentID: Int
    let value: String
    let placeholder: String?
    let focusedTextSegmentID: Binding<Int?>
    let updateText: (String) -> Void
    let activate: () -> Void
    let dropImage: (PostDraftImageDragItem) -> Bool

    init(
        segmentID: Int,
        value: String,
        placeholder: String?,
        focusedTextSegmentID: Binding<Int?>,
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
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ComposeSelectableTextEditor(
                text: Binding(get: { value }, set: updateText),
                editingController: editingController,
                isFocused: focusedTextSegmentID.wrappedValue == segmentID,
                activate: {
                    if focusedTextSegmentID.wrappedValue != segmentID { focusedTextSegmentID.wrappedValue = segmentID }
                    activate()
                },
                segmentID: segmentID
            )
                .frame(maxWidth: .infinity, minHeight: value.isEmpty ? 70 : 120, alignment: .topLeading)
                .tint(TaggrTheme.clickable)
                .onTapGesture(perform: activate)
                .dropDestination(for: PostDraftImageDragItem.self) { items, _ in
                    guard let item = items.first else { return false }
                    return dropImage(item)
                }
            if value.isEmpty, let placeholder {
                Text(placeholder)
                    .font(.title3)
                    .foregroundStyle(TaggrTheme.secondaryText)
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
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


struct ComposeMarkdownEdit {
    let text: String
    let selection: NSRange

    static func applying(_ action: ComposeMarkdownAction, to text: String, selection: NSRange, url: String = "") -> Self {
        let source = text as NSString
        let start = min(max(0, selection.location), source.length)
        let range = NSRange(location: start, length: min(max(0, selection.length), source.length - start))
        let selected = source.substring(with: range)
        let replacement: String
        let resultSelection: NSRange
        switch action {
        case .bold, .italic:
            let marker = action == .bold ? "**" : "_"
            replacement = marker + selected + marker
            resultSelection = NSRange(location: start + marker.utf16.count, length: range.length)
        case .list:
            replacement = selected.components(separatedBy: "\n").map { "- " + $0 }.joined(separator: "\n")
            resultSelection = NSRange(location: start + replacement.utf16.count, length: 0)
        case .quote:
            replacement = "> " + selected
            resultSelection = NSRange(location: start + replacement.utf16.count, length: 0)
        case .link:
            guard !url.isEmpty else { return Self(text: text, selection: range) }
            replacement = "[\(selected)](\(url))"
            resultSelection = NSRange(location: start + (range.length == 0 ? 1 : replacement.utf16.count), length: 0)
        }
        return Self(text: source.replacingCharacters(in: range, with: replacement), selection: resultSelection)
    }
}

@MainActor
final class ComposeEditingController: ObservableObject {
    struct Snapshot {
        let documentID: UUID
        let text: String
        let selection: NSRange
        var images: [TaggrDraftImage] = []
    }

    let undoManager = UndoManager()
    fileprivate weak var active: ComposeSelectableTextEditor.Coordinator?
    fileprivate var pendingSelection: NSRange?
    private var documentID: UUID?
    private var document: Binding<String>?
    private var images: Binding<[TaggrDraftImage]>?
    fileprivate var pendingSelectionRequestsFocus = true
    private var focus: Binding<Int?>?
    // UIKit can change text between SwiftUI renders; offsets must use that latest text.
    fileprivate private(set) var documentText: String?
    private(set) var suspended = false
    var imageSnapshot: Snapshot?

    func connect(documentID: UUID, text: Binding<String>, images: Binding<[TaggrDraftImage]>, focus: Binding<Int?>) {
        if self.documentID != nil && self.documentID != documentID {
            undoManager.removeAllActions()
            active = nil
            pendingSelection = nil
            imageSnapshot = nil
        }
        self.documentID = documentID
        document = text
        self.images = images
        documentText = text.wrappedValue
        self.focus = focus
        if !suspended { active?.restorePendingSelection(in: text.wrappedValue) }
    }

    func disconnect() {
        undoManager.removeAllActions()
        documentID = nil
        document = nil
        images = nil
        focus = nil
        pendingSelection = nil
        pendingSelectionRequestsFocus = true
        documentText = nil
        active = nil
        imageSnapshot = nil
        suspended = false
    }

    func capture(suspend: Bool = false) -> Snapshot? {
        guard let documentID, let document, var current = documentText else { return nil }
        let hadMarkedText = active?.view?.markedTextRange != nil
        let textIncludingMarkedText = active?.view?.text
        let selectionIncludingMarkedText = active?.view?.selectedRange
        active?.view?.unmarkText()
        // Commit IME text synchronously, but never overwrite a newer model update.
        if let active, let view = active.view {
            if hadMarkedText {
                current = PostDraftDocument.replacingText(
                    in: current,
                    segmentID: active.parent.segmentID,
                    with: textIncludingMarkedText ?? view.text
                )
                documentText = current
                document.wrappedValue = current
            } else {
                guard case .text(_, let current)? = PostDraftDocument.segments(in: current).first(where: { $0.id == active.parent.segmentID }), current == view.text else { return nil }
            }
        }
        let text = current
        let selection: NSRange
        if let active, let view = active.view,
           let offset = PostDraftDocument.textOffset(in: text, segmentID: active.parent.segmentID) {
            let localSelection = hadMarkedText ? selectionIncludingMarkedText ?? view.selectedRange : view.selectedRange
            selection = NSRange(location: offset + localSelection.location, length: localSelection.length)
        } else {
            selection = NSRange(location: text.utf16.count, length: 0)
        }
        if suspend {
            suspended = true
            focus?.wrappedValue = nil
            active?.view?.resignFirstResponder()
        }
        return Snapshot(documentID: documentID, text: text, selection: selection, images: images?.wrappedValue ?? [])
    }

    func matches(_ snapshot: Snapshot) -> Bool {
        documentID == snapshot.documentID && documentText == snapshot.text && document?.wrappedValue == snapshot.text && images?.wrappedValue == snapshot.images
    }

    func restore(_ snapshot: Snapshot) {
        suspended = false
        guard matches(snapshot) else { return }
        select(snapshot.selection, in: snapshot.text)
    }

    func perform(_ action: ComposeMarkdownAction, snapshot: Snapshot? = nil, url: String = "") {
        guard let snapshot = snapshot ?? capture(), matches(snapshot) else { return }
        let edit = ComposeMarkdownEdit.applying(action, to: snapshot.text, selection: snapshot.selection, url: url)
        apply(edit, replacing: snapshot)
    }

    func recordTyping(segmentID: Int, text: String, beforeSelection: NSRange, selection: NSRange) {
        guard let documentID, let previous = documentText,
              let offset = PostDraftDocument.textOffset(in: previous, segmentID: segmentID) else { return }
        let updated = PostDraftDocument.replacingText(in: previous, segmentID: segmentID, with: text)
        guard previous != updated else { return }
        let before = NSRange(location: offset + beforeSelection.location, length: beforeSelection.length)
        let after = NSRange(location: offset + selection.location, length: selection.length)
        apply(ComposeMarkdownEdit(text: updated, selection: after),
              replacing: Snapshot(documentID: documentID, text: previous, selection: before, images: images?.wrappedValue ?? []),
              restoreSelection: false)
    }

    func resumeFocus() {
        guard documentID != nil, !suspended, let active, let view = active.view, view.isEditable else { return }
        active.parent.activate()
        view.becomeFirstResponder()
    }

    func quote() { perform(.quote) }

    func apply(_ edit: ComposeMarkdownEdit, replacing snapshot: Snapshot, images updatedImages: [TaggrDraftImage]? = nil, restoreSelection: Bool = true, requestFocus: Bool = true) {
        guard matches(snapshot), let document, let images else { return }
        suspended = false
        let nextImages = updatedImages ?? snapshot.images
        let next = Snapshot(documentID: snapshot.documentID, text: edit.text, selection: edit.selection, images: nextImages)
        if edit.text != snapshot.text || nextImages != snapshot.images {
            undoManager.registerUndo(withTarget: self) { target in
                target.apply(ComposeMarkdownEdit(text: snapshot.text, selection: snapshot.selection), replacing: next, images: snapshot.images)
            }
            documentText = edit.text
            document.wrappedValue = edit.text
            if images.wrappedValue != nextImages { images.wrappedValue = nextImages }
        }
        if restoreSelection { select(edit.selection, in: edit.text, requestFocus: requestFocus) }
    }

    func removeImage(occurrence: Int) {
        guard let snapshot = capture(), let range = imageRange(occurrence: occurrence, in: snapshot.text) else { return }
        let text = PostDraftDocument.removing(imageOccurrence: occurrence, from: snapshot.text)
        let removedID = PostDraftDocument.segments(in: snapshot.text).compactMap { segment -> String? in
            if case .image(_, let index, _, let id) = segment, index == occurrence { return id }; return nil
        }.first
        let remaining = snapshot.images.filter { $0.id != removedID || PostDraftDocument.containsImageMarker(blobID: $0.id, in: text) }
        apply(ComposeMarkdownEdit(text: text, selection: NSRange(location: range.location, length: 0)), replacing: snapshot, images: remaining)
    }

    func moveImage(occurrence: Int, before target: Int?) {
        guard let snapshot = capture(), imageRange(occurrence: occurrence, in: snapshot.text) != nil,
              target != occurrence else { return }
        let text = PostDraftDocument.moving(imageOccurrence: occurrence, before: target, in: snapshot.text)
        let count = PostDraftDocument.segments(in: text).filter { if case .image = $0 { return true }; return false }.count
        let destination = target.map { $0 > occurrence ? $0 - 1 : $0 } ?? (count - 1)
        applyImageMove(text, occurrence: destination, snapshot: snapshot)
    }

    func moveImage(occurrence: Int, afterTextSegmentID: Int) {
        guard let snapshot = capture(), imageRange(occurrence: occurrence, in: snapshot.text) != nil,
              PostDraftDocument.textOffset(in: snapshot.text, segmentID: afterTextSegmentID) != nil else { return }
        let text = PostDraftDocument.moving(imageOccurrence: occurrence, afterTextSegmentID: afterTextSegmentID, in: snapshot.text)
        let precedingImages = afterTextSegmentID / 2
        let destination = precedingImages - (occurrence < precedingImages ? 1 : 0)
        applyImageMove(text, occurrence: destination, snapshot: snapshot)
    }

    private func applyImageMove(_ text: String, occurrence: Int, snapshot: Snapshot) {
        guard text != snapshot.text, let range = imageRange(occurrence: occurrence, in: text) else { return }
        apply(ComposeMarkdownEdit(text: text, selection: NSRange(location: NSMaxRange(range), length: 0)), replacing: snapshot)
    }

    private func imageRange(occurrence: Int, in text: String) -> NSRange? {
        var offset = 0
        for segment in PostDraftDocument.segments(in: text) {
            switch segment {
            case .text(_, let value): offset += value.utf16.count
            case .image(_, let index, let markdown, _):
                if index == occurrence { return NSRange(location: offset, length: markdown.utf16.count) }
                offset += markdown.utf16.count
            }
        }
        return nil
    }

    @discardableResult
    func insertExternalURL(_ url: URL) -> Bool {
        guard let documentID, let text = documentText, let images else { return false }
        // Upload completion can arrive before UIKit has rendered a restored draft.
        let snapshot = capture() ?? Snapshot(documentID: documentID, text: text, selection: NSRange(location: text.utf16.count, length: 0), images: images.wrappedValue)
        guard matches(snapshot) else { return false }
        let updated = PostDraftDocument.appendingExternalURL(url, to: snapshot.text)
        let start = min(snapshot.selection.location, updated.utf16.count)
        let selection = NSRange(location: start, length: min(snapshot.selection.length, updated.utf16.count - start))
        apply(ComposeMarkdownEdit(text: updated, selection: selection), replacing: snapshot, requestFocus: false)
        return true
    }

    private func select(_ selection: NSRange, in text: String, requestFocus: Bool = true) {
        pendingSelection = selection
        pendingSelectionRequestsFocus = requestFocus
        if requestFocus, let id = PostDraftDocument.textSegment(in: text, at: selection.location) {
            focus?.wrappedValue = id
        }
        // A no-op/cancel still needs to restore focus without a SwiftUI text change.
        active?.restorePendingSelection(in: text)
    }
}

struct ComposeSelectableTextEditor: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    let editingController: ComposeEditingController
    let isFocused: Bool
    let activate: () -> Void
    var segmentID: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> TextView {
        let view = TextView()
        view.editorUndoManager = editingController.undoManager
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = UIFont.preferredFont(forTextStyle: .title3)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = UIColor(TaggrTheme.text)
        view.tintColor = UIColor(TaggrTheme.clickable)
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.view = view
        if editingController.active == nil { editingController.active = context.coordinator }
        return view
    }

    func updateUIView(_ view: TextView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = isEnabled
        view.isSelectable = isEnabled
        let textColor = UIColor(TaggrTheme.text)
        let font = UIFont.preferredFont(forTextStyle: .title3, compatibleWith: view.traitCollection)
        view.font = font
        view.textColor = textColor
        view.tintColor = UIColor(TaggrTheme.clickable)
        if view.markedTextRange == nil, view.text != text {
            let selection = view.selectedRange
            let undo = view.undoManager
            undo?.disableUndoRegistration()
            view.textStorage.replaceCharacters(in: NSRange(location: 0, length: view.text.utf16.count), with: text)
            if view.textStorage.length > 0 {
                view.textStorage.addAttributes(
                    [.font: font, .foregroundColor: textColor],
                    range: NSRange(location: 0, length: view.textStorage.length)
                )
            }
            undo?.enableUndoRegistration()
            let start = min(selection.location, (text as NSString).length)
            view.selectedRange = NSRange(location: start, length: min(selection.length, (text as NSString).length - start))
        }
        view.typingAttributes[.font] = font
        view.typingAttributes[.foregroundColor] = textColor
        view.shouldBeFocused = isFocused && isEnabled && !editingController.suspended
        view.updateFocus()
        if isFocused && isEnabled {
            context.coordinator.restorePendingSelection(in: editingController.documentText ?? text)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        let fittingSize = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: fittingSize.height)
    }

    final class TextView: UITextView {
        var shouldBeFocused = false
        weak var editorUndoManager: UndoManager?
        private var focusTask: Task<Void, Never>?
        override var undoManager: UndoManager? { editorUndoManager ?? super.undoManager }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateFocus()
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            guard previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }
            font = UIFont.preferredFont(forTextStyle: .title3, compatibleWith: traitCollection)
            invalidateIntrinsicContentSize()
        }

        func updateFocus() {
            focusTask?.cancel()
            focusTask = nil
            guard window != nil else { return }
            if shouldBeFocused, isEditable, !isFirstResponder {
                // Defer focus until SwiftUI has finished updating the representable.
                // Becoming first responder synchronously invokes the delegate, which
                // publishes the focused segment and is undefined during a view update.
                focusTask = Task { @MainActor [weak self] in
                    await Task.yield()
                    guard !Task.isCancelled, let self, self.window != nil,
                          self.shouldBeFocused, self.isEditable, !self.isFirstResponder else { return }
                    self.becomeFirstResponder()
                }
            } else if (!shouldBeFocused || !isEditable), isFirstResponder {
                resignFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposeSelectableTextEditor
        weak var view: UITextView?
        private var beforeSelection = NSRange(location: 0, length: 0)
        init(_ parent: ComposeSelectableTextEditor) { self.parent = parent }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.editingController.active = self
            parent.activate()
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            beforeSelection = textView.selectedRange
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.editingController.recordTyping(segmentID: parent.segmentID, text: textView.text, beforeSelection: beforeSelection, selection: textView.selectedRange)
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let controller = parent.editingController
            if textView.isFirstResponder { controller.active = self }
            // UITextInput.insertText and IME updates need not call shouldChangeTextIn.
            // Remember selection only before the text diverges from the model.
            if let text = controller.documentText,
               case .text(_, let value)? = PostDraftDocument.segments(in: text).first(where: { $0.id == parent.segmentID }),
               value == textView.text {
                beforeSelection = textView.selectedRange
            }
        }

        func restorePendingSelection(in text: String) {
            let controller = parent.editingController
            guard let view, view.isEditable, let selection = controller.pendingSelection,
                  PostDraftDocument.textSegment(in: text, at: selection.location) == parent.segmentID,
                  let offset = PostDraftDocument.textOffset(in: text, segmentID: parent.segmentID) else { return }
            guard case .text(_, let expected)? = PostDraftDocument.segments(in: text).first(where: { $0.id == parent.segmentID }), view.text == expected else { return }
            let local = NSRange(location: selection.location - offset, length: selection.length)
            guard NSMaxRange(local) <= view.text.utf16.count else { return }
            view.selectedRange = local
            controller.pendingSelection = nil
            if controller.pendingSelectionRequestsFocus { view.becomeFirstResponder() }
            view.selectedRange = local
        }
    }
}
