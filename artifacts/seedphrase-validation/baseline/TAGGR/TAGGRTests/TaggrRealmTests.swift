import CryptoKit
import XCTest
@testable import TAGGR

extension TaggrTests {
    func testHashtagFeedComposerDoesNotPostIntoRealm() {
        XCTAssertNil(PostComposerMode.newPost(selectedMode: .tags(["tag"])).targetRealm)
        XCTAssertEqual(PostComposerMode.newPost(selectedMode: .realm("DEV")).targetRealm, "DEV")
    }

    func testRealmPickerIsAvailableForRootPostButNotReplyEditing() {
        let root = samplePost(body: "root", files: [:], realm: "DEV")
        let reply = samplePost(parent: root.id, body: "reply", files: [:], realm: "DEV")

        XCTAssertTrue(PostComposerMode.newPost(selectedMode: .latest).allowsRealmSelection)
        XCTAssertTrue(PostComposerMode.edit(post: root, selectedMode: .latest).allowsRealmSelection)
        XCTAssertFalse(PostComposerMode.edit(post: reply, selectedMode: .latest).allowsRealmSelection)
        XCTAssertFalse(PostComposerMode.reply(parentPost: root, selectedMode: .latest).allowsRealmSelection)
    }

    func testFeedModeDerivesFromFeedRoute() {
        XCTAssertEqual(FeedView.feedMode(from: .feed(.realm("DEV"))), .realm("DEV"))
        XCTAssertEqual(FeedView.feedMode(from: .feed(.tags(["tag"]))), .tags(["tag"]))
        XCTAssertNil(FeedView.feedMode(from: .realm("DEV")))
    }

    @MainActor
    func testFeedTabRestoresLastHomeMode() {
        let state = TaggrAppCoordinator()

        state.navigateToFeed(.personal)
        XCTAssertEqual(state.lastHomeFeedMode, .personal)
        state.navigateToFeed(.hot)
        XCTAssertEqual(state.lastHomeFeedMode, .hot)
        state.navigateToFeed(.latest)
        state.navigateToPost(42, from: .latest)
        state.navigateToHomeFeed()
        XCTAssertEqual(state.route, .feed(.latest))
        state.navigateToFeed(.tags(["TAGGR"]))
        state.navigateToHomeFeed()

        XCTAssertEqual(state.lastHomeFeedMode, .latest)
        XCTAssertEqual(state.route, .feed(.latest))
        XCTAssertEqual(RootView.feedRoute(lastHomeFeedMode: state.lastHomeFeedMode), .feed(.latest))
    }

    @MainActor
    func testPersonalHomeModeFallsBackToHotWithoutAuthentication() {
        let state = TaggrAppCoordinator()
        state.navigateToFeed(.personal)

        XCTAssertEqual(state.lastHomeFeedMode, .personal)
        XCTAssertEqual(state.effectiveHomeFeedMode, .hot)
    }

    @MainActor
    func testHomeFeedModesPersistAcrossNavigationStoreInstances() {
        for mode in [TaggrFeedMode.hot, .latest, .personal] {
            let suiteName = "taggr-feed-mode-test-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            let firstStore = NavigationStore(defaults: defaults)

            XCTAssertFalse(firstStore.hasStoredHomeFeedMode)
            firstStore.rememberHomeFeedMode(mode)

            let restoredStore = NavigationStore(defaults: defaults)
            XCTAssertTrue(restoredStore.hasStoredHomeFeedMode)
            XCTAssertEqual(restoredStore.lastHomeFeedMode, mode)
            XCTAssertEqual(restoredStore.route, .feed(mode))
        }
    }

    @MainActor
    func testPostNavigationReturnsToOriginalRoute() {
        let state = TaggrAppCoordinator()
        let origins: [(route: TaggrRoute, title: String)] = [
            (.feed(.latest), "Timeline"),
            (.realm("DEV"), "Realm"),
            (.profile("alice"), "Profile"),
            (.userPhotos("alice"), "Photos"),
            (.inbox, "Inbox"),
            (.settings, "Account"),
        ]

        for origin in origins {
            state.route = origin.route
            state.navigateToPost(42)

            XCTAssertEqual(state.postReturnRoute(for: 42), origin.route)
            XCTAssertEqual(state.postReturnTitle, origin.title)

            state.navigateBackFromPost()
            XCTAssertEqual(state.route, origin.route)
            XCTAssertNil(state.postReturnRoutesByPostID[42])
        }
    }

