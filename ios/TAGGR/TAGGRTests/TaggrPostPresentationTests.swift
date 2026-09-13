import XCTest
import CryptoKit
import SwiftUI
import UIKit
@testable import TAGGR

final class ModerationURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var version = 1
    nonisolated(unsafe) static var postIDs: Set<Int> = []
    nonisolated(unsafe) static var userIDs: Set<Int> = []
    nonisolated(unsafe) static var lastReport: TaggrContentReport?
    nonisolated(unsafe) static var reportAttempts = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            let data: Data
            if request.httpMethod == "POST" {
                let report = try JSONDecoder().decode(TaggrContentReport.self, from: TaggrTests.requestBody(from: request) ?? Data())
                Self.lastReport = report
                Self.reportAttempts += 1
                data = try JSONSerialization.data(withJSONObject: ["id":report.id.lowercased(),"status":"received"])
            } else {
                let canister = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
                data = try JSONEncoder().encode(TaggrModerationList(canisterID:canister,version:Self.version,postIDs:Self.postIDs,userIDs:Self.userIDs))
            }
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:Self.statusCode,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
}

extension TaggrTests {
    func makeSafetyStore() -> TaggrSafetyStore {
        let suite = "SafetyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        ModerationURLProtocolStub.statusCode = 200
        ModerationURLProtocolStub.version = 1
        ModerationURLProtocolStub.postIDs = []
        ModerationURLProtocolStub.userIDs = []
        ModerationURLProtocolStub.lastReport = nil
        ModerationURLProtocolStub.reportAttempts = 0
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModerationURLProtocolStub.self]
        return TaggrSafetyStore(defaults: defaults, session: URLSession(configuration: config))
    }

    func testModerationHideRestoreAndOutageDoNotBlockApp() async {
        let state = TaggrAppCoordinator(safety: makeSafetyStore())
        state.safety.accept(scope: state.safetyScope)
        let post = samplePost(body: "safe", files: [:])
        let canister = state.runtimeConfig.canisterId
        ModerationURLProtocolStub.statusCode = 404
        await state.safety.refresh(canisterID: canister)
        XCTAssertTrue(state.canAccessUGC)
        XCTAssertTrue(state.canDisplayPost(post))
        ModerationURLProtocolStub.statusCode = 200
        ModerationURLProtocolStub.postIDs = [post.id]
        await state.safety.refresh(canisterID: canister)
        XCTAssertFalse(state.canDisplayPost(post))
        ModerationURLProtocolStub.statusCode = 503
        ModerationURLProtocolStub.postIDs = []
        await state.safety.refresh(canisterID: canister)
        XCTAssertFalse(state.canDisplayPost(post), "Failure must retain last known restrictions")
        XCTAssertTrue(state.canAccessUGC)
        ModerationURLProtocolStub.statusCode = 200
        ModerationURLProtocolStub.version = 2
        await state.safety.refresh(canisterID: canister)
        XCTAssertTrue(state.canDisplayPost(post))
        ModerationURLProtocolStub.version = 3
        ModerationURLProtocolStub.userIDs = [post.user]
        await state.safety.refresh(canisterID: canister)
        XCTAssertFalse(state.canDisplayPost(post))
        XCTAssertTrue(state.canAccessUGC, "A hidden user's content must not suspend app access")
    }

    func testModerationRejectsOlderAndInvalidLists() async {
        let state = TaggrAppCoordinator(safety: makeSafetyStore())
        let canister = state.runtimeConfig.canisterId
        ModerationURLProtocolStub.version = 5
        ModerationURLProtocolStub.postIDs = [42]
        await state.safety.refresh(canisterID:canister)
        ModerationURLProtocolStub.version = 4
        ModerationURLProtocolStub.postIDs = []
        await state.safety.refresh(canisterID:canister)
        XCTAssertTrue(state.safety.isPostHidden(42,canisterID:canister))
        ModerationURLProtocolStub.version = 6
        ModerationURLProtocolStub.postIDs = [-1]
        await state.safety.refresh(canisterID:canister)
        XCTAssertTrue(state.safety.isPostHidden(42,canisterID:canister))
        XCTAssertFalse(state.safety.isPostHidden(42,canisterID:"other"))
    }

    func testInAppReportRequiresConfirmedReceiptAndPreservesRetryID() async throws {
        let store = makeSafetyStore()
        let report = TaggrContentReport(id:UUID().uuidString,canisterID:TaggrRuntimeConfig.productionCanisterId,userID:7,postID:42,reason:"日本語 & 🐱")
        ModerationURLProtocolStub.statusCode = 503
        do { try await store.sendReport(report); XCTFail("Failed persistence must not succeed") } catch {}
        ModerationURLProtocolStub.statusCode = 201
        try await store.sendReport(report)
        XCTAssertEqual(ModerationURLProtocolStub.lastReport?.id, report.id)
        XCTAssertEqual(ModerationURLProtocolStub.lastReport?.reason, report.reason)
        XCTAssertEqual(ModerationURLProtocolStub.lastReport?.postID, 42)
    }

    func testModerationListSurvivesRestartWithoutExpiry() async throws {
        let suite = "ModerationPersistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        _ = makeSafetyStore()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModerationURLProtocolStub.self]
        let store = TaggrSafetyStore(defaults:defaults,session:URLSession(configuration:config))
        ModerationURLProtocolStub.postIDs = [42]
        await store.refresh(canisterID:TaggrRuntimeConfig.productionCanisterId)
        let restored = TaggrSafetyStore(defaults:defaults)
        XCTAssertTrue(restored.isPostHidden(42,canisterID:TaggrRuntimeConfig.productionCanisterId))
    }

    func testModerationReportInteractiveUI() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--moderation-ui-review") else {
            throw XCTSkip("Run with --moderation-ui-review and idb for report UI verification.")
        }
        let state = TaggrAppCoordinator(safety:makeSafetyStore())
        ModerationURLProtocolStub.statusCode = 503
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene:scene)
        window.rootViewController = UIHostingController(rootView:ContentReportSheet(userID:7,postID:42,isPresented:.constant(true)).environment(state))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        var firstReport: TaggrContentReport?
        for _ in 0..<120 {
            if ModerationURLProtocolStub.reportAttempts == 1 {
                firstReport = ModerationURLProtocolStub.lastReport
                ModerationURLProtocolStub.statusCode = 201
            }
            if ModerationURLProtocolStub.reportAttempts >= 2 {
                XCTAssertFalse(firstReport?.reason.isEmpty ?? true)
                XCTAssertEqual(ModerationURLProtocolStub.lastReport?.reason, firstReport?.reason)
                XCTAssertEqual(ModerationURLProtocolStub.lastReport?.id, firstReport?.id)
                try await Task.sleep(for:.seconds(8))
                return
            }
            try await Task.sleep(for:.seconds(1))
        }
        XCTFail("Use idb to send a report, acknowledge the failure, and retry.")
    }

    func testSafetyConsentImmediatelyAllowsContentWithoutService() async {
        let state = TaggrAppCoordinator(safety: makeSafetyStore())
        let post = samplePost(body: "safe", files: [:])
        XCTAssertFalse(state.canDisplayPost(post))
        state.safety.accept(scope: state.safetyScope)
        XCTAssertTrue(state.canDisplayPost(post))
        XCTAssertFalse(state.canDisplayPost(samplePost(body: "#NSFW", files: [:])))
        await state.toggleBlock(userId: post.user)
        XCTAssertFalse(state.canDisplayPost(post))
        await state.toggleBlock(userId: post.user)
        XCTAssertTrue(state.canDisplayPost(post))
    }

    func testSafetyAgreementAndBlockSurviveRestart() {
        let suite = "SafetyPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TaggrSafetyStore(defaults: defaults)
        store.accept(scope: "canister:alice")
        store.setBlocked(true, userID: 7, scope: "canister:alice")
        let restored = TaggrSafetyStore(defaults: defaults)
        XCTAssertTrue(restored.accepted(scope: "canister:alice"))
        XCTAssertFalse(restored.accepted(scope: "canister:bob"))
        XCTAssertTrue(restored.isBlocked(userID: 7, scope: "canister:alice", remote: []))
        XCTAssertFalse(restored.isBlocked(userID: 7, scope: "canister:bob", remote: []))
    }

    func testSafetyRejectsNSFWPublishingWithoutService() async {
        let state = TaggrAppCoordinator(safety: makeSafetyStore())
        state.safety.accept(scope: state.safetyScope)
        do { try await state.requireSafePublishing(text: "#NSFW"); XCTFail("NSFW must not be published") }
        catch { XCTAssertEqual(error.localizedDescription, TaggrSafetyError.nsfw.localizedDescription) }
        do { try await state.requireSafePublishing(text: "safe text") }
        catch { XCTFail("No safety service is required: \(error)") }
    }

    func testSafetyRealmRequiresKnownNonAdultDestination() throws {
        func realm(adult: Bool) -> TaggrRealm {
            TaggrRealm(name: "TEST", description: "", labelColor: nil, logo: nil, numMembers: nil, numPosts: nil, adultContent: adult)
        }
        XCTAssertNoThrow(try TaggrAppCoordinator.validateSafetyRealm(realm(adult: false)))
        XCTAssertThrowsError(try TaggrAppCoordinator.validateSafetyRealm(realm(adult: true))) {
            XCTAssertEqual($0.localizedDescription, TaggrSafetyError.nsfw.localizedDescription)
        }
        XCTAssertThrowsError(try TaggrAppCoordinator.validateSafetyRealm(nil)) {
            XCTAssertEqual($0.localizedDescription, TaggrSafetyError.unavailable.localizedDescription)
        }
    }

    func testNotificationLabelsIdentifyRepliesAndMentions() {
        XCTAssertEqual(TaggrNotification.newPost(message: "A new reply to your post", postId: 8).safetyMessage, "A new reply to your post")
        XCTAssertEqual(TaggrNotification.newPost(message: "You were mentioned in a post", postId: 8).safetyMessage, "You were mentioned in a post")
        XCTAssertEqual(TaggrNotification.newPost(message: "A new repost of your post", postId: 8).safetyMessage, "A new repost of your post")
        XCTAssertEqual(TaggrNotification.newPost(message: "A new reply to your post\n#NSFW", postId: 8).safetyMessage, "This notification contains restricted content.")
        XCTAssertEqual(TaggrNotification.newPost(message: "A new reply to your post", postId: 8).postId, 8)
        XCTAssertEqual(TaggrNotification.generic("@alice followed you (untrusted bio, `2` followers)").safetyMessage, "@alice followed you.")
    }

    func testSafetyNotificationPreservesSystemDetailsWithoutFollowerBio() {
        let reward = "You received `0.12` ICP as rewards and `0.03` ICP as revenue! 💸"
        XCTAssertEqual(TaggrNotification.generic(reward).safetyMessage, reward)
        let legacy = "You received `12` credits."
        XCTAssertEqual(TaggrNotification.generic(legacy).safetyMessage, legacy)
        let mint = "TAGGR minted `12.5` $TAGGR tokens for you! 💎"
        XCTAssertEqual(TaggrNotification.generic(mint).safetyMessage, mint)
        XCTAssertEqual(TaggrNotification.conditional(message: "untrusted", predicate: .proposal(42)).safetyMessage,
                       "untrusted")
        XCTAssertEqual(TaggrNotification.watchedPostEntries(postId: 7, entries: [8, 9]).safetyMessage,
                       "2 new thread update(s) on a watched post.")
        XCTAssertEqual(TaggrNotification.generic("@name followed you (#NSFW bio, `2` followers)").safetyMessage,
                       "@name followed you.")
        XCTAssertFalse(TaggrNotification.generic(reward + "\n#NSFW").safetyMessage.contains("#NSFW"))
        XCTAssertFalse(TaggrNotification.newPost(message: "#NSFW", postId: 5).safetyMessage.contains("#NSFW"))
    }
}

