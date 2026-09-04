import XCTest
@testable import TAGGR

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
        XCTAssertTrue(TaggrPostContentRestriction.nsfw.isRevealable)
    }
}
