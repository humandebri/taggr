// TAGGR/Views: Modal workflow for uploading a selected video to YouTube.

import AVKit
import PhotosUI
import SwiftUI

struct YouTubeUploadSheet: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @Environment(\.dismiss) private var dismiss

    let target: YouTubeDraftTarget
    let uploaded: (URL) -> Void

    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedVideoURL: URL?
    @State private var metadata = YouTubeUploadMetadata(title: "", description: "")
    @State private var isImporting = false
    @State private var importError: String?
    @State private var importRevision = 0
    @State private var cancellationConfirmationPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    accountSection
                    if let currentJob {
                        jobSection(currentJob)
                    } else {
                        videoSection
                        metadataSection
                        uploadButton
                        if let error = state.youtubeUpload.errorMessage {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(18)
            }
            .background(TaggrTheme.background)
            .navigationTitle("YouTube Upload")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationBackground(TaggrTheme.background)
        .preferredColorScheme(.dark)
        .onChange(of: selectedItem) { _, item in
            importVideo(item)
        }
        .onChange(of: state.youtubeUpload.completionRevision) { _, _ in
            completeIfReady()
        }
        .onDisappear {
            importRevision &+= 1
            YouTubeTemporarySelection.remove(at: selectedVideoURL)
            selectedVideoURL = nil
        }
        .confirmationDialog(
            "Cancel this YouTube upload?",
            isPresented: $cancellationConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Cancel Upload", role: .destructive) {
                Task { await state.youtubeUpload.cancel() }
            }
            Button("Keep Uploading", role: .cancel) {}
        }
    }

    private var accountSection: some View {
        YouTubeUploadCard(title: "YouTube channel") {
            if let channel = state.youtubeUpload.auth.channel {
                HStack {
                    Image(systemName: "play.rectangle.fill")
                        .foregroundStyle(.red)
                    Text(channel.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else {
                Button {
                    state.youtubeUpload.auth.connect()
                } label: {
                    Label(
                        state.youtubeUpload.auth.isBusy ? "Connecting..." : "Connect YouTube",
                        systemImage: "person.crop.circle.badge.plus"
                    )
                    .font(.subheadline.weight(.bold))
                }
                .disabled(state.youtubeUpload.auth.isBusy)
            }
            if let error = state.youtubeUpload.auth.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Text("The video is sent directly from this device to the selected YouTube channel.")
                .font(.caption)
                .foregroundStyle(TaggrTheme.secondaryText)
        }
    }

    @ViewBuilder
    private var videoSection: some View {
        YouTubeUploadCard(title: "Video") {
            if let selectedVideoURL {
                YouTubeSelectedVideoPreview(url: selectedVideoURL)
                Text(selectedVideoURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(TaggrTheme.secondaryText)
                    .lineLimit(1)
            }
            PhotosPicker(
                selectedVideoURL == nil ? "Choose video" : "Choose another video",
                selection: $selectedItem,
                matching: .videos
            )
            .font(.subheadline.weight(.bold))
            .disabled(isImporting || state.youtubeUpload.isRunning)
            if isImporting {
                ProgressView("Preparing video...")
                    .tint(.white)
            }
            if let importError {
                Text(importError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var metadataSection: some View {
        YouTubeUploadCard(title: "YouTube details") {
            TextField("Title", text: $metadata.title)
                .textInputAutocapitalization(.sentences)
                .padding(12)
                .background(TaggrTheme.darkPanel)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text("\(metadata.title.count)/\(YouTubeUploadMetadata.maximumTitleCharacters)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(metadata.title.count > YouTubeUploadMetadata.maximumTitleCharacters ? .red : TaggrTheme.secondaryText)

            TextEditor(text: $metadata.description)
                .frame(minHeight: 96)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(TaggrTheme.darkPanel)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if metadata.description.isEmpty {
                        Text("Description")
                            .foregroundStyle(TaggrTheme.secondaryText)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
            Text("\(metadata.description.utf8.count)/\(YouTubeUploadMetadata.maximumDescriptionBytes) bytes")
                .font(.caption.monospacedDigit())
                .foregroundStyle(
                    metadata.description.utf8.count > YouTubeUploadMetadata.maximumDescriptionBytes
                        ? .red : TaggrTheme.secondaryText
                )

            Picker("Visibility", selection: $metadata.privacy) {
                ForEach(YouTubePrivacyStatus.allCases, id: \.self) { privacy in
                    Text(privacy.title).tag(privacy)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 8) {
                Text("Is this video made for kids?")
                    .font(.subheadline.weight(.semibold))
                Picker("Is this video made for kids?", selection: $metadata.madeForKids) {
                    Text("No").tag(Optional(false))
                    Text("Yes").tag(Optional(true))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(minHeight: 44)
                .accessibilityLabel("Is this video made for kids?")
            }

            Toggle("Contains realistic altered or synthetic media", isOn: $metadata.containsSyntheticMedia)
                .font(.subheadline)

            Toggle(isOn: $metadata.communityGuidelinesAccepted) {
                Text("I confirm that I own or may upload this video and that it follows YouTube's Community Guidelines.")
                    .font(.footnote)
            }
            Link("Read YouTube Community Guidelines", destination: URL(string: "https://www.youtube.com/howyoutubeworks/policies/community-guidelines/")!)
                .font(.footnote.weight(.semibold))

            if let validationMessage = metadata.validationMessage {
                Text(validationMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var uploadButton: some View {
        Button {
            guard let selectedVideoURL else { return }
            Task {
                do { try await state.requireSafePublishing(text: metadata.title + " " + metadata.description) }
                catch { state.errorMessage = error.localizedDescription; return }
                await state.youtubeUpload.start(
                    sourceURL: selectedVideoURL,
                    metadata: metadata,
                    target: target
                )
            }
        } label: {
            Label("Upload to YouTube", systemImage: "arrow.up.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(canUpload ? TaggrTheme.accent : TaggrTheme.panelRaised)
                .foregroundStyle(canUpload ? TaggrTheme.accentText : TaggrTheme.secondaryText)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!canUpload)
    }

    private func jobSection(_ job: YouTubeUploadJob) -> some View {
        YouTubeUploadCard(title: job.phase == .completed ? "Upload complete" : "Upload progress") {
            Text(job.metadata.title)
                .font(.headline)
            Text(job.displayFileName)
                .font(.caption)
                .foregroundStyle(TaggrTheme.secondaryText)
            switch job.phase {
            case .preparing, .uploading:
                ProgressView(value: state.youtubeUpload.progress)
                    .tint(TaggrTheme.accent)
                Text(state.youtubeUpload.progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                Button(role: .destructive) {
                    cancellationConfirmationPresented = true
                } label: {
                    Label("Cancel upload", systemImage: "xmark.circle")
                }
            case .failed:
                Text(job.failureMessage ?? "YouTube upload failed.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                HStack {
                    Button("Retry") {
                        Task {
                            do { try await state.requireSafePublishing(text: metadata.title + " " + metadata.description) }
                            catch { state.errorMessage = error.localizedDescription; return }
                            await state.youtubeUpload.retry()
                        }
                    }
                    Button("Cancel", role: .destructive) {
                        Task { await state.youtubeUpload.cancel() }
                    }
                }
            case .completed:
                Text("The video may remain unavailable while YouTube finishes processing it.")
                    .font(.footnote)
                    .foregroundStyle(TaggrTheme.secondaryText)
                Button("Insert into draft") { completeIfReady() }
                    .font(.subheadline.weight(.bold))
            }
        }
    }

    private var currentJob: YouTubeUploadJob? {
        guard let job = state.youtubeUpload.job else { return nil }
        return job.target == target ? job : nil
    }

    private var canUpload: Bool {
        selectedVideoURL != nil
            && state.youtubeUpload.auth.isConnected
            && metadata.validationMessage == nil
            && !isImporting
            && !state.youtubeUpload.isRunning
    }

    private func importVideo(_ item: PhotosPickerItem?) {
        guard let item else { return }
        importRevision &+= 1
        let revision = importRevision
        isImporting = true
        importError = nil
        Task {
            do {
                guard let selection = try await item.loadTransferable(type: YouTubeVideoSelection.self) else {
                    throw YouTubeUploadError.invalidVideo
                }
                guard revision == importRevision, !Task.isCancelled else {
                    YouTubeTemporarySelection.remove(at: selection.fileURL)
                    return
                }
                let previousURL = selectedVideoURL
                selectedVideoURL = selection.fileURL
                YouTubeTemporarySelection.remove(at: previousURL)
                if metadata.title.isEmpty {
                    metadata.title = selection.fileURL.deletingPathExtension().lastPathComponent
                }
            } catch {
                if revision == importRevision, !Task.isCancelled {
                    importError = error.localizedDescription
                }
            }
            if revision == importRevision {
                isImporting = false
            }
        }
    }

    private func completeIfReady() {
        guard let url = state.youtubeUpload.completedURL(for: target) else { return }
        uploaded(url)
        dismiss()
    }
}

private struct YouTubeUploadCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(TaggrTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct YouTubeSelectedVideoPreview: View {
    let url: URL
    @State private var player: AVPlayer

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onDisappear { player.pause() }
    }
}