extension TaggrTests {
    func testFeedImagePrefetchSkipsSensitivePosts() {
        let visible = samplePost(
            id: 1,
            body: "visible\n\n![x](/blob/visible)",
            files: ["visible@aaaaa-aa": [LosslessInt(1), LosslessInt(20)]]
        )
        let sensitive = samplePost(
            id: 2,
            body: "sensitive\n\n![x](/blob/sensitive)",
            files: ["sensitive@aaaaa-aa": [LosslessInt(2), LosslessInt(20)]],
            meta: TaggrPostMeta(authorName: "alice", realmColor: nil, nsfw: true, viewerBlocked: false)
        )

        let urls = FeedImagePrefetchPolicy
            .attachments(in: [visible, sensitive], around: visible, currentUserId: nil)
            .map(\.url)

        XCTAssertEqual(urls.map(\.absoluteString), ["https://aaaaa-aa.raw.icp0.io/image?offset=1&len=20"])
    }

    func testFeedImagePrefetchSkipsBodyTaggedNSFWPosts() {
        let visible = samplePost(
            id: 1,
            body: "visible\n\n![x](/blob/visible)",
            files: ["visible@aaaaa-aa": [LosslessInt(1), LosslessInt(20)]]
        )
        let sensitive = samplePost(
            id: 2,
            body: "#NSFW\n\n![x](/blob/sensitive)",
            files: ["sensitive@aaaaa-aa": [LosslessInt(2), LosslessInt(20)]]
        )

        let urls = FeedImagePrefetchPolicy
            .attachments(in: [visible, sensitive], around: visible, currentUserId: nil)
            .map(\.url)

        XCTAssertEqual(urls.map(\.absoluteString), ["https://aaaaa-aa.raw.icp0.io/image?offset=1&len=20"])
    }

