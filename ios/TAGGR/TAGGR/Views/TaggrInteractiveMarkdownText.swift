// TAGGR/Views: Selectable Markdown text with character-accurate link and post taps.
import SwiftUI

@MainActor
struct TaggrInteractiveMarkdownText: UIViewRepresentable {
    static let quoteDepthAttribute = NSAttributedString.Key("TaggrQuoteDepth")
    let text: String
    let maximumLines: Int?
    let textStyle: UIFont.TextStyle
    let textColor: UIColor
    let lineSpacing: CGFloat
    let accessibilityIdentifier: String?
    let openPost: (() -> Void)?
    let onTruncationChange: (Bool) -> Void
    var parsedMarkdownBlocks: [String]? = nil

    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> TextView {
        let textView = TextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.linkTextAttributes = [
            .foregroundColor: UIColor(TaggrTheme.clickable),
            .underlineStyle: 0,
        ]
        textView.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.reportTruncation()
        }

        let tapRecognizer = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tapRecognizer.cancelsTouchesInView = false
        tapRecognizer.delegate = context.coordinator
        textView.addGestureRecognizer(tapRecognizer)
        context.coordinator.textView = textView
        return textView
    }

    func updateUIView(_ textView: TextView, context: Context) {
        context.coordinator.parent = self
        // Resolve dynamic inputs before comparing: the same UIColor or text style
        // can produce a different rendering after an appearance or size change.
        _ = dynamicTypeSize
        _ = colorScheme
        let traits = textView.traitCollection
        let font = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits)
        let color = textColor.resolvedColor(with: traits)
        let key = RenderKey(text: text, blocks: parsedMarkdownBlocks, style: textStyle,
                            font: font, color: color, spacing: lineSpacing,
                            category: traits.preferredContentSizeCategory)
        if context.coordinator.renderKey != key {
            traits.performAsCurrent {
                textView.attributedText = Self.attributedText(
                    for: text, textStyle: textStyle, textColor: color,
                    lineSpacing: lineSpacing, parsedMarkdownBlocks: parsedMarkdownBlocks
                )
            }
            context.coordinator.renderKey = key
        }
        textView.textContainer.maximumNumberOfLines = maximumLines ?? 0
        textView.textContainer.lineBreakMode = maximumLines == nil ? .byWordWrapping : .byTruncatingTail
        textView.minimumHeight = font.lineHeight
        textView.accessibilityOpenPost = openPost
        textView.accessibilityIdentifier = accessibilityIdentifier
        textView.accessibilityTraits = openPost == nil ? [.staticText] : [.staticText, .button]
        textView.accessibilityElements = []
        textView.invalidateIntrinsicContentSize()
        context.coordinator.reportTruncation()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: TextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let fittingSize = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: max(44, fittingSize.height))
    }

    static func attributedText(
        for text: String,
        textStyle: UIFont.TextStyle = .body,
        textColor: UIColor = .label,
        lineSpacing: CGFloat = 3,
        parsedMarkdownBlocks: [String]? = nil
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let markdownBlocks = parsedMarkdownBlocks ?? TaggrPostBodyParser.blocks(in: text).compactMap { block -> String? in
            guard case .markdown(let markdown) = block else { return nil }
            return markdown
        }
        let blocks = markdownBlocks.isEmpty ? [text] : markdownBlocks

        for (index, block) in blocks.enumerated() {
            if index > 0 {
                result.append(
                    separator(
                        "\n\n",
                        textStyle: textStyle,
                        textColor: textColor,
                        lineSpacing: lineSpacing
                    )
                )
            }
            result.append(
                renderedBlock(
                    block,
                    textStyle: textStyle,
                    textColor: textColor,
                    lineSpacing: lineSpacing
                )
            )
        }
        return result
    }

    static func link(atUTF16Offset offset: Int, in attributedText: NSAttributedString) -> URL? {
        guard attributedText.length > 0, offset >= 0, offset < attributedText.length else { return nil }
        return attributedText.attribute(.link, at: offset, effectiveRange: nil) as? URL
    }

    private static func renderedBlock(
        _ markdown: String,
        textStyle: UIFont.TextStyle,
        textColor: UIColor,
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        let source = TaggrMarkdownText.attributedMarkdown(from: markdown)
        let result = NSMutableAttributedString()
        var previousPresentationIdentity: Int?

        for run in source.runs {
            let components = run.presentationIntent?.components ?? []
            let presentationIdentity = components.first?.identity
            if let previousPresentationIdentity,
               let presentationIdentity,
               previousPresentationIdentity != presentationIdentity {
                result.append(
                    separator(
                        "\n",
                        textStyle: textStyle,
                        textColor: textColor,
                        lineSpacing: lineSpacing
                    )
                )
            }
            if previousPresentationIdentity != presentationIdentity {
                result.append(
                    listPrefix(
                        for: components,
                        textStyle: textStyle,
                        textColor: textColor,
                        lineSpacing: lineSpacing
                    )
                )
            }

            let slice = AttributedString(source[run.range])
            let renderedRun = NSMutableAttributedString(attributedString: NSAttributedString(slice))
            let range = NSRange(location: 0, length: renderedRun.length)
            let font = font(
                textStyle: textStyle,
                inlineIntent: run.inlinePresentationIntent,
                presentationComponents: components
            )
            renderedRun.addAttributes([
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle(
                    lineSpacing: lineSpacing,
                    presentationComponents: components
                ),
            ], range: range)
            if run.inlinePresentationIntent?.contains(.strikethrough) == true {
                renderedRun.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            let quoteDepth = components.filter {
                if case .blockQuote = $0.kind { true } else { false }
            }.count
            if quoteDepth > 0 {
                renderedRun.addAttribute(quoteDepthAttribute, value: quoteDepth, range: range)
            }
            result.append(renderedRun)
            previousPresentationIdentity = presentationIdentity
        }
        return result
    }

    private static func listPrefix(
        for components: [PresentationIntent.IntentType],
        textStyle: UIFont.TextStyle,
        textColor: UIColor,
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        guard let listItem = components.first(where: {
            if case .listItem = $0.kind { true } else { false }
        }) else {
            return NSAttributedString()
        }
        let ordinal: Int
        if case .listItem(let value) = listItem.kind {
            ordinal = value
        } else {
            return NSAttributedString()
        }
        let ordered = components.contains {
            if case .orderedList = $0.kind { true } else { false }
        }
        let prefix = ordered ? "\(ordinal). " : "• "
        return NSAttributedString(
            string: prefix,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: .current),
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle(
                    lineSpacing: lineSpacing,
                    presentationComponents: components
                ),
            ]
        )
    }

    private static func separator(
        _ string: String,
        textStyle: UIFont.TextStyle,
        textColor: UIColor,
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: .current),
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle(
                    lineSpacing: lineSpacing,
                    presentationComponents: []
                ),
            ]
        )
    }

    private static func font(
        textStyle: UIFont.TextStyle,
        inlineIntent: InlinePresentationIntent?,
        presentationComponents: [PresentationIntent.IntentType]
    ) -> UIFont {
        var font = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: .current)
        if let headingLevel = presentationComponents.compactMap({ component -> Int? in
            if case .header(let level) = component.kind { level } else { nil }
        }).first {
            let headingStyle: UIFont.TextStyle = headingLevel <= 2 ? .title3 : .headline
            font = UIFont.preferredFont(forTextStyle: headingStyle, compatibleWith: .current)
        }
        if presentationComponents.contains(where: {
            if case .codeBlock = $0.kind { true } else { false }
        }) || inlineIntent?.contains(.code) == true {
            font = UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
        }

        var traits = font.fontDescriptor.symbolicTraits
        if presentationComponents.contains(where: {
            if case .header = $0.kind { true } else { false }
        }) || inlineIntent?.contains(.stronglyEmphasized) == true {
            traits.insert(.traitBold)
        }
        if inlineIntent?.contains(.emphasized) == true {
            traits.insert(.traitItalic)
        }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    private static func paragraphStyle(
        lineSpacing: CGFloat,
        presentationComponents: [PresentationIntent.IntentType]
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        let depth = presentationComponents.filter {
            if case .blockQuote = $0.kind { true } else { false }
        }.count
        style.firstLineHeadIndent = CGFloat(depth) * 12
        style.headIndent = CGFloat(depth) * 12
        return style
    }

    @MainActor
    struct RenderKey: Equatable {
        let text: String
        let blocks: [String]?
        let style: UIFont.TextStyle
        let font: UIFont
        let color: UIColor
        let spacing: CGFloat
        let category: UIContentSizeCategory
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: TaggrInteractiveMarkdownText
        weak var textView: TextView?
        var renderKey: RenderKey?
        private var lastReportedTruncation: Bool?

        init(parent: TaggrInteractiveMarkdownText) {
            self.parent = parent
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let textView else { return }
            let offset = textView.characterOffset(at: recognizer.location(in: textView))
            if let offset,
               TaggrInteractiveMarkdownText.link(atUTF16Offset: offset, in: textView.attributedText) != nil {
                return
            }
            parent.openPost?()
        }

        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            guard case .link(let url) = textItem.content else { return defaultAction }
            return UIAction { [weak self] _ in
                self?.parent.openURL(url)
            }
        }

        // A tap must lose to the containing scroll view's pan. The text view's
        // own selection gestures remain independent of post navigation.
        private func ancestorScrollViews() -> [UIScrollView] {
            var result: [UIScrollView] = []
            var ancestor = textView?.superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView, scrollView.isScrollEnabled {
                    result.append(scrollView)
                }
                ancestor = view.superview
            }
            return result
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Check at touch-down: UIKit may stop deceleration before touch-up.
            !ancestorScrollViews().contains { $0.isDragging || $0.isDecelerating }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            ancestorScrollViews().contains { $0.panGestureRecognizer === otherGestureRecognizer }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            !ancestorScrollViews().contains { $0.panGestureRecognizer === otherGestureRecognizer }
        }

        func reportTruncation() {
            guard let textView else { return }
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            let visibleGlyphs = textView.layoutManager.glyphRange(for: textView.textContainer)
            let isTruncated = NSMaxRange(visibleGlyphs) < textView.layoutManager.numberOfGlyphs
            updateAccessibility(for: visibleGlyphs, isTruncated: isTruncated, in: textView)
            guard lastReportedTruncation != isTruncated else { return }
            lastReportedTruncation = isTruncated
            parent.onTruncationChange(isTruncated)
        }

        @objc func openAccessibilityLink(_ action: UIAccessibilityCustomAction) -> Bool {
            guard let url = accessibilityLinks[action.name] else { return false }
            parent.openURL(url)
            return true
        }

        private var accessibilityLinks: [String: URL] = [:]

        private func updateAccessibility(
            for visibleGlyphs: NSRange,
            isTruncated: Bool,
            in textView: TextView
        ) {
            let visibleCharacters = textView.layoutManager.characterRange(
                forGlyphRange: visibleGlyphs,
                actualGlyphRange: nil
            )
            guard visibleCharacters.location != NSNotFound,
                  NSMaxRange(visibleCharacters) <= textView.attributedText.length else {
                return
            }
            let visibleText = textView.attributedText.attributedSubstring(from: visibleCharacters).string
            textView.accessibilityLabel = visibleText + (isTruncated ? "…" : "")
            textView.accessibilityValue = ""

            var links: [String: URL] = [:]
            textView.attributedText.enumerateAttribute(
                .link,
                in: visibleCharacters
            ) { value, range, _ in
                guard let url = value as? URL else { return }
                let label = textView.attributedText.attributedSubstring(from: range).string
                links["Open link \(label)"] = url
            }
            accessibilityLinks = links
            textView.accessibilityCustomActions = links.keys.sorted().map { label in
                UIAccessibilityCustomAction(name: label, target: self, selector: #selector(openAccessibilityLink(_:)))
            }
        }
    }

    @MainActor
    final class TextView: UITextView {
        var minimumHeight: CGFloat = 0
        var accessibilityOpenPost: (() -> Void)?
        var onLayout: (() -> Void)?

        override var intrinsicContentSize: CGSize {
            let size = super.intrinsicContentSize
            return CGSize(width: size.width, height: max(minimumHeight, size.height))
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            setNeedsDisplay()
            onLayout?()
        }

        func quoteBarRects() -> [CGRect] {
            layoutManager.ensureLayout(for: textContainer)
            let visible = layoutManager.glyphRange(for: textContainer)
            var rects: [CGRect] = []
            layoutManager.enumerateLineFragments(forGlyphRange: visible) { rect, _, _, glyphRange, _ in
                let characters = self.layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                var depth = 0
                self.attributedText.enumerateAttribute(
                    TaggrInteractiveMarkdownText.quoteDepthAttribute,
                    in: characters
                ) { value, _, _ in depth = max(depth, value as? Int ?? 0) }
                for level in 0..<depth {
                    rects.append(CGRect(
                        x: self.textContainerInset.left + CGFloat(level) * 12,
                        y: self.textContainerInset.top + rect.minY,
                        width: 3,
                        height: rect.height
                    ))
                }
            }
            return rects
        }

        override func draw(_ rect: CGRect) {
            super.draw(rect)
            let color = attributedText.length > 0
                ? attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
                : nil
            (color ?? .label).setFill()
            for bar in quoteBarRects() { UIRectFill(bar) }
        }

        override func accessibilityActivate() -> Bool {
            guard let accessibilityOpenPost else { return super.accessibilityActivate() }
            accessibilityOpenPost()
            return true
        }

        override func accessibilityElementCount() -> Int {
            0
        }

        override func accessibilityElement(at index: Int) -> Any? {
            nil
        }

        override func index(ofAccessibilityElement element: Any) -> Int {
            NSNotFound
        }

        func characterOffset(at point: CGPoint) -> Int? {
            let containerPoint = CGPoint(
                x: point.x - textContainerInset.left,
                y: point.y - textContainerInset.top
            )
            let glyphIndex = layoutManager.glyphIndex(
                for: containerPoint,
                in: textContainer,
                fractionOfDistanceThroughGlyph: nil
            )
            guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
            let glyphBounds = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 1),
                in: textContainer
            )
            guard glyphBounds.insetBy(dx: -4, dy: -4).contains(containerPoint) else { return nil }
            return layoutManager.characterIndexForGlyph(at: glyphIndex)
        }
    }
}
