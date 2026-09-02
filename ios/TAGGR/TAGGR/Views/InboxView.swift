import SwiftUI

struct InboxView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var showArchive = false

    var body: some View {
        ZStack {
            TaggrTheme.background.ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    InboxHeader(markAllRead: markAllRead, canMarkAllRead: !freshEntries.isEmpty)
                    if state.authSession == nil {
                        InboxSignedOutView {
                            state.startIdentitySignIn()
                        }
                    } else if state.currentUser == nil {
                        InboxNoAccountView()
                    } else {
                        if freshEntries.isEmpty {
                            InboxZeroView()
                        }
                        ForEach(freshEntries, id: \.id) { item in
                            InboxNotificationCard(id: item.id, entry: item.entry, archive: false)
                                .environment(state)
                        }
                        if !showArchive {
                            Button("Show archive", action: showArchivedNotifications)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(TaggrTheme.clickable)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        } else if !archivedEntries.isEmpty {
                            Text("Archive")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(TaggrTheme.secondaryText)
                                .padding(.horizontal, 16)
                            ForEach(archivedEntries, id: \.id) { item in
                                InboxNotificationCard(id: item.id, entry: item.entry, archive: true)
                                    .environment(state)
                                    .opacity(0.65)
                            }
                        }
                    }
                }
                .padding(.vertical, 16)
            }
        }
        .navigationTitle("Inbox")
        .taggrInlineNavigationChrome()
        .taggrBusyOverlay(state.isBusy)
        .taggrRefreshable()
    }

    private var freshEntries: [(id: Int, entry: TaggrNotificationEntry)] {
        state.notificationEntries(read: false)
    }

    private var archivedEntries: [(id: Int, entry: TaggrNotificationEntry)] {
        state.notificationEntries(read: true)
    }

    private func markAllRead() {
        Task { await state.markAllNotificationsRead() }
    }

    private func showArchivedNotifications() {
        showArchive = true
    }
}

private struct InboxHeader: View {
    let markAllRead: () -> Void
    let canMarkAllRead: Bool

    var body: some View {
        if canMarkAllRead {
            HStack {
                Spacer()
                Button("Clear all", action: markAllRead)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TaggrTheme.clickable)
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct InboxSignedOutView: View {
    let signIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to read notifications.")
                .font(.headline)
                .foregroundStyle(TaggrTheme.text)
            Button("Sign in", action: signIn)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(TaggrTheme.accentText)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(TaggrTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TaggrTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
    }
}

private struct InboxNoAccountView: View {
    var body: some View {
        Text("Create a TAGGR account to receive notifications.")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(TaggrTheme.secondaryText)
            .padding(16)
    }
}

private struct InboxZeroView: View {
    var body: some View {
        Text("Inbox Zero Achieved!")
            .font(.headline.weight(.bold))
            .foregroundStyle(TaggrTheme.text)
            .padding(16)
    }
}

private struct InboxNotificationCard: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let id: Int
    let entry: TaggrNotificationEntry
    let archive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: archive ? "archivebox" : "bell")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(archive ? TaggrTheme.secondaryText : TaggrTheme.clickable)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.notification.message)
                        .font(.subheadline)
                        .foregroundStyle(TaggrTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if !entry.notification.watchedEntryIds.isEmpty {
                        Text(entry.notification.watchedEntryIds.map { "#\($0)" }.joined(separator: ", "))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(TaggrTheme.secondaryText)
                    }
                }
                Spacer(minLength: 0)
                if !archive {
                    InboxNotificationActions(id: id, notification: entry.notification)
                        .environment(state)
                }
            }
            if let postId = entry.notification.postId {
                NotificationPostPreview(postId: postId)
                    .environment(state)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TaggrTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
    }
}

private struct InboxNotificationActions: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let id: Int
    let notification: TaggrNotification

    var body: some View {
        HStack(spacing: 8) {
            if case .watchedPostEntries(let postId, _) = notification {
                Button {
                    Task { await state.unwatchPostFromNotification(notificationId: id, postId: postId) }
                } label: {
                    Image(systemName: "bell.slash")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Unwatch post")
            }
            Button {
                Task { await state.markNotificationsRead([id]) }
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark notification read")
        }
        .foregroundStyle(TaggrTheme.secondaryText)
    }
}

private struct NotificationPostPreview: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let postId: Int
    @State private var post: TaggrPost?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let post {
                PostRow(post: post) {
                    state.navigateToPost(post.id)
                }
            } else if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                    Text("Loading post")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TaggrTheme.secondaryText)
                }
                .padding(.vertical, 8)
            } else {
                Text("Post unavailable")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TaggrTheme.secondaryText)
                    .padding(.vertical, 8)
            }
        }
        .task(id: postId) {
            await load()
        }
    }

    private func load() async {
        guard post == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            post = try await state.loadNotificationPost(postId)
        } catch {
            guard !state.isCancellation(error) else { return }
            state.errorMessage = error.localizedDescription
        }
    }
}
