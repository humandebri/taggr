import XCTest
import AuthenticationServices
import CryptoKit
import UIKit
import ICNativeClient
@testable import TAGGR

private func realmListJSON(_ names: [String]) -> Data {
    let rows = names.map {
        "[\"\($0)\",{\"description\":\"Builders\",\"label_color\":\"#123456\",\"num_members\":2,\"num_posts\":3}]"
    }
    return Data("[\(rows.joined(separator: ","))]".utf8)
}

extension TaggrTests {
    func testRealmPostingPreferencesKeepScopedRecentDestinations() {
        let suiteName = "RealmPostingPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = RealmPostingPreferences(defaults: defaults)
        let aliceMainnet = RealmPostingScope(canisterID: "mainnet", userID: 7)
        let aliceStaging = RealmPostingScope(canisterID: "staging", userID: 7)
        let bobMainnet = RealmPostingScope(canisterID: "mainnet", userID: 8)

        preferences.record(destination: "DEV", scope: aliceMainnet)
        preferences.record(destination: "ART", scope: aliceMainnet)
        preferences.record(destination: "dev", scope: aliceMainnet)
        preferences.record(destination: nil, scope: aliceMainnet)

        XCTAssertEqual(preferences.recentDestinations(scope: aliceMainnet), ["", "dev", "ART"])
        XCTAssertEqual(
            preferences.validDestinations(scope: aliceMainnet, availableRealms: ["DEV", "OTHER"]),
            ["", "DEV"]
        )
        XCTAssertTrue(preferences.recentDestinations(scope: aliceStaging).isEmpty)
        XCTAssertTrue(preferences.recentDestinations(scope: bobMainnet).isEmpty)
    }

    @MainActor
    func testPostingRealmSelectionUsesContextAndBackendRecency() throws {
        let suiteName = "PostingRealmSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = RealmPostingPreferences(defaults: defaults)
        let state = TaggrAppCoordinator(realmPostingPreferences: preferences)
        state.currentUser = TaggrUser(
            id: 7,
            name: "alice",
            about: "",
            principal: nil,
            realms: ["OTHER", "DEV"],
            followees: [],
            followers: [],
            blacklist: [],
            mode: nil
        )
        let scope = try XCTUnwrap(state.realmPostingScope)
        preferences.record(destination: "OTHER", scope: scope)

        XCTAssertEqual(state.initialPostingRealm(for: .hot), "DEV")
        XCTAssertEqual(state.initialPostingRealm(for: .realm("ART")), "ART")
        XCTAssertEqual(state.recentlyUsedJoinedRealms, ["DEV", "OTHER"])
        XCTAssertEqual(state.orderedPostingRealms(selectedRealm: nil), ["DEV", "OTHER"])
        XCTAssertEqual(state.orderedPostingRealms(selectedRealm: "other"), ["OTHER", "DEV"])
        XCTAssertEqual(state.orderedPostingRealms(selectedRealm: "ART"), ["ART", "DEV", "OTHER"])

        preferences.record(destination: nil, scope: scope)
        XCTAssertEqual(state.initialPostingRealm(for: .latest), "")
    }

