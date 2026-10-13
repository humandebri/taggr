// TAGGR/Views: Full-screen account image pager with swipe navigation and ShareLink export.
// Provides download/share without adding Photos library write permissions.
import SwiftUI

struct AccountImagePagerView: View {
    let images: [TaggrAccountImage]
    @Environment(\.dismiss) private var dismiss

    init(images: [TaggrAccountImage], selectedImage: TaggrAccountImage) {
        self.images = images
        self.selectedID = selectedImage.id
    }

    private let selectedID: String

    var body: some View {
        TaggrImagePagerView(
            items: images,
            selectedID: selectedID,
            imageAttachment: \.attachment,
            imageAccessibilityLabel: { "Image from post \($0.postId)" },
            countLabel: { "\($0) of \($1)" },
            close: { dismiss() },
            topTrailingContent: { AccountImageShareButton(image: $0) },
            bottomContent: { AccountImageMetadataPanel(image: $0) }
        )
    }
}

private struct AccountImageShareButton: View {
    let image: TaggrAccountImage
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var shareFileURL: URL?

    var body: some View {
        Group {
            if let shareFileURL {
                ShareLink(item: shareFileURL) {
                    AccountImageShareIcon(label: "Share image", tint: .white)
                }
            } else {
                Button("Preparing image", systemImage: "square.and.arrow.up") {}
                    .labelStyle(.iconOnly)
                    .font(.body.bold())
                    .foregroundStyle(TaggrTheme.secondaryText)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.55))
                    .clipShape(.circle)
                    .disabled(true)
            }
        }
        .task(id: image.id) {
            shareFileURL = nil
            shareFileURL = try? await AccountImageShareFile.url(for: image, api: state.api, config: state.runtimeConfig)
        }
    }
}

private struct AccountImageShareIcon: View {
    let label: String
    let tint: Color

    var body: some View {
        Label(label, systemImage: "square.and.arrow.up")
            .labelStyle(.iconOnly)
            .font(.body.bold())
            .foregroundStyle(tint)
            .frame(width: 44, height: 44)
            .background(Color.black.opacity(0.55))
            .clipShape(.circle)
    }
}

private struct AccountImageMetadataPanel: View {
    let image: TaggrAccountImage

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(image.date, format: .dateTime.year().month().day())
                .font(.subheadline.bold())
                .foregroundStyle(.white)
            Text("Post #\(image.postId)")
                .font(.footnote.bold())
                .foregroundStyle(TaggrTheme.secondaryText)
            if !image.caption.isEmpty {
                TaggrMarkdownText(text: image.caption)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .lineLimit(3)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.55))
    }
}

private enum AccountImageShareFile {
    static func url(for image: TaggrAccountImage, api: TaggrAPI, config: TaggrRuntimeConfig) async throws -> URL {
        let data = try await TaggrPostImageDataLoader.data(for: image.attachment, api: api, config: config)
        let fileURL = URL.temporaryDirectory.appending(path: fileName(for: image, data: data))
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private static func fileName(for image: TaggrAccountImage, data: Data) -> String {
        "taggr-\(safeFileName(image.id)).\(fileExtension(for: data))"
    }

    private static func safeFileName(_ value: String) -> String {
        String(value.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        })
    }

    private static func fileExtension(for data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "png"
        }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "jpg"
        }
        return "img"
    }
}
