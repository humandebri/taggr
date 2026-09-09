import XCTest
import CryptoKit
import SwiftUI
import UIKit
@testable import TAGGR

extension TaggrTests {
    func testProfileFiltersDecodeAndSurviveUserCopies() throws {
        let user = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.profileUserFixture(muted: [8]))
        XCTAssertEqual(user.filters.users, [8])
        XCTAssertEqual(user.updatingSettings([:]).filters.users, [8])
        XCTAssertEqual(user.updatingNotifications([:]).filters.users, [8])
        XCTAssertEqual(try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.userFixture()).filters.users, [])
    }

    func testProfileUserListsAndShareURLs() throws {
        let user = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.profileUserFixture(follows: [9, 7, 8, 8], followers: [9, 8]))
        XCTAssertEqual(ProfileUserListKind.follows.userIDs(in: user), [8, 9])
        XCTAssertEqual(ProfileUserListKind.followers.userIDs(in: user), [8, 9])
        let journal = TaggrNavigation.journalURL(userID: 8)
        XCTAssertEqual(journal.path, "/journal/8")
        XCTAssertEqual(TaggrNavigation.route(from: journal), .profile("8"))
        XCTAssertEqual(TaggrNavigation.route(from: TaggrNavigation.universalURL(for: .profile("8"))), .profile("8"))
    }

    func testProfileCreditAmountValidation() {
        XCTAssertEqual(ProfileCreditAmount.parse(" 10 "), 10)
        for invalid in ["", "0", "-1", "1.5", "1e3", "1,000", String(Int.max) + "0"] {
            XCTAssertNil(ProfileCreditAmount.parse(invalid), invalid)
        }
        XCTAssertEqual(ProfileCreditAmount.total(amount: 10, fee: 1, balance: 11), 11)
        XCTAssertNil(ProfileCreditAmount.total(amount: 10, fee: 1, balance: 10))
        XCTAssertNil(ProfileCreditAmount.total(amount: Int.max, fee: 1, balance: Int.max))
        XCTAssertNil(ProfileCreditAmount.total(amount: 1, fee: -1, balance: 10))
    }

    func testProfileUnfollowAcceptsFalseAndRefreshesState() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            let call = try XCTUnwrap(self.requestMethodAndArg(from: request))
            calls.append(call)
            let body = call.method == "toggle_following_user" ? Data("false".utf8) : try Self.profileUserFixture()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(body))
        }
        let state = try profileTestState(api: api, follows: [7, 8])
        let result = await state.setFollowingUser(8, following: false)
        XCTAssertEqual(result, .applied)
        XCTAssertFalse(state.isFollowingUser(8))
        XCTAssertEqual(calls.map(\.method), ["toggle_following_user", "user"])
        XCTAssertEqual(calls[0].arg, try TaggrCandid.jsonArguments([8]))
        XCTAssertFalse(state.contentStore.profileActionInFlight)
    }

    func testProfileMuteAndFollowRefreshTheirLinkedState() async throws {
        var following = false
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            let call = try XCTUnwrap(self.requestMethodAndArg(from: request))
            calls.append(call)
            let body: Data
            switch call.method {
            case "toggle_filter": body = Data(#"{"Ok":null}"#.utf8)
            case "toggle_following_user": following = true; body = Data("true".utf8)
            default: body = try Self.profileUserFixture(follows: following ? [7, 8] : [7], muted: following ? [] : [8])
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(body))
        }
        let state = try profileTestState(api: api, follows: [7, 8])
        let muted = await state.setMutedUser(8, muted: true)
        XCTAssertEqual(muted, .applied)
        XCTAssertTrue(state.isMutedUser(8))
        XCTAssertFalse(state.isFollowingUser(8))
        XCTAssertEqual(calls[0].arg, try TaggrCandid.jsonArguments(["user", "8"]))
        let followed = await state.setFollowingUser(8, following: true)
        XCTAssertEqual(followed, .applied)
        XCTAssertTrue(state.isFollowingUser(8))
        XCTAssertFalse(state.isMutedUser(8))
    }

    func testProfileCreditsSendOnceAndUpdateBalance() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            let call = try XCTUnwrap(self.requestMethodAndArg(from: request))
            calls.append(call)
            let body = call.method == "transfer_credits" ? Data(#"{"Ok":null}"#.utf8) : try Self.profileUserFixture(credits: 89)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(body))
        }
        let state = try profileTestState(api: api)
        let result = await state.sendProfileCredits(userID: 8, amount: 10, expectedFee: 1)
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(state.currentUser?.cycles, 89)
        XCTAssertEqual(calls.map(\.method), ["transfer_credits", "user"])
        XCTAssertEqual(calls[0].arg, try TaggrCandid.jsonArguments([8, 10]))
        let invalid = await state.sendProfileCredits(userID: 8, amount: 89, expectedFee: 1)
        XCTAssertEqual(invalid, .rejected)
        XCTAssertEqual(calls.count, 2)
    }

    func testProfileUpdateRejectionAndUnknownOutcomeDoNotRetry() async throws {
        for rejected in [true, false] {
            var calls = 0
            let api = makeStubbedAPI { request in
                calls += 1
                if !rejected { throw URLError(.notConnectedToInternet) }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(Data(#"{"Err":"insufficient credits"}"#.utf8)))
            }
            let state = try profileTestState(api: api)
            let result = await state.sendProfileCredits(userID: 8, amount: 10, expectedFee: 1)
            XCTAssertEqual(result, rejected ? .rejected : .uncertain)
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(state.currentUser?.cycles, 100)
            XCTAssertNotNil(state.errorMessage)
        }
    }

    func testProfileActionsRejectConcurrentAndSelfUpdates() async throws {
        let started = expectation(description: "follow request started")
        let release = DispatchSemaphore(value: 0)
        var updateCalls = 0
        let api = makeStubbedAPI { request in
            let method = self.requestMethodAndArg(from: request)?.method
            let body: Data
            if method == "toggle_following_user" {
                updateCalls += 1
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
                body = Data("true".utf8)
            } else {
                body = try Self.profileUserFixture(follows: [7, 8])
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(body))
        }
        let state = try profileTestState(api: api)
        let first = Task { await state.setFollowingUser(8, following: true) }
        await fulfillment(of: [started], timeout: 2)
        let concurrent = await state.setFollowingUser(8, following: true)
        XCTAssertEqual(concurrent, .rejected)
        release.signal()
        _ = await first.value
        let own = await state.sendProfileCredits(userID: 7, amount: 1, expectedFee: 1)
        XCTAssertEqual(own, .rejected)
        XCTAssertEqual(updateCalls, 1)
    }

    func testProfileUpdateDoesNotRestoreUserAfterSignOut() async throws {
        let started = expectation(description: "follow request started")
        let release = DispatchSemaphore(value: 0)
        var calls = 0
        let api = makeStubbedAPI { request in
            calls += 1
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(Data("true".utf8)))
        }
        let state = try profileTestState(api: api)
        let task = Task { await state.setFollowingUser(8, following: true) }
        await fulfillment(of: [started], timeout: 2)
        state.authSession = nil
        state.currentUser = nil
        state.route = .settings
        release.signal()
        _ = await task.value
        XCTAssertNil(state.currentUser)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(calls, 1)
    }

    func testMutedFeedsUseSignedQueriesOnlyWhenAuthenticated() async throws {
        for authenticated in [true, false] {
            var requestBodies: [Data] = []
            let api = makeStubbedAPI { request in
                requestBodies.append(try XCTUnwrap(Self.requestBody(from: request)))
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(Data("[]".utf8)))
            }
            let state = try profileTestState(api: api)
            if !authenticated { state.authSession = nil }
            for mode: TaggrFeedMode in [.hot, .latest, .realm("DEV")] {
                await state.loadFeed(mode: mode, reset: true)
            }
            XCTAssertEqual(requestBodies.count, 3)
            for body in requestBodies {
                let envelope = try XCTUnwrap(cborMap(from: body))
                XCTAssertEqual(value(named: "sender_sig", in: envelope) != nil, authenticated)
            }
            XCTAssertNil(state.errorMessage)
        }
    }

    func testProfileInteractiveUIReview() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--profile-ui-review") else {
            throw XCTSkip("Run with --profile-ui-review for native UI verification.")
        }
        var following = false
        let api = makeStubbedAPI { request in
            let call = try XCTUnwrap(self.requestMethodAndArg(from: request))
            let body: Data
            switch call.method {
            case "users_data": body = Data(#"{"8":"bob","9":"carol"}"#.utf8)
            case "toggle_following_user": following.toggle(); body = Data((following ? "true" : "false").utf8)
            default:
                let args = try JSONSerialization.jsonObject(with: call.arg) as? [Any]
                let isPublic = ((args?.last as? [String])?.isEmpty == false)
                body = try Self.profileUserFixture(id: isPublic ? 8 : 7, follows: following ? [7, 8] : [7], followers: [9])
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(body))
        }
        let state = try profileTestState(api: api)
        state.profile = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.profileUserFixture(id: 8, follows: [8, 9], followers: [9]))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { ProfileView().environment(state) })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .seconds(120))
    }

    private func profileTestState(api: TaggrAPI, follows: [Int] = [7]) throws -> TaggrAppCoordinator {
        let state = TaggrAppCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.profileUserFixture(follows: follows))
        state.cache = TaggrBackendCache(stats: nil, config: try JSONDecoder.taggr.decode(TaggrConfig.self, from: Data(#"{"credit_transaction_fee":1}"#.utf8)))
        state.route = .profile("8")
        return state
    }

    nonisolated private static func profileUserFixture(id: Int = 7, follows: [Int] = [7], followers: [Int] = [], muted: [Int] = [], credits: Int = 100) throws -> Data {
        var user = try JSONSerialization.jsonObject(with: userFixture(id: id, name: id == 7 ? "alice" : "bob")) as! [String: Any]
        user["followees"] = follows
        user["followers"] = followers
        user["filters"] = ["users": muted]
        user["cycles"] = credits
        return try JSONSerialization.data(withJSONObject: user)
    }
}
