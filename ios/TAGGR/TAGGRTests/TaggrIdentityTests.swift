import CryptoKit
import Security
import SwiftUI
import UIKit
@testable import ICNativeClient
import XCTest
@testable import TAGGR

extension TaggrTests {
    func testSeedPhraseMatchesWebIdentity() throws {
        // Generated with Web's SHA-256 loop and @dfinity/identity, not CryptoKit.
        let fixtures = [
            ("taggr-test-only-seed", "9a6e0a77607f916df171a390a22e2d766cdf6bae3f018e33fe02aeacda63f060", "b4hy7-sh3si-jcy5w-2wvrx-ft33v-tblad-4rjuh-giw73-vtxwt-awuyd-qqe"),
            ("  日本語 Seed 🔑  ", "b93b548230ec12a78512e2a10d0fc07e603e8a601dfc4868ca4d61f672973023", "nssj6-ror7n-uquzu-3sagw-q6owa-g2kmk-x67qv-hyw4a-4dmen-ptb2m-xqe"),
            ("\u{00e9}", "fb6e8cc5715e77484458c6cfc56b56ae1c6f696cf5a147fd4fdab4bf3e23298a", "uygcv-4rp3k-wcl7g-spjwk-srcos-tryii-45k2e-au6lp-aagit-g5hld-6qe"),
            ("e\u{0301}", "747ee6f75d1248e5b3148edf646db988ec10af2d091ee4ae9b7aa3060554f798", "apd3n-ikdy6-6mabl-heurf-viczv-s3tld-wwgtx-vkqvq-pakrd-urv6p-lae"),
        ]
        for (phrase, expectedSeed, expectedPrincipal) in fixtures {
            let seed = try TaggrSeedPhrase.privateKey(from: phrase)
            XCTAssertEqual(seed.map { String(format: "%02x", $0) }.joined(), expectedSeed)
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            let der = ICRC167Codec.derPublicKey(from: key.publicKey.rawRepresentation)
            XCTAssertEqual(ICPrincipal.text(from: ICPrincipal.selfAuthenticatingPublicKey(der)), expectedPrincipal)
        }
    }

    func testSeedPhraseSignInSavesRestoresAndSignsOut() async throws {
        let keychain = SeedPhraseTestKeychain()
        let state = makeSeedPhraseState(keychain: keychain)
        try await state.signInWithSeedPhrase("taggr-test-only-seed")
        let session = try XCTUnwrap(state.authSession)
        XCTAssertEqual(session.principal, "b4hy7-sh3si-jcy5w-2wvrx-ft33v-tblad-4rjuh-giw73-vtxwt-awuyd-qqe")
        XCTAssertEqual(session.maxTimeToLiveNanoseconds, ICClientConfiguration.maximumDelegationTTLNanoseconds)
        XCTAssertEqual(state.currentUser?.name, "alice")
        XCTAssertEqual(try state.identityStore.load(), session)
        XCTAssertFalse(state.isAuthenticatingIdentity)
        XCTAssertEqual(state.icpBalanceE8s, 200_000_000)
        await state.bootstrap()
        XCTAssertEqual(state.authSession, session)
        XCTAssertEqual(state.currentUser?.name, "alice")
        state.signOut()
        XCTAssertNil(state.authSession)
        XCTAssertNil(state.currentUser)
        XCTAssertNil(try state.identityStore.load())
    }

    func testSeedPhraseSignInRejectsUnknownUserWithoutSaving() async throws {
        let keychain = SeedPhraseTestKeychain()
        let state = makeSeedPhraseState(keychain: keychain, userExists: false)
        do {
            try await state.signInWithSeedPhrase("taggr-test-only-seed")
            XCTFail("Unknown user was accepted")
        } catch {
            XCTAssertEqual(error as? TaggrSeedPhraseError, .userNotFound)
        }
        XCTAssertNil(state.authSession)
        XCTAssertNil(state.currentUser)
        XCTAssertNil(keychain.data)
        XCTAssertFalse(state.isAuthenticatingIdentity)
    }

    func testSeedPhraseExpiredSessionRequiresReentry() async throws {
        let keychain = SeedPhraseTestKeychain()
        let state = makeSeedPhraseState(keychain: keychain)
        let session = makeAuthSession(
            privateKey: Curve25519.Signing.PrivateKey(),
            config: state.runtimeConfig,
            requestedAt: Date(timeIntervalSince1970: 1_600_000_000),
            rootPrivateKey: try Curve25519.Signing.PrivateKey(
                rawRepresentation: TaggrSeedPhrase.privateKey(from: "taggr-test-only-seed")
            )
        )
        keychain.data = try JSONEncoder().encode(session.storage)
        await state.bootstrap()
        XCTAssertNil(state.authSession)
        XCTAssertNil(state.currentUser)
        try await state.signInWithSeedPhrase("taggr-test-only-seed")
        XCTAssertEqual(state.authSession?.principal, session.principal)
        XCTAssertEqual(state.currentUser?.name, "alice")
    }

