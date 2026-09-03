import XCTest
import AuthenticationServices
import CryptoKit
import UIKit
import ICNativeClient
@testable import TAGGR

extension TaggrTests {
    func testPostCreditCostMatchesBodySizeAndTags() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data("3".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.cache = TaggrBackendCache(
            stats: nil,
            config: try JSONDecoder.taggr.decode(TaggrConfig.self, from: Data(#"{"post_cost":2,"max_tag_length":30}"#.utf8))
        )

        let cost = await state.postCreditCost(for: "hello #TAG $icp #tag")

        XCTAssertEqual(cost, 5)
        XCTAssertEqual(calls.map(\.method), ["tags_cost"])
        XCTAssertEqual(calls.first?.arg, try TaggrCandid.jsonArguments([["tag", "icp"]]))
        XCTAssertEqual(TaggrPostCreditCost.estimate(body: String(repeating: "a", count: 1024), baseCost: 2, tagCost: 0), 4)
        XCTAssertEqual(TaggrPostCreditCost.tags(in: "read #tag.next", maxLength: 30), ["tag"])
    }

    func testEditPostCreditCostIncludesBodyPatchesTagsAndPoll() {
        let poll: JSONValue = .object([
            "Poll": .object([
                "options": .array([.string("yes")]),
                "votes": .object([:]),
                "voters": .array([]),
                "deadline": .number(0),
            ]),
        ])
        let post = samplePost(
            body: "old #tag",
            files: [:],
            extensionValue: poll,
            patches: [[.number(1), .string("abc")]]
        )

        XCTAssertEqual(
            TaggrPostCreditCost.estimateEdit(
                body: post.body,
                post: post,
                baseCost: 2,
                tagCost: 4,
                pollCost: 3
            ),
            9
        )

        let editedBody = String(repeating: "é", count: 510)
        let newPatchBytes = TaggrEditPatch.fullReplacement(from: editedBody, to: post.body).utf8.count
        let expected = 2 * ((editedBody.utf8.count + 3 + newPatchBytes) / 1024 + 1) + 4 + 3
        XCTAssertEqual(
            TaggrPostCreditCost.estimateEdit(body: editedBody, post: post, baseCost: 2, tagCost: 4, pollCost: 3),
            expected
        )
        XCTAssertNil(TaggrPostCreditCost.estimateEdit(body: post.body, post: post, baseCost: 2, tagCost: 4, pollCost: nil))
    }

    func testTokenAmountFormatsConfiguredDecimals() {
        XCTAssertEqual(TaggrTokenAmount.format(12_345, decimals: 2), "123.45")
        XCTAssertEqual(TaggrTokenAmount.format(12_300, decimals: 2), "123")
        XCTAssertEqual(TaggrTokenAmount.format(12_340, decimals: 2), "123.4")
        XCTAssertEqual(TaggrTokenAmount.format(123, decimals: nil), "123")
    }

    @MainActor
    func testReportSendsUserIdAndReason() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data("null".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())

        await state.report(userId: 7, reason: "misbehavior")

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.map(\.method), ["report"])
        XCTAssertEqual(calls.first?.arg, try TaggrCandid.jsonArguments([7, "misbehavior"]))
    }

