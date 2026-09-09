import XCTest
import CryptoKit
@testable import TAGGR

final class SafetyURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var lastReport: TaggrSafetyReport?
    nonisolated(unsafe) static var failRequests = false
    nonisolated(unsafe) static var deniedPosts: Set<Int> = []
    nonisolated(unsafe) static var deniedUsers: Set<Int> = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        if Self.failRequests { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        do {
            let data: Data
            if request.httpMethod == "POST" {
                let body = TaggrTests.requestBody(from: request) ?? Data()
                let report = try JSONDecoder().decode(TaggrSafetyReport.self, from: body)
                Self.lastReport = report
                data = try JSONSerialization.data(withJSONObject: ["id": report.id, "status": "received"])
            } else {
                let canister = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
                let now = Date().timeIntervalSince1970
                data = try JSONEncoder().encode(TaggrSafetyPolicy(canisterID: canister, version: 1, issuedAt: now, expiresAt: now + 900, postIDs: Self.deniedPosts, userIDs: Self.deniedUsers))
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

extension TaggrTests {
    func makeSafetyStore() -> TaggrSafetyStore {
        let suite = "SafetyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        SafetyURLProtocolStub.failRequests = false
        SafetyURLProtocolStub.deniedPosts = []
        SafetyURLProtocolStub.deniedUsers = []
        SafetyURLProtocolStub.lastReport = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SafetyURLProtocolStub.self]
        return TaggrSafetyStore(defaults: defaults, session: URLSession(configuration: configuration), baseURL: URL(string: "https://safety.example.test")!)
    }

    func testSafetyConsentPolicyAndBlocksAreIndependent() async throws {
        let state = TaggrAppCoordinator(safety: makeSafetyStore())
        let post = samplePost(body: "safe", files: [:])
        XCTAssertFalse(state.canAccessUGC)
        await state.safety.refresh(canisterID: state.runtimeConfig.canisterId)
        XCTAssertFalse(state.canAccessUGC)
        state.safety.accept(scope: state.safetyScope)
        XCTAssertTrue(state.canDisplayPost(post))
        let sensitive = samplePost(body: "#NsFw", files: [:], hiddenFor: [7])
        XCTAssertFalse(state.canDisplayPost(sensitive))
        XCTAssertEqual(sensitive.contentRestriction(viewerID: 7), .nsfw)
        await state.toggleBlock(userId: post.user)
        XCTAssertTrue(state.isUserBlocked(post.user))
        XCTAssertFalse(state.canDisplayPost(post))
        XCTAssertEqual(SafetyURLProtocolStub.lastReport?.kind, "block")
        await state.toggleBlock(userId: post.user)
        XCTAssertTrue(state.canDisplayPost(post))
        SafetyURLProtocolStub.deniedPosts = [post.id]
        await state.safety.refresh(canisterID: state.runtimeConfig.canisterId)
        XCTAssertFalse(state.canDisplayPost(post))
    }

    func testSafetyOutageAndPolicyValidity() async throws {
        let state = TaggrAppCoordinator(safety: makeSafetyStore())
        state.safety.accept(scope: state.safetyScope)
        SafetyURLProtocolStub.failRequests = true
        await state.safety.refresh(canisterID: state.runtimeConfig.canisterId)
        XCTAssertFalse(state.canAccessUGC)
        do { try await state.requireSafePublishing(); XCTFail("Must fail closed") } catch {}
        SafetyURLProtocolStub.failRequests = false
        await state.safety.refresh(canisterID: state.runtimeConfig.canisterId)
        XCTAssertTrue(state.canAccessUGC)
        SafetyURLProtocolStub.failRequests = true
        await state.safety.refresh(canisterID: state.runtimeConfig.canisterId)
        XCTAssertTrue(state.canAccessUGC, "Unexpired cached policy remains usable")
        let now = Date().timeIntervalSince1970
        let policy = TaggrSafetyPolicy(canisterID: "test", version: 1, issuedAt: now, expiresAt: now + 900, postIDs: [], userIDs: [])
        XCTAssertFalse(policy.isValid(at: Date(timeIntervalSince1970: now + 900)))
        XCTAssertFalse(policy.isValid(at: Date(timeIntervalSince1970: now - 61)))
    }

    func testSafetyPendingBlockAndAgreementSurviveRestart() async {
        let suite = "SafetyPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TaggrSafetyStore(defaults: defaults)
        store.accept(scope: "canister:alice")
        store.setBlocked(true, userID: 7, scope: "canister:alice", canisterID: "canister")
        let restored = TaggrSafetyStore(defaults: defaults)
        XCTAssertTrue(restored.accepted(scope: "canister:alice"))
        XCTAssertFalse(restored.accepted(scope: "canister:bob"))
        XCTAssertTrue(restored.isBlocked(userID: 7, scope: "canister:alice", remote: []))
        XCTAssertFalse(restored.isBlocked(userID: 7, scope: "canister:bob", remote: []))
    }

    func testSafetyRejectsNSFWAndSuspendedPublishing() async throws {
        let state = TaggrAppCoordinator(safety: makeSafetyStore())
        state.safety.accept(scope: state.safetyScope)
        do { try await state.requireSafePublishing(text: "#NSFW"); XCTFail("NSFW must not be published") }
        catch { XCTAssertEqual(error.localizedDescription, TaggrSafetyError.nsfw.localizedDescription) }
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        SafetyURLProtocolStub.deniedUsers = [7]
        do { try await state.requireSafePublishing(text: "safe text"); XCTFail("Suspended users must not publish") }
        catch { XCTAssertEqual(error.localizedDescription, TaggrSafetyError.suspended.localizedDescription) }
        XCTAssertTrue(state.safetySuspended)
    }

    func testSafetyBlockRemainsEffectiveWhenNotificationFails() async {
        let state = TaggrAppCoordinator(safety: makeSafetyStore())
        SafetyURLProtocolStub.failRequests = true
        await state.toggleBlock(userId: 7)
        XCTAssertTrue(state.isUserBlocked(7))
        XCTAssertNil(SafetyURLProtocolStub.lastReport)
        SafetyURLProtocolStub.failRequests = false
        await state.safety.flushBlockNotifications()
        XCTAssertEqual(SafetyURLProtocolStub.lastReport?.userID, 7)
        XCTAssertEqual(SafetyURLProtocolStub.lastReport?.kind, "block")
        XCTAssertTrue(state.isUserBlocked(7))
    }

    func testSafetyRejectsRestrictedRepostBeforeCanisterWrite() async throws {
        var calls = 0
        let api = makeStubbedAPI { request in
            calls += 1
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let state = TaggrAppCoordinator(safety: makeSafetyStore(), api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        state.safety.accept(scope: state.safetyScope)
        SafetyURLProtocolStub.deniedPosts = [42]
        await state.repost(postId: 42, text: "boost", realm: nil)
        XCTAssertEqual(calls, 0)
        XCTAssertNotNil(state.errorMessage)
    }

    func testSafetyUnknownUserFailsClosedWithoutBlockingConfirmedNewUser() async throws {
        let state = TaggrAppCoordinator(safety: makeSafetyStore())
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.safety.accept(scope: state.safetyScope)
        await state.safety.refresh(canisterID: state.runtimeConfig.canisterId)
        XCTAssertTrue(state.safetyUserUnconfirmed)
        XCTAssertFalse(state.canAccessUGC)
        do { try await state.requireSafePublishing(); XCTFail("Unconfirmed account must not publish") }
        catch { XCTAssertEqual(error.localizedDescription, TaggrSafetyError.unavailable.localizedDescription) }
        state.safetyConfirmedUserScope = state.safetyScope
        XCTAssertTrue(state.canAccessUGC, "A confirmed unregistered identity can reach account creation")
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        SafetyURLProtocolStub.deniedUsers = [7]
        await state.safety.refresh(canisterID: state.runtimeConfig.canisterId)
        XCTAssertFalse(state.canAccessUGC)
        XCTAssertTrue(state.safetySuspended)
        state.currentUser = nil
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        XCTAssertTrue(state.safetyUserUnconfirmed, "Confirmation cannot transfer to another identity")
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
