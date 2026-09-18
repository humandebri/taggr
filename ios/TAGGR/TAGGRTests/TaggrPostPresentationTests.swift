import XCTest
import CryptoKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
@testable import TAGGR

final class ModerationFixture: @unchecked Sendable {
    private struct State {
        var statusCode = 200
        var version = 1
        var postIDs: Set<Int> = []
        var userIDs: Set<Int> = []
        var lastReport: TaggrContentReport?
        var reportAttempts = 0
    }
    private let state = LockedTestValue(State())
    var statusCode: Int {
        get { state.read { $0.statusCode } }
        set { state.mutate { $0.statusCode = newValue } }
    }
    var version: Int {
        get { state.read { $0.version } }
        set { state.mutate { $0.version = newValue } }
    }
    var postIDs: Set<Int> {
        get { state.read { $0.postIDs } }
        set { state.mutate { $0.postIDs = newValue } }
    }
    var userIDs: Set<Int> {
        get { state.read { $0.userIDs } }
        set { state.mutate { $0.userIDs = newValue } }
    }
    var lastReport: TaggrContentReport? {
        get { state.read { $0.lastReport } }
        set { state.mutate { $0.lastReport = newValue } }
    }
    var reportAttempts: Int {
        get { state.read { $0.reportAttempts } }
        set { state.mutate { $0.reportAttempts = newValue } }
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let current = state.read { $0 }
        let data: Data
        if request.httpMethod == "POST" {
            let report = try JSONDecoder().decode(TaggrContentReport.self, from: TaggrTests.requestBody(from: request) ?? Data())
            state.mutate { $0.lastReport = report; $0.reportAttempts += 1 }
            data = try JSONSerialization.data(withJSONObject: ["id": report.id.lowercased(), "status": "received"])
        } else {
            let canister = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
            data = try JSONEncoder().encode(TaggrModerationList(canisterID: canister, version: current.version, postIDs: current.postIDs, userIDs: current.userIDs))
        }
        return (HTTPURLResponse(url: request.url!, statusCode: current.statusCode, httpVersion: nil, headerFields: nil)!, data)
    }
}

