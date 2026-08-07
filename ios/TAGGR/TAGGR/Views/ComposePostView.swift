// TAGGR/Views: Shared full-screen composer for creating root posts, replies, and editing existing posts.

import PhotosUI
import SwiftUI
import UIKit

struct ComposePostView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @Environment(\.scenePhase) private var scenePhase
    let mode: PostComposerMode
    let dismiss: () -> Void
    @StateObject private var draft: PostDraftSession
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var creditCost: Int?
    @State private var isSubmitting = false
    @State private var discardConfirmationPresented = false
    @FocusState private var isTextEditorFocused: Bool

    init(mode: PostComposerMode, dismiss: @escaping () -> Void) {
        self.mode = mode
        self.dismiss = dismiss
        _draft = StateObject(
            wrappedValue: PostDraftSession(
                context: mode.draftContext,
                initialText: mode.initialText,
                initialRealm: mode.targetRealm ?? ""
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
                    showsCost: shouldShowCreditCost,
                    realmName: $draft.realm,
                    appName: appRealmName,
                    availableRealms: selectableRealms,
                    showsRealmPicker: showsRealmPicker,
                    showsDiscard: draft.hasChanges,
                    cancel: close,
                    discard: { discardConfirmationPresented = true },
                    submit: submit
                )

                Divider().overlay(TaggrTheme.panelRaised)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ComposePostTextEditor(
                            text: $draft.text,
                            placeholder: mode.placeholder,
                            isFocused: $isTextEditorFocused
                        )
                        if let warning = draft.restorationWarning {
                            ComposePostImageWarning(
                                text: warning,
                                showCreateStorage: false,
                                createStorage: {}
                            )
                        }
                        if let imageWarning {
                            ComposePostImageWarning(text: imageWarning, showCreateStorage: missingStorageForImages) {
                                openStorageSettings()
                            }
                        }
                        if !draft.images.isEmpty {
                            ComposePostDraftImageList(images: draft.images, removeImage: removeImage)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                }

                Divider().overlay(TaggrTheme.panelRaised)

                ComposePostAttachmentBar(
                    text: $draft.text,
                    selectedPhotos: $selectedPhotos,
                    isSubmitting: state.isBusy || isSubmitting
                )
            }
        }
        .onChange(of: selectedPhotos) { _, items in
            Task { await loadPhotos(items) }
        }
        .onChange(of: draft.text) { _, _ in
            draft.scheduleSave()
        }
        .onChange(of: draft.realm) { _, _ in
            draft.scheduleSave()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            Task { await draft.flush() }
        }
        .onAppear {
            isTextEditorFocused = true
        }
        .onDisappear {
            Task { await draft.flush() }
        }
        .task(id: draftNamespaceID) {
            guard let namespace = draftNamespace else { return }
            await draft.load(store: state.postDraftStore, namespace: namespace)
        }
        .task(id: creditCostRefreshKey) {
            await refreshCreditCost()
        }
        .confirmationDialog(
            "Discard this draft?",
            isPresented: $discardConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Discard Draft", role: .destructive) {
                Task {
                    await draft.discard()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var canSubmit: Bool {
        guard draft.isLoaded, state.currentUser != nil else { return false }
        let body = composedBody
        guard !body.isEmpty else { return false }
        guard imageWarning == nil else { return false }
        guard let editingPost = mode.editingPost else { return true }
        return body != editingPost.body
    }

    private var composedBody: String {
        draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldShowCreditCost: Bool {
        mode.editingPost == nil && !composedBody.isEmpty
    }

    private var creditCostRefreshKey: String {
        [
            mode.editingPost == nil ? "create" : "edit",
            creditCostTags.joined(separator: ","),
            String((composedBody.utf8.count / 1024) + 1),
            state.runtimeConfig.canisterId,
            String(state.cache?.config?.postCost ?? -1),
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
        if case .newPost = mode {
            return true
        }
        return false
    }

    private var selectableRealms: [String] {
        var values = state.currentUser?.realms ?? []
        if let target = mode.targetRealm, !target.isEmpty, !values.contains(where: { $0.caseInsensitiveCompare(target) == .orderedSame }) {
            values.insert(target, at: 0)
        }
        return values
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
            if let editingPost = mode.editingPost {
                await state.editPost(post: editingPost, text: body, images: images, reloadMode: mode.selectedMode)
            } else {
                await state.submitPost(
                    text: body,
                    parent: mode.parentPostID,
                    realm: selectedTargetRealm,
                    images: images,
                    reloadMode: mode.timelineModeAfterSubmit
                )
            }
            isSubmitting = false
            if state.errorMessage == nil {
                await draft.discard()
                dismiss()
            }
        }
    }

    @MainActor
    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        var sourceData: [Data] = []
        let maxBytes = state.cache?.config?.maxBlobSizeBytes ?? ImageDrafts.maxImageBytes
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                sourceData.append(data)
            }
        }
        var loaded = await ImageDrafts.draftImages(from: sourceData, maxBytes: maxBytes)
        guard !loaded.isEmpty else {
            selectedPhotos = []
            return
        }
        loaded = ImageDrafts.uniquedDraftImages(loaded, existingIDs: Set(draft.images.map(\.id)))
        await draft.addImages(loaded)
        selectedPhotos = []
    }

    private func removeImage(_ image: TaggrDraftImage) {
        Task { await draft.removeImage(image) }
    }

    @MainActor
    private func refreshCreditCost() async {
        let body = composedBody
        guard mode.editingPost == nil, !body.isEmpty else {
            creditCost = nil
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        let cost = await state.postCreditCost(for: body)
        if body == composedBody {
            creditCost = cost
        }
    }

    private var selectedTargetRealm: String? {
        guard case .newPost = mode else {
            return mode.targetRealm
        }
        return draft.realm.isEmpty ? nil : draft.realm
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
        Task {
            await draft.flush()
            dismiss()
        }
    }

    private func openStorageSettings() {
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
    let showsCost: Bool
    @Binding var realmName: String
    let appName: String
    let availableRealms: [String]
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
                    realms: availableRealms
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
                ComposePostCreditCostBadge(cost: cost)
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

    var body: some View {
        Menu {
            Button(appName) {
                selection = ""
            }
            ForEach(realms, id: \.self) { realm in
                Button(realm) {
                    selection = realm
                }
            }
        } label: {
            HStack(spacing: 6) {
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
    }
}

private struct ComposePostTextEditor: View {
    @Binding var text: String
    let placeholder: String
    let isFocused: FocusState<Bool>.Binding

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .font(.title3)
                .foregroundStyle(TaggrTheme.text)
                .frame(minHeight: 170)
                .tint(TaggrTheme.clickable)
                .focused(isFocused)
            if text.isEmpty {
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

private struct ComposePostCreditCostBadge: View {
    let cost: Int?

    var body: some View {
        HStack(spacing: 6) {
            ComposeCreditsIcon()
                .frame(width: 18, height: 18)
            Text(cost.map { $0.formatted() } ?? "...")
                .font(.title3.weight(.bold))
        }
        .foregroundStyle(TaggrTheme.text)
        .accessibilityLabel(cost.map { "Cost \($0.formatted()) credits" } ?? "Calculating cost")
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

struct ComposePostDraftImageList: View {
    let images: [TaggrDraftImage]
    let removeImage: (TaggrDraftImage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(images, id: \.id) { image in
                ComposePostDraftImage(image: image) {
                    removeImage(image)
                }
            }
        }
    }
}

private struct ComposePostDraftImage: View {
    let image: TaggrDraftImage
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let uiImage = UIImage(data: image.data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Button("Remove image", systemImage: "xmark", action: remove)
                .labelStyle(.iconOnly)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.black.opacity(0.55))
                .clipShape(Circle())
                .padding(8)
        }
    }
}

enum TaggrPostCreditCost {
    static let defaultMaxTagLength = 30

    static func estimate(body: String, baseCost: Int, tagCost: Int) -> Int {
        let sizeMultiplier = (body.utf8.count / 1024) + 1
        return max(baseCost, 0) * sizeMultiplier + max(tagCost, 0)
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

struct ComposePostAttachmentBar: View {
    @Binding var text: String
    @Binding var selectedPhotos: [PhotosPickerItem]
    let isSubmitting: Bool
    var horizontalPadding: CGFloat = 18
    var verticalPadding: CGFloat = 8
    var itemSpacing: CGFloat = 8
    var background: Color = TaggrTheme.background
    @State private var linkSheetPresented = false

    var body: some View {
        HStack {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: itemSpacing) {
                    PhotosPicker(selection: $selectedPhotos, matching: .images) {
                        ComposeMarkdownButtonLabel(kind: .image)
                    }
                    .accessibilityLabel("Attach image")
                    ForEach(ComposeMarkdownAction.inlineActions) { action in
                        Button {
                            perform(action)
                        } label: {
                            ComposeMarkdownButtonLabel(kind: action.kind)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(action.accessibilityLabel)
                    }
                }
            }
            Spacer()
            if isSubmitting {
                ProgressView()
                    .tint(.white)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(background)
        .sheet(isPresented: $linkSheetPresented) {
            ComposeLinkSheet { label, url in
                appendInline("[\(label)](\(url))")
            }
        }
    }

    private func perform(_ action: ComposeMarkdownAction) {
        switch action {
        case .bold:
            appendInline("**bold**")
        case .italic:
            appendInline("_italic_")
        case .list:
            appendBlock("- item")
        case .quote:
            appendBlock("> quote")
        case .link:
            linkSheetPresented = true
        }
    }

    private func appendInline(_ snippet: String) {
        if text.isEmpty || text.last?.isWhitespace == true {
            text += snippet
        } else {
            text += " " + snippet
        }
    }

    private func appendBlock(_ snippet: String) {
        if text.isEmpty {
            text = snippet
        } else if text.hasSuffix("\n") {
            text += snippet
        } else {
            text += "\n" + snippet
        }
    }
}

private enum ComposeMarkdownAction: Identifiable {
    case bold
    case italic
    case list
    case quote
    case link

    static let inlineActions: [ComposeMarkdownAction] = [.bold, .italic, .list, .quote, .link]

    var id: String {
        accessibilityLabel
    }

    var kind: ComposeMarkdownIconKind {
        switch self {
        case .bold:
            return .bold
        case .italic:
            return .italic
        case .list:
            return .list
        case .quote:
            return .quote
        case .link:
            return .link
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .bold:
            return "Bold"
        case .italic:
            return "Italic"
        case .list:
            return "Bullet list"
        case .quote:
            return "Quote"
        case .link:
            return "Link"
        }
    }
}

private enum ComposeMarkdownIconKind {
    case bold
    case image
    case italic
    case link
    case list
    case quote
}

private struct ComposeMarkdownButtonLabel: View {
    let kind: ComposeMarkdownIconKind

    var body: some View {
        ComposeMarkdownIcon(kind: kind)
            .frame(width: 44, height: 44)
            .background(TaggrTheme.darkPanel)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ComposeMarkdownIcon: View {
    let kind: ComposeMarkdownIconKind

    var body: some View {
        ZStack {
            switch kind {
            case .bold:
                Text("B")
                    .font(.title3.weight(.black))
            case .italic:
                Text("/")
                    .font(.title2.weight(.black).italic())
            case .image:
                Image(systemName: "photo")
                    .font(.title3.weight(.semibold))
            case .link:
                Image(systemName: "link")
                    .font(.title3.weight(.semibold))
            case .list:
                VStack(alignment: .leading, spacing: 4) {
                    markdownListRow(width: 18)
                    markdownListRow(width: 15)
                    markdownListRow(width: 20)
                }
            case .quote:
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(TaggrTheme.text, lineWidth: 1.6)
                        .frame(width: 22, height: 18)
                    Text("“")
                        .font(.title2.weight(.black))
                        .offset(x: 5, y: -2)
                }
            }
        }
        .foregroundStyle(kind == .image || kind == .link ? TaggrTheme.clickable : TaggrTheme.text)
    }

    private func markdownListRow(width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(TaggrTheme.text)
                .frame(width: 3, height: 3)
            Capsule()
                .fill(TaggrTheme.text)
                .frame(width: width, height: 2)
        }
    }
}

private struct ComposeLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var url = ""
    let insert: (String, String) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Text", text: $label)
                    .textInputAutocapitalization(.sentences)
                    .padding(12)
                    .background(TaggrTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                TextField("URL", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(TaggrTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Spacer()
            }
            .padding(18)
            .background(TaggrTheme.background)
            .navigationTitle("Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Insert") {
                        insert(effectiveLabel, trimmedURL)
                        dismiss()
                    }
                    .disabled(trimmedURL.isEmpty)
                }
            }
        }
        .presentationBackground(TaggrTheme.background)
        .preferredColorScheme(.dark)
    }

    private var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var effectiveLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? trimmedURL : trimmed
    }
}
