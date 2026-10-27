import SwiftUI

struct UserAttributeBadgesView: View {
    let badges: [TaggrUserBadge]

    var body: some View {
        if !badges.isEmpty {
            BadgeFlowLayout(spacing: 5) {
                ForEach(badges, id: \.self) { badge in
                    Text(badge.rawValue)
                        .font(.caption.bold())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(badge.foregroundColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(badge.backgroundColor)
                        .clipShape(.rect(cornerRadius: 4))
                        .accessibilityLabel(badge.accessibilityLabel)
                }
            }
        }
    }
}

private extension TaggrUserBadge {
    var backgroundColor: Color {
        switch self {
        case .bot:
            Color(red: 65 / 255, green: 105 / 255, blue: 225 / 255)
        case .og:
            Color(red: 219 / 255, green: 112 / 255, blue: 147 / 255)
        case .stalwart:
            Color(red: 250 / 255, green: 128 / 255, blue: 114 / 255)
        case .frequenter:
            Color(red: 106 / 255, green: 90 / 255, blue: 205 / 255)
        case .followsYou:
            Color(red: 46 / 255, green: 139 / 255, blue: 87 / 255)
        case .inactive:
            Color.white
        }
    }

    var foregroundColor: Color {
        switch self {
        case .bot, .frequenter, .followsYou:
            Color.white
        case .og, .stalwart, .inactive:
            Color.black
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .bot:
            "Bot account"
        case .og:
            "OG account"
        case .stalwart:
            "Stalwart"
        case .frequenter:
            "Frequenter"
        case .followsYou:
            "Follows you"
        case .inactive:
            "Inactive"
        }
    }
}

struct BadgeFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(subviews: subviews, maxWidth: proposal.width ?? .infinity).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(subviews: subviews, maxWidth: bounds.width)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func layout(
        subviews: Subviews,
        maxWidth: CGFloat
    ) -> (size: CGSize, frames: [CGRect]) {
        let itemProposal = maxWidth.isFinite
            ? ProposedViewSize(width: max(0, maxWidth), height: nil)
            : ProposedViewSize.unspecified
        let measuredSizes = subviews.map { $0.sizeThatFits(itemProposal) }
        let frames = Self.frames(
            for: measuredSizes,
            maxWidth: maxWidth,
            spacing: spacing
        )
        let contentWidth = frames.map(\.maxX).max() ?? 0
        let contentHeight = frames.map(\.maxY).max() ?? 0

        return (CGSize(width: contentWidth, height: contentHeight), frames)
    }

    static func frames(
        for measuredSizes: [CGSize],
        maxWidth: CGFloat,
        spacing: CGFloat
    ) -> [CGRect] {
        let availableWidth = maxWidth.isFinite ? max(0, maxWidth) : .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for measuredSize in measuredSizes {
            let size = CGSize(
                width: min(measuredSize.width, availableWidth),
                height: measuredSize.height
            )
            if x > 0, x + size.width > availableWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}