extension TaggrTests {
    func makeSafetyStore(defaults suppliedDefaults: UserDefaults? = nil, fixture: ModerationFixture = ModerationFixture()) -> TaggrSafetyStore {
        let suite = "SafetyTests.\(UUID().uuidString)"
        let defaults = suppliedDefaults ?? UserDefaults(suiteName: suite)!
        let id = UUID().uuidString
        TaggrURLProtocolStub.register(id: id, handler: fixture.response)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TaggrURLProtocolStub.self]
        config.httpAdditionalHeaders = [TaggrURLProtocolStub.handlerHeader: id]
        let session = URLSession(configuration: config)
        addTeardownBlock {
            session.invalidateAndCancel()
            TaggrURLProtocolStub.unregister(id: id)
            if suppliedDefaults == nil { defaults.removePersistentDomain(forName: suite) }
        }
        return TaggrSafetyStore(defaults: defaults, session: session)
    }

    func testModerationHideRestoreAndOutageDoNotBlockApp() async {
        let fixture = ModerationFixture()
        let state = makeCoordinator(safety: makeSafetyStore(fixture: fixture))
        state.safety.accept(scope: state.safetyScope)
        let post = samplePost(body: "safe", files: [:])
        let canister = state.runtimeConfig.canisterId
        fixture.statusCode = 404
        await state.safety.refresh(canisterID: canister)
        XCTAssertTrue(state.canAccessUGC)
        XCTAssertTrue(state.canDisplayPost(post))
        fixture.statusCode = 200
        fixture.postIDs = [post.id]
        await state.safety.refresh(canisterID: canister)
        XCTAssertFalse(state.canDisplayPost(post))
        fixture.statusCode = 503
        fixture.postIDs = []
        await state.safety.refresh(canisterID: canister)
        XCTAssertFalse(state.canDisplayPost(post), "Failure must retain last known restrictions")
        XCTAssertTrue(state.canAccessUGC)
        fixture.statusCode = 200
        fixture.version = 2
        await state.safety.refresh(canisterID: canister)
        XCTAssertTrue(state.canDisplayPost(post))
        fixture.version = 3
        fixture.userIDs = [post.user]
        await state.safety.refresh(canisterID: canister)
        XCTAssertFalse(state.canDisplayPost(post))
        XCTAssertTrue(state.canAccessUGC, "A hidden user's content must not suspend app access")
    }

    func testModerationRejectsOlderAndInvalidLists() async {
        let fixture = ModerationFixture()
        let state = makeCoordinator(safety: makeSafetyStore(fixture: fixture))
        let canister = state.runtimeConfig.canisterId
        fixture.version = 5
        fixture.postIDs = [42]
        await state.safety.refresh(canisterID:canister)
        fixture.version = 4
        fixture.postIDs = []
        await state.safety.refresh(canisterID:canister)
        XCTAssertTrue(state.safety.isPostHidden(42,canisterID:canister))
        fixture.version = 6
        fixture.postIDs = [-1]
        await state.safety.refresh(canisterID:canister)
        XCTAssertTrue(state.safety.isPostHidden(42,canisterID:canister))
        XCTAssertFalse(state.safety.isPostHidden(42,canisterID:"other"))
    }

    func testInAppReportRequiresConfirmedReceiptAndPreservesRetryID() async throws {
        let fixture = ModerationFixture()
        let store = makeSafetyStore(fixture: fixture)
        let report = TaggrContentReport(id:UUID().uuidString,canisterID:TaggrRuntimeConfig.productionCanisterId,userID:7,postID:42,reason:"日本語 & 🐱")
        fixture.statusCode = 503
        do { try await store.sendReport(report); XCTFail("Failed persistence must not succeed") } catch {}
        fixture.statusCode = 201
        try await store.sendReport(report)
        XCTAssertEqual(fixture.lastReport?.id, report.id)
        XCTAssertEqual(fixture.lastReport?.reason, report.reason)
        XCTAssertEqual(fixture.lastReport?.postID, 42)
    }

    func testModerationListSurvivesRestartWithoutExpiry() async throws {
        let fixture = ModerationFixture()
        let suite = "ModerationPersistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let store = makeSafetyStore(defaults: defaults, fixture: fixture)
        fixture.postIDs = [42]
        await store.refresh(canisterID:TaggrRuntimeConfig.productionCanisterId)
        let restored = TaggrSafetyStore(defaults:defaults)
        XCTAssertTrue(restored.isPostHidden(42,canisterID:TaggrRuntimeConfig.productionCanisterId))
    }

    func testModerationReportInteractiveUI() async throws {
        let fixture = ModerationFixture()
        guard ProcessInfo.processInfo.arguments.contains("--moderation-ui-review") else {
            throw XCTSkip("Run with --moderation-ui-review and idb for report UI verification.")
        }
        let state = makeCoordinator(safety:makeSafetyStore(fixture: fixture))
        fixture.statusCode = 503
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene:scene)
        window.rootViewController = UIHostingController(rootView:ContentReportSheet(userID:7,postID:42,isPresented:.constant(true)).environment(state))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        var firstReport: TaggrContentReport?
        for _ in 0..<120 {
            if fixture.reportAttempts == 1 {
                firstReport = fixture.lastReport
                fixture.statusCode = 201
            }
            if fixture.reportAttempts >= 2 {
                XCTAssertFalse(firstReport?.reason.isEmpty ?? true)
                XCTAssertEqual(fixture.lastReport?.reason, firstReport?.reason)
                XCTAssertEqual(fixture.lastReport?.id, firstReport?.id)
                try await Task.sleep(for:.seconds(8))
                return
            }
            try await Task.sleep(for:.seconds(1))
        }
        XCTFail("Use idb to send a report, acknowledge the failure, and retry.")
    }

    func testSafetyConsentImmediatelyAllowsContentWithoutService() async {
        let state = makeCoordinator(safety: makeSafetyStore())
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
        let state = makeCoordinator(safety: makeSafetyStore())
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
    func testMarkdownMatchesSharedWebFixtures() throws {
        struct Fixture: Decodable {
            struct Markdown: Decodable {
                let action: String; let text: String; let start: Int; let length: Int
                let url: String?; let expected: String; let cursor: Int; let selectedLength: Int
            }
            struct Image: Decodable {
                let text: String; let start: Int; let markers: [String]; let expected: String
            }
            let markdown: [Markdown]; let images: [Image]
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "composer-web-parity", withExtension: "json", subdirectory: "Fixtures"))
        let fixtures = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let actions: [String: ComposeMarkdownAction] = ["bold": .bold, "italic": .italic, "list": .list, "quote": .quote, "link": .link]
        for item in fixtures.markdown {
            let edit = ComposeMarkdownEdit.applying(try XCTUnwrap(actions[item.action]), to: item.text, selection: NSRange(location: item.start, length: item.length), url: item.url ?? "")
            XCTAssertEqual(edit.text, item.expected, item.action)
            XCTAssertEqual(edit.selection, NSRange(location: item.cursor, length: item.selectedLength), item.action)
        }
        for item in fixtures.images {
            let edit = PostDraftDocument.insertingImages(item.markers, in: item.text, at: item.start)
            XCTAssertEqual(edit.text, item.expected)
            XCTAssertEqual(edit.cursor, item.expected.utf16.count - (item.text.utf16.count - item.start))
        }
    }

    func testQuoteNewlineUsesPlainTextInput() async throws {
        let fixture = try HostedComposer(app: makeCoordinator(), text: "> 日本語😀")
        defer { fixture.close() }
        try await fixture.settle()
        let input = try fixture.input()
        input.selectedRange = NSRange(location: input.text.utf16.count, length: 0)
        input.insertText("\n")
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "> 日本語😀\n")
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
        @Published var images: [TaggrDraftImage] = []
        @Published var focused: Int? = 0
        @Published var imageTarget: Int?
        @Published var enabled = true
        @Published var visible = true
        @Published var revision = 0
        @Published var showsToolbar = false
        var pastedImageProviders: [NSItemProvider] = []
        let app: TaggrAppCoordinator
        init(app: TaggrAppCoordinator) { self.app = app }
        var changed: ((String) -> Void)?
        let documentID = UUID()
        let quotes = ComposeEditingController()
    }

    private struct ComposerHarness: View {
        @ObservedObject var state: ComposerState
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if state.visible {
                        ComposePostDocumentEditor(
                            text: $state.text, draftImages: $state.images, existingImages: [:],
                            placeholder: "Write a post \(state.revision)", documentID: state.documentID,
                            focusedTextSegmentID: $state.focused,
                            imageInsertionSegmentID: $state.imageTarget,
                            removeImage: { _, _ in }, moveImage: { _, _ in },
                            pasteImages: { state.pastedImageProviders = $0 }
                        )
                        .disabled(!state.enabled)
                        if state.showsToolbar {
                            ComposePostAttachmentBar(text: $state.text, selectedPhotos: .constant([]), youtubeTarget: nil, insertYouTubeURL: { _ in }, isSubmitting: false, isImagePickerDisabled: false)
                                .environment(state.app)
                        }
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
        let state: ComposerState
        let host: UIHostingController<ComposerHarness>
        let window: UIWindow
        let previousWindow: UIWindow?

        init(app: TaggrAppCoordinator, text: String = "") throws {
            state = ComposerState(app: app)
            state.text = text
            host = UIHostingController(rootView: ComposerHarness(state: state))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            previousWindow = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = host
            window.makeKeyAndVisible()
        }

        func close() {
            window.endEditing(true)
            window.rootViewController = nil
            window.isHidden = true
            previousWindow?.makeKey()
        }

        private var awaitingInitialPresentation = true

        func settle() async throws {
            // Let the initial keyboard presentation finish before driving UITextInput.
            try await Task.sleep(for: .milliseconds(awaitingInitialPresentation ? 600 : 100))
            awaitingInitialPresentation = false
            window.setNeedsLayout()
            window.layoutIfNeeded()
            host.view.setNeedsLayout()
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
        let fixture = try HostedComposer(app: makeCoordinator())
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

    func testProgrammaticallyLoadedComposerTextUsesThemeColor() async throws {
        let fixture = try HostedComposer(app: makeCoordinator())
        defer { fixture.close() }
        try await fixture.settle()

        fixture.state.text = "Existing post body"
        try await fixture.settle()

        let input = try fixture.input()
        let color = try XCTUnwrap(
            input.textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        )
        let font = try XCTUnwrap(
            input.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        )
        XCTAssertEqual(color, UIColor(TaggrTheme.text))
        XCTAssertEqual(font.pointSize, UIFont.preferredFont(forTextStyle: .title3).pointSize)
    }

    func testComposerJapaneseCompositionSurvivesParentUpdates() async throws {
        let fixture = try HostedComposer(app: makeCoordinator())
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
        let fixture = try HostedComposer(app: makeCoordinator(), text: "abc")
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
        let fixture = try HostedComposer(app: makeCoordinator(), text: "before\n![](/blob/test-image)\nafter")
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
        let fixture = try HostedComposer(app: makeCoordinator(), text: "下書き😀")
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
        let fixture = try HostedComposer(app: makeCoordinator(), text: "日本語😀/text")
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

    func testComposerImagePasteTakesPriorityAndPreservesProviderOrder() async throws {
        let fixture = try HostedComposer(app: makeCoordinator(), text: "日本語😀/text")
        defer { fixture.close() }
        try await fixture.settle()
        let input = try fixture.input()
        input.selectedRange = NSRange(location: 4, length: 0)

        let text = NSItemProvider(object: "ignored" as NSString)
        let firstImage = NSItemProvider(object: UIImage(systemName: "photo")!)
        firstImage.registerObject("ignored alternative" as NSString, visibility: .all)
        let secondImage = NSItemProvider(object: UIImage(systemName: "photo.fill")!)

        input.paste(itemProviders: [text, firstImage, secondImage])

        XCTAssertEqual(fixture.state.text, "日本語😀/text")
        XCTAssertEqual(fixture.state.pastedImageProviders.count, 2)
        XCTAssertTrue(fixture.state.pastedImageProviders[0] === firstImage)
        XCTAssertTrue(fixture.state.pastedImageProviders[1] === secondImage)
    }

    func testComposerFormatsSelection() async throws {
        let fixture = try HostedComposer(app: makeCoordinator(), text: "日本語😀")
        defer { fixture.close() }
        try await fixture.settle()
        let input = try fixture.input()
        input.selectedRange = NSRange(location: 0, length: 3)
        fixture.state.quotes.perform(.bold)
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "**日本語**😀")
        XCTAssertEqual(input.selectedRange, NSRange(location: 2, length: 3))

    }

    func testLinkSnapshotCancellationAndStaleDocument() async throws {
        let fixture = try HostedComposer(app: makeCoordinator(), text: "before TAGGR after")
        defer { fixture.close() }
        try await fixture.settle()
        let input = try fixture.input()
        input.selectedRange = NSRange(location: 7, length: 5)
        let controller = fixture.state.quotes
        let cancelled = try XCTUnwrap(controller.capture(suspend: true))
        controller.restore(cancelled)
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "before TAGGR after")
        XCTAssertEqual(input.selectedRange, NSRange(location: 7, length: 5))
        XCTAssertTrue(input.isFirstResponder)
        let snapshot = try XCTUnwrap(controller.capture(suspend: true))
        controller.perform(.link, snapshot: snapshot, url: "https://example.com")
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "before [TAGGR](https://example.com) after")
        controller.perform(.link, snapshot: snapshot, url: "duplicate")
        XCTAssertEqual(fixture.state.text, "before [TAGGR](https://example.com) after")
        let stale = try XCTUnwrap(controller.capture(suspend: true))
        controller.disconnect()
        controller.perform(.link, snapshot: stale, url: "stale")
        XCTAssertEqual(fixture.state.text, "before [TAGGR](https://example.com) after")
    }

    func testLinkInsertionCancellationAndEmptySubmission() async throws {
        let fixture = try HostedComposer(app: makeCoordinator(), text: "before TAGGR after")
        defer { fixture.close() }
        try await fixture.settle()
        let input = try fixture.input()
        input.selectedRange = NSRange(location: 7, length: 5)
        let controller = fixture.state.quotes
        let insertion = try XCTUnwrap(controller.capture(suspend: true))
        controller.perform(.link, snapshot: insertion, url: "https://example.com")
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "before [TAGGR](https://example.com) after")
        XCTAssertTrue(input.isFirstResponder)

        let cancellation = try XCTUnwrap(controller.capture(suspend: true))
        controller.restore(cancellation)
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "before [TAGGR](https://example.com) after")
        XCTAssertEqual(input.selectedRange, cancellation.selection)
        XCTAssertTrue(input.isFirstResponder)

        let emptySubmission = try XCTUnwrap(controller.capture(suspend: true))
        controller.perform(.link, snapshot: emptySubmission, url: "")
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "before [TAGGR](https://example.com) after")
        XCTAssertEqual(input.selectedRange, emptySubmission.selection)
        XCTAssertTrue(input.isFirstResponder)
    }

    func testFormattingCommitsMarkedTextWithoutLosingCharacters() async throws {
        let fixture = try HostedComposer(app: makeCoordinator(), text: "abc")
        defer { fixture.close() }
        try await fixture.settle()
        let input = try fixture.input()
        XCTAssertTrue(input.isFirstResponder)
        input.selectedRange = NSRange(location: 3, length: 0)
        input.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(input.markedTextRange)
        fixture.state.quotes.perform(.bold)
        try await fixture.settle()
        XCTAssertNil(input.markedTextRange)
        XCTAssertEqual(input.text, "abc日本****")
        XCTAssertEqual(fixture.state.text, "abc日本****")
        XCTAssertEqual(input.selectedRange, NSRange(location: 7, length: 0))
    }

    func testImageInsertionUndoRedoAndStaleResult() async throws {
        let fixture = try HostedComposer(app: makeCoordinator(), text: "abcd")
        defer { fixture.close() }
        try await fixture.settle()
        let input = try fixture.input()
        input.selectedRange = NSRange(location: 2, length: 2)
        let controller = fixture.state.quotes
        let snapshot = try XCTUnwrap(controller.capture(suspend: true))
        fixture.state.enabled = false
        try await fixture.settle()
        let inserted = PostDraftDocument.insertingImages(["![a](/blob/a)"], in: snapshot.text, at: snapshot.selection.location)
        let image = TaggrDraftImage(id: "a", data: Data([1]), width: 1, height: 1)
        let undo = try XCTUnwrap(input.undoManager)
        controller.apply(ComposeMarkdownEdit(text: inserted.text, selection: NSRange(location: inserted.cursor, length: 0)), replacing: snapshot, images: [image])
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "ab\n\n![a](/blob/a)\ncd")
        fixture.state.enabled = true
        try await fixture.settle()
        let tail = try XCTUnwrap(fixture.inputs.last)
        XCTAssertTrue(tail.isFirstResponder)
        XCTAssertEqual(tail.selectedRange, NSRange(location: 1, length: 0))
        undo.undo()
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "abcd")
        XCTAssertEqual(fixture.state.images, [])
        undo.redo()
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, inserted.text)
        XCTAssertEqual(fixture.state.images, [image])
        controller.apply(ComposeMarkdownEdit(text: "stale", selection: NSRange(location: 0, length: 0)), replacing: snapshot)
        XCTAssertEqual(fixture.state.text, inserted.text)
    }

    func testPastingBlobMarkdownDoesNotDuplicateSegments() async throws {
        for initial in ["", "前![old](/blob/old)後"] {
            let fixture = try HostedComposer(app: makeCoordinator(), text: initial)
            defer { fixture.close() }
            try await fixture.settle()
            for useTail in [false, true] {
                let input = try XCTUnwrap(useTail ? fixture.inputs.last : fixture.inputs.first)
                input.becomeFirstResponder()
                input.selectedRange = NSRange(location: 0, length: 0)
                let before = fixture.state.text
                let pasted = "日本😀![a](/blob/a)中![b](/blob/b)末尾"
                let segment = useTail ? PostDraftDocument.segments(in: before).last!.id : 0
                let expected = PostDraftDocument.replacingText(in: before, segmentID: segment, with: pasted + input.text)
                input.insertText(pasted)
                try await fixture.settle()
                XCTAssertEqual(fixture.state.text, expected)
                fixture.state.quotes.undoManager.undo()
                try await fixture.settle()
                XCTAssertEqual(fixture.state.text, before)
                fixture.state.quotes.undoManager.redo()
                try await fixture.settle()
                XCTAssertEqual(fixture.state.text, expected)
            }
        }
    }

    func testMixedImageAndURLHistoryRestoresEveryState() async throws {
        let fixture = try HostedComposer(app: makeCoordinator(), text: "日本😀")
        defer { fixture.close() }
        try await fixture.settle()
        let controller = fixture.state.quotes
        let input = try fixture.input()
        input.selectedRange = NSRange(location: 4, length: 0)
        var states: [ComposeEditingController.Snapshot] = [try XCTUnwrap(controller.capture())]
        input.insertText("追記")
        try await fixture.settle()
        states.append(try XCTUnwrap(controller.capture()))
        controller.perform(.bold)
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "日本😀追記****")
        states.append(try XCTUnwrap(controller.capture()))
        let images = [TaggrDraftImage(id: "a", data: Data([1]), width: 1, height: 1), TaggrDraftImage(id: "b", data: Data([2]), width: 1, height: 1)]
        let snapshot = try XCTUnwrap(controller.capture())
        let inserted = PostDraftDocument.insertingImages(images.map(\.markdown), in: snapshot.text, at: snapshot.selection.location)
        controller.apply(ComposeMarkdownEdit(text: inserted.text, selection: NSRange(location: inserted.cursor, length: 0)), replacing: snapshot, images: images)
        try await fixture.settle()
        states.append(try XCTUnwrap(controller.capture()))
        controller.moveImage(occurrence: 0, before: nil)
        try await fixture.settle()
        states.append(try XCTUnwrap(controller.capture()))
        controller.moveImage(occurrence: 1, afterTextSegmentID: 0)
        try await fixture.settle()
        states.append(try XCTUnwrap(controller.capture()))
        controller.removeImage(occurrence: 0)
        try await fixture.settle()
        states.append(try XCTUnwrap(controller.capture()))
        XCTAssertTrue(controller.insertExternalURL(URL(string: "https://youtu.be/example")!))
        try await fixture.settle()
        states.append(try XCTUnwrap(controller.capture()))
        for expected in states.dropLast().reversed() {
            controller.undoManager.undo()
            try await fixture.settle()
            XCTAssertEqual(fixture.state.text, expected.text)
            XCTAssertEqual(fixture.state.images, expected.images)
            XCTAssertEqual(controller.capture()?.selection, expected.selection)
        }
        for expected in states.dropFirst() {
            controller.undoManager.redo()
            try await fixture.settle()
            XCTAssertEqual(fixture.state.text, expected.text)
            XCTAssertEqual(fixture.state.images, expected.images)
            XCTAssertEqual(controller.capture()?.selection, expected.selection)
        }
        controller.undoManager.undo()
        try await fixture.settle()
        controller.perform(.italic)
        try await fixture.settle()
        XCTAssertFalse(controller.undoManager.canRedo)
    }

    func testAutomaticURLInsertionDoesNotFocusOrDuplicate() async throws {
        let fixture = try HostedComposer(app: makeCoordinator(), text: "本文")
        defer { fixture.close() }
        try await fixture.settle()
        fixture.state.focused = nil
        try await fixture.settle()
        let controller = fixture.state.quotes
        let url = URL(string: "https://youtu.be/example")!
        XCTAssertTrue(controller.insertExternalURL(url))
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "本文\n\nhttps://youtu.be/example")
        XCTAssertFalse(try fixture.input().isFirstResponder)
        XCTAssertTrue(controller.insertExternalURL(url))
        try await fixture.settle()
        controller.undoManager.undo()
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "本文")
        controller.undoManager.redo()
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "本文\n\nhttps://youtu.be/example")
    }

    func testImageHistoryPersistsRestoredDataAndResetsAcrossDrafts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PostDraftStore(rootURL: root)
        let namespace = PostDraftNamespace(canisterID: "test", userID: 7)
        let image = TaggrDraftImage(id: "same", data: Data([1, 2, 3]), width: 1, height: 1)
        do {
            let context = PostDraftContext.newPost
            let draft = PostDraftSession(context: context, initialText: "", initialRealm: "")
            await draft.load(store: store, namespace: namespace)
            let controller = ComposeEditingController()
            controller.connect(documentID: UUID(), text: Binding(get: { draft.text }, set: { draft.text = $0 }), images: Binding(get: { draft.images }, set: { draft.restoreEditorImages($0) }), focus: .constant(nil))
            let snapshot = try XCTUnwrap(controller.capture())
            let text = "前" + image.markdown + "中" + image.markdown + "後"
            controller.apply(ComposeMarkdownEdit(text: text, selection: NSRange(location: 0, length: 0)), replacing: snapshot, images: [image])
            try await Task.sleep(for: .milliseconds(50))
            controller.removeImage(occurrence: 0)
            XCTAssertEqual(draft.images, [image])
            try await Task.sleep(for: .milliseconds(50))
            controller.removeImage(occurrence: 0)
            XCTAssertEqual(draft.images, [])
            await draft.flush()
            try await Task.sleep(for: .milliseconds(50))
            controller.undoManager.undo()
            XCTAssertEqual(draft.images, [image])
            await draft.flush()
            let restored = await store.load(namespace: namespace, context: context)
            XCTAssertEqual(restored.text, draft.text)
            XCTAssertEqual(restored.images, [image])
            controller.disconnect()
            controller.connect(documentID: UUID(), text: .constant("別の下書き"), images: .constant([]), focus: .constant(nil))
            XCTAssertFalse(controller.undoManager.canUndo)
            XCTAssertFalse(controller.undoManager.canRedo)
        }
    }

    func testImageSegmentSelectionMapsToDocument() async throws {
        let fixture = try HostedComposer(app: makeCoordinator(), text: "before\n![image](/blob/photo)\nafter😀")
        defer { fixture.close() }
        try await fixture.settle()
        let input = try XCTUnwrap(fixture.inputs.last)
        input.becomeFirstResponder()
        input.selectedRange = NSRange(location: 1, length: 5)
        fixture.state.quotes.perform(.italic)
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "before\n![image](/blob/photo)\n_after_😀")
        XCTAssertEqual(input.selectedRange, NSRange(location: 2, length: 5))
    }

    func testComposerRestoredDraftEditsPersistInEachContext() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ComposerDraft-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PostDraftStore(rootURL: root)
        let namespace = PostDraftNamespace(canisterID: "test", userID: 7)
        do {
            let context = PostDraftContext.newPost
            let session = PostDraftSession(context: context, initialText: "", initialRealm: "")
            await session.load(store: store, namespace: namespace)
            session.text = "**保存済み**😀"
            await session.flush()
            let restored = PostDraftSession(context: context, initialText: "", initialRealm: "")
            await restored.load(store: store, namespace: namespace)
            let fixture = try HostedComposer(app: makeCoordinator(), text: restored.text)
            fixture.state.changed = { restored.text = $0 }
            defer { fixture.close() }
            try await fixture.settle()
            let input = try fixture.input()
            XCTAssertEqual(input.text, "**保存済み**😀")
            input.selectedRange = NSRange(location: (input.text as NSString).length, length: 0)
            input.insertText("追記")
            try await fixture.settle()
            input.selectedRange = NSRange(location: 2, length: 4)
            fixture.state.quotes.perform(.italic)
            try await fixture.settle()
            await restored.flush()
            let saved = await store.load(namespace: namespace, context: context)
            XCTAssertEqual(saved.text, "**_保存済み_**😀追記")
        }
    }

    func testComposerResizesAndSupportsLargeText() async throws {
        let fixture = try HostedComposer(app: makeCoordinator(), text: String(repeating: "日本語の折り返し ", count: 12))
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
        let fixture = try HostedComposer(app: makeCoordinator(), text: "日本語😀")
        defer { fixture.close() }
        try await fixture.settle()
        let input = try fixture.input()
        input.selectedRange = NSRange(location: 0, length: 0)
        fixture.state.quotes.quote()
        try await fixture.settle()
        XCTAssertEqual(fixture.state.text, "> 日本語😀")
        XCTAssertEqual(input.text, fixture.state.text)
        XCTAssertTrue(input.isFirstResponder)
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

@MainActor
private final class MarkdownAppearanceFixture: ObservableObject {
    @Published var large = false
    @Published var blue = false
    @Published var text = "> A [link](https://example.com)"
}

private struct MarkdownAppearanceView: View {
    @ObservedObject var model: MarkdownAppearanceFixture
    var body: some View {
        TaggrPostBodyView(text: model.text, maximumLines: 10,
                          textColor: Color(uiColor: model.blue ? .blue : .red))
            .environment(\.dynamicTypeSize, model.large ? .accessibility3 : .medium)
    }
}

extension TaggrTests {
    func testPostBodyUpdatesDynamicTypeColorAndTextWithoutLosingLinks() async throws {
        let model = MarkdownAppearanceFixture()
        let host = UIHostingController(rootView: MarkdownAppearanceView(model: model))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.rootViewController = nil
            window.isHidden = true
            previous?.makeKey()
        }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
        }
        func findText(_ view: UIView) -> UITextView? {
            if let text = view as? UITextView { return text }
            return view.subviews.compactMap(findText).first
        }
        try await settle()
        let textView = try XCTUnwrap(findText(host.view))
        let initialFont = try XCTUnwrap(textView.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(textView.textContainer.maximumNumberOfLines, 10)
        XCTAssertEqual(textView.attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, .red)
        model.large = true
        model.blue = true
        try await settle()
        let enlargedFont = try XCTUnwrap(textView.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertGreaterThan(enlargedFont.pointSize, initialFont.pointSize)
        XCTAssertEqual(textView.attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, .blue)
        model.text = "> Updated [link](https://example.com)"
        try await settle()
        XCTAssertTrue(textView.text.contains("Updated"))
        let offset = (textView.text as NSString).range(of: "link").location
        XCTAssertEqual(TaggrInteractiveMarkdownText.link(atUTF16Offset: offset, in: textView.attributedText), URL(string: "https://example.com"))
        XCTAssertNotNil(textView.attributedText.attribute(TaggrInteractiveMarkdownText.quoteDepthAttribute, at: 0, effectiveRange: nil))
    }
}