    func testUserDecodesEngagementState() throws {
        let data = Data(
            #"""
            {
              "id": 7,
              "name": "alice",
              "about": "hi",
              "principal": "aaaaa-aa",
              "realms": ["DEV"],
              "followees": [1],
              "followers": [2],
              "blacklist": [3],
              "bookmarks": [42],
              "pinned_posts": [43],
              "settings": {"tap_and_hold": "350"},
              "controlled_realms": ["DEV"],
              "bucket": "aaaaa-aa",
              "num_posts": 9,
              "active_weeks": 4,
              "deactivated": false,
              "mode": "Mining"
            }
            """#.utf8
        )
        let user = try JSONDecoder.taggr.decode(TaggrUser.self, from: data)
        XCTAssertEqual(user.bookmarks, [42])
        XCTAssertEqual(user.pinnedPosts, [43])
        XCTAssertEqual(user.settings["tap_and_hold"], "350")
        XCTAssertEqual(user.controlledRealms, ["DEV"])
        XCTAssertEqual(user.bucket, "aaaaa-aa")
        XCTAssertEqual(user.numPosts, 9)
        XCTAssertEqual(user.activeWeeks, 4)
        XCTAssertEqual(user.deactivated, false)
    }

    func testUserDecodesNotificationVariants() throws {
        let data = Data(
            #"""
            {
              "id": 7,
              "name": "alice",
              "about": "",
              "principal": null,
              "realms": [],
              "followees": [],
              "followers": [],
              "blacklist": [],
              "settings": {},
              "controlled_realms": [],
              "notifications": {
                "1": [{"Generic": "System message"}, false],
                "2": [{"NewPost": ["New post", 42]}, false],
                "3": [{"Conditional": ["Vote now", {"Proposal": 43}]}, true],
                "4": [{"WatchedPostEntries": [44, [45, 46]]}, false]
              },
              "mode": null
            }
            """#.utf8
        )
        let user = try JSONDecoder.taggr.decode(TaggrUser.self, from: data)
        XCTAssertEqual(user.notifications[1], TaggrNotificationEntry(notification: .generic("System message"), read: false))
        XCTAssertEqual(user.notifications[2]?.notification.postId, 42)
        XCTAssertEqual(user.notifications[3], TaggrNotificationEntry(notification: .conditional(message: "Vote now", predicate: .proposal(43)), read: true))
        XCTAssertEqual(user.notifications[4]?.notification.watchedEntryIds, [45, 46])
    }

    func testReactionIconMatchesWebMapping() {
        XCTAssertEqual(TaggrReactionIcon.emoji(for: 1), "❌")
        XCTAssertEqual(TaggrReactionIcon.emoji(for: 50), "🔥")
        XCTAssertEqual(TaggrReactionIcon.emoji(for: 51), "😂")
        XCTAssertEqual(TaggrReactionIcon.emoji(for: 52), "💯")
        XCTAssertEqual(TaggrReactionIcon.emoji(for: 53), "🚀")
        XCTAssertEqual(TaggrReactionIcon.emoji(for: 100), "⭐️")
        XCTAssertEqual(TaggrReactionIcon.emoji(for: 101), "🏴‍☠️")
        XCTAssertEqual(TaggrReactionIcon.emoji(for: 10), "❤️")
        XCTAssertEqual(TaggrReactionIcon.emoji(for: 11), "👍")
        XCTAssertEqual(TaggrReactionIcon.emoji(for: 12), "😢")
        XCTAssertNil(TaggrReactionIcon.emoji(for: 999))
    }

    func testReactionGroupsPreserveUsersAndUseConfiguredOrder() {
        let groups = TaggrReactionGroup.groups(
            reactions: ["53": [7], "11": [2, 3], "999": [4]],
            order: [11, 53]
        )

        XCTAssertEqual(
            groups,
            [
                TaggrReactionGroup(id: 11, emoji: "👍", userIDs: [2, 3]),
                TaggrReactionGroup(id: 53, emoji: "🚀", userIDs: [7]),
            ]
        )
    }

    @MainActor
    func testLoadAuthorNamesCachesReactionUsersInOneQuery() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data(#"{"2":"bob","3":"carol"}"#.utf8)))
        }
        let state = TaggrAppCoordinator(api: api)

        let names = try await state.loadAuthorNames(
            userIDs: [2, 3],
            generation: state.runtimeGeneration,
            api: state.api
        )

        XCTAssertEqual(calls.map(\.method), ["users_data"])
        XCTAssertEqual(calls.first?.arg, try TaggrCandid.jsonArguments([[2, 3]]))
        XCTAssertEqual(names, [2: "bob", 3: "carol"])
        XCTAssertEqual(state.authorNamesByUserID, [2: "bob", 3: "carol"])
    }

    @MainActor
    func testAuthorProfileHandleUsesCurrentUserAndCachedNamesOnly() {
        let state = TaggrAppCoordinator()
        state.currentUser = TaggrUser(
            id: 7,
            name: "alice",
            about: "",
            principal: nil,
            realms: [],
            followees: [],
            followers: [],
            blacklist: [],
            mode: nil
        )
        state.authorNamesByUserID = [2: "bob", 3: ""]

        XCTAssertEqual(state.authorProfileHandle(for: 7), "alice")
        XCTAssertEqual(state.authorProfileHandle(for: 2), "bob")
        XCTAssertNil(state.authorProfileHandle(for: 3))
        XCTAssertNil(state.authorProfileHandle(for: 99))
    }

    func testPostAddingReactionAppendsUserOnce() {
        let post = samplePost(id: 42, body: "hello", reactions: ["11": [2]], files: [:])
        let reacted = post.addingReaction(53, by: 7)
        let duplicate = reacted.addingReaction(50, by: 7)

        XCTAssertEqual(reacted.reactions["11"], [2])
        XCTAssertEqual(reacted.reactions["53"], [7])
        XCTAssertNil(duplicate.reactions["50"])
        XCTAssertEqual(duplicate.reactions["53"], [7])
    }

    func testPostImageMarkdownExtraction() {
        let body = "hello\n\n![320x240, 12kb](/blob/a1b2c3d4)\n![remote](https://example.com/image.png)\n![x](/blob/second)"
        XCTAssertEqual(TaggrPostImages.imageIDs(in: body), ["a1b2c3d4", "second"])
        XCTAssertEqual(TaggrPostImages.textWithoutImageMarkdown(body), "hello")
    }

    func testPostImageAttachmentsIncludeRemoteMarkdownImages() {
        let post = samplePost(
            body: "first\n![local](/blob/local)\n![remote](https://example.com/image.png)",
            files: ["local@aaaaa-aa": [LosslessInt(12), LosslessInt(34)]]
        )

        XCTAssertEqual(
            post.imageAttachments().map(\.url.absoluteString),
            [
                "https://aaaaa-aa.raw.icp0.io/image?offset=12&len=34",
                "https://example.com/image.png",
            ]
        )
        XCTAssertEqual(post.imageAttachments().first?.bucketId, "aaaaa-aa")
        XCTAssertEqual(post.imageAttachments().first?.offset, 12)
        XCTAssertEqual(post.imageAttachments().first?.length, 34)
        XCTAssertNil(post.imageAttachments().last?.bucketId)
    }

    func testEditablePostImagesCanRemoveMarkdownReferences() {
        let local = "![local](/blob/local)"
        let remote = "![remote](https://example.com/image.png)"
        let post = samplePost(
            body: "before\n\(local)\n\(local)\n\(remote)\nafter",
            files: ["local@aaaaa-aa": [LosslessInt(12), LosslessInt(34)]]
        )

        let images = post.editableImageAttachments(bodyText: post.body)

        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images[0].markdownReferences, [local, local])
        XCTAssertTrue(images.allSatisfy(\.isRemovable))
        let withoutLocal = TaggrPostImages.removingImageMarkdown(images[0].markdownReferences, from: post.body)
        XCTAssertFalse(withoutLocal.contains(local))
        XCTAssertTrue(withoutLocal.contains(remote))
        let withoutImages = TaggrPostImages.removingImageMarkdown(images[1].markdownReferences, from: withoutLocal)
        XCTAssertEqual(withoutImages, "before\nafter")
        XCTAssertTrue(post.editableImageAttachments(bodyText: withoutImages).isEmpty)
    }

    func testLegacyPostImageIsPreviewOnly() throws {
        let post = samplePost(
            body: "legacy image",
            files: ["local@aaaaa-aa": [LosslessInt(12), LosslessInt(34)]]
        )

        let image = try XCTUnwrap(post.editableImageAttachments(bodyText: post.body).first)

        XCTAssertFalse(image.isRemovable)
        XCTAssertEqual(image.attachment.url.absoluteString, "https://aaaaa-aa.raw.icp0.io/image?offset=12&len=34")
    }

    func testPostImageAttachmentsSkipUnsafeRemoteMarkdownImages() {
        let post = samplePost(
            body: "![unsafe](javascript:alert(1))\n![data](data:image/png;base64,AAAA)",
            files: [:]
        )

        XCTAssertEqual(post.imageAttachments(), [])
    }

    func testEditPatchAppliesFullReplacement() throws {
        let patch = TaggrEditPatch.fullReplacement(from: "updated", to: "hello")

        XCTAssertEqual(try TaggrEditPatch.apply(patch, to: "updated"), "hello")
    }

    func testDeletionVersionsRebuildEditedBodies() throws {
        let firstPatch = TaggrEditPatch.fullReplacement(from: "edited", to: "original")
        let secondPatch = TaggrEditPatch.fullReplacement(from: "current", to: "edited")
        let post = samplePost(
            body: "current",
            files: [:],
            patches: [
                [.number(1), .string(firstPatch)],
                [.number(2), .string(secondPatch)],
            ]
        )

        XCTAssertEqual(try post.deletionVersions(), ["original", "edited", "current"])
    }

    func testMalformedEditPatchThrows() {
        XCTAssertThrowsError(try TaggrEditPatch.apply("@@ malformed", to: "current"))
    }

    func testAccountImagePagingContinuesUntilImageOrEnd() {
        let textOnlyPage = [
            samplePost(id: 101, body: "text only", files: [:]),
        ]
        let imagePage = [
            samplePost(
                id: 100,
                body: "photo\n![image](/blob/img)",
                files: ["img@aaaaa-aa": [LosslessInt(7), LosslessInt(9)]]
            ),
        ]

        let first = TaggrAccountImagePaging.append(posts: textOnlyPage, to: [], page: 0, pagingOffset: 0)
        XCTAssertEqual(first.images, [])
        XCTAssertEqual(first.page, 1)
        XCTAssertEqual(first.pagingOffset, 101)
        XCTAssertFalse(first.reachedEnd)
        XCTAssertTrue(TaggrAccountImagePaging.shouldContinueLoading(previousImageCount: 0, result: first))

        let second = TaggrAccountImagePaging.append(
            posts: imagePage,
            to: first.images,
            page: first.page,
            pagingOffset: first.pagingOffset
        )
        XCTAssertEqual(second.images.map(\.postId), [100])
        XCTAssertEqual(second.page, 2)
        XCTAssertEqual(second.pagingOffset, 101)
        XCTAssertFalse(second.reachedEnd)
        XCTAssertFalse(TaggrAccountImagePaging.shouldContinueLoading(previousImageCount: first.images.count, result: second))

        let end = TaggrAccountImagePaging.append(
            posts: [],
            to: second.images,
            page: second.page,
            pagingOffset: second.pagingOffset
        )
        XCTAssertTrue(end.reachedEnd)
        XCTAssertFalse(TaggrAccountImagePaging.shouldContinueLoading(previousImageCount: second.images.count, result: end))
    }

    func testPostExtensionDecodesPollRepostAndProposal() throws {
        let pollPost = try JSONDecoder.taggr.decode(
            TaggrPostEnvelope.self,
            from: postEnvelopeFixture(extensionJSON: #"{"Poll":{"options":["yes","no"],"votes":{"0":[7]},"voters":[7],"deadline":123}}"#)
        ).post
        let repost = TaggrPostExtension(value: .object(["Repost": .number(42)]))
        let proposal = TaggrPostExtension(value: .object(["Proposal": .number(9)]))

        XCTAssertEqual(pollPost.extensionKind, .poll(TaggrPoll(value: .object([
            "options": .array([.string("yes"), .string("no")]),
            "votes": .object(["0": .array([.number(7)])]),
            "voters": .array([.number(7)]),
            "deadline": .number(123),
        ]))!))
        XCTAssertEqual(repost, .repost(42))
        XCTAssertEqual(proposal, .proposal(9))
    }

    func testMarkdownTextUsesMarkdownParser() {
        let attributed = TaggrMarkdownText.attributedMarkdown(from: "**hello** [TAGGR](https://taggr.link)")

        XCTAssertEqual(String(attributed.characters), "hello TAGGR")
        XCTAssertTrue(attributed.runs.contains { $0.link?.absoluteString == "https://taggr.link" })
    }

    func testMarkdownTextPreservesUserLineBreaks() {
        let attributed = TaggrMarkdownText.attributedMarkdown(from: "first line\nsecond line")

        XCTAssertEqual(String(attributed.characters), "first line\nsecond line")
    }

    func testMarkdownTextDoesNotAlterFencedCodeLineBreaks() {
        let attributed = TaggrMarkdownText.attributedMarkdown(from: "```\nfirst line\nsecond line\n```")

        XCTAssertEqual(String(attributed.characters), "first line\nsecond line\n")
    }

    func testMarkdownLineBreakNormalizationPreservesIndentedCode() {
        let input = "    first line\n    second line\n\ta tab-indented line"

        XCTAssertEqual(TaggrMarkdownText.preservingUserLineBreaks(in: input), input)
    }

    func testMarkdownLineBreakNormalizationOnlyClosesFenceWithWhitespace() {
        let input = "```\n```not a closing fence\ncode\n```\nafter\nnext"
        let expected = "```\n```not a closing fence\ncode\n```\nafter  \nnext"

        XCTAssertEqual(TaggrMarkdownText.preservingUserLineBreaks(in: input), expected)
    }

    func testMarkdownLineBreakNormalizationSupportsTildeFences() {
        let input = "~~~swift\nlet value = 1\n~~~~\nafter\nnext"
        let expected = "~~~swift\nlet value = 1\n~~~~\nafter  \nnext"

        XCTAssertEqual(TaggrMarkdownText.preservingUserLineBreaks(in: input), expected)
    }

    func testMarkdownTextRemovesUnsafeLinks() {
        let attributed = TaggrMarkdownText.attributedMarkdown(from: "[bad](javascript:alert%281%29)")

        XCTAssertEqual(String(attributed.characters), "bad")
        XCTAssertFalse(attributed.runs.contains { $0.link != nil })
    }

    func testMarkdownTextLinksTagsAndUsersWithoutTouchingMarkdownLinks() {
        let linked = TaggrMarkdownText.linkTagsAndUsers("hi @alice /DEV #tag $TAG [@raw](https://example.com) `#code`")

        XCTAssertTrue(linked.contains("[@alice](https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/user/alice)"))
        XCTAssertTrue(linked.contains("[/DEV](https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/realm/DEV)"))
        XCTAssertTrue(linked.contains("[#tag](https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/feed/tag)"))
        XCTAssertTrue(linked.contains("[$TAG](https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/feed/TAG)"))
        XCTAssertTrue(linked.contains("[@raw](https://example.com)"))
        XCTAssertTrue(linked.contains("`#code`"))
    }

    func testMarkdownTextStopsHashtagLinksBeforeDots() {
        let linked = TaggrMarkdownText.linkTagsAndUsers("read #tag.next")

        XCTAssertTrue(linked.contains("[#tag](https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/feed/tag).next"))
    }

    func testMarkdownTextKeepsPostTapSeparateWhenLinksArePresent() {
        XCTAssertTrue(TaggrMarkdownText.containsInteractiveLink(in: "read #tag"))
        XCTAssertTrue(TaggrMarkdownText.containsInteractiveLink(in: "read [TAGGR](https://taggr.link)"))
        XCTAssertFalse(TaggrMarkdownText.containsInteractiveLink(in: "plain post text"))
    }

    func testPostBodyParserSeparatesParagraphsAndYouTubeEmbeds() {
        let body = """
        部屋の掃除をめっちゃ頑張ってたくさんゴミを捨てました

        音源のほうは清志郎がプロデュース&演奏で参加してる https://nico.ms/sm7037560?ref=other_cap_off

        **GOMI _ 加奈崎芳太郎**
        https://youtu.be/zG9K9Za56jI?si=vvHxqwh5SE3Msr3r
        """

        let blocks = TaggrPostBodyParser.blocks(in: body)
        XCTAssertEqual(blocks.count, 4)
        guard case .markdown(let first) = blocks[0],
              case .markdown(let second) = blocks[1],
              case .markdown(let third) = blocks[2],
              case .youtube(let preview) = blocks[3] else {
            return XCTFail("Unexpected post body blocks")
        }
        XCTAssertEqual(first, "部屋の掃除をめっちゃ頑張ってたくさんゴミを捨てました")
        XCTAssertTrue(second.contains("https://nico.ms/sm7037560"))
        XCTAssertEqual(third, "**GOMI _ 加奈崎芳太郎**")
        XCTAssertEqual(preview.id, "zG9K9Za56jI")
        XCTAssertTrue(TaggrPostBodyView.containsInteractiveLink(in: body))
    }

    func testMarkdownTextAutolinksBareURLsWithoutTouchingCode() {
        let attributed = TaggrMarkdownText.attributedMarkdown(
            from: "https://nico.ms/sm7037560 www.example.com WWW.example.org `https://example.com`"
        )

        XCTAssertEqual(String(attributed.characters), "NICO.MS WWW.EXAMPLE.COM WWW.EXAMPLE.ORG https://example.com")
        XCTAssertTrue(attributed.runs.contains { $0.link?.host == "nico.ms" })
        XCTAssertTrue(attributed.runs.contains { $0.link?.absoluteString == "https://www.example.com" })
        XCTAssertTrue(attributed.runs.contains { $0.link?.absoluteString == "https://WWW.example.org" })
        XCTAssertFalse(attributed.runs.contains { $0.link?.host == "example.com" })
    }

    func testPostImageURLUsesRuntimeConfig() {
        let mainnet = TaggrRuntimeConfig.from(info: [:])
        XCTAssertEqual(
            TaggrPostImages.imageURL(bucketId: "aaaaa-aa", offset: 12, length: 34, config: mainnet)?.absoluteString,
            "https://aaaaa-aa.raw.icp0.io/image?offset=12&len=34"
        )
        let local = TaggrRuntimeConfig.from(info: ["TAGGR_API_BASE_URL": "https://taggr.trycloudflare.com"])
        XCTAssertEqual(
            TaggrPostImages.imageURL(bucketId: "aaaaa-aa", offset: 12, length: 34, config: local)?.absoluteString,
            "https://aaaaa-aa.raw.icp0.io/image?offset=12&len=34"
        )
    }

    func testBucketHTTPRequestCandidMatchesWebIDL() {
        XCTAssertEqual(
            TaggrCandid.encodeBucketHTTPRequest(offset: 268, length: 211736).icHexString,
            "4449444c036c02007101716d006c02efd6e40271c6a4a198060101021c2f696d6167653f6f66667365743d323638266c656e3d32313137333600"
        )
    }

    func testBucketHTTPResponseDecodesImageBody() throws {
        let response = Data(icHex: "4449444c056d7b6c02007101716d016e7e6c04a2f5ed880400c6a4a19806029ce9c69906039aa1b2f90c7a010403010203010c636f6e74656e742d747970650a696d6167652f6a70656700c800")!

        XCTAssertEqual(try TaggrCandid.decodeBucketHTTPResponseBody(response), Data([1, 2, 3]))
    }

    func testPostImageAttachmentsSkipMalformedFilesMetadata() {
        let post = samplePost(
            body: "hello\n\n![x](/blob/a1b2c3d4)",
            files: ["a1b2c3d4@aaaaa-aa": [LosslessInt(12)]]
        )
        XCTAssertEqual(post.imageAttachments(), [])
    }

    func testAccountImagesExtractPostedImages() {
        let post = samplePost(
            id: 42,
            body: "caption\n\n![first](/blob/first)\n![second](/blob/second)",
            files: [
                "first@aaaaa-aa": [LosslessInt(12), LosslessInt(34)],
                "second@aaaaa-aa": [LosslessInt(56), LosslessInt(78)],
            ]
        )

        let images = TaggrAccountImage.images(from: [post])

        XCTAssertEqual(images.map(\.id), ["first", "second"])
        XCTAssertEqual(images.map(\.postId), [42, 42])
        XCTAssertEqual(images.map(\.caption), ["caption", "caption"])
    }

    func testAccountImagesGroupByYearDescending() {
        let newer = samplePost(
            id: 3,
            body: "newer\n\n![x](/blob/newer)",
            files: ["newer@aaaaa-aa": [LosslessInt(1), LosslessInt(2)]],
            timestamp: timestamp(year: 2025, month: 12)
        )
        let olderSameYear = samplePost(
            id: 2,
            body: "older\n\n![x](/blob/older)",
            files: ["older@aaaaa-aa": [LosslessInt(1), LosslessInt(2)]],
            timestamp: timestamp(year: 2025, month: 1)
        )
        let previousYear = samplePost(
            id: 1,
            body: "previous\n\n![x](/blob/previous)",
            files: ["previous@aaaaa-aa": [LosslessInt(1), LosslessInt(2)]],
            timestamp: timestamp(year: 2024, month: 6)
        )

        let groups = TaggrAccountImage.yearGroups(from: TaggrAccountImage.images(from: [previousYear, olderSameYear, newer]))

        XCTAssertEqual(groups.map(\.year), [2025, 2024])
        XCTAssertEqual(groups.first?.images.map(\.id), ["newer", "older"])
        XCTAssertEqual(groups.last?.images.map(\.id), ["previous"])
    }

    func testAccountImagesDeduplicateImageIDs() {
        let post = samplePost(
            body: "hello\n\n![first](/blob/repeated)\n![again](/blob/repeated)",
            files: ["repeated@aaaaa-aa": [LosslessInt(12), LosslessInt(34)]]
        )

        XCTAssertEqual(TaggrAccountImage.images(from: [post]).map(\.id), ["repeated"])
    }

    func testAccountImagesSkipPostsWithoutImages() {
        let post = samplePost(body: "plain text only", files: [:])

        XCTAssertEqual(TaggrAccountImage.images(from: [post]), [])
    }

    func testPostImageGridUsesCompactColumns() {
        XCTAssertEqual(PostImageGrid.columns(for: 0), 1)
        XCTAssertEqual(PostImageGrid.columns(for: 1), 1)
        XCTAssertEqual(PostImageGrid.columns(for: 2), 2)
        XCTAssertEqual(PostImageGrid.columns(for: 3), 2)
        XCTAssertEqual(PostImageGrid.columns(for: 4), 2)
        XCTAssertEqual(PostImageGrid.columns(for: 5), 2)
        XCTAssertEqual(PostImageGrid.visibleRows(for: 0), 0)
        XCTAssertEqual(PostImageGrid.visibleRows(for: 1), 1)
        XCTAssertEqual(PostImageGrid.visibleRows(for: 2), 1)
        XCTAssertEqual(PostImageGrid.visibleRows(for: 3), 2)
        XCTAssertEqual(PostImageGrid.visibleRows(for: 4), 2)
        XCTAssertEqual(PostImageGrid.visibleRows(for: 5), 2)
        XCTAssertEqual(PostImageGrid.displayedCount(for: 0), 0)
        XCTAssertEqual(PostImageGrid.displayedCount(for: 1), 1)
        XCTAssertEqual(PostImageGrid.displayedCount(for: 2), 2)
        XCTAssertEqual(PostImageGrid.displayedCount(for: 3), 3)
        XCTAssertEqual(PostImageGrid.displayedCount(for: 4), 4)
        XCTAssertEqual(PostImageGrid.displayedCount(for: 5), 4)
        XCTAssertEqual(PostImageGrid.visibleCount(for: 3), 3)
        XCTAssertEqual(PostImageGrid.visibleCount(for: 4), 4)
        XCTAssertEqual(PostImageGrid.visibleCount(for: 5), 4)
        XCTAssertEqual(PostImageGrid.hiddenCount(for: 0), 0)
        XCTAssertEqual(PostImageGrid.hiddenCount(for: 3), 0)
        XCTAssertEqual(PostImageGrid.hiddenCount(for: 4), 0)
        XCTAssertEqual(PostImageGrid.hiddenCount(for: 5), 1)
        XCTAssertEqual(PostImageGrid.hiddenCount(for: 6), 2)
        XCTAssertEqual(PostImageGrid.timelineAspectRatio(for: 0), 16.0 / 10.0, accuracy: 0.001)
        XCTAssertEqual(PostImageGrid.timelineAspectRatio(for: 1), 16.0 / 10.0, accuracy: 0.001)
        XCTAssertEqual(PostImageGrid.timelineAspectRatio(for: 2), 16.0 / 10.0, accuracy: 0.001)
        XCTAssertEqual(PostImageGrid.timelineAspectRatio(for: 3), 1.0, accuracy: 0.001)
        XCTAssertEqual(PostImageGrid.timelineAspectRatio(for: 4), 1.0, accuracy: 0.001)
        XCTAssertEqual(PostImageGrid.timelineAspectRatio(for: 5), 1.0, accuracy: 0.001)
        XCTAssertEqual(PostImageGrid.timelineAspectRatio(for: 6), 1.0, accuracy: 0.001)
    }

    func testFeedImagePrefetchIncludesCurrentAndLookAheadVisibleImages() {
        let posts = (1...8).map { id in
            samplePost(
                id: id,
                body: "post \(id)\n\n![x](/blob/image\(id))",
                files: ["image\(id)@aaaaa-aa": [LosslessInt(Int64(id)), LosslessInt(20)]]
            )
        }

        let urls = FeedImagePrefetchPolicy
            .attachments(in: posts, around: posts[1], currentUserId: nil)
            .map(\.url)

        XCTAssertEqual(urls.count, 7)
        XCTAssertEqual(urls.first?.absoluteString, "https://aaaaa-aa.raw.icp0.io/image?offset=2&len=20")
        XCTAssertEqual(urls.last?.absoluteString, "https://aaaaa-aa.raw.icp0.io/image?offset=8&len=20")
    }

    func testFeedImagePrefetchOnlyUsesVisibleTimelineBody() {
        let post = samplePost(
            id: 1,
            body: "visible\n\n![x](/blob/visible)\n\n\n\nhidden\n\n![x](/blob/hidden)",
            files: [
                "visible@aaaaa-aa": [LosslessInt(1), LosslessInt(20)],
                "hidden@aaaaa-aa": [LosslessInt(2), LosslessInt(20)],
            ]
        )

        let urls = FeedImagePrefetchPolicy
            .attachments(in: [post], around: post, currentUserId: nil)
            .map(\.url)

        XCTAssertEqual(urls.map(\.absoluteString), ["https://aaaaa-aa.raw.icp0.io/image?offset=1&len=20"])
    }

    func testRelativeTimeUsesCompactTimelineLabels() {
        let nowSeconds: Int64 = 1_700_000_000
        let now = Date(timeIntervalSince1970: TimeInterval(nowSeconds))
        func timestamp(secondsAgo: Int64) -> LosslessInt {
            LosslessInt((nowSeconds - secondsAgo) * 1_000_000_000)
        }

        XCTAssertEqual(TaggrRelativeTime.string(from: timestamp(secondsAgo: 0), now: now), "1s ago")
        XCTAssertEqual(TaggrRelativeTime.string(from: timestamp(secondsAgo: 30), now: now), "30s ago")
        XCTAssertEqual(TaggrRelativeTime.string(from: timestamp(secondsAgo: 60), now: now), "1m ago")
        XCTAssertEqual(TaggrRelativeTime.string(from: timestamp(secondsAgo: 3_600), now: now), "1h ago")

        let recentDate = Date(timeIntervalSince1970: TimeInterval(nowSeconds - 86_400))
        let recentFormatter = DateFormatter()
        recentFormatter.locale = .current
        recentFormatter.setLocalizedDateFormatFromTemplate("MMM d")
        XCTAssertEqual(TaggrRelativeTime.string(from: timestamp(secondsAgo: 86_400), now: now), recentFormatter.string(from: recentDate))

        let oldDate = Date(timeIntervalSince1970: TimeInterval(nowSeconds - 90 * 86_400))
        let oldFormatter = DateFormatter()
        oldFormatter.locale = .current
        oldFormatter.setLocalizedDateFormatFromTemplate("yy MMM d")
        XCTAssertEqual(TaggrRelativeTime.string(from: timestamp(secondsAgo: 90 * 86_400), now: now), oldFormatter.string(from: oldDate))
    }

    func testImageDraftsRejectsOversizedCompressedOutput() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        guard let data = image.pngData() else {
            return XCTFail("Fixture image is missing.")
        }
        XCTAssertNil(ImageDrafts.normalizedImageData(data, maxBytes: 1))
    }

    func testImageDraftsDownsamplesImagesAbovePixelLimit() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24))
        let source = try XCTUnwrap(renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }.pngData())

        let normalized = try XCTUnwrap(
            ImageDrafts.normalizedImageData(source, maxBytes: 50_000, maxPixels: 192)
        )
        let image = try XCTUnwrap(UIImage(data: normalized))
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)

        XCTAssertLessThanOrEqual(width * height, 192)
        XCTAssertEqual(
            Double(width) / Double(height),
            4.0 / 3.0,
            accuracy: 0.1
        )
    }

    func testDraftImageMarkdownUsesWebBlobFormatAndStableHashId() {
        let image = TaggrDraftImage(id: "abc12345", data: Data(repeating: 1, count: 1537), width: 320, height: 240)

        XCTAssertEqual(image.markdown, "![320x240, 2kb](/blob/abc12345)")
        XCTAssertEqual(ImageDrafts.blobId(for: Data([1, 2, 3])), ImageDrafts.blobId(for: Data([1, 2, 3])))
        XCTAssertEqual(ImageDrafts.blobId(for: Data([1, 2, 3])).count, 8)
    }

    func testDraftImageIDsAreUniquedPerAttachment() {
        let image = TaggrDraftImage(id: "abc12345", data: Data([1, 2, 3]), width: 10, height: 20)

        let images = ImageDrafts.uniquedDraftImages([image, image], existingIDs: [])

        XCTAssertEqual(images.map(\.id), ["abc12345", "abc12301"])
        XCTAssertEqual(images.map(\.markdown), [
            "![10x20, 1kb](/blob/abc12345)",
            "![10x20, 1kb](/blob/abc12301)",
        ])
    }

    func testPostDraftStoreRoundTripsImagesAndSeparatesContextsAndNamespaces() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PostDraftStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PostDraftStore(rootURL: root)
        let mainnetAlice = PostDraftNamespace(canisterID: "mainnet-canister", userID: 7)
        let stagingAlice = PostDraftNamespace(canisterID: "staging-canister", userID: 7)
        let mainnetBob = PostDraftNamespace(canisterID: "mainnet-canister", userID: 8)
        let image = TaggrDraftImage(id: "abc12345", data: Data([1, 2, 3]), width: 10, height: 20)
        let text = "hello\n\n\(image.markdown)"

        try await store.save(
            namespace: mainnetAlice,
            context: .newPost,
            text: text,
            realm: "DEV",
            images: [image]
        )

        let restored = await store.load(namespace: mainnetAlice, context: .newPost)
        XCTAssertEqual(restored.text, text)
        XCTAssertEqual(restored.realm, "DEV")
        XCTAssertEqual(restored.images, [image])
        XCTAssertNil(restored.warning)
        let otherContext = await store.load(namespace: mainnetAlice, context: .reply(42))
        let otherNetwork = await store.load(namespace: stagingAlice, context: .newPost)
        let otherUser = await store.load(namespace: mainnetBob, context: .newPost)
        XCTAssertNil(otherContext.text)
        XCTAssertNil(otherNetwork.text)
        XCTAssertNil(otherUser.text)

        try await store.save(
            namespace: mainnetAlice,
            context: .reply(42),
            text: "reply 42",
            realm: "",
            images: []
        )
        try await store.save(
            namespace: mainnetAlice,
            context: .reply(43),
            text: "reply 43",
            realm: "",
            images: []
        )
        try await store.save(
            namespace: mainnetAlice,
            context: .edit(42),
            text: "edit 42",
            realm: "",
            images: []
        )
        let reply42 = await store.load(namespace: mainnetAlice, context: .reply(42))
        let reply43 = await store.load(namespace: mainnetAlice, context: .reply(43))
        let edit42 = await store.load(namespace: mainnetAlice, context: .edit(42))
        XCTAssertEqual(reply42.text, "reply 42")
        XCTAssertEqual(reply43.text, "reply 43")
        XCTAssertEqual(edit42.text, "edit 42")

        await store.delete(namespace: mainnetAlice, context: .newPost)
        let deleted = await store.load(namespace: mainnetAlice, context: .newPost)
        XCTAssertNil(deleted.text)
    }

    func testPostDraftStoreRemovesMissingImageMarkersWithoutLosingRemainingDraft() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PostDraftStoreMissingImageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PostDraftStore(rootURL: root)
        let namespace = PostDraftNamespace(canisterID: "mainnet-canister", userID: 7)
        let missing = TaggrDraftImage(id: "missing1", data: Data([1]), width: 10, height: 20)
        let remaining = TaggrDraftImage(id: "present1", data: Data([2]), width: 30, height: 40)
        let text = "caption\n\n\(missing.markdown)\n\(remaining.markdown)"

        try await store.save(
            namespace: namespace,
            context: .reply(42),
            text: text,
            realm: "",
            images: [missing, remaining]
        )
        let missingURL = root
            .appending(path: "mainnet-canister/7/reply-42/image-missing1.bin")
        try FileManager.default.removeItem(at: missingURL)

        let restored = await store.load(namespace: namespace, context: .reply(42))
        XCTAssertFalse(restored.text?.contains("/blob/missing1") == true)
        XCTAssertTrue(restored.text?.contains("/blob/present1") == true)
        XCTAssertEqual(restored.images, [remaining])
        XCTAssertEqual(
            restored.warning,
            "Some draft images were unavailable and were removed."
        )
    }

    func testPostDraftStoreRecoversFromCorruptMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PostDraftStoreCorruptTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PostDraftStore(rootURL: root)
        let namespace = PostDraftNamespace(canisterID: "mainnet-canister", userID: 7)
        try await store.save(
            namespace: namespace,
            context: .edit(99),
            text: "edited",
            realm: "",
            images: []
        )
        let metadataURL = root
            .appending(path: "mainnet-canister/7/edit-99/draft.json")
        try Data("not-json".utf8).write(to: metadataURL)

        let restored = await store.load(namespace: namespace, context: .edit(99))
        XCTAssertNil(restored.text)
        XCTAssertEqual(restored.warning, "The saved draft could not be restored.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
    }

    @MainActor
    func testPostDraftSessionRestoresAndDeletesEmptyOrDiscardedDrafts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PostDraftSessionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PostDraftStore(rootURL: root)
        let namespace = PostDraftNamespace(canisterID: "mainnet-canister", userID: 7)
        let session = PostDraftSession(
            context: .newPost,
            initialText: "",
            initialRealm: ""
        )
        await session.load(store: store, namespace: namespace)
        session.text = "saved text"
        session.realm = "DEV"
        await session.flush()

        let restoredSession = PostDraftSession(
            context: .newPost,
            initialText: "",
            initialRealm: "OTHER"
        )
        await restoredSession.load(store: store, namespace: namespace)
        XCTAssertEqual(restoredSession.text, "saved text")
        XCTAssertEqual(restoredSession.realm, "DEV")

        restoredSession.text = ""
        await restoredSession.flush()
        let emptied = await store.load(namespace: namespace, context: .newPost)
        XCTAssertNil(emptied.text)

        session.text = "discard me"
        await session.flush()
        await session.discard()
        let discarded = await store.load(namespace: namespace, context: .newPost)
        XCTAssertNil(discarded.text)

        let editSession = PostDraftSession(
            context: .edit(42),
            initialText: "original",
            initialRealm: "DEV"
        )
        await editSession.load(store: store, namespace: namespace)
        XCTAssertFalse(editSession.hasChanges)
        editSession.realm = "ART"
        XCTAssertTrue(editSession.hasChanges)
        editSession.realm = "DEV"
        await editSession.flush()
        let unchangedEdit = await store.load(namespace: namespace, context: .edit(42))
        XCTAssertNil(unchangedEdit.text)
    }

    func testQueryRejectedResponseSurfacesRejectedError() async throws {
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = ICCBOR.encode(.map([
                (.text("status"), .text("rejected")),
                (.text("reject_message"), .text("denied")),
            ]))
            return (response, body)
        }
        do {
            _ = try await api.query("stats", args: [], as: TaggrStats.self)
            XCTFail("Expected rejected error.")
        } catch TaggrAPIError.rejected(let message) {
            XCTAssertEqual(message, "denied")
        } catch {
            XCTFail("Expected rejected error, got \(error).")
        }
    }

    @MainActor
    func testPersonalFeedUsesSignedQueryWhenAuthenticated() async throws {
        var capturedBody: Data?
        let api = makeStubbedAPI { request in
            capturedBody = Self.requestBody(from: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data("[]".utf8)))
        }
        let privateKey = Curve25519.Signing.PrivateKey()
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: privateKey)

        await state.loadFeed(mode: .personal, reset: true)

        guard let capturedBody,
              case .map(let envelope)? = ICCBOR.decode(capturedBody) else {
            return XCTFail("Signed personal feed query was not sent.")
        }
        XCTAssertNotNil(value(named: "sender_sig", in: envelope))
        XCTAssertNil(state.errorMessage)
    }

    @MainActor
    func testTagFeedUsesPostsByTagsQuery() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data("[]".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)

        await state.loadFeed(mode: .tags(["tag"]), reset: true)

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.map(\.method), ["posts_by_tags"])
        XCTAssertEqual(calls.first?.arg, try TaggrCandid.jsonArguments([TaggrRuntimeConfig.productionDomain, "", ["tag"], 0, 0]))
    }

    @MainActor
    func testRefreshCancellationDoesNotSurfaceErrorBanner() async {
        let api = makeStubbedAPI { _ in
            throw URLError(.cancelled)
        }
        let state = TaggrAppCoordinator(api: api)

        await state.loadFeed(mode: .hot, reset: true)

        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.isBusy)
        XCTAssertTrue(state.feed.isEmpty)
    }

    @MainActor
    func testNewerFeedRequestWinsWhenOlderResponseFinishesLast() async {
        let firstRequestStarted = expectation(description: "first feed request started")
        let releaseFirstRequest = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var requestCount = 0
        let api = makeStubbedAPI { request in
            lock.lock()
            requestCount += 1
            let requestNumber = requestCount
            lock.unlock()
            if requestNumber == 1 {
                firstRequestStarted.fulfill()
                _ = releaseFirstRequest.wait(timeout: .now() + 5)
            }
            let postID = requestNumber == 1 ? 101 : 202
            let body = Data("[\(String(data: self.postEnvelopeFixture(id: postID), encoding: .utf8)!)]".utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(body))
        }
        let state = TaggrAppCoordinator(api: api)

        let oldRequest = Task { await state.loadFeed(mode: .hot, reset: true) }
        await fulfillment(of: [firstRequestStarted], timeout: 1)
        await state.loadFeed(mode: .latest, reset: true)
        releaseFirstRequest.signal()
        await oldRequest.value

        XCTAssertEqual(state.feed.map(\.id), [202])
        XCTAssertNil(state.errorMessage)
    }

    @MainActor
    func testPostResponseDoesNotOverwriteFeedAfterRouteChange() async {
        let postRequestStarted = expectation(description: "post request started")
        let releasePostRequest = DispatchSemaphore(value: 0)
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            switch self.requestMethodAndArg(from: request)?.method {
            case "thread":
                postRequestStarted.fulfill()
                _ = releasePostRequest.wait(timeout: .now() + 5)
                let body = Data("[\(String(data: self.postEnvelopeFixture(id: 101), encoding: .utf8)!)]".utf8)
                return (response, Self.queryReply(body))
            case "hot_posts":
                let body = Data("[\(String(data: self.postEnvelopeFixture(id: 202), encoding: .utf8)!)]".utf8)
                return (response, Self.queryReply(body))
            default:
                return (response, Self.queryReply(Data("null".utf8)))
            }
        }
        let state = TaggrAppCoordinator(api: api)
        state.navigateToPost(101)

        let oldPostRequest = Task { await state.loadPost(101) }
        await fulfillment(of: [postRequestStarted], timeout: 1)

        state.navigateToFeed(.hot)
        await state.loadFeed(mode: .hot, reset: true)
        releasePostRequest.signal()
        await oldPostRequest.value

        XCTAssertEqual(state.route, .feed(.hot))
        XCTAssertEqual(state.feed.map(\.id), [202])
        XCTAssertNil(state.focusedPost)
        XCTAssertNil(state.errorMessage)
    }

    @MainActor
    func testBusyRemainsSetUntilAllConcurrentOperationsFinish() async {
        let firstStarted = expectation(description: "first operation started")
        let secondStarted = expectation(description: "second operation started")
        let firstGate = TaggrTestGate()
        let secondGate = TaggrTestGate()
        let state = TaggrAppCoordinator()

        let first = Task {
            await state.runBusy {
                firstStarted.fulfill()
                await firstGate.wait()
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)
        let second = Task {
            await state.runBusy {
                secondStarted.fulfill()
                await secondGate.wait()
            }
        }
        await fulfillment(of: [secondStarted], timeout: 1)
        XCTAssertTrue(state.isBusy)

        await firstGate.open()
        _ = await first.value
        XCTAssertTrue(state.isBusy)

        await secondGate.open()
        _ = await second.value
        XCTAssertFalse(state.isBusy)
    }

    @MainActor
    func testPostCreditCostCachesNormalizedTagsAndRetriesAfterFailure() async throws {
        let lock = NSLock()
        var callCount = 0
        let api = makeStubbedAPI { request in
            lock.lock()
            callCount += 1
            let requestNumber = callCount
            lock.unlock()
            if requestNumber == 1 {
                throw URLError(.cannotConnectToHost)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data("4".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.cache = TaggrBackendCache(
            stats: nil,
            config: try JSONDecoder.taggr.decode(
                TaggrConfig.self,
                from: Data(#"{"post_cost":2,"max_tag_length":30}"#.utf8)
            )
        )

        let failedCost = await state.postCreditCost(for: "first #TAG")
        let retriedCost = await state.postCreditCost(for: "retry #tag")
        let cachedCost = await state.postCreditCost(for: "cached #Tag")
        XCTAssertEqual(failedCost, 2)
        XCTAssertEqual(retriedCost, 6)
        XCTAssertEqual(cachedCost, 6)
        XCTAssertEqual(callCount, 2)
    }

    @MainActor
    func testImageDraftBatchPreservesOrderAndSkipsInvalidData() async throws {
        func png(_ color: UIColor) throws -> Data {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
            return try XCTUnwrap(renderer.image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }.pngData())
        }
        let red = try png(.red)
        let blue = try png(.blue)

        let drafts = await ImageDrafts.draftImages(
            from: [red, Data("not-an-image".utf8), blue],
            maxConcurrent: 2
        )

        let expectedRed = try XCTUnwrap(ImageDrafts.draftImage(from: red))
        let expectedBlue = try XCTUnwrap(ImageDrafts.draftImage(from: blue))
        XCTAssertEqual(drafts.map(\.id), [
            expectedRed.id,
            expectedBlue.id,
        ])
        XCTAssertTrue(drafts.allSatisfy { $0.data.count <= ImageDrafts.maxImageBytes })
        XCTAssertTrue(drafts.allSatisfy { String(data: $0.data.prefix(4), encoding: .ascii) == "RIFF" })
    }

    @MainActor
    func testChildStoresKeepUnrelatedStateIndependent() {
        let navigation = NavigationStore()
        let session = SessionStore(config: .from(info: [:]))
        let feed = FeedStore()
        let content = ContentStore()
        let wallet = WalletStorageStore()

        feed.canLoadMoreFeed = true
        navigation.route = .settings

        XCTAssertTrue(feed.canLoadMoreFeed)
        XCTAssertEqual(navigation.route, .settings)
        XCTAssertNil(session.errorMessage)
        XCTAssertNil(content.focusedPost)
        XCTAssertNil(wallet.icpBalanceE8s)
    }

    @MainActor
    func testProfileRouteAndJournalLoadEachEndpointOnce() async throws {
        var userQueryCount = 0
        var journalQueryCount = 0
        let api = makeStubbedAPI { request in
            let method = self.requestMethodAndArg(from: request)?.method
            if method == "user" {
                userQueryCount += 1
            }
            if method == "journal" {
                journalQueryCount += 1
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if method == "journal" {
                let body = Data("[\(String(data: self.postEnvelopeFixture(id: 303), encoding: .utf8)!)]".utf8)
                return (response, Self.queryReply(body))
            }
            return (response, Self.queryReply(Self.userFixture()))
        }
        let state = TaggrAppCoordinator(api: api)

        state.navigateToProfile("alice")
        XCTAssertEqual(userQueryCount, 0)
        await state.loadCurrentRoute()
        let journal = try await state.loadJournalPosts(handle: "alice", page: 0, offset: 0)

        XCTAssertEqual(userQueryCount, 1)
        XCTAssertEqual(journalQueryCount, 1)
        XCTAssertEqual(state.profile?.name, "alice")
        XCTAssertEqual(journal.map(\.id), [303])
    }
}

private actor TaggrTestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}
