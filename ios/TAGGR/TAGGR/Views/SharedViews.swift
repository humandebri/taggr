import SwiftUI

struct TaggrBusyIndicator: View {
    var body: some View {
        ProgressView()
            .tint(.white)
            .padding(18)
            .background(TaggrTheme.panelRaised)
            .clipShape(.rect(cornerRadius: 8))
    }
}

struct TaggrLoadMoreView: View {
    let loading: Bool
    let verticalPadding: CGFloat
    let height: CGFloat?
    let load: () -> Void

    init(loading: Bool, verticalPadding: CGFloat = 16, height: CGFloat? = nil, load: @escaping () -> Void) {
        self.loading = loading
        self.verticalPadding = verticalPadding
        self.height = height
        self.load = load
    }

    var body: some View {
        HStack {
            Spacer()
            if loading {
                ProgressView()
                    .tint(.white)
                    .padding(verticalPadding)
            } else {
                Button("Load more", systemImage: "chevron.down", action: load)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(TaggrTheme.clickable)
                    .padding(verticalPadding)
            }
            Spacer()
        }
        .frame(height: height)
    }
}

struct TaggrBackToolbarButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, systemImage: "chevron.left", action: action)
            .foregroundStyle(TaggrTheme.clickable)
            .accessibilityLabel(title)
    }
}

struct TaggrAccountImageThumbnail: View {
    let image: TaggrAccountImage
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GeometryReader { proxy in
                TaggrPostImageLoaderView(attachment: image.attachment, contentMode: .fill)
                .frame(width: proxy.size.width, height: proxy.size.width)
                .background(TaggrTheme.panelRaised)
                .clipped()
            }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct TopSafeAreaFill: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            color
                .frame(height: proxy.safeAreaInsets.top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)
        }
        .allowsHitTesting(false)
    }
}

extension View {
    func taggrNavigationChrome() -> some View {
        toolbarBackground(TaggrTheme.background, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }

    func taggrInlineNavigationChrome() -> some View {
        navigationBarTitleDisplayMode(.inline)
            .taggrNavigationChrome()
    }

    func taggrBusyOverlay(_ isVisible: Bool) -> some View {
        overlay {
            if isVisible {
                TaggrBusyIndicator()
            }
        }
    }
}
