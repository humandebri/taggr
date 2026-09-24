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
        let state = makeCoordinator(realmPostingPreferences: preferences)
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
        let state = makeCoordinator(api: api)
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
        let state = makeCoordinator(api: api)

        await state.loadAllRealmsList()

        XCTAssertEqual(calls.first?.method, "all_realms")
        XCTAssertEqual(calls.first?.arg, try TaggrCandid.jsonArguments([TaggrRuntimeConfig.productionDomain, "popularity", 0]))
        XCTAssertEqual(state.realms.first?.description, "Builders")
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
        let state = makeCoordinator()
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
    func testRealmMembershipOperationRejectsConcurrentRequest() async throws {
        let started = expectation(description: "first membership update started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let updates = LockedTestValue(0)
        let api = makeStubbedAPI { request in
            let body: Data
            switch self.requestMethodAndArg(from: request)?.method {
            case "toggle_realm_membership":
                updates.mutate { $0 += 1 }
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
                body = Data("true".utf8)
            case "user": body = Self.realmUserFixture(realms: ["DEV"])
            case "realms": body = Self.safeRealmFixture()
            default: body = Data("null".utf8)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(body))
        }
        let state = makeCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.realmUserFixture(realms: []))
        let first = Task { await state.setRealmMembership(name: "DEV", joined: true) }
        await fulfillment(of: [started], timeout: 2)
        let second = await state.setRealmMembership(name: "DEV", joined: true)
        XCTAssertFalse(second)
        XCTAssertEqual(updates.read { $0 }, 1)
        release.signal()
        let firstResult = await first.value
        XCTAssertTrue(firstResult)
        XCTAssertEqual(updates.read { $0 }, 1)
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
        let state = makeCoordinator(api: api)
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
        let state = makeCoordinator(api: api)
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
        let state = makeCoordinator(api: api)
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
        let state = makeCoordinator(api: api)

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
                var user = try JSONSerialization.jsonObject(with: Self.currentUserFixture()) as! [String: Any]
                user["bucket"] = "bkyz2-fmaaa-aaaaa-qaaaq-cai"
                return (response, Self.queryReply(try JSONSerialization.data(withJSONObject: user)))
            case "account_balance":
                return (response, Self.queryReply(Self.candidTokens(200_000_000)))
            case "canister_status":
                return (response, Self.queryReply(try Self.candidCanisterStatus()))
            case "bucket_wasm_hash":
                return (response, Self.queryReply(Data(#""010203""#.utf8)))
            default:
                return (response, Self.queryReply(Data("null".utf8)))
            }
        }
        let state = makeCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.route = .settings

        await state.refreshVisibleRoute()

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(Set(calls.prefix(2).map(\.method)), Set(["stats", "config"]))
        XCTAssertEqual(Array(calls.dropFirst(2).map(\.method)), ["user", "account_balance", "bucket_wasm_hash", "canister_status"])
        XCTAssertTrue(calls.first { $0.method == "account_balance" }?.path.contains(TaggrAPI.icpLedgerCanisterId) == true)
        XCTAssertEqual(state.currentUser?.name, "alice")
        XCTAssertEqual(state.icpBalanceE8s, 200_000_000)
        XCTAssertEqual(state.storageExpectedWasmHash, "010203")
        XCTAssertEqual(state.storageStatus?.status, "running")
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
                if calls.last?.method == "realms" {
                    return (response, Self.queryReply(Self.safeRealmFixture()))
                }
                return (response, Self.queryReply(Data("[]".utf8)))
            }
            return (response, Self.queryReply(Self.candidAddPostResultOk(42)))
        }
        let suiteName = "SubmitPostRealmPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = RealmPostingPreferences(defaults: defaults)
        let state = makeCoordinator(safety: makeSafetyStore(), api: api, realmPostingPreferences: preferences)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        let postingScope = try XCTUnwrap(state.realmPostingScope)
        state.route = .feed(.realm("DEV"))

        state.safety.accept(scope: state.safetyScope)
        let outcome = await runQueuedSubmission(state, context: .newPost, text: "hello", realm: "DEV", images: []) { draft in
            state.enqueuePostSubmission(text: "hello", realm: "DEV", draft: draft)
        }
        await waitForPostReconciliation(state)

        XCTAssertEqual(outcome, .succeeded)
        XCTAssertNil(state.errorMessage)
        let functionalCalls = calls.filter { $0.method != "realms" }
        XCTAssertEqual(functionalCalls.first?.method, "add_post")
        XCTAssertEqual(Set(functionalCalls.dropFirst().map(\.method)), Set(["user", "last_posts"]))
        try assertAddPostRequest(functionalCalls.first?.arg, text: "hello", refs: [], parent: nil, realm: "DEV", extensionBlob: nil)
        XCTAssertEqual(
            functionalCalls.first { $0.method == "last_posts" }?.arg,
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
        let state = makeCoordinator(safety: makeSafetyStore(), api: api, realmPostingPreferences: preferences)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        let postingScope = try XCTUnwrap(state.realmPostingScope)

        state.safety.accept(scope: state.safetyScope)
        await runQueuedSubmission(state, context: .newPost, text: "    hello\n\n", realm: nil, images: []) { draft in
            state.enqueuePostSubmission(text: "    hello\n\n", draft: draft)
        }
        await waitForPostReconciliation(state)

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.first?.method, "add_post")
        try assertAddPostRequest(calls.first?.arg, text: "    hello\n\n", refs: [], parent: nil, realm: nil, extensionBlob: nil)
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
        let state = makeCoordinator(safety: makeSafetyStore(), api: api, postDraftStore: store)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        state.route = .feed(.hot)
        let namespace = PostDraftNamespace(canisterID: state.runtimeConfig.canisterId, userID: 7)
        let draft = PostDraftSession(context: .newPost, initialText: "", initialRealm: "")
        await draft.load(store: store, namespace: namespace)
        draft.text = "hello"
        let draftSaved = await draft.markSubmissionNeedsVerification()
        XCTAssertTrue(draftSaved)

        state.safety.accept(scope: state.safetyScope)
        XCTAssertTrue(state.enqueuePostSubmission(text: "hello", draft: draft))
        state.safety.accept(scope: state.safetyScope)
        XCTAssertFalse(state.enqueuePostSubmission(text: "hello", draft: draft))
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
        let state = makeCoordinator(safety: makeSafetyStore(), api: api, postDraftStore: store)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        state.route = .feed(.hot)
        let namespace = PostDraftNamespace(canisterID: state.runtimeConfig.canisterId, userID: 7)
        let draft = PostDraftSession(context: .newPost, initialText: "", initialRealm: "")
        await draft.load(store: store, namespace: namespace)
        draft.text = "hello"
        await draft.markSubmissionNeedsVerification()

        state.safety.accept(scope: state.safetyScope)
        XCTAssertTrue(state.enqueuePostSubmission(text: "hello", draft: draft))
        let submission = try XCTUnwrap(state.postSubmissionTasks[.newPost])
        await submission.value

        XCTAssertFalse(state.hasPendingPostSubmission)
        XCTAssertEqual(state.postSubmissionNotice?.phase, .succeeded)
        XCTAssertFalse(draft.hasChanges)
        await fulfillment(of: [userRefreshStarted], timeout: 5)
    }

    @MainActor
    func testEnqueuedPostDoesNotRefreshStaleFeedRoute() async throws {
        let updateStarted = expectation(description: "add_post started")
        let userRefreshFinished = expectation(description: "user refresh finished")
        let releaseUpdate = DispatchSemaphore(value: 0)
        let methods = LockedTestValue<[String]>([])
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let method = self.requestMethodAndArg(from: request)?.method ?? ""
            methods.mutate { $0.append(method) }
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
        let state = makeCoordinator(safety: makeSafetyStore(), api: api, postDraftStore: store)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        state.route = .feed(.hot)
        state.returnFeedMode = .hot
        let namespace = PostDraftNamespace(canisterID: state.runtimeConfig.canisterId, userID: 7)
        let draft = PostDraftSession(context: .newPost, initialText: "", initialRealm: "")
        await draft.load(store: store, namespace: namespace)
        draft.text = "hello"
        await draft.markSubmissionNeedsVerification()

        state.safety.accept(scope: state.safetyScope)
        XCTAssertTrue(state.enqueuePostSubmission(text: "hello", draft: draft))
        let submission = try XCTUnwrap(state.postSubmissionTasks[.newPost])
        await fulfillment(of: [updateStarted], timeout: 1)
        state.route = .feed(.latest)
        state.returnFeedMode = .latest
        releaseUpdate.signal()
        await submission.value
        await fulfillment(of: [userRefreshFinished], timeout: 1)

        XCTAssertEqual(state.route, .feed(.latest))
        XCTAssertEqual(state.returnFeedMode, .latest)
        XCTAssertFalse(methods.read { $0.contains("hot_posts") || $0.contains("last_posts") })
    }

    @MainActor
    func testImagePostKeepsEnqueuedAPIWhenSessionChangesDuringUpload() async throws {
        let uploadStarted = expectation(description: "bucket write started")
        let releaseUpload = DispatchSemaphore(value: 0)
        let originalMethods = LockedTestValue<[String]>([])
        let replacementMethods = LockedTestValue<[String]>([])
        let originalAPI = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let method = self.requestMethodAndArg(from: request)?.method ?? ""
            originalMethods.mutate { $0.append(method) }
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
            replacementMethods.mutate { $0.append(method) }
            return (response, Self.queryReply(Self.candidAddPostResultOk(99)))
        }
        let rootURL = URL.temporaryDirectory
            .appending(path: "PostContextTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let store = PostDraftStore(rootURL: rootURL)
        let state = makeCoordinator(safety: makeSafetyStore(), api: originalAPI, postDraftStore: store)
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
        draft.restoreEditorImages([image])
        draft.text = image.markdown
        await draft.flush()

        state.safety.accept(scope: state.safetyScope)
        XCTAssertTrue(state.enqueuePostSubmission(text: image.markdown, images: [image], draft: draft))
        let submission = try XCTUnwrap(state.postSubmissionTasks[.newPost])
        await fulfillment(of: [uploadStarted], timeout: 5)
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

        XCTAssertEqual(originalMethods.read { $0 }, ["write"], "Account changes must stop publication after upload")
        XCTAssertTrue(replacementMethods.read(\.isEmpty))
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
        let rejectedState = makeCoordinator(safety: makeSafetyStore(), api: rejectedAPI, postDraftStore: store)
        rejectedState.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        rejectedState.currentUser = user
        let retryableDraft = PostDraftSession(context: .newPost, initialText: "", initialRealm: "")
        await retryableDraft.load(store: store, namespace: namespace)
        retryableDraft.text = "retry me"
        await retryableDraft.markSubmissionNeedsVerification()

        rejectedState.safety.accept(scope: rejectedState.safetyScope)
        XCTAssertTrue(rejectedState.enqueuePostSubmission(text: "retry me", draft: retryableDraft))
        await rejectedState.postSubmissionTasks[.newPost]?.value

        XCTAssertEqual(rejectedState.postSubmissionNotice?.phase, .retryableFailure)
        XCTAssertTrue(retryableDraft.hasChanges)
        XCTAssertFalse(retryableDraft.submissionNeedsVerification)

        let unavailableAPI = makeStubbedAPI { request in
            let method = self.requestMethodAndArg(from: request)?.method
            let status = method == "add_post" ? 502 : 200
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            if method == "posts" {
                let parent = String(data: self.postEnvelopeFixture(id: 42), encoding: .utf8)!
                return (response, Self.queryReply(Data("[\(parent)]".utf8)))
            }
            if method == "realms" {
                return (response, Self.queryReply(Self.safeRealmFixture()))
            }
            return (response, Data("gateway unavailable".utf8))
        }
        let uncertainState = makeCoordinator(safety: makeSafetyStore(), api: unavailableAPI, postDraftStore: store)
        uncertainState.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        uncertainState.currentUser = user
        let uncertainDraft = PostDraftSession(context: .reply(42), initialText: "", initialRealm: "DEV")
        await uncertainDraft.load(store: store, namespace: namespace)
        uncertainDraft.text = "maybe sent"
        await uncertainDraft.markSubmissionNeedsVerification()

        uncertainState.safety.accept(scope: uncertainState.safetyScope)
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
        let state = makeCoordinator(safety: makeSafetyStore(), api: api, postDraftStore: store)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        let namespace = PostDraftNamespace(canisterID: state.runtimeConfig.canisterId, userID: 7)
        let draft = PostDraftSession(context: .repost(42), initialText: "", initialRealm: "DEV")
        await draft.load(store: store, namespace: namespace)
        draft.text = "comment"
        await draft.markSubmissionNeedsVerification()

        state.safety.accept(scope: state.safetyScope)
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
            let method = self.requestMethodAndArg(from: request)?.method
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if method == "realms" {
                return (response, Self.queryReply(Self.safeRealmFixture()))
            }
            return (response, Self.queryReply(Self.candidResultErr("denied")))
        }
        let failingState = makeCoordinator(safety: makeSafetyStore(), api: failingAPI, realmPostingPreferences: preferences)
        failingState.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        failingState.currentUser = user

        failingState.safety.accept(scope: failingState.safetyScope)
        let failedOutcome = await runQueuedSubmission(failingState, context: .newPost, text: "hello", realm: "DEV", images: []) { draft in
            failingState.enqueuePostSubmission(text: "hello", realm: "DEV", draft: draft)
        }
        await waitForPostReconciliation(failingState)
        XCTAssertEqual(failedOutcome, .retryableFailure)
        XCTAssertEqual(preferences.recentDestinations(scope: scope), ["ART"])

        let unavailableAPI = makeStubbedAPI { request in
            let method = self.requestMethodAndArg(from: request)?.method
            let status = method == "realms" ? 200 : 502
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            if method == "realms" {
                return (response, Self.queryReply(Self.safeRealmFixture()))
            }
            return (response, Data("gateway unavailable".utf8))
        }
        let unavailableState = makeCoordinator(safety: makeSafetyStore(), api: unavailableAPI, realmPostingPreferences: preferences)
        unavailableState.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        unavailableState.currentUser = user

        unavailableState.safety.accept(scope: unavailableState.safetyScope)
        let uncertainOutcome = await runQueuedSubmission(unavailableState, context: .newPost, text: "hello", realm: "DEV", images: []) { draft in
            unavailableState.enqueuePostSubmission(text: "hello", realm: "DEV", draft: draft)
        }
        await waitForPostReconciliation(unavailableState)
        XCTAssertEqual(uncertainOutcome, .uncertain)
        XCTAssertEqual(preferences.recentDestinations(scope: scope), ["ART"])

        let replyAPI = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/query") == true {
                let method = self.requestMethodAndArg(from: request)?.method
                if method == "user" {
                    return (response, Self.queryReply(Self.currentUserFixture()))
                }
                if method == "posts" {
                    let parent = String(data: self.postEnvelopeFixture(id: 42), encoding: .utf8)!
                    return (response, Self.queryReply(Data("[\(parent)]".utf8)))
                }
                if method == "realms" {
                    return (response, Self.queryReply(Self.safeRealmFixture()))
                }
                return (response, Self.queryReply(Data("[]".utf8)))
            }
            return (response, Self.queryReply(Self.candidAddPostResultOk(42)))
        }
        let replyState = makeCoordinator(safety: makeSafetyStore(), api: replyAPI, realmPostingPreferences: preferences)
        replyState.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        replyState.currentUser = user

        replyState.safety.accept(scope: replyState.safetyScope)
        await runQueuedSubmission(replyState, context: .reply(42), text: "reply", realm: "DEV", images: []) { draft in
            replyState.enqueuePostSubmission(text: "reply", parent: 42, realm: "DEV", draft: draft)
        }
        await waitForPostReconciliation(replyState)
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
        let state = makeCoordinator(safety: makeSafetyStore(), api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.route = .feed(.tags(["tag"]))

        state.safety.accept(scope: state.safetyScope)
        await runQueuedSubmission(state, context: .newPost, text: "hello #tag", realm: nil, images: []) { draft in
            state.enqueuePostSubmission(text: "hello #tag", draft: draft)
        }
        await waitForPostReconciliation(state)

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.first?.method, "add_post")
        XCTAssertEqual(Set(calls.dropFirst().map(\.method)), Set(["user", "posts_by_tags"]))
        XCTAssertEqual(
            calls.first { $0.method == "posts_by_tags" }?.arg,
            try TaggrCandid.jsonArguments([TaggrRuntimeConfig.productionDomain, "", ["tag"], 0, 0])
        )
        XCTAssertEqual(state.route, .feed(.tags(["tag"])))
    }

    @MainActor
    func testReplyPostPassesParentAndRefreshesDirectReplies() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            let call = self.requestMethodAndArg(from: request)
            if let call {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/query") == true {
                if call?.method == "user" {
                    return (response, Self.queryReply(Self.currentUserFixture()))
                }
                if call?.method == "realms" {
                    return (response, Self.queryReply(Self.safeRealmFixture()))
                }
                if call?.arg == (try TaggrCandid.jsonArguments([[42]])) {
                    let body = Data("[\(String(data: self.postEnvelopeFixture(id: 42, children: [43]), encoding: .utf8)!)]".utf8)
                    return (response, Self.queryReply(body))
                }
                let body = Data("[\(String(data: self.postEnvelopeFixture(id: 43, parent: 42), encoding: .utf8)!)]".utf8)
                return (response, Self.queryReply(body))
            }
            return (response, Self.queryReply(Self.candidAddPostResultOk(43)))
        }
        let state = makeCoordinator(safety: makeSafetyStore(), api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        state.route = .post(42)
        let parent = samplePost(id: 42, body: "parent", files: [:])
        state.feed = [parent]
        state.focusedPost = parent
        var didFinishReply = false

        state.safety.accept(scope: state.safetyScope)
        await runQueuedSubmission(state, context: .reply(42), text: "reply", realm: "DEV", images: []) { draft in
            state.enqueuePostSubmission(text: "reply", parent: 42, realm: "DEV", draft: draft) {
                didFinishReply = state.repliesByPostID[42]?.map(\.id) == [43]
            }
        }
        await waitForPostReconciliation(state)

        XCTAssertNil(state.errorMessage)
        try assertAddPostRequest(calls.first { $0.method == "add_post" }?.arg, text: "reply", refs: [], parent: 42, realm: "DEV", extensionBlob: nil)
        XCTAssertTrue(calls.contains { $0.method == "user" })
        XCTAssertGreaterThanOrEqual(calls.filter { $0.method == "posts" }.count, 4)
        XCTAssertEqual(state.repliesByPostID[42]?.map(\.id), [43])
        XCTAssertEqual(state.focusedPost?.children, [43])
        XCTAssertTrue(didFinishReply)
    }

    @MainActor
    func testRefreshRepliesForNestedReplyDoesNotReturnParentAsItsOwnChild() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            let call = try XCTUnwrap(self.requestMethodAndArg(from: request))
            calls.append(call)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if call.arg == (try TaggrCandid.jsonArguments([[42]])) {
                let body = Data("[\(String(data: self.postEnvelopeFixture(id: 42, parent: 10, children: [43]), encoding: .utf8)!)]".utf8)
                return (response, Self.queryReply(body))
            }
            let body = Data("[\(String(data: self.postEnvelopeFixture(id: 43, parent: 42), encoding: .utf8)!)]".utf8)
            return (response, Self.queryReply(body))
        }
        let state = makeCoordinator(safety: makeSafetyStore(), api: api)
        let staleParent = samplePost(id: 42, parent: 10, body: "parent reply", files: [:])
        state.feed = [staleParent]
        state.focusedPost = staleParent
        state.repliesByPostID[42] = [staleParent]

        let snapshot = try await state.loadReplySnapshot(postID: 42, api: api)
        state.applyReplySnapshot(snapshot)

        XCTAssertEqual(calls.map(\.method), ["posts", "posts"])
        XCTAssertEqual(calls.map(\.arg), [
            try TaggrCandid.jsonArguments([[42]]),
            try TaggrCandid.jsonArguments([[43]]),
        ])
        XCTAssertEqual(state.repliesByPostID[42]?.map(\.id), [43])
        XCTAssertEqual(state.focusedPost?.children, [43])
        XCTAssertNil(state.errorMessage)
    }

    @MainActor
    func testRefreshRepliesWithNoChildrenSkipsChildQuery() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            let call = try XCTUnwrap(self.requestMethodAndArg(from: request))
            calls.append(call)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = Data("[\(String(data: self.postEnvelopeFixture(id: 42), encoding: .utf8)!)]".utf8)
            return (response, Self.queryReply(body))
        }
        let state = makeCoordinator(safety: makeSafetyStore(), api: api)

        let snapshot = try await state.loadReplySnapshot(postID: 42, api: api)
        state.applyReplySnapshot(snapshot)

        XCTAssertEqual(calls.map(\.method), ["posts"])
        XCTAssertEqual(state.repliesByPostID[42], [])
        XCTAssertNil(state.errorMessage)
    }

    @MainActor
    func testFailedReplyRefreshLeavesCacheRetryable() async {
        var requestCount = 0
        let api = makeStubbedAPI { request in
            requestCount += 1
            if requestCount == 1 {
                throw URLError(.timedOut)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = Data("[\(String(data: self.postEnvelopeFixture(id: 43, parent: 42), encoding: .utf8)!)]".utf8)
            return (response, Self.queryReply(body))
        }
        let state = makeCoordinator(safety: makeSafetyStore(), api: api)

        let parent = samplePost(id: 42, body: "parent", children: [43], files: [:])
        await state.loadReplies(for: parent)

        XCTAssertNil(state.repliesByPostID[42])
        XCTAssertNotNil(state.errorMessage)

        await state.loadReplies(for: parent)

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(state.repliesByPostID[42]?.map(\.id), [43])
    }

    @MainActor
    func testPostSubmissionReplyReloadRecoversAfterSnapshotFailureAndUsesCache() async throws {
        var calls: [(method: String, arg: Data)] = []
        var parentRequestCount = 0
        let api = makeStubbedAPI { request in
            let call = try XCTUnwrap(self.requestMethodAndArg(from: request))
            calls.append(call)
            if call.arg == (try TaggrCandid.jsonArguments([[42]])) {
                parentRequestCount += 1
                if parentRequestCount == 1 {
                    throw URLError(.timedOut)
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let body = Data("[\(String(data: self.postEnvelopeFixture(id: 42, children: [43]), encoding: .utf8)!)]".utf8)
                return (response, Self.queryReply(body))
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = Data("[\(String(data: self.postEnvelopeFixture(id: 43, parent: 42), encoding: .utf8)!)]".utf8)
            return (response, Self.queryReply(body))
        }
        let state = makeCoordinator(safety: makeSafetyStore(), api: api)
        let staleParent = samplePost(id: 42, body: "parent", files: [:])
        state.feed = [staleParent]
        state.focusedPost = staleParent

        do {
            _ = try await state.loadReplySnapshot(postID: 42, api: api)
            XCTFail("Initial reconciliation should fail.")
        } catch {
            XCTAssertEqual(parentRequestCount, 1)
        }

        await state.loadReplies(postID: 42)

        XCTAssertEqual(state.repliesByPostID[42]?.map(\.id), [43])
        XCTAssertEqual(state.focusedPost?.children, [43])
        let requestCountAfterReload = calls.count

        await state.loadReplies(postID: 42)

        XCTAssertEqual(calls.count, requestCountAfterReload)
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
                if calls.last?.method == "realms" {
                    return (response, Self.queryReply(Data(#"[{"name":"ART","description":"Art","adult_content":false}]"#.utf8)))
                }
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
        let state = makeCoordinator(safety: makeSafetyStore(), api: api, realmPostingPreferences: preferences)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        let postingScope = try XCTUnwrap(state.realmPostingScope)
        preferences.record(destination: "ART", scope: postingScope)
        state.route = .post(42)
        let post = samplePost(id: 42, user: 7, body: "hello", files: [:], realm: "DEV")

        state.safety.accept(scope: state.safetyScope)
        await runQueuedSubmission(state, context: .edit(post.id), text: "    updated\n\n", realm: "ART", images: []) { draft in
            state.enqueueEditPost(post: post, text: "    updated\n\n", realm: "ART", draft: draft)
        }
        await waitForPostReconciliation(state)

        XCTAssertEqual(calls.filter { $0.method == "realms" }.count, 2)
        calls.removeAll { $0.method == "realms" }
        let patch = "@@ -1,13 +1,5 @@\n-    updated%0A%0A\n+hello\n"
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.first?.method, "edit_post")
        XCTAssertEqual(Set(calls.dropFirst().map(\.method)), Set(["user", "thread"]))
        try assertEditPostRequest(calls.first?.arg, id: 42, text: "    updated\n\n", refs: [], patch: patch, realm: "ART")
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
                if calls.last?.method == "realms" {
                    return (response, Self.queryReply(Self.safeRealmFixture()))
                }
                return (response, Self.queryReply(Data("[]".utf8)))
            }
            return (response, Self.queryReply(Self.candidEditPostResultOk()))
        }
        let state = makeCoordinator(safety: makeSafetyStore(), api: api)
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

        state.safety.accept(scope: state.safetyScope)
        await runQueuedSubmission(state, context: .edit(post.id), text: body, realm: post.realm, images: [image]) { draft in
            state.enqueueEditPost(post: post, text: body, realm: post.realm, images: [image], draft: draft)
        }
        await waitForPostReconciliation(state)

        let patch = "@@ -1,38 +1,5 @@\n-updated%0A%0A!%5B10x20, 1kb%5D(/blob/abc12345)\n+hello\n"
        XCTAssertNil(state.errorMessage)
        let functionalCalls = calls.filter { $0.method != "realms" }
        XCTAssertEqual(functionalCalls.prefix(2).map(\.method), ["write", "edit_post"])
        XCTAssertEqual(Set(functionalCalls.dropFirst(2).map(\.method)), Set(["user", "thread"]))
        XCTAssertEqual(functionalCalls.first?.arg, Data([1, 2, 3]))
        try assertEditPostRequest(functionalCalls.dropFirst().first?.arg, id: 42,
                text: body,
                refs: [(id: "abc12345", offset: 7, length: 3)],
                patch: patch,
                realm: "DEV")
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
        let state = makeCoordinator(safety: makeSafetyStore(), api: api)
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

        state.safety.accept(scope: state.safetyScope)
        await runQueuedSubmission(state, context: .newPost, text: body, realm: nil, images: images) { draft in
            state.enqueuePostSubmission(text: body, images: images, draft: draft)
        }
        await waitForPostReconciliation(state)

        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls.prefix(3).map(\.method), ["write", "write", "add_post"])
        XCTAssertEqual(Set(calls.dropFirst(3).map(\.method)), Set(["user", "hot_posts"]))
        XCTAssertEqual(calls[0].arg, Data([1, 2, 3]))
        XCTAssertEqual(calls[1].arg, Data([1, 2, 3]))
        try assertAddPostRequest(calls[2].arg, text: body,
                refs: [
                    (id: "abc12345", offset: 7, length: 3),
                    (id: "abc12301", offset: 8, length: 3),
                ],
                parent: nil,
                realm: nil,
                extensionBlob: nil)
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
        let state = makeCoordinator(safety: makeSafetyStore(), api: api)
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

        state.safety.accept(scope: state.safetyScope)
        await runQueuedSubmission(state, context: .newPost, text: image.markdown, realm: nil, images: [image]) { draft in
            state.enqueuePostSubmission(text: image.markdown, images: [image], draft: draft)
        }
        await waitForPostReconciliation(state)

        XCTAssertEqual(state.postSubmissionNotice?.phase, .retryableFailure)
        XCTAssertTrue(state.postSubmissionNotice?.message.contains("No personal media bucket configured. Set one up under Settings > Storage.") == true)
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
        let state = makeCoordinator(safety: makeSafetyStore(), api: api)
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

        state.safety.accept(scope: state.safetyScope)
        await runQueuedSubmission(state, context: .newPost, text: "!([10x20, 1kb](/blob/abc12345)]", realm: nil, images: [image]) { draft in
            state.enqueuePostSubmission(text: "!([10x20, 1kb](/blob/abc12345)]", images: [image], draft: draft)
        }
        await waitForPostReconciliation(state)

        XCTAssertEqual(state.postSubmissionNotice?.phase, .retryableFailure)
        XCTAssertTrue(state.postSubmissionNotice?.message.contains("Attached image marker was edited. Remove and attach the image again.") == true)
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
        let state = makeCoordinator(safety: makeSafetyStore(), api: api)
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

        state.safety.accept(scope: state.safetyScope)
        await runQueuedSubmission(state, context: .edit(post.id), text: "updated\n\n![10x20, 1kb](/blob/missing)", realm: post.realm, images: []) { draft in
            state.enqueueEditPost(post: post, text: "updated\n\n![10x20, 1kb](/blob/missing)", realm: post.realm, images: [], draft: draft)
        }
        await waitForPostReconciliation(state)

        XCTAssertEqual(state.postSubmissionNotice?.phase, .retryableFailure)
        XCTAssertTrue(state.postSubmissionNotice?.message.contains("You're referencing pictures that are not attached anymore. Please re-upload.") == true)
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
        let state = makeCoordinator(api: api)
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
        let state = makeCoordinator(api: api)
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
        let state = makeCoordinator(api: api)
        let post = samplePost(id: 42, body: "hello", reactions: [:], files: [:])
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        state.feed = [post]
        state.postThread = [post]
        state.focusedPost = post
        state.repliesByPostID = [100: [post]]
        state.feedStore.notificationPosts[42] = post

        await state.react(postId: 42, reaction: 53)

        XCTAssertNotNil(state.errorMessage)
        XCTAssertNil(state.feed.first?.reactions["53"])
        XCTAssertNil(state.postThread.first?.reactions["53"])
        XCTAssertNil(state.focusedPost?.reactions["53"])
        XCTAssertNil(state.repliesByPostID[100]?.first?.reactions["53"])
        XCTAssertNil(state.notificationPosts[42]?.reactions["53"])
    }

    @MainActor
    func testDeletePostDropsRetainedNotificationPost() async throws {
        var methods: [String] = []
        let api = makeStubbedAPI { request in
            if let method = self.requestMethodAndArg(from: request)?.method {
                methods.append(method)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url?.path.hasSuffix("/query") == true {
                if methods.last == "user" {
                    return (response, Self.queryReply(Self.currentUserFixture()))
                }
                return (response, Self.queryReply(Data("[]".utf8)))
            }
            return (response, Self.queryReply(Data("null".utf8)))
        }
        let state = makeCoordinator(api: api)
        let post = samplePost(id: 42, body: "hello", files: [:])
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        state.feedStore.notificationPosts[42] = post

        await state.deletePost(post)

        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(methods.contains("delete_post"))
        XCTAssertNil(state.notificationPosts[42])
        XCTAssertTrue(state.isNotificationPostUnavailable(42))
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
        let state = makeCoordinator(api: api)
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
        let state = makeCoordinator()
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
    func testLoadPostOpensAReplyInsideItsThread() async {
        var calls: [(method: String, arg: Data)] = []
        let rootEnvelope = try! JSONSerialization.jsonObject(with: postEnvelopeFixture(id: 100)) as! [Any]
        let replyEnvelope = try! JSONSerialization.jsonObject(
            with: postEnvelopeFixture(id: 101, parent: 100, children: [102])
        ) as! [Any]
        let threadBody = try! JSONSerialization.data(withJSONObject: [rootEnvelope, replyEnvelope])
        let api = makeStubbedAPI { request in
            calls.append(try XCTUnwrap(self.requestMethodAndArg(from: request)))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(threadBody))
        }
        let state = makeCoordinator(api: api)
        state.navigateToPost(101)

        await state.loadPost(101)

        XCTAssertEqual(calls.map(\.method), ["thread"])
        XCTAssertEqual(calls.map(\.arg), [try TaggrCandid.jsonArguments([101])])
        XCTAssertEqual(state.postThread.map(\.id), [100, 101])
        XCTAssertEqual(state.focusedPost?.id, 101)
        XCTAssertEqual(state.focusedPost?.parent, 100)
        // A thread keeps the focused post's replies behind the reply toggle.
        XCTAssertNil(state.repliesByPostID[101])
        XCTAssertTrue(state.feed.isEmpty)
    }

    @MainActor
    func testLoadThreadKeepsTheAncestorChainWithTheFocusedPostLast() async {
        let rootEnvelope = try! JSONSerialization.jsonObject(with: postEnvelopeFixture(id: 100)) as! [Any]
        let replyEnvelope = try! JSONSerialization.jsonObject(
            with: postEnvelopeFixture(id: 101, parent: 100)
        ) as! [Any]
        let threadBody = try! JSONSerialization.data(withJSONObject: [rootEnvelope, replyEnvelope])
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(threadBody))
        }
        let state = makeCoordinator(api: api)
        state.navigateToThread(101)

        await state.loadThread(101)

        XCTAssertEqual(state.route, .thread(101))
        XCTAssertEqual(state.postThread.map(\.id), [100, 101])
        XCTAssertEqual(state.focusedPost?.id, 101)
        XCTAssertEqual(state.focusedPost?.parent, 100)
    }

    @MainActor
    func testLoadPostShowsTheRootPostBeforeItsRepliesArrive() async throws {
        let repliesStarted = expectation(description: "replies query started")
        let releaseReplies = DispatchSemaphore(value: 0)
        let api = makeStubbedAPI { request in
            let call = try XCTUnwrap(self.requestMethodAndArg(from: request))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let fixture: Data
            if call.method == "thread" {
                fixture = self.postEnvelopeFixture(id: 42, children: [43])
            } else {
                repliesStarted.fulfill()
                _ = releaseReplies.wait(timeout: .now() + 5)
                fixture = self.postEnvelopeFixture(id: 43, parent: 42)
            }
            let body = Data("[\(String(data: fixture, encoding: .utf8)!)]".utf8)
            return (response, Self.queryReply(body))
        }
        let state = makeCoordinator(api: api)

        let load = Task { await state.loadPost(42) }
        await fulfillment(of: [repliesStarted], timeout: 2)

        XCTAssertEqual(state.focusedPost?.id, 42)
        XCTAssertFalse(state.isBusy)
        XCTAssertTrue(state.loadingReplyPostIDs.contains(42))
        XCTAssertNil(state.repliesByPostID[42])

        releaseReplies.signal()
        await load.value

        XCTAssertEqual(state.repliesByPostID[42]?.map(\.id), [43])
        XCTAssertFalse(state.loadingReplyPostIDs.contains(42))
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
        let state = makeCoordinator(api: api)
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
        let state = makeCoordinator(api: api)
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
        let state = makeCoordinator(api: api)
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
        let failedFeedState = makeCoordinator(api: failureAPI)
        failedFeedState.canLoadMoreFeed = true
        await failedFeedState.loadMoreFeed(mode: .hot)
        XCTAssertFalse(failedFeedState.isLoadingMoreFeed)

        let cancelledAPI = makeStubbedAPI { _ in
            throw URLError(.cancelled)
        }
        let cancelledRealmState = makeCoordinator(api: cancelledAPI)
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
        let state = makeCoordinator(api: api)
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
}


extension TaggrTests {
    @MainActor
    func testReturningFromPostPreservesLoadedFeedPagesUntilExplicitRefresh() async throws {
        var calls: [String] = []
        var feedPage = 0
        let api = makeStubbedAPI { request in
            let method = try XCTUnwrap(self.requestMethodAndArg(from: request)?.method)
            calls.append(method)
            if method == "hot_posts" { feedPage += 1 }
            let id = method == "thread" ? 999 : feedPage
            let body = Data("[\(String(data: self.postEnvelopeFixture(id: id), encoding: .utf8)!)]".utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(body))
        }
        let state = makeCoordinator(api: api)
        state.cache = TaggrBackendCache(stats: nil, config: try JSONDecoder.taggr.decode(
            TaggrConfig.self, from: Data(#"{"feed_page_size":1}"#.utf8)))
        state.navigateToFeed(.hot)
        await state.loadCurrentRoute()
        await state.loadMoreFeed(mode: .hot)
        state.navigateToPost(999)
        await state.loadCurrentRoute()
        XCTAssertEqual(state.focusedPost?.id, 999)
        XCTAssertTrue(state.postThread.isEmpty)
        XCTAssertEqual(state.feed.map(\.id), [1, 2])
        state.navigateToPost(998)
        state.navigateBackFromPost()
        await state.loadCurrentRoute()
        XCTAssertEqual(state.feed.map(\.id), [1, 2])
        XCTAssertTrue(state.canLoadMoreFeed)
        XCTAssertEqual(calls, ["hot_posts", "hot_posts", "thread"])
        await state.refreshVisibleRoute()
        XCTAssertEqual(state.feed.map(\.id), [3])
        XCTAssertEqual(calls.last, "hot_posts")
    }

    @MainActor
    func testReturningWithoutLoadedFeedFetchesFirstPage() async {
        var calls = 0
        let api = makeStubbedAPI { request in
            calls += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data("[]".utf8)))
        }
        let state = makeCoordinator(api: api)
        state.navigateToPost(99)
        state.navigateBackFromPost()
        await state.loadCurrentRoute()
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testReturningFromProposalPreservesLoadedFeedPages() async throws {
        var calls: [String] = []
        var feedPage = 0
        let api = makeStubbedAPI { request in
            let method = try XCTUnwrap(self.requestMethodAndArg(from: request)?.method)
            calls.append(method)
            if method == "hot_posts" { feedPage += 1 }
            let body = Data("[\(String(data: self.postEnvelopeFixture(id: feedPage), encoding: .utf8)!)]".utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(body))
        }
        let state = makeCoordinator(api: api)
        state.cache = TaggrBackendCache(stats: nil, config: try JSONDecoder.taggr.decode(
            TaggrConfig.self, from: Data(#"{"feed_page_size":1}"#.utf8)))
        state.navigateToFeed(.hot)
        await state.loadCurrentRoute()
        await state.loadMoreFeed(mode: .hot)
        XCTAssertEqual(state.feed.map(\.id), [1, 2])

        state.navigate(to: .proposal(7))
        state.returnFromFeature(fallback: .proposals)
        XCTAssertEqual(state.route, .feed(.hot))
        await state.loadCurrentRoute()

        XCTAssertEqual(calls, ["hot_posts", "hot_posts"])
        XCTAssertEqual(state.feed.map(\.id), [1, 2])
        XCTAssertTrue(state.canLoadMoreFeed)
    }

    @MainActor
    func testReturningFromProfilePreservesLoadedFeedPages() async throws {
        var calls: [String] = []
        var feedPage = 0
        let api = makeStubbedAPI { request in
            let method = try XCTUnwrap(self.requestMethodAndArg(from: request)?.method)
            calls.append(method)
            if method == "hot_posts" { feedPage += 1 }
            let body = Data("[\(String(data: self.postEnvelopeFixture(id: feedPage), encoding: .utf8)!)]".utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(body))
        }
        let state = makeCoordinator(api: api)
        state.cache = TaggrBackendCache(stats: nil, config: try JSONDecoder.taggr.decode(
            TaggrConfig.self, from: Data(#"{"feed_page_size":1}"#.utf8)))
        state.navigateToFeed(.hot)
        await state.loadCurrentRoute()
        await state.loadMoreFeed(mode: .hot)

        state.navigateToProfile("alice")
        state.navigateBackFromProfile()
        XCTAssertEqual(state.route, .feed(.hot))
        await state.loadCurrentRoute()

        XCTAssertEqual(calls, ["hot_posts", "hot_posts"])
        XCTAssertEqual(state.feed.map(\.id), [1, 2])
    }
}


extension TaggrTests {
    @MainActor
    func testInitialUserHydrationPreservesLoadedPostThread() throws {
        let state = makeCoordinator()
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        let thread = [
            samplePost(id: 41, body: "parent", files: [:]),
            samplePost(id: 42, body: "reply", files: [:]),
        ]
        state.postThread = thread

        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())

        XCTAssertEqual(state.postThread.map(\.id), [41, 42])
    }

    @MainActor
    func testAuthenticatedAccountChangeInvalidatesLoadedPostThread() throws {
        let state = makeCoordinator()
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        let user = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
        state.currentUser = user
        state.postThread = [samplePost(id: 42, body: "post", files: [:])]

        state.currentUser = TaggrUser(
            id: user.id + 1,
            name: "bob",
            about: "",
            principal: nil,
            realms: [],
            followees: [],
            followers: [],
            blacklist: [],
            mode: nil
        )

        XCTAssertTrue(state.postThread.isEmpty)
    }

    @MainActor
    func testRuntimeChangeInvalidatesFeedReturnAndThread() async {
        var calls = 0
        let api = makeStubbedAPI { request in
            calls += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data("[]".utf8)))
        }
        let state = makeCoordinator(api: api)
        state.navigateToFeed(.hot)
        await state.loadCurrentRoute()
        state.navigateToPost(42)
        state.postThread = [samplePost(id: 42, body: "post", files: [:])]
        state.runtimeGeneration += 1
        state.navigateBackFromPost()
        await state.loadCurrentRoute()
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(state.postThread.isEmpty)
    }
}
