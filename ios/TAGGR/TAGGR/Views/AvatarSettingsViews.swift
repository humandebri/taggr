// TAGGR/Views: Account icon editing and posted-image selection.
// Stores only a URL in user settings, so no bucket listing or new upload path is needed.
import SwiftUI

struct AccountAvatarSettingsPanel: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var avatarInput = ""
    @State private var validationMessage: String?
    @State private var urlEditorPresented = false
    @State private var pickerPresented = false

    let user: TaggrUser

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                AvatarView(name: user.name, avatarURLString: currentAvatarURLString, size: 58)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Icon")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(TaggrTheme.text)
                    Text("Use an image URL or one of your posted images.")
                        .font(.caption)
                        .foregroundStyle(TaggrTheme.secondaryText)
                }
            }
            if let currentAvatarURLString {
                Text(currentAvatarURLString)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(TaggrTheme.secondaryText)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TaggrTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], spacing: 8) {
                Button {
                    avatarInput = currentAvatarURLString ?? ""
                    validationMessage = nil
                    urlEditorPresented = true
                } label: {
                    Label("Image URL", systemImage: "link")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                }
                .disabled(state.isBusy)
                Button {
                    pickerPresented = true
                } label: {
                    Label("Posted images", systemImage: "photo.on.rectangle")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                }
                .disabled(state.isBusy)
            }
        }
        .onAppear {
            avatarInput = currentAvatarURLString ?? ""
        }
        .sheet(isPresented: $urlEditorPresented) {
            AvatarURLEditorSheet(
                avatarInput: $avatarInput,
                validationMessage: $validationMessage
            ) {
                if saveTypedURL() {
                    urlEditorPresented = false
                }
            }
        }
        .sheet(isPresented: $pickerPresented) {
            AvatarImagePickerSheet(handle: user.name) { imageURLString in
                pickerPresented = false
                avatarInput = imageURLString
                saveAvatarURL(imageURLString)
            }
            .environment(state)
        }
    }

    private var currentAvatarURLString: String? {
        state.currentUser?.avatarURLString ?? user.avatarURLString
    }

    private func saveTypedURL() -> Bool {
        do {
            _ = try TaggrAvatar.validatedURLString(avatarInput)
            validationMessage = nil
            saveAvatarURL(avatarInput)
            return true
        } catch {
            validationMessage = error.localizedDescription
            return false
        }
    }

    private func saveAvatarURL(_ rawURL: String) {
        Task {
            await state.updateCurrentUserAvatarURL(rawURL)
            if state.errorMessage == nil {
                avatarInput = state.currentUser?.avatarURLString ?? ""
            }
        }
    }
}

private struct AvatarURLEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var avatarInput: String
    @Binding var validationMessage: String?
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                TaggrTheme.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Image URL")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(TaggrTheme.secondaryText)
                    TextField("https://example.com/icon.jpg", text: $avatarInput)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.plain)
                        .foregroundStyle(TaggrTheme.text)
                        .padding(12)
                        .background(TaggrTheme.panelRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    if let validationMessage {
                        Text(validationMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
            .navigationTitle("Icon URL")
            .taggrInlineNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        validationMessage = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct AvatarImagePickerSheet: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var images: [TaggrAccountImage] = []
    @State private var page = 0
    @State private var pagingOffset = 0
    @State private var loading = false
    @State private var reachedEnd = false

    let handle: String
    let onSelect: (String) -> Void

    private let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 3), count: 3)

    var body: some View {
        NavigationStack {
            ZStack {
                TaggrTheme.background.ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if images.isEmpty && !loading && reachedEnd {
                            ContentUnavailableView(
                                "No posted images",
                                systemImage: "photo.on.rectangle",
                                description: Text("Images attached to your posts will appear here.")
                            )
                            .foregroundStyle(TaggrTheme.secondaryText)
                            .padding(.top, 60)
                        } else {
                            ForEach(TaggrAccountImage.yearGroups(from: images)) { group in
                                AvatarImagePickerYearSection(
                                    group: group,
                                    columns: columns
                                ) { image in
                                    select(image)
                                }
                            }
                            if !reachedEnd {
                                TaggrLoadMoreView(loading: loading, verticalPadding: 0, height: 44) {
                                    Task { await loadNextPage() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 3)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Choose icon")
            .taggrInlineNavigationChrome()
            .taggrBusyOverlay(loading && images.isEmpty)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: handle) {
                resetPaging()
                await loadNextPage()
            }
        }
    }

    private func select(_ image: TaggrAccountImage) {
        onSelect(image.attachment.url.absoluteString)
        dismiss()
    }

    private func loadNextPage() async {
        guard !loading, !reachedEnd, !handle.isEmpty else { return }
        loading = true
        defer { loading = false }

        do {
            let posts = try await state.loadUserPosts(handle: handle, page: page, offset: currentPagingOffset)
            let result = TaggrAccountImagePaging.append(
                posts: posts,
                to: images,
                page: page,
                pagingOffset: pagingOffset
            )
            images = result.images
            page = result.page
            pagingOffset = result.pagingOffset
            reachedEnd = result.reachedEnd
        } catch {
            guard !state.isCancellation(error) else { return }
            state.errorMessage = error.localizedDescription
            reachedEnd = true
        }
    }

    private var currentPagingOffset: Int {
        page == 0 ? 0 : pagingOffset
    }

    private func resetPaging() {
        images = []
        page = 0
        pagingOffset = 0
        loading = false
        reachedEnd = false
    }
}

private struct AvatarImagePickerYearSection: View {
    let group: TaggrAccountImageYearGroup
    let columns: [GridItem]
    let onSelect: (TaggrAccountImage) -> Void

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
                        accessibilityLabel: "Use image from post \(image.postId) as icon"
                    ) {
                        onSelect(image)
                    }
                }
            }
        }
    }
}