    func testLoadRealmsListUsesCurrentUserJoinedRealms() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (
                response,
                Self.queryReply(
                    Data(
                        ##"[{"description":"Newest","label_color":"#123456"},{"description":"Older","label_color":"#654321"}]"##.utf8
                    )
                )
            )
        }
        let state = TaggrAppCoordinator(api: api)
        state.currentUser = TaggrUser(
            id: 7,
            name: "alice",
            about: "",
            principal: nil,
            realms: ["OTHER", "DEV"],
            followees: [],
            followers: [],
            blacklist: [],
            mode: nil
        )

        await state.loadRealmsList()

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.map(\.method), ["realms"])
        XCTAssertEqual(calls.first?.arg, try TaggrCandid.jsonArguments([["DEV", "OTHER"]]))
        XCTAssertEqual(state.realms.map(\.name), ["DEV", "OTHER"])
        XCTAssertEqual(state.realms.map(\.description), ["Newest", "Older"])
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
        XCTAssertEqual(state.nextAllRealmsPage, 1)
        XCTAssertFalse(state.canLoadMoreRealms)
    }

    @MainActor
    func testLoadAllRealmsListAppendsNextPageWithoutDuplicatesAndResets() async throws {
        let pageSize = 20
        let firstPageNames = (0 ..< pageSize).map { "REALM\($0)" }
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let names = switch calls.count {
            case 1: firstPageNames
            case 2: ["REALM19", "REALM20"]
            default: ["REFRESHED"]
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(realmListJSON(names)))
        }
        let state = TaggrAppCoordinator(api: api)

        await state.loadAllRealmsList()

        XCTAssertEqual(state.realms.count, pageSize)
        XCTAssertEqual(state.nextAllRealmsPage, 1)
        XCTAssertTrue(state.canLoadMoreRealms)

        await state.loadAllRealmsList(reset: false)

        let secondCall = try XCTUnwrap(calls.dropFirst().first)
        XCTAssertEqual(secondCall.arg, try TaggrCandid.jsonArguments([TaggrRuntimeConfig.productionDomain, "popularity", 1]))
        XCTAssertEqual(state.realms.count, 21)
        XCTAssertEqual(state.realms.last?.name, "REALM20")
        XCTAssertEqual(state.nextAllRealmsPage, 2)
        XCTAssertFalse(state.canLoadMoreRealms)

        await state.loadAllRealmsList()

        let thirdCall = try XCTUnwrap(calls.dropFirst(2).first)
        XCTAssertEqual(thirdCall.arg, try TaggrCandid.jsonArguments([TaggrRuntimeConfig.productionDomain, "popularity", 0]))
        XCTAssertEqual(state.realms.map(\.name), ["REFRESHED"])
        XCTAssertEqual(state.nextAllRealmsPage, 1)
        XCTAssertFalse(state.canLoadMoreRealms)

        state.nextAllRealmsPage = 4
        state.canLoadMoreRealms = true
        await state.loadRealmsList()

        XCTAssertEqual(state.nextAllRealmsPage, 0)
        XCTAssertFalse(state.canLoadMoreRealms)
    }

    @MainActor
    func testRealmAccessPolicyUsesJoinedAndControlledRealms() {
        let state = TaggrAppCoordinator()
        state.currentUser = TaggrUser(
            id: 7,
            name: "alice",
            about: "",
            principal: nil,
            realms: ["DEV"],
            followees: [],
            followers: [],
            blacklist: [],
            controlledRealms: ["MODS"],
            mode: nil
        )

        XCTAssertTrue(state.isJoinedRealm("dev"))
        XCTAssertFalse(state.isJoinedRealm("MODS"))
        XCTAssertTrue(state.canManageRealm("mods"))
        XCTAssertFalse(state.canManageRealm("DEV"))
    }

    @MainActor
    func testRealmMembershipOperationRejectsConcurrentRequest() async {
        var calls: [String] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call.method)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data("true".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.realmMembershipOperation = "OTHER"

        let result = await state.setRealmMembership(name: "DEV", joined: true)
        XCTAssertFalse(result)
        XCTAssertTrue(calls.isEmpty)
    }

    @MainActor
    func testJoinRealmRefreshesUserAndRealmMetadata() async {
        var calls: [String] = []
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            guard let call = self.requestMethodAndArg(from: request) else {
                return (response, Self.queryReply(Data("null".utf8)))
            }
            calls.append(call.method)
            switch call.method {
            case "toggle_realm_membership":
                return (response, Self.queryReply(Data("true".utf8)))
            case "user":
                return (response, Self.queryReply(Self.realmUserFixture(realms: ["DEV"])))
            case "realms":
                return (response, Self.queryReply(Data(##"[{"description":"Builders","num_members":1}]"##.utf8)))
            default:
                return (response, Self.queryReply(Data("null".utf8)))
            }
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try? JSONDecoder.taggr.decode(TaggrUser.self, from: Self.realmUserFixture(realms: []))
        state.realms = [
            TaggrRealm(name: "DEV", description: "Builders", labelColor: nil, logo: nil, numMembers: 0, numPosts: 0)
        ]

        let result = await state.setRealmMembership(name: "DEV", joined: true)

        XCTAssertTrue(result)
        XCTAssertTrue(state.isJoinedRealm("DEV"))
        XCTAssertEqual(state.realms.first?.numMembers, 1)
        XCTAssertEqual(calls, ["toggle_realm_membership", "user", "realms"])
    }

    @MainActor
    func testLeaveRealmStaysOnRealmAndRefreshesMembership() async {
        var calls: [String] = []
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            guard let call = self.requestMethodAndArg(from: request) else {
                return (response, Self.queryReply(Data("null".utf8)))
            }
            calls.append(call.method)
            switch call.method {
            case "toggle_realm_membership":
                return (response, Self.queryReply(Data("false".utf8)))
            case "user":
                return (response, Self.queryReply(Self.realmUserFixture(realms: [])))
            case "realms":
                return (response, Self.queryReply(Data(##"[{"description":"Builders","num_members":0}]"##.utf8)))
            default:
                return (response, Self.queryReply(Data("null".utf8)))
            }
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try? JSONDecoder.taggr.decode(TaggrUser.self, from: Self.realmUserFixture(realms: ["DEV"]))
        state.route = .realm("DEV")

        let result = await state.setRealmMembership(name: "DEV", joined: false)

        XCTAssertTrue(result)
        XCTAssertFalse(state.isJoinedRealm("DEV"))
        XCTAssertEqual(state.route, .realm("DEV"))
        XCTAssertEqual(calls, ["toggle_realm_membership", "user", "realms"])
    }

    nonisolated static func realmUserFixture(realms: [String]) -> Data {
        let realmJSON = realms.map { "\"\($0)\"" }.joined(separator: ",")
        return Data(
            """
            {
              "id": 7,
              "name": "alice",
              "about": "",
              "principal": null,
              "realms": [\(realmJSON)],
              "followees": [],
              "followers": [],
              "blacklist": [],
              "settings": {},
              "controlled_realms": [],
              "mode": null
            }
            """.utf8
        )
    }

    @MainActor
    func testPostingRealmColorsDoNotMutateRealmOrFeedState() async throws {
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data(##"[{"name":"DEV","description":"","label_color":"#123456"}]"##.utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        let existingRealm = TaggrRealm(
            name: "OLD",
            description: "",
            labelColor: nil,
            logo: nil,
            numMembers: nil,
            numPosts: nil
        )
        state.realms = [existingRealm]
        state.feed = [samplePost(id: 42, body: "hello", files: [:])]

        let colors = await state.postingRealmColors(["DEV"])

        XCTAssertEqual(colors, ["DEV": "#123456"])
        XCTAssertEqual(state.realms, [existingRealm])
        XCTAssertEqual(state.feed.map(\.id), [42])
        XCTAssertNil(state.errorMessage)
    }

    @MainActor
    func testPostingRealmColorFailureFallsBackWithoutGlobalError() async {
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let state = TaggrAppCoordinator(api: api)

        let colors = await state.postingRealmColors(["DEV"])

        XCTAssertEqual(colors, [:])
        XCTAssertNil(state.errorMessage)
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
        let suiteName = "SubmitPostRealmPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = RealmPostingPreferences(defaults: defaults)
        let state = TaggrAppCoordinator(api: api, realmPostingPreferences: preferences)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        let postingScope = try XCTUnwrap(state.realmPostingScope)
        state.route = .feed(.realm("DEV"))

        await state.submitPost(text: "hello", realm: "DEV", reloadMode: .realm("DEV"))

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.map(\.method), ["add_post", "user", "last_posts"])
        XCTAssertEqual(calls.first?.arg, TaggrCandid.encodeAddPost(text: "hello", parent: nil, realm: "DEV"))
        XCTAssertEqual(calls.last?.arg, try TaggrCandid.jsonArguments([TaggrRuntimeConfig.productionDomain, "DEV", 0, 0, true]))
        XCTAssertEqual(state.route, .feed(.realm("DEV")))
        XCTAssertEqual(state.currentUser?.name, "alice")
        XCTAssertEqual(preferences.recentDestinations(scope: postingScope), ["DEV"])
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
        let suiteName = "SubmitPostTaggrPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = RealmPostingPreferences(defaults: defaults)
        let state = TaggrAppCoordinator(api: api, realmPostingPreferences: preferences)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        let postingScope = try XCTUnwrap(state.realmPostingScope)

        await state.submitPost(text: "hello")

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.map(\.method), ["add_post", "user", "hot_posts"])
        XCTAssertEqual(calls.last?.arg, try TaggrCandid.jsonArguments([TaggrRuntimeConfig.productionDomain, "", 0, 0, true]))
        XCTAssertEqual(state.route, .feed(.hot))
        XCTAssertEqual(preferences.recentDestinations(scope: postingScope), [""])
    }

    @MainActor
    func testFailedAndReplyPostsDoNotUpdateRealmPostingPreferences() async throws {
        let suiteName = "UntrackedPostRealmPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = RealmPostingPreferences(defaults: defaults)
        let user = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        let scope = RealmPostingScope(canisterID: TaggrRuntimeConfig.productionCanisterId, userID: user.id)
        preferences.record(destination: "ART", scope: scope)

        let failingAPI = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Self.candidResultErr("denied")))
        }
        let failingState = TaggrAppCoordinator(api: failingAPI, realmPostingPreferences: preferences)
        failingState.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        failingState.currentUser = user

        await failingState.submitPost(text: "hello", realm: "DEV")
        XCTAssertEqual(preferences.recentDestinations(scope: scope), ["ART"])

        let replyAPI = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/query") == true {
                if self.requestMethodAndArg(from: request)?.method == "user" {
                    return (response, Self.queryReply(Self.currentUserFixture()))
                }
                return (response, Self.queryReply(Data("[]".utf8)))
            }
            return (response, Self.queryReply(Self.candidResultOkNat64(42)))
        }
        let replyState = TaggrAppCoordinator(api: replyAPI, realmPostingPreferences: preferences)
        replyState.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        replyState.currentUser = user

        await replyState.submitPost(text: "reply", parent: 42, realm: "DEV")
        XCTAssertEqual(preferences.recentDestinations(scope: scope), ["ART"])
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
        let suiteName = "EditPostRealmPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = RealmPostingPreferences(defaults: defaults)
        let state = TaggrAppCoordinator(api: api, realmPostingPreferences: preferences)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        let postingScope = try XCTUnwrap(state.realmPostingScope)
        preferences.record(destination: "ART", scope: postingScope)
        state.route = .post(42)
        let post = samplePost(id: 42, user: 7, body: "hello", files: [:], realm: "DEV")

        await state.editPost(post: post, text: "updated", realm: "ART", reloadMode: .latest)

        let patch = TaggrEditPatch.fullReplacement(from: "updated", to: "hello")
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.map(\.method), ["edit_post", "user", "thread"])
        XCTAssertEqual(
            calls.first?.arg,
            TaggrCandid.encodeEditPost(id: 42, text: "updated", refs: [], patch: patch, realm: "ART")
        )
        XCTAssertEqual(preferences.recentDestinations(scope: postingScope), ["ART"])
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

        await state.editPost(post: post, text: body, realm: post.realm, images: [image], reloadMode: .latest)

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

        await state.editPost(post: post, text: "updated\n\n![10x20, 1kb](/blob/missing)", realm: post.realm, images: [])

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
    func testAuthorDisplayNameUsesPostMetadataAndFallsBackToUserID() {
        let state = TaggrAppCoordinator()
        let named = samplePost(id: 1, user: 7, body: "hello", files: [:])
        let missing = samplePost(
            id: 2,
            user: 8,
            body: "hello",
            files: [:],
            meta: TaggrPostMeta(authorName: nil, realmColor: nil, nsfw: false, viewerBlocked: false)
        )

        XCTAssertEqual(state.authorDisplayName(for: named), "alice")
        XCTAssertEqual(state.authorProfileHandle(for: named), "alice")
        XCTAssertEqual(state.authorDisplayName(for: missing), "@8")
        XCTAssertNil(state.authorProfileHandle(for: missing))
    }

    @MainActor
    func testLoadPostFocusesRequestedReplyAtEndOfThread() async {
        let rootEnvelope = try! JSONSerialization.jsonObject(with: postEnvelopeFixture(id: 100)) as! [Any]
        let replyEnvelope = try! JSONSerialization.jsonObject(
            with: postEnvelopeFixture(id: 101, parent: 100)
        ) as! [Any]
        let threadBody = try! JSONSerialization.data(withJSONObject: [rootEnvelope, replyEnvelope])
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(threadBody))
        }
        let state = TaggrAppCoordinator(api: api)
        state.navigateToPost(101)

        await state.loadPost(101)

        XCTAssertEqual(state.feed.map(\.id), [100, 101])
        XCTAssertEqual(state.focusedPost?.id, 101)
        XCTAssertEqual(state.focusedPost?.parent, 100)
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
    func testLoadMoreFeedUsesScopedStateAndIgnoresDuplicateRequest() async {
        let requestStarted = expectation(description: "feed load more started")
        let releaseRequest = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var requestCount = 0
        let api = makeStubbedAPI { request in
            lock.lock()
            requestCount += 1
            lock.unlock()
            requestStarted.fulfill()
            _ = releaseRequest.wait(timeout: .now() + 5)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data("[]".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.canLoadMoreFeed = true

        let firstRequest = Task { await state.loadMoreFeed(mode: .hot) }
        await fulfillment(of: [requestStarted], timeout: 1)

        XCTAssertTrue(state.isLoadingMoreFeed)
        XCTAssertTrue(state.isBusy)

        await state.loadMoreFeed(mode: .hot)
        let countWhileLoading = lock.withLock { requestCount }
        XCTAssertEqual(countWhileLoading, 1)

        releaseRequest.signal()
        await firstRequest.value
        XCTAssertFalse(state.isLoadingMoreFeed)
    }

    @MainActor
    func testLoadMoreRealmsUsesScopedStateAndIgnoresDuplicateRequest() async {
        let requestStarted = expectation(description: "realm load more started")
        let releaseRequest = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var requestCount = 0
        let api = makeStubbedAPI { request in
            lock.lock()
            requestCount += 1
            lock.unlock()
            requestStarted.fulfill()
            _ = releaseRequest.wait(timeout: .now() + 5)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data("[]".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.canLoadMoreRealms = true

        let firstRequest = Task { await state.loadAllRealmsList(reset: false) }
        await fulfillment(of: [requestStarted], timeout: 1)

        XCTAssertTrue(state.isLoadingMoreRealms)
        XCTAssertTrue(state.isBusy)

        await state.loadAllRealmsList(reset: false)
        let countWhileLoading = lock.withLock { requestCount }
        XCTAssertEqual(countWhileLoading, 1)

        releaseRequest.signal()
        await firstRequest.value
        XCTAssertFalse(state.isLoadingMoreRealms)
    }

    @MainActor
    func testLoadMoreScopedStatesResetAfterFailureAndCancellation() async {
        let failureAPI = makeStubbedAPI { _ in
            throw URLError(.cannotConnectToHost)
        }
        let failedFeedState = TaggrAppCoordinator(api: failureAPI)
        failedFeedState.canLoadMoreFeed = true
        await failedFeedState.loadMoreFeed(mode: .hot)
        XCTAssertFalse(failedFeedState.isLoadingMoreFeed)

        let cancelledAPI = makeStubbedAPI { _ in
            throw URLError(.cancelled)
        }
        let cancelledRealmState = TaggrAppCoordinator(api: cancelledAPI)
        cancelledRealmState.canLoadMoreRealms = true
        await cancelledRealmState.loadAllRealmsList(reset: false)
        XCTAssertFalse(cancelledRealmState.isLoadingMoreRealms)
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