    func testLoadMorePresentationUsesScopedLoadingState() {
        XCTAssertTrue(FeedView.showsBusyOverlay(isBusy: true, isLoadingMore: false))
        XCTAssertFalse(FeedView.showsBusyOverlay(isBusy: true, isLoadingMore: true))
        XCTAssertTrue(ProfileView.showsJournalHeaderSpinner(isLoading: true, hasPosts: false))
        XCTAssertFalse(ProfileView.showsJournalHeaderSpinner(isLoading: true, hasPosts: true))
    }

    func testLongLinkedPostKeepsPlainTextAndLinkTapTargetsSeparate() {
        let body = """
        I have no words

        If you're not living under a rock, I'm sure the world has changed.

        Two hours later, the [PR](https://example.com/pr) was ready.

        I have no words to properly express what I feel.
        """

        let attributed = TaggrInteractiveMarkdownText.attributedText(for: body)
        let string = attributed.string as NSString
        let linkOffset = string.range(of: "PR").location
        let plainOffset = string.range(of: "Two hours later").location

        XCTAssertEqual(
            TaggrInteractiveMarkdownText.link(atUTF16Offset: linkOffset, in: attributed),
            URL(string: "https://example.com/pr")
        )
        XCTAssertNil(TaggrInteractiveMarkdownText.link(atUTF16Offset: plainOffset, in: attributed))
        XCTAssertEqual(attributed.string.components(separatedBy: "\n\n").count, 4)
    }

