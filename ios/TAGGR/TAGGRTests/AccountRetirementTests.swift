import CryptoKit
import Foundation
import XCTest
import SwiftUI
import UIKit
@testable import TAGGR
@testable import ICNativeClient

@MainActor
extension TaggrTests {
    private func retirementFixture(credits: Int = 2000, stopped: Bool = false) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.currentUserFixture()) as? [String: Any])
        object["mode"] = "Mining"
        object["cycles"] = credits
        object["deactivated"] = stopped
        object["settings"] = ["links": "private link", "pgp": "private pgp", "theme": "dark", "bucket_creation_state": "retained"]
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testRetirementClearsProfileThenStopsAndClearsCredentials() async throws {
        let stopped = LockedTestValue(false)
        let calls = LockedTestValue<[(String, Data)]>([])
        let active = try retirementFixture()
        let inactive = try retirementFixture(stopped: true)
        let api = makeStubbedAPI { request in
            let call = try XCTUnwrap(self.requestMethodAndArg(from: request))
            calls.mutate { $0.append((call.method, call.arg)) }
            let data: Data
            switch call.method {
            case "user": data = stopped.read { $0 } ? inactive : active
            case "config": data = Data(#"{"account_activation_cost":1000}"#.utf8)
            case "crypt": stopped.mutate { $0 = true }; data = Data(#"{"Ok":3}"#.utf8)
            default: data = Data(#"{"Ok":null}"#.utf8)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(data))
        }
        let state = makeCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: active)
        try state.identityStore.save(try XCTUnwrap(state.authSession))
        let key = state.retirementKey
        state.feed = [samplePost(id: 42, body: "cached", files: [:])]
        state.contentStore.profilePosts = state.feed
        await state.retireAccount()
        XCTAssertTrue(state.retirementCompleted, state.retirementMessage ?? "")
        XCTAssertNil(state.authSession)
        XCTAssertNil(try state.identityStore.load())
        XCTAssertTrue(state.feed.isEmpty && state.contentStore.profilePosts.isEmpty)
        XCTAssertEqual(state.retirementDefaults.string(forKey: key), "cleanup")
        let captured = calls.read { $0 }
        XCTAssertEqual(captured.map { $0.0 }, ["user", "config", "update_user", "update_user_settings", "crypt", "user"])
        guard captured.count == 6 else { return }
        let user = try JSONDecoder.taggr.decode(TaggrUser.self, from: active)
        let expected = try TaggrCandid.jsonArguments(["", "", user.controllers, user.filters.noise.jsonObject, user.governance, try XCTUnwrap(user.mode), user.showPostsInRealms])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: captured[2].1) as? NSArray, try JSONSerialization.jsonObject(with: expected) as? NSArray)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: captured[3].1) as? [String: String], ["theme": "dark", "bucket_creation_state": "retained"])
        // Only the non-secret stage is persisted by the retirement workflow.
        XCTAssertEqual(state.retirementDefaults.dictionaryRepresentation().filter { $0.key.hasPrefix("taggr.retirement.") }.count, 1)
    }

    func testRetirementCleanupFailureRetriesLocallyAfterRestart() async throws {
        let inactive = try retirementFixture(stopped: true)
        let methods = LockedTestValue<[String]>([])
        let api = makeStubbedAPI { request in
            methods.mutate { $0.append((try? self.requestMethodAndArg(from: request))?.method ?? "unknown") }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(inactive))
        }
        let keychain = TaggrTestKeychain()
        let initial = makeCoordinator(api: api)
        let store = ICIdentityStore(configuration: initial.runtimeConfig.icClientConfiguration, service: UUID().uuidString, account: "session", keychain: keychain)
        let state = makeCoordinator(api: api, identityStore: store)
        let identity = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.authSession = identity
        try store.save(identity)
        try state.saveRetirementStage("uncertain", key: state.retirementKey)
        keychain.deletionStatus = errSecInteractionNotAllowed
        await state.retireAccount()
        XCTAssertEqual(state.retirementStage, "cleanup")
        XCTAssertFalse(state.retirementCompleted)
        XCTAssertNotNil(state.authSession)
        XCTAssertEqual(state.retirementActionTitle, "Finish on this device")
        XCTAssertTrue(state.retirementMessage?.contains("device") == true)
        let restarted = makeCoordinator(api: api, identityStore: store)
        restarted.retirementDefaults = state.retirementDefaults
        restarted.authSession = identity
        restarted.feed = [samplePost(id: 42, body: "cached", files: [:])]
        keychain.deletionStatus = errSecSuccess
        await restarted.retireAccount()
        XCTAssertTrue(restarted.retirementCompleted)
        XCTAssertNil(restarted.authSession)
        XCTAssertNil(try store.load())
        XCTAssertTrue(restarted.feed.isEmpty)
        XCTAssertEqual(methods.read { $0 }, ["user"])
    }

    func testRetirementConfirmedResponseNeverResendsWhileStateIsUnavailable() async throws {
        let methods = LockedTestValue<[String]>([])
        let api = makeStubbedAPI { request in
            methods.mutate { $0.append((try? self.requestMethodAndArg(from: request))?.method ?? "unknown") }
            throw URLError(.notConnectedToInternet)
        }
        let state = makeCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        try state.saveRetirementStage("confirmed", key: state.retirementKey)
        await state.retireAccount()
        await state.retireAccount()
        XCTAssertEqual(methods.read { $0 }, ["user", "user"])
        XCTAssertEqual(state.retirementStage, "confirmed")
        XCTAssertFalse(state.retirementCompleted)
        XCTAssertEqual(state.retirementActionTitle, "Check status")
    }

    func testRetirementPersistedStagesHaveDistinctStatusAndActions() throws {
        let state = makeCoordinator(api: makeStubbedAPI { _ in throw URLError(.notConnectedToInternet) })
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        var titles = Set<String>()
        for stage in ["preparing", "uncertain", "confirmed", "cleanup"] {
            try state.saveRetirementStage(stage, key: state.retirementKey)
            titles.insert(state.retirementStatusTitle)
            XCTAssertFalse(state.retirementStatusDetail.isEmpty)
            XCTAssertEqual(state.retirementActionTitle, stage == "preparing" ? "Retry preparation" : stage == "cleanup" ? "Finish on this device" : "Check status")
        }
        XCTAssertEqual(titles.count, 4)
    }

    func testRetirementInsufficientCreditsDoesNotMutate() async throws {
        let fixture = try retirementFixture(credits: 999)
        let methods = LockedTestValue<[String]>([])
        let api = makeStubbedAPI { request in
            let method = try XCTUnwrap(self.requestMethodAndArg(from: request)).method
            methods.mutate { $0.append(method) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(method == "user" ? fixture : Data(#"{"account_activation_cost":1000}"#.utf8)))
        }
        let state = makeCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        await state.retireAccount()
        XCTAssertEqual(methods.read { $0 }, ["user", "config"])
        XCTAssertNil(state.retirementStage)
        XCTAssertTrue(state.retirementMessage?.contains("1000") == true)
        XCTAssertFalse(state.accountRetired)
    }

    func testRetirementUncertainStopNeverResendsAfterRestart() async throws {
        let fixture = try retirementFixture()
        let methods = LockedTestValue<[String]>([])
        let api = makeStubbedAPI { request in
            let method = try XCTUnwrap(self.requestMethodAndArg(from: request)).method
            methods.mutate { $0.append(method) }
            if method == "crypt" { throw URLError(.networkConnectionLost) }
            let data = method == "user" ? fixture : Data((method == "config" ? #"{"account_activation_cost":1000}"# : #"{"Ok":null}"#).utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(data))
        }
        let state = makeCoordinator(api: api)
        let identity = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.authSession = identity
        await state.retireAccount()
        XCTAssertEqual(state.retirementStage, "uncertain")
        await state.retireAccount()
        let restarted = makeCoordinator(api: api)
        restarted.retirementDefaults = state.retirementDefaults
        restarted.authSession = identity
        XCTAssertTrue(restarted.accountRetired)
        await restarted.retireAccount()
        XCTAssertEqual(methods.read { $0.filter { $0 == "crypt" }.count }, 1)
        XCTAssertEqual(restarted.retirementStage, "uncertain")
        do { _ = try await api.updateJSON("react", args: [1, 1], identity: identity); XCTFail("SNS update accepted") } catch {}
    }

    func testRetirementProfileFailureDoesNotStop() async throws {
        let fixture = try retirementFixture()
        let methods = LockedTestValue<[String]>([])
        let api = makeStubbedAPI { request in
            let method = try XCTUnwrap(self.requestMethodAndArg(from: request)).method
            methods.mutate { $0.append(method) }
            let data: Data
            switch method {
            case "user": data = fixture
            case "config": data = Data(#"{"account_activation_cost":1000}"#.utf8)
            case "update_user_settings": data = Data(#"{"Err":"failed"}"#.utf8)
            default: data = Data(#"{"Ok":null}"#.utf8)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(data))
        }
        let state = makeCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        await state.retireAccount()
        XCTAssertFalse(methods.read { $0.contains("crypt") })
        XCTAssertEqual(state.retirementStage, "preparing")
        XCTAssertTrue(state.retirementMessage?.contains("already") == true)
    }

    func testAlreadyStoppedAccountDoesNotEncryptAgain() async throws {
        let fixture = try retirementFixture(stopped: true)
        let methods = LockedTestValue<[String]>([])
        let api = makeStubbedAPI { request in
            let method = try XCTUnwrap(self.requestMethodAndArg(from: request)).method
            methods.mutate { $0.append(method) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(fixture))
        }
        let state = makeCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        await state.retireAccount()
        XCTAssertEqual(methods.read { $0 }, ["user"])
        XCTAssertTrue(state.accountRetired)
        XCTAssertFalse(state.retirementCompleted)
        XCTAssertTrue(state.retirementMessage?.contains("already stopped") == true)
    }

    func testDefiniteStopRejectionAllowsRetryWithoutTreatingItAsSuccess() async throws {
        let fixture = try retirementFixture()
        let count = LockedTestValue(0)
        let api = makeStubbedAPI { request in
            let method = try XCTUnwrap(self.requestMethodAndArg(from: request)).method
            if method == "crypt" { count.mutate { $0 += 1 } }
            let data: Data
            switch method {
            case "user": data = fixture
            case "config": data = Data(#"{"account_activation_cost":1000}"#.utf8)
            case "crypt": data = Data(#"{"Err":"not enough credits"}"#.utf8)
            default: data = Data(#"{"Ok":null}"#.utf8)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(data))
        }
        let state = makeCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        await state.retireAccount()
        XCTAssertEqual(state.retirementStage, "preparing")
        XCTAssertFalse(state.retirementCompleted)
        await state.retireAccount()
        XCTAssertEqual(count.read { $0 }, 2)
    }

    func testRetirementGuardsDoubleTapAndDifferentIdentity() async throws {
        let fixture = try retirementFixture()
        let started = expectation(description: "profile lookup")
        let release = DispatchSemaphore(value: 0)
        let methods = LockedTestValue<[String]>([])
        let api = makeStubbedAPI { request in
            let method = try XCTUnwrap(self.requestMethodAndArg(from: request)).method
            methods.mutate { $0.append(method) }
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(fixture))
        }
        let state = makeCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        let first = Task { await state.retireAccount() }
        await fulfillment(of: [started], timeout: 3)
        await state.retireAccount()
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        release.signal()
        await first.value
        XCTAssertEqual(methods.read { $0 }, ["user"])
        XCTAssertNil(state.retirementStage)
        XCTAssertFalse(state.retirementBusy)
    }

    func testRetirementStoppedScreen() async throws {
        let fixture = try retirementFixture(stopped: true)
        let api = makeStubbedAPI { request in
            let method = self.requestMethodAndArg(from: request)?.method ?? ""
            let data = method == "user" ? fixture : Self.candidTokens(200_000_000)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(data))
        }
        let state = makeCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: fixture)
        state.cache = TaggrBackendCache(stats: nil, config: try JSONDecoder.taggr.decode(TaggrConfig.self, from: Data(#"{"token_decimals":8}"#.utf8)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: RootView().environment(state))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .seconds(1))
        window.layoutIfNeeded()
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: screenshot)
        attachment.lifetime = .keepAlways
        add(attachment)
        try screenshot.pngData()?.write(to: URL(fileURLWithPath: "/tmp/taggr-retirement-screen.png"))
        XCTAssertTrue(state.accountRetired)
        XCTAssertFalse(state.canAccessUGC)
        for stage in ["preparing", "uncertain", "confirmed", "cleanup"] {
            try state.saveRetirementStage(stage, key: state.retirementKey)
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
            let rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let stageAttachment = XCTAttachment(image: rendered)
            stageAttachment.name = "retirement-\(stage)"
            stageAttachment.lifetime = .keepAlways
            add(stageAttachment)
            try rendered.pngData()?.write(to: URL(fileURLWithPath: "/tmp/taggr-retirement-\(stage).png"))
        }
    }

    func testRetirementChangedCostRequiresNewConfirmation() async throws {
        let fixture = try retirementFixture(credits: 3000)
        let methods = LockedTestValue<[String]>([])
        let api = makeStubbedAPI { request in
            let method = try XCTUnwrap(self.requestMethodAndArg(from: request)).method
            methods.mutate { $0.append(method) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(method == "user" ? fixture : Data(#"{"account_activation_cost":2000}"#.utf8)))
        }
        let state = makeCoordinator(api: api)
        state.authSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        state.cache = TaggrBackendCache(stats: nil, config: try JSONDecoder.taggr.decode(TaggrConfig.self, from: Data(#"{"account_activation_cost":1000}"#.utf8)))
        await state.retireAccount()
        XCTAssertEqual(methods.read { $0 }, ["user", "config"])
        XCTAssertNil(state.retirementStage)
        XCTAssertEqual(state.cache?.config?.accountActivationCost, 2000)
        XCTAssertTrue(state.retirementMessage?.contains("changed") == true)
    }

    func testRetirementSeedIs32RandomBytes() throws {
        let first = try TaggrAppCoordinator.retirementSeed()
        let second = try TaggrAppCoordinator.retirementSeed()
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit })
        XCTAssertNotEqual(first, second)
    }
}