    func testSeedPhraseCancelledAttemptDoesNotSave() async throws {
        let keychain = SeedPhraseTestKeychain()
        let state = makeSeedPhraseState(keychain: keychain)
        let task = Task { try await state.signInWithSeedPhrase("taggr-test-only-seed") }
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled sign-in accepted")
        } catch is CancellationError {}
        XCTAssertNil(state.authSession)
        XCTAssertNil(keychain.data)
        XCTAssertFalse(state.isAuthenticatingIdentity)
    }

    func testSeedPhraseFailuresPreserveExistingSession() async throws {
        for networkFailure in [false, true] {
            let keychain = SeedPhraseTestKeychain()
            let state = makeSeedPhraseState(keychain: keychain, networkFailure: networkFailure)
            let oldSession = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
            try state.identityStore.save(oldSession)
            state.authSession = oldSession
            state.currentUser = try JSONDecoder.taggr.decode(TaggrUser.self, from: Self.currentUserFixture())
            let oldData = keychain.data
            let oldAPI = state.api
            keychain.writeAttempts = 0
            if !networkFailure { keychain.writeStatus = errSecInteractionNotAllowed }
            do {
                try await state.signInWithSeedPhrase("taggr-test-only-seed")
                XCTFail("Failed sign-in was accepted")
            } catch {}
            XCTAssertEqual(state.authSession, oldSession)
            XCTAssertEqual(state.currentUser?.name, "alice")
            XCTAssertEqual(keychain.data, oldData)
            XCTAssertTrue(state.api === oldAPI)
            XCTAssertFalse(state.isAuthenticatingIdentity)
            XCTAssertEqual(keychain.writeAttempts, networkFailure ? 0 : 1)
        }
    }

    func testSeedPhraseSignInRejectsConcurrentAttemptAndEmptyInput() async throws {
        let keychain = SeedPhraseTestKeychain()
        let state = makeSeedPhraseState(keychain: keychain)
        state.isAuthenticatingIdentity = true
        do {
            try await state.signInWithSeedPhrase("taggr-test-only-seed")
            XCTFail("Concurrent sign-in accepted")
        } catch {
            XCTAssertEqual(error as? TaggrSeedPhraseError, .signInInProgress)
        }
        XCTAssertTrue(state.isAuthenticatingIdentity)
        state.isAuthenticatingIdentity = false
        do {
            try await state.signInWithSeedPhrase("")
            XCTFail("Empty phrase accepted")
        } catch {
            XCTAssertEqual(error as? TaggrSeedPhraseError, .empty)
        }
        XCTAssertNil(keychain.data)
        XCTAssertFalse(state.isAuthenticatingIdentity)
    }

    func testSeedPhraseInteractiveUIReview() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--seed-phrase-ui-review") else {
            throw XCTSkip("Run with idb and --seed-phrase-ui-review for interactive UI review.")
        }
        let state = makeSeedPhraseState(keychain: SeedPhraseTestKeychain())
        state.safety.accept(scope: state.safetyScope)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: RootView().environment(state))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previous?.makeKeyAndVisible()
        }
        for _ in 0..<180 {
            if state.authSession != nil {
                XCTAssertEqual(state.currentUser?.name, "alice")
                try await Task.sleep(for: .seconds(5))
                state.signOut()
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        XCTFail("Complete seed-phrase sign-in with taggr-test-only-seed during the UI review.")
    }

    private func makeSeedPhraseState(
        keychain: SeedPhraseTestKeychain,
        userExists: Bool = true,
        networkFailure: Bool = false
    ) -> TaggrAppCoordinator {
        let api = makeStubbedAPI { request in
            if networkFailure { throw URLError(.notConnectedToInternet) }
            let method = self.requestMethodAndArg(from: request)?.method ?? ""
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data: Data
            switch method {
            case "user":
                let body = Self.requestBody(from: request) ?? Data()
                let envelope = self.cborMap(from: body) ?? []
                let expectedSender = ICPrincipal.parse("b4hy7-sh3si-jcy5w-2wvrx-ft33v-tblad-4rjuh-giw73-vtxwt-awuyd-qqe")!
                let matches: Bool
                if case .map(let content)? = self.value(named: "content", in: envelope) {
                    matches = self.value(named: "sender", in: content) == .bytes(expectedSender)
                } else {
                    matches = false
                }
                data = userExists && matches ? Self.currentUserFixture() : Data("null".utf8)
            case "stats": data = Data(#"{"canister_id":"\#(TaggrRuntimeConfig.productionCanisterId)"}"#.utf8)
            case "config": data = Data(#"{"feed_page_size":30}"#.utf8)
            case "account_balance": data = Self.candidTokens(200_000_000)
            default: data = Data("null".utf8)
            }
            return (response, Self.queryReply(data))
        }
        let config = TaggrRuntimeConfig.from(info: [:])
        let store = ICIdentityStore(configuration: config.icClientConfiguration, service: "seed-phrase-test", account: "session", keychain: keychain)
        let state = makeCoordinator(safety: makeSafetyStore(), api: api, identityStore: store, buildConfig: config)
        state.route = .settings
        return state
    }

}

private final class SeedPhraseTestKeychain: ICKeychainAccess, @unchecked Sendable {
    var data: Data?
    var writeStatus: OSStatus = errSecSuccess
    var writeAttempts = 0

    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        guard let data else { return errSecItemNotFound }
        result?.pointee = data as CFData
        return errSecSuccess
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        writeAttempts += 1
        guard writeStatus == errSecSuccess else { return writeStatus }
        guard data != nil else { return errSecItemNotFound }
        data = (attributes as NSDictionary)[kSecValueData] as? Data
        return errSecSuccess
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        guard writeStatus == errSecSuccess else { return writeStatus }
        data = (attributes as NSDictionary)[kSecValueData] as? Data
        return errSecSuccess
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        data = nil
        return errSecSuccess
    }
}