    func testInteractiveMarkdownPreservesListItemsAsSeparateLines() {
        let attributed = TaggrInteractiveMarkdownText.attributedText(for: "- first\n- second")

        XCTAssertEqual(attributed.string, "• first\n• second")
    }

    func testInteractiveMarkdownLayoutStopsAtTenActualLines() {
        let textView = TaggrInteractiveMarkdownText.TextView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 1_000)
        )
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.maximumNumberOfLines = 10
        textView.textContainer.lineBreakMode = .byTruncatingTail
        textView.attributedText = TaggrInteractiveMarkdownText.attributedText(
            for: (1...12).map { "line \($0)" }.joined(separator: "  \n")
        )
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let visibleGlyphs = textView.layoutManager.glyphRange(for: textView.textContainer)
        var visibleLineCount = 0
        textView.layoutManager.enumerateLineFragments(forGlyphRange: visibleGlyphs) { _, _, _, _, _ in
            visibleLineCount += 1
        }

        XCTAssertEqual(visibleLineCount, 10)
        XCTAssertLessThan(NSMaxRange(visibleGlyphs), textView.layoutManager.numberOfGlyphs)
    }

    func testPostPresentationDerivesBodiesAndReplyCount() {
        let post = samplePost(
            body: "original",
            effBody: "edited\n\n\n\nhidden",
            children: [2],
            files: [:],
            treeSize: 4
        )
        let leaf = samplePost(body: "leaf", files: [:], treeSize: 4)

        XCTAssertEqual(post.effectiveBody, "edited\n\n\n\nhidden")
        XCTAssertEqual(post.timelineBody, "edited")
        XCTAssertEqual(post.replyCount, 4)
        XCTAssertEqual(leaf.replyCount, 0)
    }

    func testPostContentRestrictionUsesStablePriorityAndRevealability() {
        let meta = TaggrPostMeta(
            authorName: "alice",
            realmColor: nil,
            nsfw: true,
            viewerBlocked: false,
            maxDownvotesReached: true
        )
        let allRestrictions = samplePost(
            body: "#nsfw",
            files: [:],
            hashes: ["deleted"],
            encrypted: true,
            hiddenFor: [7],
            meta: meta
        )
        let moderated = samplePost(body: "body", files: [:], meta: meta)
        let deleted = samplePost(body: "body", files: [:], hashes: ["deleted"])
        let hidden = samplePost(body: "body", files: [:], hiddenFor: [7])
        let nsfw = samplePost(body: "#NsFw", files: [:])

        XCTAssertEqual(allRestrictions.contentRestriction(viewerID: 7), .encrypted)
        XCTAssertEqual(moderated.contentRestriction(viewerID: nil), .moderated)
        XCTAssertEqual(deleted.contentRestriction(viewerID: nil), .deleted(["deleted"]))
        XCTAssertEqual(hidden.contentRestriction(viewerID: 7), .hidden)
        XCTAssertNil(hidden.contentRestriction(viewerID: 8))
        XCTAssertEqual(nsfw.contentRestriction(viewerID: nil), .nsfw)
        XCTAssertFalse(TaggrPostContentRestriction.encrypted.isRevealable)
        XCTAssertTrue(TaggrPostContentRestriction.hidden.isRevealable)
        XCTAssertFalse(TaggrPostContentRestriction.nsfw.isRevealable)
    }
}


@MainActor
final class TaggrQuoteTests: XCTestCase {
    func testQuoteSelectionAndCursor() {
        let selected = ComposeQuoteEdit.quote("one\ntwo\nthree", selection: NSRange(location: 1, length: 7))
        XCTAssertEqual(selected.text, "> one\n> two\nthree")
        XCTAssertEqual(selected.selection, NSRange(location: 3, length: 9))
        XCTAssertEqual(ComposeQuoteEdit.quote("one\ntwo", selection: NSRange(location: 5, length: 0)).text, "one\n> two")
        XCTAssertEqual(ComposeQuoteEdit.quote("", selection: NSRange(location: 0, length: 0)).text, "> ")
        XCTAssertEqual(ComposeQuoteEdit.quote("> existing", selection: NSRange(location: 3, length: 0)).text, "> existing")
    }