    @MainActor
    func testPostNavigationKeepsOriginalListWhileTraversingPosts() {
        let state = TaggrAppCoordinator()
        state.route = .inbox

        state.navigateToPost(42)
        state.navigateToPost(43)

        XCTAssertNil(state.postReturnRoutesByPostID[42])
        XCTAssertEqual(state.postReturnRoute(for: 43), .inbox)

        state.navigateBackFromPost()

        XCTAssertEqual(state.route, .inbox)
    }

    @MainActor
    func testPostNavigationKeepsParentReturnRouteAcrossProfile() {
        let state = TaggrAppCoordinator()
        state.route = .inbox

        state.navigateToPost(42)
        state.navigateToProfile("alice")
        state.navigateToPost(43)

        XCTAssertEqual(state.postReturnRoute(for: 42), .inbox)
        XCTAssertEqual(state.postReturnRoute(for: 43), .profile("alice"))

        state.navigateBackFromPost()
        XCTAssertEqual(state.route, .profile("alice"))

        state.navigateBackFromProfile()
        XCTAssertEqual(state.route, .post(42))
        XCTAssertEqual(state.postReturnTitle, "Inbox")

        state.navigateBackFromPost()
        XCTAssertEqual(state.route, .inbox)
    }

    @MainActor
    func testPostNavigationWithoutRecordedReturnUsesCurrentHomeFeed() {
        let state = TaggrAppCoordinator()
        state.navigateToFeed(.personal)
        state.route = .post(42)

        state.navigateBackFromPost()

        XCTAssertEqual(state.route, .feed(.personal))
    }

