import PhotosUI
import SwiftUI
import UIKit

enum DiscordTheme {
    static let background = Color(red: 0.13, green: 0.14, blue: 0.17)
    static let panel = Color(red: 0.18, green: 0.19, blue: 0.23)
    static let panelRaised = Color(red: 0.22, green: 0.23, blue: 0.28)
    static let accent = Color(red: 0.35, green: 0.45, blue: 0.95)
    static let text = Color(red: 0.95, green: 0.96, blue: 0.98)
    static let secondaryText = Color(red: 0.68, green: 0.70, blue: 0.76)
}

struct FeedView: View {
    @EnvironmentObject private var state: TaggrAppState
    @State private var selectedMode = TaggrFeedMode.hot
    @State private var showingComposer = false

    var body: some View {
        ZStack {
            DiscordTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                FeedHeader(selectedMode: selectedMode, changeMode: changeMode)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if state.feed.isEmpty {
                            EmptyFeedView()
                        } else {
                            ForEach(state.feed) { post in
                                Button {
                                    state.route = .post(post.id)
                                    Task { await state.loadPost(post.id) }
                                } label: {
                                    PostRow(post: post)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            if state.authSession != nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            showingComposer = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 56, height: 56)
                                .background(DiscordTheme.accent)
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                        }
                        .accessibilityLabel("Post")
                        .padding(.trailing, 18)
                        .padding(.bottom, 18)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(DiscordTheme.background, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .refreshable {
            await state.loadFeed(mode: selectedMode, reset: true)
        }
        .overlay {
            if state.isBusy {
                ProgressView()
                    .tint(.white)
                    .padding(18)
                    .background(DiscordTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .fullScreenCover(isPresented: $showingComposer) {
            ComposePostView(isPresented: $showingComposer)
                .environmentObject(state)
        }
    }

    private func changeMode(_ mode: TaggrFeedMode) {
        selectedMode = mode
        state.route = .feed(mode)
        Task { await state.loadFeed(mode: mode, reset: true) }
    }
}

private struct FeedHeader: View {
    let selectedMode: TaggrFeedMode
    let changeMode: (TaggrFeedMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(DiscordTheme.accent)
                    .frame(width: 34, height: 34)
                    .overlay(Text("T").font(.subheadline.weight(.black)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 2) {
                    Text("TAGGR")
                        .font(.headline.weight(.black))
                        .foregroundStyle(DiscordTheme.text)
                    Text(channelTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DiscordTheme.secondaryText)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                ChannelPill(title: "# hot", selected: selectedMode == .hot) { changeMode(.hot) }
                ChannelPill(title: "# latest", selected: selectedMode == .latest) { changeMode(.latest) }
                ChannelPill(title: "# personal", selected: selectedMode == .personal) { changeMode(.personal) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(DiscordTheme.panel)
    }

    private var channelTitle: String {
        switch selectedMode {
        case .hot:
            return "# hot"
        case .latest:
            return "# latest"
        case .personal:
            return "# personal"
        case .realm(let name):
            return "# \(name.lowercased())"
        }
    }
}

private struct ChannelPill: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(selected ? .white : DiscordTheme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(selected ? DiscordTheme.accent : DiscordTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }
}

private struct ComposePostView: View {
    @EnvironmentObject private var state: TaggrAppState
    @Binding var isPresented: Bool
    @State private var text = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var draftImage: TaggrDraftImage?
    @State private var draftPreview: Image?
    @State private var isSubmitting = false

    var body: some View {
        ZStack {
            DiscordTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(DiscordTheme.text)
                            .frame(width: 40, height: 40)
                    }
                    Spacer()
                    Button(action: submit) {
                        Text("Post")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(height: 36)
                            .background(canSubmit && !isSubmitting ? DiscordTheme.accent : DiscordTheme.panelRaised)
                            .clipShape(Capsule())
                    }
                    .disabled(!canSubmit || state.isBusy || isSubmitting)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)
                .background(DiscordTheme.background)

                Divider().overlay(DiscordTheme.panelRaised)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $text)
                                .scrollContentBackground(.hidden)
                                .font(.title3)
                                .foregroundStyle(DiscordTheme.text)
                                .frame(minHeight: 170)
                                .tint(DiscordTheme.accent)
                            if text.isEmpty {
                                Text("What's happening?")
                                    .font(.title3)
                                    .foregroundStyle(DiscordTheme.secondaryText)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                        if let draftPreview {
                            ZStack(alignment: .topTrailing) {
                                draftPreview
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                Button(action: clearImage) {
                                    Image(systemName: "xmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 30, height: 30)
                                        .background(Color.black.opacity(0.55))
                                        .clipShape(Circle())
                                }
                                .padding(8)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                }

                Divider().overlay(DiscordTheme.panelRaised)

                HStack {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Image(systemName: "photo")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(DiscordTheme.accent)
                            .frame(width: 44, height: 44)
                    }
                    Spacer()
                    if state.isBusy || isSubmitting {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(DiscordTheme.background)
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            Task { await loadPhoto(item) }
        }
    }

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftImage != nil
    }

    private func submit() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit, !isSubmitting else { return }
        let image = draftImage
        isSubmitting = true
        Task {
            await state.submitPost(text: body, image: image)
            isSubmitting = false
            if state.errorMessage == nil {
                clearDraft()
                isPresented = false
            }
        }
    }

    @MainActor
    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item,
              let data = try? await item.loadTransferable(type: Data.self),
              let normalized = ImageDrafts.normalizedImageData(data) else {
            clearImage()
            return
        }
        draftImage = TaggrDraftImage(id: ImageDrafts.blobId(), data: normalized)
        if let image = UIImage(data: normalized) {
            draftPreview = Image(uiImage: image)
        }
    }

    private func clearImage() {
        selectedPhoto = nil
        draftImage = nil
        draftPreview = nil
    }

    private func clearDraft() {
        text = ""
        clearImage()
    }
}

private struct EmptyFeedView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No posts")
                .font(.headline)
                .foregroundStyle(DiscordTheme.text)
            Text("Pull to refresh or switch channels.")
                .font(.subheadline)
                .foregroundStyle(DiscordTheme.secondaryText)
        }
        .padding(16)
    }
}

private enum ImageDrafts {
    static func blobId() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    static func normalizedImageData(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        if data.count <= 460_800 { return data }
        var quality: CGFloat = 0.82
        while quality >= 0.35 {
            if let compressed = image.jpegData(compressionQuality: quality), compressed.count <= 460_800 {
                return compressed
            }
            quality -= 0.12
        }
        return image.jpegData(compressionQuality: 0.35)
    }
}

struct PostRow: View {
    @EnvironmentObject private var state: TaggrAppState
    let post: TaggrPost

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(name: post.meta.authorName ?? "\(post.user)")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(post.meta.authorName ?? "@\(post.user)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(DiscordTheme.text)
                    if let realm = post.realm, !realm.isEmpty {
                        Text("#\(realm.lowercased())")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(DiscordTheme.secondaryText)
                    }
                }
                if !post.displayBody.isEmpty {
                    Text(post.displayBody)
                        .font(.body)
                        .foregroundStyle(DiscordTheme.text)
                        .lineSpacing(3)
                        .lineLimit(10)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(post.imageAttachments()) { attachment in
                    AsyncImage(url: attachment.url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure:
                            Image(systemName: "photo")
                                .font(.title2)
                                .foregroundStyle(DiscordTheme.secondaryText)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        case .empty:
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 360)
                    .background(DiscordTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                HStack(spacing: 18) {
                    Button {
                        Task { await state.react(postId: post.id, reaction: 1) }
                    } label: {
                        Label("\(post.reactions.values.flatMap { $0 }.count)", systemImage: "star")
                    }
                    Button {
                        Task { await state.report(postId: post.id, reason: "Reported from iOS") }
                    } label: {
                        Label("Report", systemImage: "flag")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(DiscordTheme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(DiscordTheme.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DiscordTheme.panelRaised.opacity(0.8))
                .frame(height: 1)
                .padding(.leading, 66)
        }
    }
}

private struct AvatarView: View {
    let name: String

    var body: some View {
        Circle()
            .fill(DiscordTheme.panelRaised)
            .frame(width: 38, height: 38)
            .overlay(
                Text(String(name.prefix(1)).uppercased())
                    .font(.subheadline.weight(.black))
                    .foregroundStyle(DiscordTheme.text)
            )
    }
}

struct RealmsView: View {
    @EnvironmentObject private var state: TaggrAppState
    @State private var realmName = ""

    var body: some View {
        ZStack {
            DiscordTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Channels")
                        .font(.largeTitle.weight(.black))
                        .foregroundStyle(DiscordTheme.text)
                    HStack(spacing: 10) {
                        TextField("REALM", text: $realmName)
                            .textInputAutocapitalization(.characters)
                            .textFieldStyle(.plain)
                            .foregroundStyle(DiscordTheme.text)
                            .padding(12)
                            .background(DiscordTheme.panelRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Button {
                            let name = realmName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                            guard !name.isEmpty else { return }
                            state.route = .realm(name)
                            Task { await state.loadRealm(name) }
                        } label: {
                            Image(systemName: "arrow.right")
                                .font(.body.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 42)
                                .background(DiscordTheme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    ForEach(state.realms) { realm in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("# \(realm.name.lowercased())")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(DiscordTheme.text)
                            Text(realm.description)
                                .font(.subheadline)
                                .foregroundStyle(DiscordTheme.secondaryText)
                            Button("Open feed") {
                                state.route = .feed(.realm(realm.name))
                                Task { await state.loadFeed(mode: .realm(realm.name), reset: true) }
                            }
                            .font(.caption.weight(.bold))
                            .foregroundStyle(DiscordTheme.accent)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DiscordTheme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(16)
            }
        }
        .toolbarBackground(DiscordTheme.background, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}
