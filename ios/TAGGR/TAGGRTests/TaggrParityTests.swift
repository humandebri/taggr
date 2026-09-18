import XCTest
import CryptoKit
import ICNativeClient
@testable import TAGGR

extension TaggrTests {
    nonisolated private func regressionProposal(_ id: Int = 1, status: String = "Open") -> Data {
        Data("{\"Ok\":{\"id\":\(id),\"proposer\":7,\"timestamp\":1,\"post_id\":42,\"status\":\"\(status)\",\"payload\":{\"Release\":{\"commit\":\"abc\",\"hash\":\"def\"}},\"bulletins\":[],\"voting_power\":100}}".utf8)
    }

    private func regressionState(api: TaggrAPI) throws -> TaggrAppCoordinator {
        let state = makeCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.safety.accept(scope: state.safetyScope)
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Data(#"{"id":7,"name":"alice","cycles":1000,"realms":[],"controlled_realms":["ALPHA"]}"#.utf8))
        state.cache = TaggrBackendCache(stats: nil, config: try JSONDecoder.taggr.decode(TaggrConfig.self,
            from: Data(#"{"realm_cost":10,"max_realm_name":20,"max_realm_cleanup_penalty":100}"#.utf8)))
        return state
    }

    func testProposalConfirmationUsesSnapshotAndInvalidationPreventsVoting() async throws {
        let calls = LockedTestValue<[(String, Data)]>([])
        let api = makeStubbedAPI { request in
            let call = try XCTUnwrap(self.requestMethodAndArg(from: request))
            calls.mutate { $0.append((call.method, call.arg)) }
            let data: Data
            switch call.method {
            case "proposal": data = self.regressionProposal()
            case "posts": data = Data("[\(String(decoding: self.postEnvelopeFixture(), as: UTF8.self))]".utf8)
            case "users_data": data = Data("{}".utf8)
            case "user": data = Self.currentUserFixture()
            default: data = Data("null".utf8)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(data))
        }
        let state = try regressionState(api: api)
        let model = TaggrProposalDetailState(id: 1)
        await model.load(state)
        XCTAssertTrue(model.canVote(state, canonical: true))
        model.data = "confirmed-hash"
        model.prepareVote(adopted: true, state: state, canonical: true)
        model.data = "changed-after-confirmation"
        await model.vote(state, canonical: true)
        let votes = calls.read { $0.filter { $0.0 == "vote_on_proposal" } }
        XCTAssertEqual(votes.count, 1)
        XCTAssertEqual(votes.first?.1, try TaggrCandid.jsonArguments([1, true, "confirmed-hash"]))
        await model.load(state)
        model.prepareVote(adopted: false, state: state, canonical: true)
        model.invalidate()
        await model.vote(state, canonical: true)
        XCTAssertNil(model.proposal)
        XCTAssertNil(model.pendingVote)
        XCTAssertEqual(calls.read { $0.filter { $0.0 == "vote_on_proposal" }.count }, 1)
        let other = TaggrProposalDetailState(id: 2)
        await other.load(state) // The API deliberately returns proposal 1.
        XCTAssertFalse(other.canVote(state, canonical: true))
        XCTAssertNil(other.proposal)
    }

    func testProposalLateLoadCannotOverwriteNewerLoad() async throws {
        let started = expectation(description: "first proposal request")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let count = LockedTestValue(0)
        let api = makeStubbedAPI { request in
            let method = self.requestMethodAndArg(from: request)?.method
            let data: Data
            if method == "proposal" {
                let first = count.read { $0 == 0 }
                count.mutate { $0 += 1 }
                if first { started.fulfill(); _ = release.wait(timeout: .now() + 5) }
                data = self.regressionProposal(status: first ? "Open" : "Executed")
            } else if method == "posts" {
                data = Data("[\(String(decoding: self.postEnvelopeFixture(), as: UTF8.self))]".utf8)
            } else { data = Data("{}".utf8) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(data))
        }
        let state = try regressionState(api: api)
        let model = TaggrProposalDetailState(id: 1)
        let first = Task { await model.load(state) }
        await fulfillment(of: [started], timeout: 2)
        await model.load(state)
        release.signal()
        await first.value
        XCTAssertEqual(model.proposal?.status, "Executed")
        XCTAssertFalse(model.busy)
    }

    func testFeaturePostFailureRestoresOnlyTargetAndPreventsDuplicateSubmission() async throws {
        let started = expectation(description: "reaction started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = LockedTestValue(0)
        let api = makeStubbedAPI { request in
            calls.mutate { $0 += 1 }
            started.fulfill(); _ = release.wait(timeout: .now() + 5)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(Data(#"{"Err":"denied"}"#.utf8)))
        }
        let state = try regressionState(api: api)
        let post = try JSONDecoder.taggr.decode(TaggrPostEnvelope.self, from: postEnvelopeFixture()).post
        let other = try JSONDecoder.taggr.decode(TaggrPostEnvelope.self, from: postEnvelopeFixture(id: 43)).post
        state.featurePosts.register([post, other])
        let first = Task { await state.react(postId: 42, reaction: 1) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(state.featurePosts.posts[42]?.reactions["1"], [7])
        await state.react(postId: 42, reaction: 2)
        state.updatePost(43) { $0.addingReaction(2, by: 7) }
        release.signal(); await first.value
        XCTAssertEqual(state.featurePosts.posts[42], post)
        XCTAssertEqual(state.featurePosts.posts[43]?.reactions["2"], [7])
        XCTAssertEqual(calls.read { $0 }, 1)
        XCTAssertNil(state.featurePosts.operations[42])
    }

    func testFeaturePostRefreshRetryDoesNotResubmitMutation() async throws {
        let calls = LockedTestValue<[String]>([])
        let reads = LockedTestValue(0)
        let api = makeStubbedAPI { request in
            let method = try XCTUnwrap(self.requestMethodAndArg(from: request)).method
            calls.mutate { $0.append(method) }
            var status = 200
            var data = Data("null".utf8)
            if method == "posts" {
                reads.mutate { $0 += 1 }
                if reads.read({ $0 }) == 1 { status = 500 }
                data = Data("[\(String(decoding: self.postEnvelopeFixture(), as: UTF8.self).replacingOccurrences(of: "\"body\": \"hello\"", with: "\"body\": \"refreshed\""))]".utf8)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Self.queryReply(data))
        }
        let state = try regressionState(api: api)
        state.featurePosts.register([try JSONDecoder.taggr.decode(TaggrPostEnvelope.self, from: postEnvelopeFixture()).post])
        await state.react(postId: 42, reaction: 1)
        XCTAssertEqual(state.featurePosts.operations[42], .refreshRequired)
        await state.react(postId: 42, reaction: 2)
        await state.refreshFeaturePost(42)
        XCTAssertEqual(state.featurePosts.posts[42]?.body, "refreshed")
        XCTAssertNil(state.featurePosts.operations[42])
        XCTAssertEqual(calls.read { $0.filter { $0 == "react" }.count }, 1)
    }

    func testFeaturePostResponseCannotRestorePreviousAccountData() async throws {
        let started = expectation(description: "mutation started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let api = makeStubbedAPI { request in
            started.fulfill(); _ = release.wait(timeout: .now() + 5)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(Data(#"{"Err":"denied"}"#.utf8)))
        }
        let state = try regressionState(api: api)
        state.featurePosts.register([try JSONDecoder.taggr.decode(TaggrPostEnvelope.self, from: postEnvelopeFixture()).post])
        let first = Task { await state.react(postId: 42, reaction: 1) }
        await fulfillment(of: [started], timeout: 2)
        state.currentUser = nil
        release.signal(); await first.value
        XCTAssertTrue(state.featurePosts.posts.isEmpty)
        XCTAssertTrue(state.featurePosts.operations.isEmpty)
        XCTAssertTrue(state.featurePosts.errors.isEmpty)
    }

    private func regressionRealmRequest(_ name: String) -> TaggrRealmCreationRequest {
        TaggrRealmCreationRequest(name: name, description: "description", controllers: "7", whitelist: "",
            labelColor: "#ffffff", penalty: 10, maxDownvotes: 0, adult: false, filterComments: true,
            safe: false, age: 0, balance: 0, followers: 0, ownTheme: false, themeColors: [:])
    }

    func testRealmCreateKeepsSubmittedNameAndRetriesOnlyJoining() async throws {
        let started = expectation(description: "create started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = LockedTestValue<[(String, Data)]>([])
        let joins = LockedTestValue(0)
        let api = makeStubbedAPI { request in
            let call = try XCTUnwrap(self.requestMethodAndArg(from: request))
            calls.mutate { $0.append((call.method, call.arg)) }
            let data: Data
            switch call.method {
            case "create_realm":
                started.fulfill(); _ = release.wait(timeout: .now() + 5)
                data = Data("null".utf8)
            case "realms": data = Data("[]".utf8)
            case "user": data = Self.currentUserFixture()
            case "toggle_realm_membership":
                joins.mutate { $0 += 1 }
                data = Data((joins.read { $0 } == 1 ? #"{"Err":"join denied"}"# : "true").utf8)
            default: data = Data("{}".utf8)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(data))
        }
        let state = try regressionState(api: api)
        let model = TaggrRealmCreationState()
        model.prepare(regressionRealmRequest("ALPHA"))
        let create = Task { await model.create(state) }
        await fulfillment(of: [started], timeout: 2)
        model.prepare(regressionRealmRequest("BETA"))
        release.signal(); await create.value
        XCTAssertEqual(model.createdName, "ALPHA")
        XCTAssertNil(model.completedName)
        await model.create(state)
        await model.join("ALPHA", state: state)
        XCTAssertEqual(model.completedName, "ALPHA")
        XCTAssertEqual(calls.read { $0.filter { $0.0 == "create_realm" }.count }, 1)
        XCTAssertTrue(calls.read { $0.filter { $0.0 == "toggle_realm_membership" }.allSatisfy { $0.1 == Data(#""ALPHA""#.utf8) } })
    }

    func testFeaturePollVoteRefreshesSharedPostAndUnknownUpdateStaysBlocked() async throws {
        for unknown in [false, true] {
            let updates = LockedTestValue(0)
            let api = makeStubbedAPI { request in
                let call = try XCTUnwrap(self.requestMethodAndArg(from: request))
                if call.method == "vote_on_poll" {
                    updates.mutate { $0 += 1 }
                    if unknown { throw URLError(.timedOut) }
                }
                let data = call.method == "posts"
                    ? Data("[\(String(decoding: self.postEnvelopeFixture(extensionJSON: #"{"Poll":{"options":["A"],"deadline":24,"votes":{"0":[7]},"voters":[7]}}"#), as: UTF8.self))]".utf8)
                    : Data("null".utf8)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(data))
            }
            let state = try regressionState(api: api)
            let post = try JSONDecoder.taggr.decode(TaggrPostEnvelope.self, from: postEnvelopeFixture(extensionJSON: #"{"Poll":{"options":["A"],"deadline":24,"votes":{},"voters":[]}}"#)).post
            state.featurePosts.register([post])
            await state.voteOnPoll(postId: 42, option: 0, anonymously: false)
            if unknown {
                XCTAssertEqual(state.featurePosts.operations[42], .uncertain)
                await state.refreshFeaturePost(42)
                await state.voteOnPoll(postId: 42, option: 0, anonymously: false)
                XCTAssertEqual(state.featurePosts.operations[42], .uncertain)
            } else { XCTAssertNil(state.featurePosts.operations[42]) }
            guard case .poll(let poll) = state.featurePosts.posts[42]?.extensionKind else { return XCTFail("Poll missing") }
            XCTAssertEqual(poll.votes[0], [7])
            XCTAssertEqual(updates.read { $0 }, 1)
        }
    }

    func testRealmUnknownCreationReconcilesOriginalNameWithoutResubmission() async throws {
        let createCount = LockedTestValue(0)
        let queriedNames = LockedTestValue<[Data]>([])
        let api = makeStubbedAPI { request in
            let call = try XCTUnwrap(self.requestMethodAndArg(from: request))
            let data: Data
            switch call.method {
            case "create_realm":
                createCount.mutate { $0 += 1 }
                throw URLError(.timedOut)
            case "realms":
                queriedNames.mutate { $0.append(call.arg) }
                data = createCount.read { $0 } == 0 ? Data("[]".utf8) : Self.safeRealmFixture("ALPHA")
            case "user": data = Data(#"{"id":7,"name":"alice","controlled_realms":["ALPHA"]}"#.utf8)
            default: data = Data("null".utf8)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(data))
        }
        let state = try regressionState(api: api)
        let model = TaggrRealmCreationState()
        model.prepare(regressionRealmRequest("ALPHA"))
        await model.create(state)
        XCTAssertTrue(model.uncertain)
        model.prepare(regressionRealmRequest("BETA"))
        await model.create(state)
        await model.reconcile(state)
        XCTAssertEqual(model.createdName, "ALPHA")
        XCTAssertEqual(createCount.read { $0 }, 1)
        XCTAssertTrue(queriedNames.read { $0.allSatisfy { $0 == Data(#"["ALPHA"]"#.utf8) } })
    }

    func testParityAmountsKeepUInt64Precision() {
        XCTAssertEqual(FeatureAmount.format(UInt64.max, decimals: 8), "184467440737.09551615")
        XCTAssertEqual(FeatureAmount.parse("184467440737.09551615", decimals: 8), UInt64.max)
        XCTAssertNil(FeatureAmount.parse("184467440737.09551616", decimals: 8))
        XCTAssertNil(FeatureAmount.parse("1.001", decimals: 2))
        XCTAssertNil(FeatureAmount.parse("-1", decimals: 8))
        XCTAssertNil(FeatureAmount.parse("1e3", decimals: 8))
        XCTAssertEqual(FeatureAmount.format(100, decimals: 2), "1")
        XCTAssertEqual(FeatureAmount.parse("0.01", decimals: 2), 1)
    }

    func testParityUserPreservesProtectedFieldsAndOldDefaults() throws {
        let data = Data(#"{"id":7,"name":"alice","about":"bio","governance":false,"show_posts_in_realms":false,"filters":{"users":[9],"noise":{"age_days":12,"safe":true,"balance":30,"num_followers":4}},"settings":{"links":"Home: https://example.com","pgp":"key"}}"#.utf8)
        let user = try JSONDecoder.taggr.decode(TaggrUser.self, from: data)
        XCTAssertFalse(user.governance)
        XCTAssertFalse(user.showPostsInRealms)
        XCTAssertEqual(user.filters.noise.ageDays, 12)
        XCTAssertEqual(user.filters.noise.balance, 30)
        XCTAssertTrue(user.filters.noise.safe)
        XCTAssertEqual(user.filters.noise.numFollowers, 4)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        XCTAssertEqual(try JSONDecoder.taggr.decode(TaggrUser.self, from: encoder.encode(user)), user)
        let legacy = try JSONDecoder.taggr.decode(TaggrUser.self, from: Data(#"{"id":1,"name":"old"}"#.utf8))
        XCTAssertTrue(legacy.governance)
        XCTAssertTrue(legacy.showPostsInRealms)
        XCTAssertEqual(legacy.filters.noise, TaggrRealmFilter())
    }

    func testParityProfileAndLinksAPIContract() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) { calls.append(call) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(Data("null".utf8)))
        }
        let identity = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        let user = try JSONDecoder.taggr.decode(TaggrUser.self, from: Data(#"{"id":7,"name":"alice","about":"bio","mode":"Mining","show_posts_in_realms":false,"filters":{"noise":{"age_days":12,"safe":true,"balance":30,"num_followers":4}},"settings":{"links":"old","pgp":"key","other":"keep"}}"#.utf8))
        var draft = TaggrProfileDraft(user)
        XCTAssertFalse(draft.profileChanged(from: user))
        draft.about = "updated"
        try await api.updateProfile(draft, preserving: user, identity: identity)
        try await api.updateLinks("Home: https://example.com", preserving: user.settings, identity: identity)
        XCTAssertEqual(calls.map(\.method), ["update_user", "update_user_settings"])
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: calls[0].arg), try JSONDecoder().decode(JSONValue.self, from: TaggrCandid.jsonArguments(["", "updated", [], user.filters.noise.jsonObject, true, "Mining", false])))
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: calls[1].arg), ["links":"Home: https://example.com", "pgp":"key", "other":"keep"])
        draft.controllers = "invalid principal"
        XCTAssertThrowsError(try draft.validate())
        draft.controllers = "aaaaa-aa"
        draft.links = "Bad: http://example.com"
        XCTAssertThrowsError(try draft.validate())
        draft.links = "Home: https://example.com"
        XCTAssertNoThrow(try draft.validate())
    }

    func testParityInviteStopAndOptionalArguments() async throws {
        let unused = TaggrInvite(credits: 100, creditsPerUser: 50, joinedUserIds: [], realmId: nil, inviterUserId: 7)
        let used = TaggrInvite(credits: 50, creditsPerUser: 50, joinedUserIds: [8], realmId: "TEST", inviterUserId: 7)
        XCTAssertFalse(unused.canStop)
        XCTAssertTrue(used.canStop)
        XCTAssertThrowsError(try unused.validateCredits(0))
        XCTAssertThrowsError(try used.validateCredits(51))
        XCTAssertNoThrow(try used.validateCredits(0))
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) { calls.append(call) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(Data("null".utf8)))
        }
        let identity = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        try await api.createInvite(credits: 100, perUser: 50, realm: "", identity: identity)
        try await api.updateInvite(code: "code", credits: 0, realm: "", identity: identity)
        try await api.voteOnProposal(id: 3, adopted: true, data: "hash", identity: identity)
        try await api.voteOnProposal(id: 3, adopted: false, data: "", identity: identity)
        XCTAssertEqual(calls.map(\.method), ["create_invite", "update_invite", "vote_on_proposal", "vote_on_proposal"])
        XCTAssertEqual(calls[0].arg, try TaggrCandid.jsonArguments([100, 50, nil]))
        XCTAssertEqual(calls[1].arg, try TaggrCandid.jsonArguments(["code", 0, nil]))
        XCTAssertEqual(calls[2].arg, try TaggrCandid.jsonArguments([3, true, "hash"]))
        XCTAssertEqual(calls[3].arg, try TaggrCandid.jsonArguments([3, false, ""]))
    }

    func testParityProposalPayloadsAndVotingGates() throws {
        for payload in [#"{"Release":{"commit":"abc","hash":"def"}}"#, #"{"Rewards":{"receiver":"aaaaa-aa","minted":1}}"#, #"{"Funding":["aaaaa-aa",2]}"#, #"{"ICPTransfer":[[1,2],{"e8s":3}]}"#, #"{"AddRealmController":["TEST",7]}"#] {
            let data = Data("{\"id\":1,\"proposer\":7,\"timestamp\":1,\"post_id\":9,\"status\":\"Open\",\"payload\":\(payload),\"bulletins\":[[7,true,1]],\"voting_power\":3}".utf8)
            let proposal = try JSONDecoder.taggr.decode(TaggrProposal.self, from: data)
            XCTAssertTrue(proposal.canVote(userID: 8, canonical: true))
            XCTAssertFalse(proposal.canVote(userID: 7, canonical: true))
            XCTAssertFalse(proposal.canVote(userID: nil, canonical: true))
            XCTAssertFalse(proposal.canVote(userID: 8, canonical: false))
            XCTAssertEqual(proposal.percentage(adopted: true), "33.34%")
            XCTAssertEqual(proposal.power(adopted: false), 0)
            XCTAssertEqual(try proposal.voteData(adopted: false, input: "ignored", decimals: 2, maximum: 100), "")
            switch proposal.payload {
            case .release:
                XCTAssertThrowsError(try proposal.voteData(adopted: true, input: "", decimals: 2, maximum: 100))
                XCTAssertEqual(try proposal.voteData(adopted: true, input: "hash", decimals: 2, maximum: 100), "hash")
            case .rewards:
                XCTAssertEqual(try proposal.voteData(adopted: true, input: "1", decimals: 2, maximum: 100), "1")
                XCTAssertThrowsError(try proposal.voteData(adopted: true, input: "2", decimals: 2, maximum: 100))
                XCTAssertThrowsError(try proposal.voteData(adopted: true, input: "0.5", decimals: 2, maximum: 100))
            default:
                XCTAssertEqual(try proposal.voteData(adopted: true, input: "ignored", decimals: 2, maximum: 100), "")
            }
        }
        for status in ["Open", "Executed", "Future"] {
            let data = Data("{\"id\":1,\"proposer\":7,\"timestamp\":1,\"post_id\":9,\"status\":\"\(status)\",\"payload\":{\"Future\":{}},\"bulletins\":[],\"voting_power\":0}".utf8)
            XCTAssertFalse(try JSONDecoder.taggr.decode(TaggrProposal.self, from: data).canVote(userID: 8, canonical: true))
        }
    }

    func testParityProposalVotingPowerRoundsUpWithoutLosingIntegerPrecision() {
        XCTAssertEqual(TaggrProposal.displayedPower(19_601_330, decimals: 2), 196_014)
        XCTAssertEqual(TaggrProposal.displayedPower(17_616_579, decimals: 2), 176_166)
        XCTAssertEqual(TaggrProposal.displayedPower(100, decimals: 2), 1)
        XCTAssertEqual(TaggrProposal.displayedPower(1, decimals: 2), 1)
        XCTAssertEqual(TaggrProposal.displayedPower(0, decimals: 2), 0)
        XCTAssertEqual(TaggrProposal.displayedPower(UInt64.max, decimals: 0), UInt64.max)
        XCTAssertEqual(TaggrProposal.displayedPower(UInt64.max, decimals: 19), 2)
        XCTAssertEqual(TaggrProposal.displayedPower(UInt64.max, decimals: 20), 1)
    }

    func testParityFeatureContextRejectsAccountChange() throws {
        let state = makeCoordinator()
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Data(#"{"id":7,"name":"alice"}"#.utf8))
        let context = TaggrFeatureContext(state)
        XCTAssertTrue(context.matches(state))
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Data(#"{"id":8,"name":"bob"}"#.utf8))
        XCTAssertFalse(context.matches(state))
        XCTAssertThrowsError(try context.requireCurrent(state))
        state.currentUser = nil
        XCTAssertFalse(context.matches(state))
    }

    func testParityRoutesRoundTrip() {
        for route: TaggrRoute in [.bookmarks, .invites, .proposals, .proposal(7), .search("@alice /TEST"), .transactions("aaaaa-aa")] {
            XCTAssertEqual(TaggrNavigation.route(from: TaggrNavigation.universalURL(for: route)), route)
        }
    }

    func testParitySearchInviteAndTransactionDecoding() throws {
        let search = try JSONDecoder.taggr.decode(TaggrSearchResult.self, from: Data(#"{"id":9,"user_id":7,"generic_id":"TEST","result":"realm","relevant":"text"}"#.utf8))
        XCTAssertEqual(search.userId, 7)
        XCTAssertEqual(search.genericId, "TEST")
        let invites = try JSONDecoder.taggr.decode([TaggrInviteEntry].self, from: Data(#"[["code",{"credits":100,"credits_per_user":50,"joined_user_ids":[8],"realm_id":null,"inviter_user_id":7}]]"#.utf8))
        XCTAssertEqual(invites.first?.id, "code")
        XCTAssertNil(invites.first?.invite.realmId)
        XCTAssertEqual(invites.first?.invite.joinedUserIds, [8])
        let entries = try JSONDecoder.taggr.decode([TaggrTransactionEntry].self, from: Data(#"[[1,{"timestamp":123,"from":{"owner":"aaaaa-aa","subaccount":null},"to":{"owner":"2vxsx-fae","subaccount":[0]},"amount":18446744073709551615,"fee":10,"memo":[1,2]}]]"#.utf8))
        XCTAssertEqual(entries.first?.transaction.amount, UInt64.max)
        XCTAssertEqual(entries.first?.transaction.from.address, "aaaaa-aa")
        XCTAssertEqual(entries.first?.transaction.to.address, "2vxsx-fae")
        XCTAssertEqual(entries.first?.transaction.memo, [1, 2])
        let config = try JSONDecoder.taggr.decode(TaggrConfig.self, from: Data(#"{"identity_change_cost":10,"min_credits_for_inviting":50,"realm_cost":100,"max_realm_name":12,"default_max_downvotes":5,"max_funding_amount":10000,"proposal_approval_threshold":66}"#.utf8))
        XCTAssertEqual(config.identityChangeCost, 10)
        XCTAssertEqual(config.minCreditsForInviting, 50)
        XCTAssertEqual(config.realmCost, 100)
        XCTAssertEqual(config.maxRealmName, 12)
        XCTAssertEqual(config.defaultMaxDownvotes, 5)
        XCTAssertEqual(config.maxFundingAmount, 10000)
        XCTAssertEqual(config.proposalApprovalThreshold, 66)
    }
    func testParityICRCAccountMatchesWebEncoding() throws {
        let address = "aaaaa-aa-nygwkoy.1"
        let account = try TaggrFeatureAccount(address)
        XCTAssertEqual(account.owner, "aaaaa-aa")
        XCTAssertEqual(account.subaccount, String(repeating: "0", count: 63) + "1")
        XCTAssertEqual(TaggrFeatureAccount.address(owner: "aaaaa-aa", subaccount: Array(repeating: 0, count: 31) + [1]), address)
        XCTAssertThrowsError(try TaggrFeatureAccount("aaaaa-aa-invalid.1"))
        XCTAssertThrowsError(try TaggrFeatureAccount("aaaaa-aa-nygwkoy.z"))
        XCTAssertEqual(try TaggrFeatureAccount("aaaaa-aa").subaccount, String(repeating: "0", count: 64))
    }
    func testParityFeatureBackNavigationPreservesOrigin() {
        let state = makeCoordinator()
        state.route = .settings
        state.navigate(to: .proposals)
        state.navigate(to: .proposal(7))
        state.navigate(to: .transactions("aaaaa-aa"))
        state.returnFromFeature(fallback: .search(""))
        XCTAssertEqual(state.route, .proposal(7))
        state.returnFromFeature(fallback: .settings)
        XCTAssertEqual(state.route, .proposals)
        state.returnFromFeature(fallback: .settings)
        XCTAssertEqual(state.route, .settings)
    }
    func testParityPartialSaveAndRealmJoinRecovery() throws {
        let original = try JSONDecoder.taggr.decode(TaggrUser.self, from: Data(#"{"id":7,"name":"alice","mode":"Mining","about":"old"}"#.utf8))
        var draft = TaggrProfileDraft(original)
        draft.about = "saved"
        draft.links = "Home: https://example.com"
        let partial = try JSONDecoder.taggr.decode(TaggrUser.self, from: Data(#"{"id":7,"name":"alice","mode":"Mining","about":"saved"}"#.utf8))
        XCTAssertEqual(draft.unsavedFields(comparedTo: partial), ["Links"])
        XCTAssertTrue(TaggrRealmCreationProgress.editing.canCreate)
        XCTAssertFalse(TaggrRealmCreationProgress.uncertain.canCreate)
        let created = TaggrRealmCreationProgress.created("TEST")
        XCTAssertFalse(created.canCreate)
        XCTAssertEqual(created.createdName, "TEST")
    }
    func testParityUnregisteredPrincipalHasNoUser() async throws {
        let api = makeStubbedAPI { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(Data("null".utf8)))
        }
        let user = try await api.featureLookupUser("aaaaa-aa")
        XCTAssertNil(user)
    }
}