    @MainActor
    func testPostURLUsesCurrentRouteAsReturnDestination() {
        let state = TaggrAppCoordinator()
        state.navigateToFeed(.personal)

        state.open(URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/post/42")!)

        XCTAssertEqual(state.route, .post(42))
        XCTAssertEqual(state.postReturnRoute(for: 42), .feed(.personal))
        XCTAssertEqual(state.postReturnTitle, "Timeline")
        state.navigateBackFromPost()
        XCTAssertEqual(state.route, .feed(.personal))
    }

    func testFeedTabReselectionActions() {
        XCTAssertEqual(RootView.feedTabReselectionAction(for: .feed(.hot)), .scrollToTop)
        XCTAssertEqual(RootView.feedTabReselectionAction(for: .feed(.latest)), .scrollToTop)
        XCTAssertEqual(RootView.feedTabReselectionAction(for: .feed(.personal)), .scrollToTop)
        XCTAssertEqual(RootView.feedTabReselectionAction(for: .feed(.tags(["TAGGR"]))), .returnToHomeFeed)
        XCTAssertEqual(RootView.feedTabReselectionAction(for: .feed(.realm("DEV"))), .returnToHomeFeed)
        XCTAssertEqual(RootView.feedTabReselectionAction(for: .post(42)), .returnToHomeFeed)
    }

    func testStatsAndRealmDecodeSnakeCaseFields() throws {
        let stats = try JSONDecoder.taggr.decode(TaggrStats.self, from: Data(#"{"canister_id":"6qfxa-ryaaa-aaaai-qbhsq-cai"}"#.utf8))
        let realm = try JSONDecoder.taggr.decode(TaggrRealm.self, from: Data(##"{"name":"DEV","description":"Builders","label_color":"#123456","num_members":2,"num_posts":3}"##.utf8))
        let unnamedRealm = try JSONDecoder.taggr.decode(TaggrRealm.self, from: Data(##"{"description":"Builders"}"##.utf8))
        let realmEntry = try JSONDecoder.taggr.decode(TaggrRealmListEntry.self, from: Data(##"["DEV",{"description":"Builders","label_color":"#123456","num_members":2,"num_posts":3}]"##.utf8))
        XCTAssertEqual(stats.canisterId, "6qfxa-ryaaa-aaaai-qbhsq-cai")
        XCTAssertEqual(realm.labelColor, "#123456")
        XCTAssertEqual(realm.numMembers, 2)
        XCTAssertEqual(realm.numPosts, 3)
        XCTAssertEqual(unnamedRealm.name, "")
        XCTAssertEqual(realmEntry.namedRealm.name, "DEV")
        XCTAssertEqual(realmEntry.namedRealm.labelColor, "#123456")
    }

    func testRealmFeedDoesNotReplaceLastHomeMode() {
        let state = TaggrAppCoordinator()

        state.navigateToFeed(.personal)
        state.navigateToRealm("DEV")
        state.navigateToHomeFeed()

        XCTAssertEqual(state.lastHomeFeedMode, .personal)
        XCTAssertEqual(state.route, .feed(.personal))
    }

    func testRealmSettingsDecodeAndEditPayloadPreserveUneditedFields() throws {
        let realm = try JSONDecoder.taggr.decode(
            TaggrRealm.self,
            from: Data(
                ##"""
                {
                  "cleanup_penalty": 10,
                  "controllers": [7, 8],
                  "description": "Builders",
                  "filter": {"age_days": 30, "safe": true, "balance": 50, "num_followers": 3},
                  "label_color": "#123456",
                  "last_setting_update": 11,
                  "last_update": 12,
                  "logo": "b2xk",
                  "max_downvotes": 4,
                  "num_members": 2,
                  "num_posts": 3,
                  "revenue": 99,
                  "theme": "{\"accent\":\"red\"}",
                  "whitelist": [9],
                  "created": 1,
                  "posts": [42],
                  "adult_content": false,
                  "comments_filtering": true
                }
                """##.utf8
            )
        )
        var draft = TaggrRealmSettingsDraft(realm: realm)
        draft.description = "Updated"
        draft.labelColor = "#abcdef"
        draft.cleanupPenalty = 20

        let payload = try draft.payload(for: realm, maxCleanupPenalty: 500, maxLogoLength: 16_384)

        XCTAssertTrue(realm.hasCompleteSettings)
        XCTAssertEqual(realm.controllers, [7, 8])
        XCTAssertEqual(realm.filter.ageDays, 30)
        XCTAssertEqual(payload["description"] as? String, "Updated")
        XCTAssertEqual(payload["label_color"] as? String, "#ABCDEF")
        XCTAssertEqual(payload["controllers"] as? [Int], [7, 8])
        XCTAssertEqual(payload["whitelist"] as? [Int], [9])
        XCTAssertEqual(payload["theme"] as? String, "{\"accent\":\"red\"}")
        XCTAssertEqual((payload["filter"] as? [String: Any])?["age_days"] as? Int, 30)
    }

    func testRealmSettingsValidationRejectsInvalidValues() throws {
        let realm = try JSONDecoder.taggr.decode(
            TaggrRealm.self,
            from: Data(
                ##"{"cleanup_penalty":10,"controllers":[7],"description":"Builders","filter":{},"label_color":"#123456","whitelist":[]}"##.utf8
            )
        )
        var draft = TaggrRealmSettingsDraft(realm: realm)
        draft.description = " "
        XCTAssertThrowsError(try draft.payload(for: realm, maxCleanupPenalty: 500, maxLogoLength: 16_384))
        draft.description = "Valid"
        draft.labelColor = "red"
        XCTAssertThrowsError(try draft.payload(for: realm, maxCleanupPenalty: 500, maxLogoLength: 16_384))
        draft.labelColor = "#123456"
        draft.cleanupPenalty = 501
        XCTAssertThrowsError(try draft.payload(for: realm, maxCleanupPenalty: 500, maxLogoLength: 16_384))

        draft.cleanupPenalty = 10
        draft.maxDownvotes = -1
        XCTAssertThrowsError(try draft.payload(for: realm, maxCleanupPenalty: 500, maxLogoLength: 16_384))
        draft.maxDownvotes = 1
        draft.description = String(repeating: "a", count: 2_001)
        XCTAssertThrowsError(try draft.payload(for: realm, maxCleanupPenalty: 500, maxLogoLength: 16_384))
        draft.description = "Valid"
        draft.logo = String(repeating: "a", count: 17)
        XCTAssertThrowsError(try draft.payload(for: realm, maxCleanupPenalty: 500, maxLogoLength: 16))
    }

    func testJoinRealmRequiresAuthenticationWithoutCallingAPI() async {
        var callCount = 0
        let api = makeStubbedAPI { request in
            callCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data("true".utf8)))
        }
        let state = TaggrAppCoordinator(api: api)

        let result = await state.setRealmMembership(name: "DEV", joined: true)

        XCTAssertFalse(result)
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(state.errorMessage, TaggrAPIError.signInRequiredMessage)
    }

    func testJoinRealmRejectsUnexpectedToggleResultWithoutChangingState() async throws {
        var calls: [String] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call.method)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data("false".utf8)))
        }
        let state = realmCoordinator(api: api, realms: [], controlledRealms: [])

        let result = await state.setRealmMembership(name: "DEV", joined: true)

        XCTAssertFalse(result)
        XCTAssertFalse(state.isJoinedRealm("DEV"))
        XCTAssertEqual(calls, ["toggle_realm_membership"])
        XCTAssertNotNil(state.errorMessage)
    }

    func testJoinRealmRejectsRefreshedMembershipMismatch() async throws {
        var calls: [String] = []
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            guard let call = self.requestMethodAndArg(from: request) else {
                return (response, Self.queryReply(Data("null".utf8)))
            }
            calls.append(call.method)
            if call.method == "toggle_realm_membership" {
                return (response, Self.queryReply(Data("true".utf8)))
            }
            return (response, Self.queryReply(Self.realmUserFixture(realms: [])))
        }
        let state = realmCoordinator(api: api, realms: [], controlledRealms: [])

        let result = await state.setRealmMembership(name: "DEV", joined: true)

        XCTAssertFalse(result)
        XCTAssertFalse(state.isJoinedRealm("DEV"))
        XCTAssertEqual(calls, ["toggle_realm_membership", "user"])
        XCTAssertNotNil(state.errorMessage)
    }

    func testRealmMembershipAPIFailureKeepsDisplayedState() async throws {
        let api = makeStubbedAPI { _ in
            throw URLError(.cannotConnectToHost)
        }
        let state = realmCoordinator(api: api, realms: [], controlledRealms: [])

        let result = await state.setRealmMembership(name: "DEV", joined: true)

        XCTAssertFalse(result)
        XCTAssertFalse(state.isJoinedRealm("DEV"))
        XCTAssertNotNil(state.errorMessage)
        XCTAssertNil(state.realmMembershipOperation)
    }

    func testRealmSettingsSaveRefreshesRealm() async throws {
        var calls: [String] = []
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            guard let call = self.requestMethodAndArg(from: request) else {
                return (response, Self.queryReply(Data("null".utf8)))
            }
            calls.append(call.method)
            if call.method == "realms" {
                return (response, Self.queryReply(Self.completeRealmFixture(description: "Updated")))
            }
            return (response, Self.queryReply(Data("null".utf8)))
        }
        let state = realmCoordinator(api: api, realms: [], controlledRealms: ["DEV"])
        let realm = try XCTUnwrap(
            JSONDecoder.taggr.decode([TaggrRealm].self, from: Self.completeRealmFixture()).first
        )
        var draft = TaggrRealmSettingsDraft(realm: realm)
        draft.description = "Updated"

        let result = await state.saveRealmSettings(draft, realm: realm)

        XCTAssertTrue(result)
        XCTAssertEqual(calls, ["edit_realm", "realms"])
        XCTAssertEqual(state.realms.first?.description, "Updated")
        XCTAssertNil(state.errorMessage)
    }

    func testRealmSettingsSaveSurfacesBackendRejection() async throws {
        var calls: [String] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call.method)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data(#"{"Err":"denied"}"#.utf8)))
        }
        let state = realmCoordinator(api: api, realms: [], controlledRealms: ["DEV"])
        let realm = try XCTUnwrap(
            JSONDecoder.taggr.decode([TaggrRealm].self, from: Self.completeRealmFixture()).first
        )
        var draft = TaggrRealmSettingsDraft(realm: realm)
        draft.description = "Updated"

        let result = await state.saveRealmSettings(draft, realm: realm)

        XCTAssertFalse(result)
        XCTAssertEqual(calls, ["edit_realm"])
        XCTAssertEqual(state.errorMessage, "denied")
        XCTAssertTrue(state.realms.isEmpty)
    }

    private func realmCoordinator(
        api: TaggrAPI,
        realms: [String],
        controlledRealms: [String]
    ) -> TaggrAppCoordinator {
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = TaggrUser(
            id: 7,
            name: "alice",
            about: "",
            principal: nil,
            realms: realms,
            followees: [],
            followers: [],
            blacklist: [],
            controlledRealms: controlledRealms,
            mode: nil
        )
        return state
    }

    nonisolated private static func completeRealmFixture(description: String = "Builders") -> Data {
        Data(
            ##"[{"name":"DEV","cleanup_penalty":10,"controllers":[7],"description":"\##(description)","filter":{},"label_color":"#123456","max_downvotes":4,"whitelist":[],"adult_content":false,"comments_filtering":true}]"##.utf8
        )
    }
}