    func testUnicodeAndQuoteNewlines() {
        let text = "日本語😀"
        let quoted = ComposeQuoteEdit.quote(text, selection: NSRange(location: (text as NSString).length, length: 0))
        XCTAssertEqual(quoted.text, "> 日本語😀")
        XCTAssertEqual(quoted.selection.location, (quoted.text as NSString).length)
        let continued = ComposeQuoteEdit.newline(quoted.text, selection: quoted.selection)!
        XCTAssertEqual(continued.text, "> 日本語😀\n> ")
        let ended = ComposeQuoteEdit.newline(continued.text, selection: continued.selection)!
        XCTAssertEqual(ended.text, "> 日本語😀\n\n")
        XCTAssertEqual(ComposeQuoteEdit.newline(">a", selection: NSRange(location: 2, length: 0))?.text, ">a\n> ")
        XCTAssertNil(ComposeQuoteEdit.newline("plain", selection: NSRange(location: 5, length: 0)))
    }

    func testQuoteOnlyChangesTheActiveImageSegment() {
        let document = "before\n![image](/blob/photo)\nafter😀"
        let edit = ComposeQuoteEdit.quote("\nafter😀", selection: NSRange(location: 3, length: 0))
        XCTAssertEqual(
            PostDraftDocument.replacingText(in: document, segmentID: 2, with: edit.text),
            "before\n![image](/blob/photo)\n> after😀"
        )
    }

    func testQuoteControllerUsesLastActiveEditorAndRestoresSelection() {
        let controller = ComposeQuoteEditor()
        var first = "first"
        var second = "日本語😀"
        var activated = false
        let firstEditor = ComposeSelectableTextEditor(
            text: Binding(get: { first }, set: { first = $0 }), quoteEditor: controller,
            isFocused: false, activate: {}
        ).makeCoordinator()
        let secondEditor = ComposeSelectableTextEditor(
            text: Binding(get: { second }, set: { second = $0 }), quoteEditor: controller,
            isFocused: false, activate: { activated = true }
        ).makeCoordinator()
        let firstView = UITextView()
        firstView.text = first
        firstEditor.view = firstView
        firstEditor.textViewDidBeginEditing(firstView)
        let secondView = UITextView()
        secondView.text = second
        secondView.selectedRange = NSRange(location: 3, length: 2)
        secondEditor.view = secondView
        secondEditor.textViewDidBeginEditing(secondView)
        controller.quote()
        XCTAssertEqual(first, "first")
        XCTAssertEqual(second, "> 日本語😀")
        XCTAssertEqual(secondView.selectedRange, NSRange(location: 5, length: 2))
        XCTAssertTrue(activated)
    }

    func testQuoteBarsFollowFontSizeAndNestedDepth() {
        let view = TaggrInteractiveMarkdownText.TextView(frame: CGRect(x: 0, y: 0, width: 320, height: 1000))
        view.textContainerInset = .zero
        view.isScrollEnabled = false
        let text = NSMutableAttributedString(attributedString: TaggrInteractiveMarkdownText.attributedText(for: "> > nested"))
        view.attributedText = text
        let original = view.quoteBarRects()
        XCTAssertEqual(original.count, 2)
        XCTAssertEqual(original.map(\.minX), [0, 12])
        text.addAttribute(.font, value: UIFont.systemFont(ofSize: 40), range: NSRange(location: 0, length: text.length))
        view.attributedText = text
        XCTAssertGreaterThan(view.quoteBarRects()[0].height, original[0].height)
    }

    func testQuoteDepthLinksAndNormalParagraph() {
        let text = TaggrInteractiveMarkdownText.attributedText(for: "> **quoted** [link](https://example.com)\n>\n> > nested\n\nnormal")
        let source = text.string as NSString
        for (word, depth) in [("quoted", 1), ("nested", 2)] {
            let offset = source.range(of: word).location
            XCTAssertEqual(text.attribute(TaggrInteractiveMarkdownText.quoteDepthAttribute, at: offset, effectiveRange: nil) as? Int, depth)
            XCTAssertEqual((text.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)?.headIndent, CGFloat(depth * 12))
        }
        XCTAssertNil(text.attribute(TaggrInteractiveMarkdownText.quoteDepthAttribute, at: source.range(of: "normal").location, effectiveRange: nil))
        XCTAssertNotNil(text.attribute(.link, at: source.range(of: "link").location, effectiveRange: nil))
        XCTAssertFalse(text.string.contains(">"))
    }

