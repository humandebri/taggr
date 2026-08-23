import XCTest
import AuthenticationServices
import CryptoKit
import UIKit
import ICNativeClient
@testable import TAGGR

extension TaggrTests {
    func testLoadRealmsListUsesCurrentUserJoinedRealms() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data(##"[{"name":"DEV","description":"Builders","label_color":"#123456","num_members":2,"num_posts":3}]"##.utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.currentUser = TaggrUser(
            id: 7,
            name: "alice",
            about: "",
            principal: nil,
            realms: ["DEV"],
            followees: [],
            followers: [],
            blacklist: [],
            mode: nil
        )

        await state.loadRealmsList()

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.map(\.method), ["realms"])
        XCTAssertEqual(calls.first?.arg, try TaggrCandid.jsonArguments([["DEV"]]))
        XCTAssertEqual(state.realms.map(\.name), ["DEV"])
        XCTAssertEqual(state.realms.first?.description, "Builders")
    }

    @MainActor
    func testLoadAllRealmsListUsesAllRealmsQuery() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data(##"[["DEV",{"description":"Builders","label_color":"#123456","num_members":2,"num_posts":3}]]"##.utf8)))
        }
        let state = TaggrAppCoordinator(api: api)

        await state.loadAllRealmsList()

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.map(\.method), ["all_realms"])
        XCTAssertEqual(calls.first?.arg, try TaggrCandid.jsonArguments([TaggrRuntimeConfig.productionDomain, "popularity", 0]))
        XCTAssertEqual(state.realms.map(\.name), ["DEV"])
        XCTAssertEqual(state.realms.first?.description, "Builders")
    }

    @MainActor
    func testSettingsRefreshUpdatesWalletBalance() async throws {
        var calls: [(method: String, path: String)] = []
        let api = makeStubbedAPI { request in
            let method = self.requestMethodAndArg(from: request)?.method ?? ""
            calls.append((method, request.url?.path ?? ""))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            switch method {
            case "stats":
                return (response, Self.queryReply(Data(#"{"canister_id":"\#(TaggrRuntimeConfig.productionCanisterId)"}"#.utf8)))
            case "config":
                return (response, Self.queryReply(Data(#"{"feed_page_size":30}"#.utf8)))
            case "user":
                return (response, Self.queryReply(Self.currentUserFixture()))
            case "account_balance":
                return (response, Self.queryReply(Self.candidTokens(200_000_000)))
            case "bucket_wasm_hash":
                return (response, Self.queryReply(Data(#""010203""#.utf8)))
            default:
                return (response, Self.queryReply(Data("null".utf8)))
            }
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.route = .settings

        await state.refreshVisibleRoute()

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(Set(calls.prefix(2).map(\.method)), Set(["stats", "config"]))
        XCTAssertEqual(Array(calls.dropFirst(2).map(\.method)), ["user", "account_balance", "user", "bucket_wasm_hash"])
        XCTAssertTrue(calls.first { $0.method == "account_balance" }?.path.contains(TaggrAPI.icpLedgerCanisterId) == true)
        XCTAssertEqual(state.currentUser?.name, "alice")
        XCTAssertEqual(state.icpBalanceE8s, 200_000_000)
        XCTAssertEqual(state.storageExpectedWasmHash, "010203")
    }

    @MainActor
    func testSubmitPostPassesRealmAndReloadsRealmFeed() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/query") == true {
                if calls.last?.method == "user" {
                    return (response, Self.queryReply(Self.currentUserFixture()))
                }
                return (response, Self.queryReply(Data("[]".utf8)))
            }
            return (response, Self.queryReply(Self.candidResultOkNat64(42)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.route = .feed(.realm("DEV"))

        await state.submitPost(text: "hello", realm: "DEV", reloadMode: .realm("DEV"))

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.map(\.method), ["add_post", "user", "last_posts"])
        XCTAssertEqual(calls.first?.arg, TaggrCandid.encodeAddPost(text: "hello", parent: nil, realm: "DEV"))
        XCTAssertEqual(calls.last?.arg, try TaggrCandid.jsonArguments([TaggrRuntimeConfig.productionDomain, "DEV", 0, 0, true]))
        XCTAssertEqual(state.route, .feed(.realm("DEV")))
        XCTAssertEqual(state.currentUser?.name, "alice")
    }

    @MainActor
    func testSubmitPostStaysOnCurrentFeedAndReloadsIt() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/query") == true {
                if calls.last?.method == "user" {
                    return (response, Self.queryReply(Self.currentUserFixture()))
                }
                return (response, Self.queryReply(Data("[]".utf8)))
            }
            return (response, Self.queryReply(Self.candidResultOkNat64(42)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())

        await state.submitPost(text: "hello")

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.map(\.method), ["add_post", "user", "hot_posts"])
        XCTAssertEqual(calls.last?.arg, try TaggrCandid.jsonArguments([TaggrRuntimeConfig.productionDomain, "", 0, 0, true]))
        XCTAssertEqual(state.route, .feed(.hot))
    }

    @MainActor
    func testSubmitPostFromTagFeedReloadsTagFeed() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/query") == true {
                if calls.last?.method == "user" {
                    return (response, Self.queryReply(Self.currentUserFixture()))
                }
                return (response, Self.queryReply(Data("[]".utf8)))
            }
            return (response, Self.queryReply(Self.candidResultOkNat64(42)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.route = .feed(.tags(["tag"]))

        await state.submitPost(text: "hello #tag", reloadMode: .tags(["tag"]))

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.map(\.method), ["add_post", "user", "posts_by_tags"])
        XCTAssertEqual(calls.last?.arg, try TaggrCandid.jsonArguments([TaggrRuntimeConfig.productionDomain, "", ["tag"], 0, 0]))
        XCTAssertEqual(state.route, .feed(.tags(["tag"])))
    }

    func testRootPostKeepsSelectedTimeline() {
        XCTAssertEqual(PostComposerMode.newPost(selectedMode: .hot).timelineModeAfterSubmit, .hot)
        XCTAssertEqual(PostComposerMode.newPost(selectedMode: .personal).timelineModeAfterSubmit, .personal)
        XCTAssertEqual(PostComposerMode.newPost(selectedMode: .realm("DEV")).timelineModeAfterSubmit, .realm("DEV"))
        XCTAssertEqual(PostComposerMode.newPost(selectedMode: .tags(["tag"])).timelineModeAfterSubmit, .tags(["tag"]))
    }

    @MainActor
    func testReplyPostPassesParentAndReloadsCurrentRoute() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/query") == true {
                if calls.last?.method == "user" {
                    return (response, Self.queryReply(Self.currentUserFixture()))
                }
                return (response, Self.queryReply(Data("[]".utf8)))
            }
            return (response, Self.queryReply(Self.candidResultOkNat64(43)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.route = .post(42)

        await state.submitPost(text: "reply", parent: 42, realm: "DEV", reloadMode: .latest)

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.map(\.method), ["add_post", "user", "thread", "thread"])
        XCTAssertEqual(calls.first?.arg, TaggrCandid.encodeAddPost(text: "reply", parent: 42, realm: "DEV"))
        XCTAssertEqual(state.repliesByPostID[42], [])
    }

    @MainActor
    func testEditPostPassesPatchAndReloadsCurrentRoute() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/query") == true {
                if calls.last?.method == "user" {
                    return (response, Self.queryReply(Self.currentUserFixture()))
                }
                return (response, Self.queryReply(Data("[]".utf8)))
            }
            return (response, Self.queryReply(Self.candidResultOkNat64(42)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.route = .post(42)
        let post = samplePost(id: 42, user: 7, body: "hello", files: [:], realm: "DEV")

        await state.editPost(post: post, text: "updated", reloadMode: .latest)

        let patch = TaggrEditPatch.fullReplacement(from: "updated", to: "hello")
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.map(\.method), ["edit_post", "user", "thread"])
        XCTAssertEqual(
            calls.first?.arg,
            TaggrCandid.encodeEditPost(id: 42, text: "updated", refs: [], patch: patch, realm: "DEV")
        )
    }

    @MainActor
    func testEditPostUploadsImageBeforeEditPost() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if calls.last?.method == "write" {
                return (response, Self.queryReply(Data([0, 0, 0, 0, 0, 0, 0, 7])))
            }
            if request.url?.path.hasSuffix("/query") == true {
                if calls.last?.method == "user" {
                    return (response, Self.queryReply(Self.currentUserFixture()))
                }
                return (response, Self.queryReply(Data("[]".utf8)))
            }
            return (response, Self.queryReply(Self.candidResultOkNat64(42)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = TaggrUser(
            id: 7,
            name: "alice",
            about: "",
            principal: nil,
            realms: ["DEV"],
            followees: [],
            followers: [],
            blacklist: [],
            bucket: "aaaaa-aa",
            mode: nil
        )
        state.route = .post(42)
        let post = samplePost(id: 42, user: 7, body: "hello", files: [:], realm: "DEV")
        let image = TaggrDraftImage(id: "abc12345", data: Data([1, 2, 3]), width: 10, height: 20)
        let body = "updated\n\n\(image.markdown)"

        await state.editPost(post: post, text: body, images: [image], reloadMode: .latest)

        let patch = TaggrEditPatch.fullReplacement(from: body, to: "hello")
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.map(\.method), ["write", "edit_post", "user", "thread"])
        XCTAssertEqual(calls.first?.arg, Data([1, 2, 3]))
        XCTAssertEqual(
            calls.dropFirst().first?.arg,
            TaggrCandid.encodeEditPost(
                id: 42,
                text: body,
                refs: [(id: "abc12345", offset: 7, length: 3)],
                patch: patch,
                realm: "DEV"
            )
        )
    }

    @MainActor
    func testSubmitPostUploadsDuplicateImageAttachmentsWithUniqueRefs() async throws {
        var calls: [(method: String, arg: Data)] = []
        var writeCount = 0
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if calls.last?.method == "write" {
                writeCount += 1
                return (response, Self.queryReply(Data([0, 0, 0, 0, 0, 0, 0, UInt8(6 + writeCount)])))
            }
            if request.url?.path.hasSuffix("/query") == true {
                if calls.last?.method == "user" {
                    return (response, Self.queryReply(Self.currentUserFixture()))
                }
                return (response, Self.queryReply(Data("[]".utf8)))
            }
            return (response, Self.queryReply(Self.candidResultOkNat64(42)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = TaggrUser(
            id: 7,
            name: "alice",
            about: "",
            principal: nil,
            realms: [],
            followees: [],
            followers: [],
            blacklist: [],
            bucket: "aaaaa-aa",
            mode: nil
        )
        let image = TaggrDraftImage(id: "abc12345", data: Data([1, 2, 3]), width: 10, height: 20)
        let images = ImageDrafts.uniquedDraftImages([image, image], existingIDs: [])
        let body = images.map(\.markdown).joined(separator: "\n")

        await state.submitPost(text: body, images: images, reloadMode: .hot)

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.map(\.method), ["write", "write", "add_post", "user", "hot_posts"])
        XCTAssertEqual(calls[0].arg, Data([1, 2, 3]))
        XCTAssertEqual(calls[1].arg, Data([1, 2, 3]))
        XCTAssertEqual(
            calls[2].arg,
            TaggrCandid.encodeAddPost(
                text: body,
                refs: [
                    (id: "abc12345", offset: 7, length: 3),
                    (id: "abc12301", offset: 8, length: 3),
                ],
                parent: nil,
                realm: nil
            )
        )
    }

    @MainActor
    func testSubmitPostWithImageRequiresMediaBucket() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Self.candidResultOkNat64(42)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = TaggrUser(
            id: 7,
            name: "alice",
            about: "",
            principal: nil,
            realms: [],
            followees: [],
            followers: [],
            blacklist: [],
            bucket: nil,
            mode: nil
        )
        let image = TaggrDraftImage(id: "abc12345", data: Data([1, 2, 3]), width: 10, height: 20)

        await state.submitPost(text: image.markdown, images: [image], reloadMode: .latest)

        XCTAssertEqual(state.errorMessage, "No personal media bucket configured. Set one up under Settings > Storage.")
        XCTAssertEqual(calls.map(\.method), [])
    }

    @MainActor
    func testSubmitPostRejectsEditedDraftImageMarkerBeforeSaving() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Self.candidResultOkNat64(42)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = TaggrUser(
            id: 7,
            name: "alice",
            about: "",
            principal: nil,
            realms: [],
            followees: [],
            followers: [],
            blacklist: [],
            bucket: "aaaaa-aa",
            mode: nil
        )
        let image = TaggrDraftImage(id: "abc12345", data: Data([1, 2, 3]), width: 10, height: 20)

        await state.submitPost(text: "!([10x20, 1kb](/blob/abc12345)]", images: [image], reloadMode: .latest)

        XCTAssertEqual(state.errorMessage, "Attached image marker was edited. Remove and attach the image again.")
        XCTAssertEqual(calls.map(\.method), [])
    }

    @MainActor
    func testEditPostRejectsMissingBlobReferenceBeforeSaving() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Self.candidResultOkNat64(42)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = TaggrUser(
            id: 7,
            name: "alice",
            about: "",
            principal: nil,
            realms: [],
            followees: [],
            followers: [],
            blacklist: [],
            bucket: "aaaaa-aa",
            mode: nil
        )
        let post = samplePost(id: 42, user: 7, body: "hello", files: [:], realm: nil)

        await state.editPost(post: post, text: "updated\n\n![10x20, 1kb](/blob/missing)", images: [])

        XCTAssertEqual(state.errorMessage, "You're referencing pictures that are not attached anymore. Please re-upload.")
        XCTAssertEqual(calls.map(\.method), [])
    }

    @MainActor
    func testLoadRepliesSkipsThreadWhenPostHasNoChildren() async throws {
        var calls: [String] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call.method)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data(#"{"Err":"thread should not be called"}"#.utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        let post = samplePost(body: "hello", files: [:], treeSize: 1)

        await state.loadReplies(for: post)

        XCTAssertEqual(calls, [])
        XCTAssertEqual(state.repliesByPostID[post.id], [])
        XCTAssertNil(state.errorMessage)
    }

    @MainActor
    func testReactPassesSelectedReactionId() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/query") == true {
                if calls.last?.method == "user" {
                    return (response, Self.queryReply(Self.currentUserFixture()))
                }
                return (response, Self.queryReply(Data("[]".utf8)))
            }
            return (response, Self.queryReply(Data("null".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())

        await state.react(postId: 42, reaction: 53)

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.first?.method, "react")
        XCTAssertEqual(calls.first?.arg, try TaggrCandid.jsonArguments([42, 53]))
    }

    @MainActor
    func testReactRollsBackVisiblePostsOnFailure() async throws {
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data("denied".utf8))
        }
        let state = TaggrAppCoordinator(api: api)
        let post = samplePost(id: 42, body: "hello", reactions: [:], files: [:])
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        state.feed = [post]
        state.focusedPost = post
        state.repliesByPostID = [100: [post]]

        await state.react(postId: 42, reaction: 53)

        XCTAssertNotNil(state.errorMessage)
        XCTAssertNil(state.feed.first?.reactions["53"])
        XCTAssertNil(state.focusedPost?.reactions["53"])
        XCTAssertNil(state.repliesByPostID[100]?.first?.reactions["53"])
    }

    @MainActor
    func testBookmarkAndWatchUsePostUpdateMethods() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/query") == true {
                if calls.last?.method == "user" {
                    return (response, Self.queryReply(Self.currentUserFixture()))
                }
                return (response, Self.queryReply(Data("[]".utf8)))
            }
            return (response, Self.queryReply(Data("true".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())

        await state.toggleBookmark(postId: 42)
        await state.toggleFollowingPost(postId: 42)

        let updates = calls.filter { $0.method == "toggle_bookmark" || $0.method == "toggle_following_post" }
        XCTAssertEqual(updates.map(\.method), ["toggle_bookmark", "toggle_following_post"])
        XCTAssertEqual(updates.map(\.arg), [
            try TaggrCandid.jsonArguments([42]),
            try TaggrCandid.jsonArguments([42]),
        ])
    }

    @MainActor
    func testAvatarUpdateSendsMergedSettingsAndRefreshesUser() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/query") == true, calls.last?.method == "user" {
                return (
                    response,
                    Self.queryReply(Data(#"{"id":7,"name":"alice","about":"","principal":null,"realms":[],"followees":[],"followers":[],"blacklist":[],"settings":{"tap_and_hold":"350","avatar_url":"https://example.com/icon.png"},"controlled_realms":[],"mode":null}"#.utf8))
                )
            }
            return (response, Self.queryReply(Data("null".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = TaggrUser(
            id: 7,
            name: "alice",
            about: "",
            principal: nil,
            realms: [],
            followees: [],
            followers: [],
            blacklist: [],
            settings: ["tap_and_hold": "350"],
            mode: nil
        )

        await state.updateCurrentUserAvatarURL(" https://example.com/icon.png ")

        let update = try XCTUnwrap(calls.first { $0.method == "update_user_settings" })
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: update.arg) as? [String: String])
        XCTAssertEqual(settings["tap_and_hold"], "350")
        XCTAssertEqual(settings[TaggrAvatar.settingKey], "https://example.com/icon.png")
        XCTAssertEqual(state.currentUser?.avatarURLString, "https://example.com/icon.png")
        let authoredPost = samplePost(id: 42, user: 7, body: "hello", files: [:])
        XCTAssertEqual(state.avatarURLString(for: authoredPost), "https://example.com/icon.png")
        XCTAssertNil(state.errorMessage)
    }

    @MainActor
    func testAuthorAvatarUsesCachedProfileWhenPostMetaAvatarMissing() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if calls.last?.method == "user" {
                return (response, Self.queryReply(Self.userFixture(avatarURL: "https://example.com/alice.png")))
            }
            return (response, Self.queryReply(Data("null".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        let post = samplePost(id: 42, user: 7, body: "hello", files: [:])

        XCTAssertNil(state.avatarURLString(for: post))
        await state.prefetchAuthorProfile(for: post)

        XCTAssertEqual(state.avatarURLString(for: post), "https://example.com/alice.png")
        XCTAssertEqual(calls.map(\.method), ["user"])
        XCTAssertNil(state.errorMessage)
    }

    @MainActor
    func testAuthorProfilePrefetchDeduplicatesCachedUsers() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if calls.last?.method == "user" {
                return (response, Self.queryReply(Self.userFixture(avatarURL: "https://example.com/alice.png")))
            }
            return (response, Self.queryReply(Data("null".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        let first = samplePost(id: 1, user: 7, body: "hello", files: [:])
        let second = samplePost(id: 2, user: 7, body: "again", files: [:])

        await state.prefetchAuthorProfile(for: first)
        await state.prefetchAuthorProfile(for: second)

        XCTAssertEqual(calls.filter { $0.method == "user" }.count, 1)
        XCTAssertEqual(state.avatarURLString(for: second), "https://example.com/alice.png")
        XCTAssertNil(state.errorMessage)
    }

    @MainActor
    func testAuthorProfilePrefetchDeduplicatesUsersWithoutAvatars() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if calls.last?.method == "user" {
                return (response, Self.queryReply(Self.userFixture()))
            }
            return (response, Self.queryReply(Data("null".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        let first = samplePost(id: 1, user: 7, body: "hello", files: [:])
        let second = samplePost(id: 2, user: 7, body: "again", files: [:])

        await state.prefetchAuthorProfile(for: first)
        await state.prefetchAuthorProfile(for: second)

        XCTAssertEqual(calls.filter { $0.method == "user" }.count, 1)
        XCTAssertEqual(state.authorDisplayName(for: second), "alice")
        XCTAssertNil(state.avatarURLString(for: second))
        XCTAssertNil(state.errorMessage)
    }

    @MainActor
    func testAuthorProfilePrefetchResolvesMissingAuthorNameWithUsersData() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            switch calls.last?.method {
            case "users_data":
                return (response, Self.queryReply(Data(#"{"7":"alice"}"#.utf8)))
            case "user":
                return (response, Self.queryReply(Self.userFixture(avatarURL: "https://example.com/alice.png")))
            default:
                return (response, Self.queryReply(Data("null".utf8)))
            }
        }
        let state = TaggrAppCoordinator(api: api)
        let post = samplePost(
            id: 42,
            user: 7,
            body: "hello",
            files: [:],
            meta: TaggrPostMeta(authorName: nil, realmColor: nil, nsfw: false, viewerBlocked: false)
        )

        await state.prefetchAuthorProfile(for: post)

        XCTAssertEqual(calls.map(\.method), ["users_data", "user"])
        XCTAssertEqual(state.authorDisplayName(for: post), "alice")
        XCTAssertEqual(state.avatarURLString(for: post), "https://example.com/alice.png")
        XCTAssertNil(state.errorMessage)
    }

    @MainActor
    func testAuthorProfilePrefetchFailureRecordsRetryWithoutBanner() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let status = calls.last?.method == "user" ? 500 : 200
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data("null".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        let post = samplePost(id: 42, user: 7, body: "hello", files: [:])

        await state.prefetchAuthorProfile(for: post)
        await state.prefetchAuthorProfile(for: post)

        XCTAssertNil(state.avatarURLString(for: post))
        XCTAssertNil(state.errorMessage)
        XCTAssertNotNil(state.authorProfileRetryAfter[7])
        XCTAssertEqual(calls.filter { $0.method == "user" }.count, 1)
    }

    @MainActor
    func testAuthorProfileCacheEvictsOldEntriesAtLimit() async throws {
        var userQueryCount = 0
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if self.requestMethodAndArg(from: request)?.method == "user" {
                userQueryCount += 1
                return (
                    response,
                    Self.queryReply(Self.userFixture(
                        id: userQueryCount,
                        name: "user\(userQueryCount)",
                        avatarURL: "https://example.com/\(userQueryCount).png"
                    ))
                )
            }
            return (response, Self.queryReply(Data("null".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)

        for userID in 1...501 {
            let post = samplePost(
                id: userID,
                user: userID,
                body: "hello",
                files: [:],
                meta: TaggrPostMeta(authorName: "user\(userID)", realmColor: nil, nsfw: false, viewerBlocked: false)
            )
            await state.prefetchAuthorProfile(for: post)
        }

        let evicted = samplePost(
            id: 1,
            user: 1,
            body: "hello",
            files: [:],
            meta: TaggrPostMeta(authorName: "user1", realmColor: nil, nsfw: false, viewerBlocked: false)
        )
        let newest = samplePost(
            id: 501,
            user: 501,
            body: "hello",
            files: [:],
            meta: TaggrPostMeta(authorName: "user501", realmColor: nil, nsfw: false, viewerBlocked: false)
        )

        XCTAssertEqual(state.authorProfilesByUserID.count, 500)
        XCTAssertEqual(state.authorNamesByUserID.count, 500)
        XCTAssertNil(state.avatarURLString(for: evicted))
        XCTAssertEqual(state.avatarURLString(for: newest), "https://example.com/501.png")
    }

    @MainActor
    func testAuthorProfileRetryCacheEvictsOldFailuresAtLimit() async throws {
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if self.requestMethodAndArg(from: request)?.method == "user" {
                return (response, Self.queryReply(Self.userFixture(id: 999_999, name: "wrong")))
            }
            return (response, Self.queryReply(Data("null".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)

        for userID in 1...501 {
            let post = samplePost(
                id: userID,
                user: userID,
                body: "hello",
                files: [:],
                meta: TaggrPostMeta(authorName: "user\(userID)", realmColor: nil, nsfw: false, viewerBlocked: false)
            )
            await state.prefetchAuthorProfile(for: post)
        }

        XCTAssertEqual(state.authorProfileRetryAfter.count, 500)
        XCTAssertEqual(state.authorNamesByUserID.count, 500)
        XCTAssertNil(state.authorProfileRetryAfter[1])
        XCTAssertNotNil(state.authorProfileRetryAfter[501])
    }

    @MainActor
    func testLoadMoreFeedUsesNextPageAndStableOffset() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if calls.count == 1 {
                return (response, Self.queryReply(Data("[\(String(data: self.postEnvelopeFixture(id: 101), encoding: .utf8)!)]".utf8)))
            }
            return (response, Self.queryReply(Data("[]".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.cache = TaggrBackendCache(
            stats: nil,
            config: try JSONDecoder.taggr.decode(TaggrConfig.self, from: Data(#"{"feed_page_size":1}"#.utf8))
        )

        await state.loadFeed(mode: .hot, reset: true)
        await state.loadMoreFeed(mode: .hot)

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.map(\.method), ["hot_posts", "hot_posts"])
        XCTAssertEqual(calls.map(\.arg), [
            try TaggrCandid.jsonArguments([TaggrRuntimeConfig.productionDomain, "", 0, 0, true]),
            try TaggrCandid.jsonArguments([TaggrRuntimeConfig.productionDomain, "", 1, 101, true]),
        ])
        XCTAssertEqual(state.feed.map(\.id), [101])
        XCTAssertFalse(state.canLoadMoreFeed)
    }

    @MainActor
    func testLoadMoreTagFeedKeepsTagFilter() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if calls.count == 1 {
                return (response, Self.queryReply(Data("[\(String(data: self.postEnvelopeFixture(id: 101), encoding: .utf8)!)]".utf8)))
            }
            return (response, Self.queryReply(Data("[]".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.cache = TaggrBackendCache(
            stats: nil,
            config: try JSONDecoder.taggr.decode(TaggrConfig.self, from: Data(#"{"feed_page_size":1}"#.utf8))
        )

        await state.loadFeed(mode: .tags(["tag"]), reset: true)
        await state.loadMoreFeed(mode: .tags(["tag"]))

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.map(\.method), ["posts_by_tags", "posts_by_tags"])
        XCTAssertEqual(calls.map(\.arg), [
            try TaggrCandid.jsonArguments([TaggrRuntimeConfig.productionDomain, "", ["tag"], 0, 0]),
            try TaggrCandid.jsonArguments([TaggrRuntimeConfig.productionDomain, "", ["tag"], 1, 101]),
        ])
        XCTAssertEqual(state.feed.map(\.id), [101])
        XCTAssertFalse(state.canLoadMoreFeed)
    }

    @MainActor
    func testJournalPostsUseJournalQueryAndStableOffset() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data("[]".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)

        _ = try await state.loadJournalPosts(handle: "alice", page: 0, offset: 0)
        _ = try await state.loadJournalPosts(handle: "alice", page: 1, offset: 101)

        XCTAssertEqual(calls.map(\.method), ["journal", "journal"])
        XCTAssertEqual(calls.map(\.arg), [
            try TaggrCandid.jsonArguments([TaggrRuntimeConfig.productionDomain, "alice", 0, 0]),
            try TaggrCandid.jsonArguments([TaggrRuntimeConfig.productionDomain, "alice", 1, 101]),
        ])
    }
}
