// TAGGR/Views: Shared image, video, and Markdown attachment controls for post composers.

import PhotosUI
import SwiftUI

struct ComposePostAttachmentBar: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @EnvironmentObject private var quoteEditor: ComposeQuoteEditor
    @Binding var text: String
    @Binding var selectedPhotos: [PhotosPickerItem]
    let youtubeTarget: YouTubeDraftTarget?
    let insertYouTubeURL: (URL) -> Void
    let isSubmitting: Bool
    let isImagePickerDisabled: Bool
    var horizontalPadding: CGFloat = 18
    var verticalPadding: CGFloat = 8
    var itemSpacing: CGFloat = 8
    var background: Color = TaggrTheme.background
    @State private var linkSheetPresented = false
    @State private var youtubeSheetPresented = false

    var body: some View {
        HStack {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: itemSpacing) {
                    PhotosPicker(selection: $selectedPhotos, selectionBehavior: .ordered, matching: .images) {
                        ComposeMarkdownButtonLabel(kind: .image)
                    }
                    .disabled(isImagePickerDisabled)
                    .accessibilityLabel("Attach image")
                    if state.youtubeUpload.auth.isEnabled {
                        Button {
                            youtubeSheetPresented = true
                        } label: {
                            ComposeMarkdownButtonLabel(kind: .video)
                                .overlay(alignment: .bottomTrailing) {
                                    if state.youtubeUpload.isRunning && state.youtubeUpload.job?.target == youtubeTarget {
                                        Circle()
                                            .trim(from: 0, to: state.youtubeUpload.progress)
                                            .stroke(TaggrTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                            .rotationEffect(.degrees(-90))
                                            .frame(width: 14, height: 14)
                                            .padding(4)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            isSubmitting || youtubeTarget == nil
                                || (state.youtubeUpload.job != nil && state.youtubeUpload.job?.target != youtubeTarget)
                        )
                        .accessibilityLabel("Upload video to YouTube")
                    }
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
        .sheet(isPresented: $youtubeSheetPresented) {
            if let youtubeTarget {
                YouTubeUploadSheet(target: youtubeTarget, uploaded: insertYouTubeURL)
                    .environment(state)
            }
        }
    }

    func perform(_ action: ComposeMarkdownAction) {
        switch action {
        case .bold:
            appendInline("**bold**")
        case .italic:
            appendInline("_italic_")
        case .list:
            appendBlock("- item")
        case .quote:
            quoteEditor.quote()
        case .link:
            linkSheetPresented = true
        }
    }

    func appendInline(_ snippet: String) {
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

enum ComposeMarkdownAction: Identifiable {
    case bold
    case italic
    case list
    case quote
    case link

    static let inlineActions: [ComposeMarkdownAction] = [.bold, .italic, .list, .quote, .link]

    var id: String { accessibilityLabel }

    fileprivate var kind: ComposeMarkdownIconKind {
        switch self {
        case .bold: .bold
        case .italic: .italic
        case .list: .list
        case .quote: .quote
        case .link: .link
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .list: "Bullet list"
        case .quote: "Quote"
        case .link: "Link"
        }
    }
}

fileprivate enum ComposeMarkdownIconKind {
    case bold
    case image
    case italic
    case link
    case list
    case quote
    case video
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
                Text("B").font(.title3.weight(.black))
            case .italic:
                Text("/").font(.title2.weight(.black).italic())
            case .image:
                Image(systemName: "photo").font(.title3.weight(.semibold))
            case .link:
                Image(systemName: "link").font(.title3.weight(.semibold))
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
            case .video:
                Image(systemName: "play.rectangle.fill").font(.title3.weight(.semibold))
            }
        }
        .foregroundStyle(kind == .image || kind == .link || kind == .video ? TaggrTheme.clickable : TaggrTheme.text)
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