    @MainActor
    private final class ComposerState: ObservableObject {
        @Published var text = ""
        @Published var focused: Int? = 0
        @Published var imageTarget: Int?
        @Published var enabled = true
        @Published var visible = true
        @Published var revision = 0
        var changed: ((String) -> Void)?
        let documentID = UUID()
        let quotes = ComposeQuoteEditor()
    }

    private struct ComposerHarness: View {
        @ObservedObject var state: ComposerState
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if state.visible {
                        ComposePostDocumentEditor(
                            text: $state.text, draftImages: [], existingImages: [:],
                            placeholder: "Write a post \(state.revision)", documentID: state.documentID,
                            focusedTextSegmentID: $state.focused,
                            imageInsertionSegmentID: $state.imageTarget,
                            removeImage: { _, _ in }, moveImage: { _, _ in }
                        )
                        .disabled(!state.enabled)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
            }
            .environmentObject(state.quotes)
            .onChange(of: state.text) { _, text in state.changed?(text) }
        }
    }

    @MainActor
    private final class HostedComposer {
        let state = ComposerState()
        let host: UIHostingController<ComposerHarness>
        let window: UIWindow
        let previousWindow: UIWindow?

        init(text: String = "") throws {
            state.text = text
            host = UIHostingController(rootView: ComposerHarness(state: state))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            previousWindow = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
        }

        func close() {
            window.isHidden = true
            previousWindow?.makeKey()
        }

        private var awaitingInitialPresentation = true

        func settle() async throws {
            // Let the initial keyboard presentation finish before driving UITextInput.
            try await Task.sleep(for: .milliseconds(awaitingInitialPresentation ? 600 : 100))
            awaitingInitialPresentation = false
            host.view.layoutIfNeeded()
        }

        var inputs: [UITextView] {
            func find(_ view: UIView) -> [UITextView] {
                if let input = view as? UITextView { return [input] }
                return view.subviews.flatMap(find)
            }
            return find(host.view)
        }

        func input() throws -> UITextView { try XCTUnwrap(inputs.first) }
    }

    func testComposerWidthFocusAndMultilineLayout() async throws {
        let fixture = try HostedComposer()
        defer { fixture.close() }
        try await fixture.settle()
        let input = try fixture.input()
        for text in ["", "abc", String(repeating: "日本語の長い行を入力して折り返しを確認します。\n", count: 8), ""] {
            let shortHeight = input.bounds.height
            input.selectedRange = NSRange(location: 0, length: (input.text as NSString).length)
            input.insertText(text)
            try await fixture.settle()
            XCTAssertEqual(fixture.state.text, text)
            XCTAssertEqual(input.convert(input.bounds, to: fixture.host.view).minX, 18, accuracy: 1)
            XCTAssertEqual(input.bounds.width, fixture.host.view.bounds.width - 36, accuracy: 1)
            XCTAssertTrue(input.isFirstResponder)
            if text.contains("\n") { XCTAssertGreaterThan(input.bounds.height, shortHeight) }
        }
    }

    func testComposerJapaneseCompositionSurvivesParentUpdates() async throws {
        let fixture = try HostedComposer()
        defer { fixture.close() }
        try await fixture.settle()
        let input = try fixture.input()
        input.insertText("abc")
        try await fixture.settle()
        input.selectedRange = NSRange(location: 3, length: 0)
        input.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertNotNil(input.markedTextRange, "Immediately after marking")
        XCTAssertEqual(input.text, "abcにほん", "Immediately after marking")
        try await fixture.settle()
        XCTAssertNotNil(input.markedTextRange, "Before parent refresh")
        fixture.state.revision += 1
        try await fixture.settle()
        XCTAssertNotNil(input.markedTextRange)
        XCTAssertEqual(input.text, "abcにほん")
        XCTAssertTrue(input.isFirstResponder)
        input.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        input.unmarkText()
        input.insertText("語")
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "abc日本語")
        input.setMarkedText("とりけし", selectedRange: NSRange(location: 4, length: 0))
        input.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        input.unmarkText()
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "abc日本語")
        input.selectedRange = NSRange(location: 3, length: 3)
        fixture.state.revision += 1
        try await fixture.settle()
        XCTAssertEqual(input.selectedRange, NSRange(location: 3, length: 3))
        input.insertText("😀")
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "abc😀")
    }

    func testComposerRestoredMarkedTextSurvivesUpdatesWithoutSystemKeyboard() async throws {
        let fixture = try HostedComposer(text: "abc")
        defer { fixture.close() }
        fixture.state.focused = nil
        try await fixture.settle()
        let input = try fixture.input()
        XCTAssertFalse(input.isFirstResponder)
        // Synthetic marked text must not compete with the live keyboard's candidate callbacks.
        input.selectedRange = NSRange(location: 3, length: 0)
        input.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        fixture.state.revision += 1
        try await fixture.settle()
        XCTAssertNotNil(input.markedTextRange)
        XCTAssertEqual(input.text, "abcにほん")
        input.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        input.unmarkText()
        input.insertText("語")
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "abc日本語")
    }

    func testComposerImageSegmentFocusAndMarkerPreservation() async throws {
        let fixture = try HostedComposer(text: "before\n![](/blob/test-image)\nafter")
        defer { fixture.close() }
        try await fixture.settle()
        XCTAssertEqual(fixture.inputs.count, 2)
        let first = try fixture.input()
        let last = try XCTUnwrap(fixture.inputs.last)
        XCTAssertTrue(last.becomeFirstResponder())
        last.selectedRange = NSRange(location: (last.text as NSString).length, length: 0)
        last.insertText(" 日本語")
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "before\n![](/blob/test-image)\nafter 日本語")
        XCTAssertTrue(last.isFirstResponder)
        XCTAssertFalse(first.isFirstResponder)
        XCTAssertEqual(last.bounds.width, fixture.host.view.bounds.width - 36, accuracy: 1)
    }

    func testComposerDisablesAndReopensWithoutLosingText() async throws {
        let fixture = try HostedComposer(text: "下書き😀")
        defer { fixture.close() }
        try await fixture.settle()
        let input = try fixture.input()
        fixture.state.enabled = false
        try await fixture.settle()
        XCTAssertFalse(input.isEditable)
        XCTAssertFalse(input.isFirstResponder)
        fixture.state.enabled = true
        try await fixture.settle()
        XCTAssertTrue(input.isFirstResponder)
        fixture.state.focused = nil
        try await fixture.settle()
        XCTAssertFalse(input.isFirstResponder)
        fixture.state.visible = false
        try await fixture.settle()
        XCTAssertTrue(fixture.inputs.isEmpty)
        fixture.state.visible = true
        fixture.state.focused = 0
        try await fixture.settle()
        let reopened = try fixture.input()
        XCTAssertEqual(reopened.text, "下書き😀")
        XCTAssertTrue(reopened.isFirstResponder)
        reopened.selectedRange = NSRange(location: (reopened.text as NSString).length, length: 0)
        reopened.insertText("追記")
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "下書き😀追記")
    }

    func testComposerCutPasteUndoRedo() async throws {
        let fixture = try HostedComposer(text: "日本語😀/text")
        defer { fixture.close() }
        try await fixture.settle()
        let input = try fixture.input()
        let pasteboard = UIPasteboard.general
        let previousItems = pasteboard.items
        defer { pasteboard.items = previousItems }
        input.selectedRange = NSRange(location: 0, length: 5)
        input.cut(nil)
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "/text")
        XCTAssertEqual(pasteboard.string, "日本語😀")
        // Supply test data explicitly; OS clipboard permission is a separate UI check.
        // UIKit smart insertion also adds this newline in a standalone UITextView.
        input.paste(itemProviders: [NSItemProvider(object: "日本語😀" as NSString)])
        for _ in 0..<20 {
            try await fixture.settle()
            if fixture.state.text != "/text" { break }
        }
        XCTAssertEqual(fixture.state.text, "日本語😀\n/text")
        let undo = try XCTUnwrap(input.undoManager)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "/text")
        XCTAssertTrue(undo.canRedo)
        undo.redo()
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "日本語😀\n/text")
    }

    func testComposerToolbarPreservesAppendSemanticsAndSelection() async throws {
        let fixture = try HostedComposer(text: "日本語😀")
        defer { fixture.close() }
        try await fixture.settle()
        let input = try fixture.input()
        input.selectedRange = NSRange(location: 0, length: 3)
        let bar = ComposePostAttachmentBar(
            text: Binding(get: { fixture.state.text }, set: { fixture.state.text = $0 }),
            selectedPhotos: .constant([]), youtubeTarget: nil, insertYouTubeURL: { _ in },
            isSubmitting: false, isImagePickerDisabled: true
        )
        for (action, expected) in [
            (ComposeMarkdownAction.bold, "日本語😀 **bold**"),
            (.italic, "日本語😀 **bold** _italic_"),
            (.list, "日本語😀 **bold** _italic_\n- item")
        ] {
            bar.perform(action)
            try await fixture.settle()
            XCTAssertEqual(fixture.state.text, expected)
            XCTAssertEqual(input.text, expected)
            XCTAssertEqual(input.selectedRange, NSRange(location: 0, length: 3))
        }
        bar.appendInline("[example](https://example.com)")
        try await fixture.settle()
        XCTAssertEqual(input.text, "日本語😀 **bold** _italic_\n- item [example](https://example.com)")
        fixture.state.quotes.quote()
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "> 日本語😀 **bold** _italic_\n- item [example](https://example.com)")
    }

    func testComposerRestoredDraftEditsPersistInEachContext() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ComposerDraft-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PostDraftStore(rootURL: root)
        let namespace = PostDraftNamespace(canisterID: "test", userID: 7)
        for context in [PostDraftContext.newPost, .reply(42), .edit(42)] {
            let session = PostDraftSession(context: context, initialText: "", initialRealm: "")
            await session.load(store: store, namespace: namespace)
            session.text = "**保存済み**😀"
            await session.flush()
            let restored = PostDraftSession(context: context, initialText: "", initialRealm: "")
            await restored.load(store: store, namespace: namespace)
            let fixture = try HostedComposer(text: restored.text)
            fixture.state.changed = { restored.text = $0 }
            defer { fixture.close() }
            try await fixture.settle()
            let input = try fixture.input()
            XCTAssertEqual(input.text, "**保存済み**😀")
            input.selectedRange = NSRange(location: (input.text as NSString).length, length: 0)
            input.insertText("追記")
            try await fixture.settle()
            await restored.flush()
            let saved = await store.load(namespace: namespace, context: context)
            XCTAssertEqual(saved.text, "**保存済み**😀追記")
        }
    }

    func testComposerResizesAndSupportsLargeText() async throws {
        let fixture = try HostedComposer(text: String(repeating: "日本語の折り返し ", count: 12))
        defer { fixture.close() }
        try await fixture.settle()
        let input = try fixture.input()
        // Host the same editor at portrait and landscape widths without rotating the user's device.
        for width: CGFloat in [320, 700] {
            fixture.window.frame = CGRect(x: 0, y: 0, width: width, height: 700)
            try await fixture.settle()
            XCTAssertEqual(input.bounds.width, fixture.host.view.bounds.width - 36, accuracy: 1)
            XCTAssertEqual(input.convert(input.bounds, to: fixture.host.view).minX, 18, accuracy: 1)
            XCTAssertEqual(input.text, fixture.state.text)
        }
        let originalFont = try XCTUnwrap(input.font).pointSize
        fixture.host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        try await fixture.settle()
        XCTAssertGreaterThan(try XCTUnwrap(input.font).pointSize, originalFont)
        XCTAssertEqual(input.bounds.width, fixture.host.view.bounds.width - 36, accuracy: 1)
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: fixture.host.view.bounds).image { _ in
            fixture.host.view.drawHierarchy(in: fixture.host.view.bounds, afterScreenUpdates: true)
        })
        attachment.name = "Composer large text layout"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHostedEditorQuotesWithoutPriorTyping() async throws {
        let controller = ComposeQuoteEditor()
        var text = "日本語😀"
        let host = UIHostingController(rootView: ComposeSelectableTextEditor(
            text: Binding(get: { text }, set: { text = $0 }), quoteEditor: controller,
            isFocused: true, activate: {}
        ))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousWindow?.makeKey()
        }
        host.view.layoutIfNeeded()
        await Task.yield()
        controller.quote()
        XCTAssertEqual(text, "> 日本語😀")
        func textView(in view: UIView) -> UITextView? {
            if let view = view as? UITextView { return view }
            return view.subviews.compactMap { textView(in: $0) }.first
        }
        let input = try XCTUnwrap(textView(in: host.view))
        XCTAssertTrue(input.isFirstResponder)
        XCTAssertEqual(input.text, text)
    }

    func testQuoteDecorationIsActuallyDrawn() {
        let view = TaggrInteractiveMarkdownText.TextView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.textContainerInset = .zero
        view.backgroundColor = .white
        view.isScrollEnabled = false
        view.attributedText = TaggrInteractiveMarkdownText.attributedText(
            for: "> quoted\n> second line\n\nnormal", textColor: .black
        )
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Quote decoration and normal paragraph"
        attachment.lifetime = .keepAlways
        add(attachment)
        let pixel = image.cgImage!.cropping(to: CGRect(x: 1, y: 8, width: 1, height: 1))!
        var rgba = [UInt8](repeating: 255, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertLessThan(rgba[0], 32)
        XCTAssertLessThan(rgba[1], 32)
        XCTAssertLessThan(rgba[2], 32)
    }

    func testQuoteBarsWrapAndRespectLineLimit() {
        let view = TaggrInteractiveMarkdownText.TextView(frame: CGRect(x: 0, y: 0, width: 150, height: 1000))
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.attributedText = TaggrInteractiveMarkdownText.attributedText(for: "> " + String(repeating: "quoted words ", count: 30))
        view.layoutIfNeeded()
        XCTAssertGreaterThan(view.quoteBarRects().count, 2)
        view.textContainer.maximumNumberOfLines = 2
        view.textContainer.lineBreakMode = .byTruncatingTail
        view.layoutManager.ensureLayout(for: view.textContainer)
        XCTAssertEqual(view.quoteBarRects().count, 2)
        XCTAssertTrue(view.quoteBarRects().allSatisfy { $0.width == 3 && $0.minX == 0 })
    }
}
