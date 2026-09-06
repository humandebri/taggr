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
            return (response, Self.queryReply(Self.candidAddPostResultOk(42)))
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

        let outcome = await state.submitPost(text: "hello", realm: "DEV", reloadMode: .realm("DEV"))

        XCTAssertEqual(outcome, .submitted)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.first?.method, "add_post")
        XCTAssertEqual(Set(calls.dropFirst().map(\.method)), Set(["user", "last_posts"]))
        XCTAssertEqual(calls.first?.arg, try TaggrCandidAdapter.addPostArguments(text: "hello", refs: [], parent: nil, realm: "DEV", extensionBlob: nil).encode())
        XCTAssertEqual(
            calls.first { $0.method == "last_posts" }?.arg,
            try TaggrCandid.jsonArguments([TaggrRuntimeConfig.productionDomain, "DEV", 0, 0, true])
        )
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
            return (response, Self.queryReply(Self.candidAddPostResultOk(42)))
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
        XCTAssertEqual(calls.first?.method, "add_post")
        XCTAssertEqual(Set(calls.dropFirst().map(\.method)), Set(["user", "hot_posts"]))
        XCTAssertEqual(
            calls.first { $0.method == "hot_posts" }?.arg,
            try TaggrCandid.jsonArguments([TaggrRuntimeConfig.productionDomain, "", 0, 0, true])
        )
        XCTAssertEqual(state.route, .feed(.hot))
        XCTAssertEqual(preferences.recentDestinations(scope: postingScope), [""])
    }

    @MainActor
    func testEnqueuedPostReturnsBeforeUpdateReplyAndRejectsDuplicateDraft() async throws {
        let requestStarted = expectation(description: "add_post started")
        let releaseRequest = DispatchSemaphore(value: 0)
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let method = self.requestMethodAndArg(from: request)?.method
            if method == "add_post" {
                requestStarted.fulfill()
                _ = releaseRequest.wait(timeout: .now() + 5)
                return (response, Self.queryReply(Self.candidAddPostResultOk(42)))
            }
            if request.url?.path.hasSuffix("/query") == true {
                if method == "user" {
                    return (response, Self.queryReply(Self.currentUserFixture()))
                }
                return (response, Self.queryReply(Data("[]".utf8)))
            }
            return (response, Self.queryReply(Data()))
        }
        let rootURL = URL.temporaryDirectory
            .appending(path: "EnqueuedPostTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = PostDraftStore(rootURL: rootURL)
        let state = TaggrAppCoordinator(api: api, postDraftStore: store)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        state.route = .feed(.hot)
        let namespace = PostDraftNamespace(canisterID: state.runtimeConfig.canisterId, userID: 7)
        let draft = PostDraftSession(context: .newPost, initialText: "", initialRealm: "")
        await draft.load(store: store, namespace: namespace)
        draft.text = "hello"
        let draftSaved = await draft.markSubmissionNeedsVerification()
        XCTAssertTrue(draftSaved)

        XCTAssertTrue(state.enqueuePostSubmission(text: "hello", reloadMode: .hot, draft: draft))
        XCTAssertFalse(state.enqueuePostSubmission(text: "hello", reloadMode: .hot, draft: draft))
        XCTAssertEqual(state.postSubmissionNotice?.phase, .submitting)
        XCTAssertFalse(state.isBusy)
        let task = try XCTUnwrap(state.postSubmissionTasks[.newPost])

        await fulfillment(of: [requestStarted], timeout: 1)
        XCTAssertTrue(state.isPostSubmissionPending(.newPost))
        releaseRequest.signal()
        await task.value

        XCTAssertFalse(state.isPostSubmissionPending(.newPost))
        XCTAssertEqual(state.postSubmissionNotice?.phase, .succeeded)
        XCTAssertFalse(draft.hasChanges)
    }

    @MainActor
    func testEnqueuedPostFinishesBeforeBackgroundReconciliation() async throws {
        let userRefreshStarted = expectation(description: "user refresh started")
        let releaseQueries = DispatchSemaphore(value: 0)
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let method = self.requestMethodAndArg(from: request)?.method
            if request.url?.path.hasSuffix("/query") == true {
                if method == "user" {
                    userRefreshStarted.fulfill()
                }
                _ = releaseQueries.wait(timeout: .now() + 5)
                let body = method == "user" ? Self.currentUserFixture() : Data("[]".utf8)
                return (response, Self.queryReply(body))
            }
            return (response, Self.queryReply(Self.candidAddPostResultOk(42)))
        }
        let rootURL = URL.temporaryDirectory
            .appending(path: "PostReconciliationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            releaseQueries.signal()
            releaseQueries.signal()
            try? FileManager.default.removeItem(at: rootURL)
        }
        let store = PostDraftStore(rootURL: rootURL)
        let state = TaggrAppCoordinator(api: api, postDraftStore: store)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        state.route = .feed(.hot)
        let namespace = PostDraftNamespace(canisterID: state.runtimeConfig.canisterId, userID: 7)
        let draft = PostDraftSession(context: .newPost, initialText: "", initialRealm: "")
        await draft.load(store: store, namespace: namespace)
        draft.text = "hello"
        await draft.markSubmissionNeedsVerification()

        XCTAssertTrue(state.enqueuePostSubmission(text: "hello", reloadMode: .hot, draft: draft))
        let submission = try XCTUnwrap(state.postSubmissionTasks[.newPost])
        await submission.value

        XCTAssertFalse(state.hasPendingPostSubmission)
        XCTAssertEqual(state.postSubmissionNotice?.phase, .succeeded)
        XCTAssertFalse(draft.hasChanges)
        await fulfillment(of: [userRefreshStarted], timeout: 1)
    }

    @MainActor
    func testEnqueuedPostDoesNotRefreshStaleFeedRoute() async throws {
        let updateStarted = expectation(description: "add_post started")
        let userRefreshFinished = expectation(description: "user refresh finished")
        let releaseUpdate = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var methods: [String] = []
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let method = self.requestMethodAndArg(from: request)?.method ?? ""
            lock.withLock { methods.append(method) }
            if method == "add_post" {
                updateStarted.fulfill()
                _ = releaseUpdate.wait(timeout: .now() + 5)
                return (response, Self.queryReply(Self.candidAddPostResultOk(42)))
            }
            if method == "user" {
                userRefreshFinished.fulfill()
                return (response, Self.queryReply(Self.currentUserFixture()))
            }
            return (response, Self.queryReply(Data("[]".utf8)))
        }
        let rootURL = URL.temporaryDirectory
            .appending(path: "StalePostRouteTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = PostDraftStore(rootURL: rootURL)
        let state = TaggrAppCoordinator(api: api, postDraftStore: store)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        state.route = .feed(.hot)
        state.returnFeedMode = .hot
        let namespace = PostDraftNamespace(canisterID: state.runtimeConfig.canisterId, userID: 7)
        let draft = PostDraftSession(context: .newPost, initialText: "", initialRealm: "")
        await draft.load(store: store, namespace: namespace)
        draft.text = "hello"
        await draft.markSubmissionNeedsVerification()

        XCTAssertTrue(state.enqueuePostSubmission(text: "hello", reloadMode: .hot, draft: draft))
        let submission = try XCTUnwrap(state.postSubmissionTasks[.newPost])
        await fulfillment(of: [updateStarted], timeout: 1)
        state.route = .feed(.latest)
        state.returnFeedMode = .latest
        releaseUpdate.signal()
        await submission.value
        await fulfillment(of: [userRefreshFinished], timeout: 1)

        XCTAssertEqual(state.route, .feed(.latest))
        XCTAssertEqual(state.returnFeedMode, .latest)
        XCTAssertFalse(lock.withLock { methods.contains("hot_posts") || methods.contains("last_posts") })
    }

    @MainActor
    func testImagePostKeepsEnqueuedAPIWhenSessionChangesDuringUpload() async throws {
        let uploadStarted = expectation(description: "bucket write started")
        let releaseUpload = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var originalMethods: [String] = []
        var replacementMethods: [String] = []
        let originalAPI = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let method = self.requestMethodAndArg(from: request)?.method ?? ""
            lock.withLock { originalMethods.append(method) }
            if method == "write" {
                uploadStarted.fulfill()
                _ = releaseUpload.wait(timeout: .now() + 5)
                return (response, Self.queryReply(Data([0, 0, 0, 0, 0, 0, 0, 7])))
            }
            return (response, Self.queryReply(Self.candidAddPostResultOk(42)))
        }
        let replacementAPI = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let method = self.requestMethodAndArg(from: request)?.method ?? ""
            lock.withLock { replacementMethods.append(method) }
            return (response, Self.queryReply(Self.candidAddPostResultOk(99)))
        }
        let rootURL = URL.temporaryDirectory
            .appending(path: "PostContextTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = PostDraftStore(rootURL: rootURL)
        let state = TaggrAppCoordinator(api: originalAPI, postDraftStore: store)
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
        let namespace = PostDraftNamespace(canisterID: state.runtimeConfig.canisterId, userID: 7)
        let draft = PostDraftSession(context: .newPost, initialText: "", initialRealm: "")
        await draft.load(store: store, namespace: namespace)
        let image = TaggrDraftImage(id: "abc12345", data: Data([1, 2, 3]), width: 10, height: 20)
        draft.text = image.markdown
        await draft.addImages([image])

        XCTAssertTrue(state.enqueuePostSubmission(text: image.markdown, images: [image], draft: draft))
        let submission = try XCTUnwrap(state.postSubmissionTasks[.newPost])
        await fulfillment(of: [uploadStarted], timeout: 1)
        state.api = replacementAPI
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = TaggrUser(
            id: 8,
            name: "bob",
            about: "",
            principal: nil,
            realms: [],
            followees: [],
            followers: [],
            blacklist: [],
            bucket: "bbbbb-bb",
            mode: nil
        )
        releaseUpload.signal()
        await submission.value

        XCTAssertEqual(lock.withLock { originalMethods }, ["write", "add_post"])
        XCTAssertTrue(lock.withLock { replacementMethods.isEmpty })
        XCTAssertEqual(state.currentUser?.id, 8)
    }

    @MainActor
    func testEnqueuedPostKeepsRetryableAndUncertainDrafts() async throws {
        let rootURL = URL.temporaryDirectory
            .appending(path: "FailedEnqueuedPostTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = PostDraftStore(rootURL: rootURL)
        let user = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        let namespace = PostDraftNamespace(canisterID: TaggrRuntimeConfig.productionCanisterId, userID: user.id)

        let rejectedAPI = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Self.candidResultErr("denied")))
        }
        let rejectedState = TaggrAppCoordinator(api: rejectedAPI, postDraftStore: store)
        rejectedState.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        rejectedState.currentUser = user
        let retryableDraft = PostDraftSession(context: .newPost, initialText: "", initialRealm: "")
        await retryableDraft.load(store: store, namespace: namespace)
        retryableDraft.text = "retry me"
        await retryableDraft.markSubmissionNeedsVerification()

        XCTAssertTrue(rejectedState.enqueuePostSubmission(text: "retry me", draft: retryableDraft))
        await rejectedState.postSubmissionTasks[.newPost]?.value

        XCTAssertEqual(rejectedState.postSubmissionNotice?.phase, .retryableFailure)
        XCTAssertTrue(retryableDraft.hasChanges)
        XCTAssertFalse(retryableDraft.submissionNeedsVerification)

        let unavailableAPI = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!
            return (response, Data("gateway unavailable".utf8))
        }
        let uncertainState = TaggrAppCoordinator(api: unavailableAPI, postDraftStore: store)
        uncertainState.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        uncertainState.currentUser = user
        let uncertainDraft = PostDraftSession(context: .reply(42), initialText: "", initialRealm: "DEV")
        await uncertainDraft.load(store: store, namespace: namespace)
        uncertainDraft.text = "maybe sent"
        await uncertainDraft.markSubmissionNeedsVerification()

        XCTAssertTrue(uncertainState.enqueuePostSubmission(text: "maybe sent", parent: 42, realm: "DEV", draft: uncertainDraft))
        await uncertainState.postSubmissionTasks[.reply(42)]?.value

        XCTAssertEqual(uncertainState.postSubmissionNotice?.phase, .uncertain)
        XCTAssertTrue(uncertainDraft.hasChanges)
        XCTAssertTrue(uncertainDraft.submissionNeedsVerification)
    }

    @MainActor
    func testEmptyRepostVerificationStateRestoresUntilConfirmed() async throws {
        let rootURL = URL.temporaryDirectory
            .appending(path: "RepostDraftTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = PostDraftStore(rootURL: rootURL)
        let namespace = PostDraftNamespace(canisterID: TaggrRuntimeConfig.productionCanisterId, userID: 7)
        let context = PostDraftContext.repost(42)
        let submittedDraft = PostDraftSession(context: context, initialText: "", initialRealm: "DEV")
        await submittedDraft.load(store: store, namespace: namespace)

        let markedForVerification = await submittedDraft.markSubmissionNeedsVerification()
        XCTAssertTrue(markedForVerification)

        let restoredDraft = PostDraftSession(context: context, initialText: "", initialRealm: "DEV")
        await restoredDraft.load(store: store, namespace: namespace)
        XCTAssertTrue(restoredDraft.submissionNeedsVerification)
        XCTAssertTrue(restoredDraft.hasChanges)

        await restoredDraft.discard()
        let confirmedDraft = PostDraftSession(context: context, initialText: "", initialRealm: "DEV")
        await confirmedDraft.load(store: store, namespace: namespace)
        XCTAssertFalse(confirmedDraft.submissionNeedsVerification)
        XCTAssertFalse(confirmedDraft.hasChanges)
    }

    @MainActor
    func testRejectedRepostKeepsDraftForRetry() async throws {
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Self.candidResultErr("denied")))
        }
        let rootURL = URL.temporaryDirectory
            .appending(path: "RejectedRepostDraftTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = PostDraftStore(rootURL: rootURL)
        let state = TaggrAppCoordinator(api: api, postDraftStore: store)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        let namespace = PostDraftNamespace(canisterID: state.runtimeConfig.canisterId, userID: 7)
        let draft = PostDraftSession(context: .repost(42), initialText: "", initialRealm: "DEV")
        await draft.load(store: store, namespace: namespace)
        draft.text = "comment"
        await draft.markSubmissionNeedsVerification()

        XCTAssertTrue(state.enqueueRepost(postId: 42, text: draft.text, realm: "DEV", draft: draft))
        await state.postSubmissionTasks[.repost(42)]?.value

        XCTAssertEqual(state.postSubmissionNotice?.phase, .retryableFailure)
        XCTAssertEqual(draft.text, "comment")
        XCTAssertTrue(draft.hasChanges)
        XCTAssertFalse(draft.submissionNeedsVerification)
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

        let failedOutcome = await failingState.submitPost(text: "hello", realm: "DEV")
        XCTAssertEqual(failedOutcome, .retryableFailure)
        XCTAssertEqual(preferences.recentDestinations(scope: scope), ["ART"])

        let unavailableAPI = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!
            return (response, Data("gateway unavailable".utf8))
        }
        let unavailableState = TaggrAppCoordinator(api: unavailableAPI, realmPostingPreferences: preferences)
        unavailableState.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        unavailableState.currentUser = user

        let uncertainOutcome = await unavailableState.submitPost(text: "hello", realm: "DEV")
        XCTAssertEqual(uncertainOutcome, .uncertain)
        XCTAssertEqual(preferences.recentDestinations(scope: scope), ["ART"])

        let replyAPI = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/query") == true {
                if self.requestMethodAndArg(from: request)?.method == "user" {
                    return (response, Self.queryReply(Self.currentUserFixture()))
                }
                return (response, Self.queryReply(Data("[]".utf8)))
            }
            return (response, Self.queryReply(Self.candidAddPostResultOk(42)))
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
            return (response, Self.queryReply(Self.candidAddPostResultOk(42)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.route = .feed(.tags(["tag"]))

        await state.submitPost(text: "hello #tag", reloadMode: .tags(["tag"]))

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.first?.method, "add_post")
        XCTAssertEqual(Set(calls.dropFirst().map(\.method)), Set(["user", "posts_by_tags"]))
        XCTAssertEqual(
            calls.first { $0.method == "posts_by_tags" }?.arg,
            try TaggrCandid.jsonArguments([TaggrRuntimeConfig.productionDomain, "", ["tag"], 0, 0])
        )
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
            return (response, Self.queryReply(Self.candidAddPostResultOk(43)))
        }
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.route = .post(42)

        await state.submitPost(text: "reply", parent: 42, realm: "DEV", reloadMode: .latest)

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.first?.method, "add_post")
        XCTAssertEqual(Set(calls.dropFirst().map(\.method)), Set(["user", "thread"]))
        XCTAssertEqual(calls.first?.arg, try TaggrCandidAdapter.addPostArguments(text: "reply", refs: [], parent: 42, realm: "DEV", extensionBlob: nil).encode())
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
            return (response, Self.queryReply(Self.candidEditPostResultOk()))
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
        XCTAssertEqual(calls.first?.method, "edit_post")
        XCTAssertEqual(Set(calls.dropFirst().map(\.method)), Set(["user", "thread"]))
        XCTAssertEqual(
            calls.first?.arg,
            try TaggrCandidAdapter.editPostArguments(id: 42, text: "updated", refs: [], patch: patch, realm: "ART").encode()
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
            return (response, Self.queryReply(Self.candidEditPostResultOk()))
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
        XCTAssertEqual(calls.prefix(2).map(\.method), ["write", "edit_post"])
        XCTAssertEqual(Set(calls.dropFirst(2).map(\.method)), Set(["user", "thread"]))
        XCTAssertEqual(calls.first?.arg, Data([1, 2, 3]))
        XCTAssertEqual(
            calls.dropFirst().first?.arg,
            try TaggrCandidAdapter.editPostArguments(
                id: 42,
                text: body,
                refs: [(id: "abc12345", offset: 7, length: 3)],
                patch: patch,
                realm: "DEV"
            ).encode()
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
            return (response, Self.queryReply(Self.candidAddPostResultOk(42)))
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
        XCTAssertEqual(calls.prefix(3).map(\.method), ["write", "write", "add_post"])
        XCTAssertEqual(Set(calls.dropFirst(3).map(\.method)), Set(["user", "hot_posts"]))
        XCTAssertEqual(calls[0].arg, Data([1, 2, 3]))
        XCTAssertEqual(calls[1].arg, Data([1, 2, 3]))
        XCTAssertEqual(
            calls[2].arg,
            try TaggrCandidAdapter.addPostArguments(
                text: body,
                refs: [
                    (id: "abc12345", offset: 7, length: 3),
                    (id: "abc12301", offset: 8, length: 3),
                ],
                parent: nil,
                realm: nil,
                extensionBlob: nil
            ).encode()
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
            return (response, Self.queryReply(Self.candidAddPostResultOk(42)))
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
            return (response, Self.queryReply(Self.candidAddPostResultOk(42)))
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
            return (response, Self.queryReply(Self.candidAddPostResultOk(42)))
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
