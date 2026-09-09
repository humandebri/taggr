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

    func testSafetyNotificationPreservesSystemDetailsWithoutFollowerBio() {
        let reward = "You received `0.12` ICP as rewards and `0.03` ICP as revenue! 💸"
        XCTAssertEqual(TaggrNotification.generic(reward).safetyMessage, reward)
        let mint = "TAGGR minted `12.5` $TAGGR tokens for you! 💎"
        XCTAssertEqual(TaggrNotification.generic(mint).safetyMessage, mint)
        XCTAssertEqual(TaggrNotification.conditional(message: "untrusted", predicate: .proposal(42)).safetyMessage,
                       "Governance proposal on post #42 needs attention.")
        XCTAssertEqual(TaggrNotification.watchedPostEntries(postId: 7, entries: [8, 9]).safetyMessage,
                       "2 new thread update(s) on watched post #7.")
        XCTAssertEqual(TaggrNotification.generic("@name followed you (#NSFW bio, `2` followers)").safetyMessage,
                       "Someone followed you.")
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

    func testPostBodyMaximumHeightUsesLineCountAndAllowsDetailExpansion() {
        let feedHeight = TaggrPostBodyView.maximumHeight(for: 10)
        let compactHeight = TaggrPostBodyView.maximumHeight(for: 4)

        XCTAssertNotNil(feedHeight)
        XCTAssertNotNil(compactHeight)
        XCTAssertGreaterThan(feedHeight ?? 0, compactHeight ?? 0)
        XCTAssertNil(TaggrPostBodyView.maximumHeight(for: nil))
        XCTAssertNil(TaggrPostBodyView.maximumHeight(for: 10, containsYouTube: true))
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
