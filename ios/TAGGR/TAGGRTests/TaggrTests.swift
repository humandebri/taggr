import XCTest
import AuthenticationServices
import CryptoKit
import UIKit
@testable import ICNativeClient
@testable import TAGGR

@MainActor
final class TaggrTests: XCTestCase {
    func testRoutesUniversalLinks() {
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/post/12")!), .post(12))
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/user/alice")!), .profile("alice"))
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/user/alice/photos")!), .userPhotos("alice"))
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/realm/DEV")!), .realm("DEV"))
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/inbox")!), .inbox)
        XCTAssertEqual(TaggrNavigation.universalURL(for: .userPhotos("alice")).path, "/user/alice/photos")
    }

    func testFeedFragmentRoutesSupportTags() {
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/feed/latest")!), .feed(.latest))
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/feed/tag")!), .feed(.tags(["tag"])))
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/feed/TAG")!), .feed(.tags(["TAG"])))
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/#/feed/@alice+tag")!), .feed(.tags(["@alice", "tag"])))
        XCTAssertEqual(TaggrNavigation.universalURL(for: .feed(.tags(["TAG"]))).path, "/feed/TAG")
        XCTAssertEqual(TaggrNavigation.universalURL(for: .feed(.realm("DEV"))).path, "/realm/DEV")
    }

    func testTokenAndWalletRoutesOpenAccount() {
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/transaction/12")!), .settings)
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/transactions")!), .transactions("2vxsx-fae"))
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/tokens")!), .settings)
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/wallet")!), .settings)
        XCTAssertEqual(TaggrNavigation.route(from: URL(string: "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/auction")!), .settings)
    }

    func testRejectsExternalHosts() {
        XCTAssertNil(TaggrNavigation.route(from: URL(string: "https://example.com/post/1")!))
    }

    func testRuntimeConfigUsesProductionDefaults() {
        let config = TaggrRuntimeConfig.from(info: [:])
        XCTAssertEqual(config.canisterId, TaggrRuntimeConfig.productionCanisterId)
        XCTAssertEqual(config.apiBaseURL, TaggrRuntimeConfig.productionAPIBaseURL)
        XCTAssertEqual(config.domain, TaggrRuntimeConfig.productionDomain)
        XCTAssertEqual(config.callbackDomain, TaggrRuntimeConfig.productionDomain)
        XCTAssertEqual(config.identityURL, TaggrRuntimeConfig.productionIdentityURL)
        XCTAssertEqual(
            config.identityURL.absoluteString,
            "https://id.ai/authorize"
        )
        XCTAssertEqual(config.derivationOrigin, TaggrRuntimeConfig.productionDerivationOrigin)
        XCTAssertEqual(
            config.icClientConfiguration.delegationTTLNanoseconds,
            ICClientConfiguration.maximumDelegationTTLNanoseconds
        )
    }

    func testProductionIdentitySignInMethodsUseFixedTrustedURLs() {
        let config = TaggrRuntimeConfig.from(info: [:])

        XCTAssertEqual(config.availableIdentitySignInMethods, [.passkey, .apple, .google])
        XCTAssertEqual(
            config.config(for: .passkey).identityURL.absoluteString,
            "https://id.ai/authorize"
        )
        XCTAssertEqual(
            config.config(for: .apple).identityURL.absoluteString,
            "https://id.ai/authorize?openid=https://appleid.apple.com"
        )
        XCTAssertEqual(
            config.config(for: .google).identityURL.absoluteString,
            "https://id.ai/authorize?openid=https://accounts.google.com"
        )
    }

    func testCustomIdentityURLDoesNotEnableProductionOpenIDProviders() {
        let config = TaggrRuntimeConfig.from(info: [
            "TAGGR_II_URL": "https://identity.trycloudflare.com/authorize",
        ])

        XCTAssertEqual(config.availableIdentitySignInMethods, [.passkey])
        XCTAssertEqual(
            config.config(for: .apple).identityURL.absoluteString,
            "https://identity.trycloudflare.com/authorize"
        )
    }

    func testAppleSignInActivatesMatchingIdentityConfigurationEverywhere() {
        let config = TaggrRuntimeConfig.from(info: [:])
        let identityService = testIdentityService()
        var apiConfigurations: [TaggrRuntimeConfig] = []
        var identityStoreConfigurations: [TaggrRuntimeConfig] = []
        var authenticatorConfigurations: [TaggrRuntimeConfig] = []
        let state = makeCoordinator(
            buildConfig: config,
            apiFactory: { selectedConfig in
                apiConfigurations.append(selectedConfig)
                return TaggrAPI(config: selectedConfig)
            },
            identityStoreFactory: { selectedConfig in
                identityStoreConfigurations.append(selectedConfig)
                return self.makeTestIdentityStore(config: selectedConfig, service: identityService)
            },
            identityAuthenticatorFactory: { selectedConfig in
                authenticatorConfigurations.append(selectedConfig)
                return try! ICInternetIdentityAuthenticator(
                    configuration: selectedConfig.icClientConfiguration,
                    callbackDomain: selectedConfig.callbackDomain,
                    callbackPath: ICInternetIdentityAuthenticator.callbackPath
                )
            }
        )

        state.activateIdentityConfiguration(for: .apple)

        let expectedURL = "https://id.ai/authorize?openid=https://appleid.apple.com"
        XCTAssertEqual(apiConfigurations.last?.identityURL.absoluteString, expectedURL)
        XCTAssertEqual(identityStoreConfigurations.last?.identityURL.absoluteString, expectedURL)
        XCTAssertEqual(authenticatorConfigurations.last?.identityURL.absoluteString, expectedURL)
    }

    @MainActor
    func testCustomBuildConfigIsUsedAtLaunch() {
        let customConfig = TaggrRuntimeConfig.from(info: [
            "TAGGR_CANISTER_ID": "bkyz2-fmaaa-aaaaa-qaaaq-cai",
            "TAGGR_API_BASE_URL": "https://taggr.trycloudflare.com",
            "TAGGR_CALLBACK_DOMAIN": "callback.trycloudflare.com",
            "TAGGR_DOMAIN": "taggr.trycloudflare.com",
            "TAGGR_II_URL": "https://identity.trycloudflare.com/authorize",
            "TAGGR_DERIVATION_ORIGIN": "https://taggr.trycloudflare.com",
        ])
        var apiConfig: TaggrRuntimeConfig?
        var identityStoreConfig: TaggrRuntimeConfig?
        var authenticatorConfig: TaggrRuntimeConfig?
        let identityService = testIdentityService()

        let state = makeCoordinator(
            buildConfig: customConfig,
            apiFactory: { config in
                apiConfig = config
                return TaggrAPI(config: config)
            },
            identityStoreFactory: { config in
                identityStoreConfig = config
                return self.makeTestIdentityStore(config: config, service: identityService)
            },
            identityAuthenticatorFactory: { config in
                authenticatorConfig = config
                return try! ICInternetIdentityAuthenticator(
                    configuration: config.icClientConfiguration,
                    callbackDomain: config.callbackDomain,
                    callbackPath: ICInternetIdentityAuthenticator.callbackPath
                )
            }
        )

        XCTAssertEqual(state.runtimeConfig, customConfig)
        XCTAssertEqual(apiConfig, customConfig)
        XCTAssertEqual(identityStoreConfig, customConfig)
        XCTAssertEqual(authenticatorConfig, customConfig)
        XCTAssertEqual(state.runtimeConfig.canisterId, "bkyz2-fmaaa-aaaaa-qaaaq-cai")
        XCTAssertEqual(state.runtimeConfig.apiBaseURL.absoluteString, "https://taggr.trycloudflare.com")
        XCTAssertEqual(state.runtimeConfig.domain, "taggr.trycloudflare.com")
        XCTAssertEqual(state.runtimeConfig.callbackDomain, "callback.trycloudflare.com")
        XCTAssertEqual(state.runtimeConfig.identityURL.absoluteString, "https://identity.trycloudflare.com/authorize")
        XCTAssertEqual(state.runtimeConfig.derivationOrigin, "https://taggr.trycloudflare.com")
    }

    func testRuntimeConfigReadsInfoOverrides() {
        let config = TaggrRuntimeConfig.from(info: [
            "TAGGR_CANISTER_ID": "bkyz2-fmaaa-aaaaa-qaaaq-cai",
            "TAGGR_API_BASE_URL": "https://taggr.trycloudflare.com",
            "TAGGR_CALLBACK_DOMAIN": "6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io",
            "TAGGR_DOMAIN": "taggr.trycloudflare.com",
            "TAGGR_II_URL": "https://taggr-identity.trycloudflare.com/authorize",
            "TAGGR_DERIVATION_ORIGIN": "https://taggr.trycloudflare.com",
        ])
        XCTAssertEqual(config.canisterId, "bkyz2-fmaaa-aaaaa-qaaaq-cai")
        XCTAssertEqual(config.apiURL(for: "query").absoluteString, "https://taggr.trycloudflare.com/api/v3/canister/bkyz2-fmaaa-aaaaa-qaaaq-cai/query")
        XCTAssertEqual(config.domain, "taggr.trycloudflare.com")
        XCTAssertEqual(config.callbackDomain, "6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io")
        XCTAssertEqual(config.identityURL.absoluteString, "https://taggr-identity.trycloudflare.com/authorize")
        XCTAssertEqual(config.derivationOrigin, "https://taggr.trycloudflare.com")
        XCTAssertTrue(config.shouldLoadBucketImagesThroughAPI)
    }

    func testRuntimeConfigIgnoresBuildSettingPlaceholders() {
        let config = TaggrRuntimeConfig.from(info: [
            "TAGGR_CANISTER_ID": "$(TAGGR_CANISTER_ID)",
            "TAGGR_API_BASE_URL": "$(TAGGR_API_BASE_URL)",
            "TAGGR_CALLBACK_DOMAIN": "$(TAGGR_CALLBACK_DOMAIN)",
            "TAGGR_DOMAIN": "$(TAGGR_DOMAIN)",
            "TAGGR_II_URL": "$(TAGGR_II_URL)",
            "TAGGR_DERIVATION_ORIGIN": "$(TAGGR_DERIVATION_ORIGIN)",
        ])
        XCTAssertEqual(config, TaggrRuntimeConfig.from(info: [:]))
    }

    func testAPIURLUsesRuntimeConfig() {
        let config = TaggrRuntimeConfig.from(info: [
            "TAGGR_CANISTER_ID": "bkyz2-fmaaa-aaaaa-qaaaq-cai",
            "TAGGR_API_BASE_URL": "https://taggr.trycloudflare.com/",
        ])
        let api = TaggrAPI(config: config)
        XCTAssertEqual(api.apiURL(for: "read_state").absoluteString, "https://taggr.trycloudflare.com/api/v3/canister/bkyz2-fmaaa-aaaaa-qaaaq-cai/read_state")
        XCTAssertEqual(api.apiURL(for: "call", canisterId: "aaaaa-aa").absoluteString, "https://taggr.trycloudflare.com/api/v4/canister/aaaaa-aa/call")
    }

    func testICRC167AuthorizationURLUsesRuntimeConfig() throws {
        let config = TaggrRuntimeConfig.from(info: [
            "TAGGR_DERIVATION_ORIGIN": "https://taggr.trycloudflare.com",
            "TAGGR_II_URL": "https://taggr-identity.trycloudflare.com/authorize",
            "TAGGR_CALLBACK_DOMAIN": "6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io",
            "TAGGR_DOMAIN": "taggr.trycloudflare.com",
        ])
        let callbackURL = try ICInternetIdentityAuthenticator.callbackURL(
            callbackDomain: config.callbackDomain,
            callbackPath: ICInternetIdentityAuthenticator.callbackPath
        )
        let pending = try ICRC167Codec.makePendingRequest()
        let url = try ICRC167Codec.authorizationURL(
            configuration: config.icClientConfiguration,
            callbackURL: callbackURL,
            pendingRequest: pending
        )
        var fragment = URLComponents()
        fragment.percentEncodedQuery = try XCTUnwrap(url.fragment)
        let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(fragment.queryItems).map {
            ($0.name, $0.value ?? "")
        })
        let message = try XCTUnwrap(query["message"]?.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: message) as? [String: Any])
        let params = try XCTUnwrap(object["params"] as? [String: Any])

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "taggr-identity.trycloudflare.com")
        XCTAssertEqual(url.path, "/authorize")
        XCTAssertNil(url.port)
        XCTAssertEqual(query["state"], pending.state)
        XCTAssertEqual(query["callback"], "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/ios-auth-callback")
        XCTAssertEqual(object["method"] as? String, "icrc34_delegation")
        XCTAssertEqual(object["id"] as? String, pending.requestID)
        XCTAssertEqual(params["maxTimeToLive"] as? String, String(pending.maxTimeToLiveNanoseconds))
        XCTAssertEqual(params["icrc95DerivationOrigin"] as? String, config.derivationOrigin)
    }

    func testAppleICRC167AuthorizationURLPreservesOpenIDQueryAndUsesFragment() throws {
        let config = TaggrRuntimeConfig.from(info: [:]).config(for: .apple)
        let callbackURL = try ICInternetIdentityAuthenticator.callbackURL(
            callbackDomain: config.callbackDomain,
            callbackPath: ICInternetIdentityAuthenticator.callbackPath
        )
        let pending = try ICRC167Codec.makePendingRequest()
        let url = try ICRC167Codec.authorizationURL(
            configuration: config.icClientConfiguration,
            callbackURL: callbackURL,
            pendingRequest: pending
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "openid", value: "https://appleid.apple.com")])
        XCTAssertNotNil(components.fragment)
    }

    func testProductionCallbackUsesExplicitHTTPSPath() throws {
        let config = TaggrRuntimeConfig.from(info: [:])
        let callbackURL = try ICInternetIdentityAuthenticator.callbackURL(
            callbackDomain: config.callbackDomain,
            callbackPath: ICInternetIdentityAuthenticator.callbackPath
        )

        XCTAssertEqual(callbackURL.absoluteString, "https://6qfxa-ryaaa-aaaai-qbhsq-cai.icp0.io/ios-auth-callback")
    }

    func testCustomDomainCallbackUsesExplicitHTTPSPath() throws {
        let config = TaggrRuntimeConfig.from(info: [
            "TAGGR_DOMAIN": "example.ngrok-free.app",
        ])
        let callbackURL = try ICInternetIdentityAuthenticator.callbackURL(
            callbackDomain: config.callbackDomain,
            callbackPath: ICInternetIdentityAuthenticator.callbackPath
        )

        XCTAssertEqual(callbackURL.absoluteString, "https://example.ngrok-free.app/ios-auth-callback")
    }

    func testJsonArgumentEncoding() throws {
        let data = try TaggrCandid.jsonArguments(["domain", 0, true])
        XCTAssertEqual(String(data: data, encoding: .utf8), "[\"domain\",0,true]")
    }

    func testJsonArgumentFragments() throws {
        let empty = try TaggrCandid.jsonArguments([])
        let single = try TaggrCandid.jsonArguments([12])
        let singleNil = try TaggrCandid.jsonArguments([nil])
        let nullPreserved = try TaggrCandid.jsonArguments(["domain", nil, 1])
        XCTAssertEqual(String(data: empty, encoding: .utf8), "null")
        XCTAssertEqual(String(data: single, encoding: .utf8), "12")
        XCTAssertEqual(String(data: singleNil, encoding: .utf8), "null")
        XCTAssertEqual(String(data: nullPreserved, encoding: .utf8), "[\"domain\",null,1]")
    }

    func testCandidGoldenFixturesMatchSentPostRequests() async throws {
        let sent = LockedTestValue<[Data]>([])
        let api = makeStubbedAPI { request in
            let call = try XCTUnwrap(self.requestMethodAndArg(from: request))
            sent.mutate { $0.append(call.arg) }
            let reply = call.method == "edit_post" ? Self.candidEditPostResultOk() : Self.candidAddPostResultOk(7)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(reply))
        }
        let identity = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        _ = try await api.addPost(text: "hello", parent: 1, realm: "DEV", identity: identity)
        _ = try await api.addPost(text: "hello", refs: [(id: "blob-id", offset: 0, length: 3)], parent: 1, realm: "DEV", identity: identity)
        _ = try await api.editPost(id: 7, text: "hello", patch: "patch", realm: "DEV", identity: identity)
        XCTAssertEqual(sent.read { $0.map(\.icHexString) }, [
            "4449444c066d016c030071017802786e786e716e056d7b0571000203040568656c6c6f00010100000000000000010344455600",
            "4449444c066d016c030071017802786e786e716e056d7b0571000203040568656c6c6f0107626c6f622d696400000000000000000300000000000000010100000000000000010344455600",
            "4449444c036d016c030071017802786e7105787100710207000000000000000568656c6c6f000570617463680103444556"
        ])
    }

    func testGeneratedCMCNotifyErrorCoversEveryProductionVariant() throws {
        let errors: [CMCNotifyError] = [
            .refunded(value: CMCNotifyErrorRefunded(blockIndex: 9, reason: "refunded")),
            .invalidTransaction(value: "invalid"),
            .transactionTooOld(value: 12),
            .processing,
            .other(value: CMCNotifyErrorOther(errorMessage: "other", errorCode: 5)),
        ]
        for error in errors {
            XCTAssertFalse(TaggrCandidAdapter.notifyErrorMessage(error).isEmpty)
        }
    }

    func testLedgerTransferErrorsIncludeRequiredFeeAndBalance() {
        XCTAssertThrowsError(try TaggrCandidAdapter.transferResult(
            .err(value: .badFee(value: .init(expectedFee: .init(e8s: 10_000))))
        )) { XCTAssertTrue($0.localizedDescription.contains("0.0001")) }
        XCTAssertThrowsError(try TaggrCandidAdapter.transferResult(
            .err(value: .insufficientFunds(value: .init(balance: .init(e8s: 25_000))))
        )) { XCTAssertTrue($0.localizedDescription.contains("0.00025")) }
    }

    func testCanisterStatusRejectsNatOverflow() throws {
        let tooLarge = try CandidNat("18446744073709551616")
        let status = try Self.managementCanisterStatus(cycles: tooLarge)
        XCTAssertThrowsError(try TaggrCandidAdapter.canisterStatus(status))
    }

    func testLedgerFutureTransferErrorUsesMainnetNullPayload() {
        XCTAssertThrowsError(try TaggrCandidAdapter.transferResult(.err(value: .txCreatedInFuture))) { error in
            XCTAssertEqual(error.localizedDescription, "ICP transfer request was created in the future.")
        }
    }

    func testEditPatchBuildsFullReplacementPatches() {
        XCTAssertEqual(
            TaggrEditPatch.fullReplacement(from: "hello world", to: "hello"),
            "@@ -1,11 +1,5 @@\n-hello world\n+hello\n"
        )
        XCTAssertEqual(
            TaggrEditPatch.fullReplacement(from: "a\nc", to: "a\nb"),
            "@@ -1,3 +1,3 @@\n-a%0Ac\n+a%0Ab\n"
        )
        XCTAssertEqual(
            TaggrEditPatch.fullReplacement(from: "new", to: ""),
            "@@ -1,3 +0,0 @@\n-new\n"
        )
        XCTAssertEqual(
            TaggrEditPatch.fullReplacement(from: "", to: "old"),
            "@@ -0,0 +1,3 @@\n+old\n"
        )
    }

    func testCandidResultErrSurfacesRejectedError() async throws {
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Self.candidResultErr("denied")))
        }
        do {
            _ = try await api.addPost(text: "hello", parent: nil, realm: nil, identity: makeAuthSession(privateKey: Curve25519.Signing.PrivateKey()))
            XCTFail("Expected rejected error.")
        } catch TaggrAPIError.rejected(let message) {
            XCTAssertEqual(message, "denied")
        } catch {
            XCTFail("Expected rejected error, got \(error).")
        }
    }

    func testAddPostReturnsCreatedPostId() async throws {
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Self.candidAddPostResultOk(77)))
        }

        let postId = try await api.addPost(
            text: "hello",
            parent: nil,
            realm: nil,
            identity: makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        )

        XCTAssertEqual(postId, 77)
    }

    func testJSONErrSurfacesRejectedError() async throws {
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data(#"{"Err":"denied"}"#.utf8)))
        }
        do {
            _ = try await api.updateJSON("react", args: [42, 53], identity: makeAuthSession(privateKey: Curve25519.Signing.PrivateKey()))
            XCTFail("Expected rejected error.")
        } catch TaggrAPIError.rejected(let message) {
            XCTAssertEqual(message, "denied")
        } catch {
            XCTFail("Expected rejected error, got \(error).")
        }
    }

    func testHTTPHTMLFailureSurfacesBackendUnavailableWithoutBody() async throws {
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 502,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )!
            let html = Data("<!DOCTYPE html><html><head><title>trycloudflare.com | 502: Bad gateway</title></head><body>Bad gateway</body></html>".utf8)
            return (response, html)
        }
        do {
            _ = try await api.query("user", args: [[]], as: Optional<TaggrUser>.self)
            XCTFail("Expected backend unavailable error.")
        } catch TaggrAPIError.backendUnavailable(let context) {
            XCTAssertEqual(context, "query user HTTP 502")
        } catch {
            XCTFail("Expected backend unavailable error, got \(error).")
        }
    }

    func testHTTPTextFailureKeepsShortContext() async throws {
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, Data("gateway unavailable".utf8))
        }
        do {
            _ = try await api.query("user", args: [[]], as: Optional<TaggrUser>.self)
            XCTFail("Expected backend unavailable error.")
        } catch TaggrAPIError.backendUnavailable(let context) {
            XCTAssertEqual(context, "query user HTTP 503: gateway unavailable")
        } catch {
            XCTFail("Expected backend unavailable error, got \(error).")
        }
    }

    func testCancelledHTTPErrorIsNotWrappedAsBackendUnavailable() async throws {
        let api = makeStubbedAPI { _ in
            throw URLError(.cancelled)
        }
        do {
            _ = try await api.query("user", args: [[]], as: Optional<TaggrUser>.self)
            XCTFail("Expected cancelled URL error.")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        } catch {
            XCTFail("Expected cancelled URL error, got \(error).")
        }
    }

    func testUpdateCallsShareMissingIdentityMessage() async {
        let api = makeStubbedAPI { _ in
            XCTFail("Missing identity should fail before network.")
            let response = HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let operations: [() async throws -> Void] = [
            { _ = try await api.updateJSON("react", args: [42, 53], identity: nil) },
            { _ = try await api.addPost(text: "hello", parent: nil, realm: nil, identity: nil) },
            { _ = try await api.editPost(id: 42, text: "hello", patch: "patch", realm: nil, identity: nil) },
            { _ = try await api.transferICP(to: "invalid", e8s: 1, identity: nil) },
        ]

        for operation in operations {
            do {
                try await operation()
                XCTFail("Expected missing identity error.")
            } catch {
                XCTAssertEqual(error.localizedDescription, TaggrAPIError.signInRequiredMessage)
            }
        }
    }

    func testMintCreditsWithICPDecodesInvoice() async throws {
        var calls: [(method: String, arg: Data)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append(call)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data(#"{"Ok":{"e8s":123456789,"paid_e8s":0,"paid":false,"account":[1,2,255]}}"#.utf8)))
        }

        let invoice = try await api.mintCreditsWithICP(
            identity: makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        )

        XCTAssertEqual(calls.first?.method, "mint_credits_with_icp")
        XCTAssertEqual(calls.first?.arg, try TaggrCandid.jsonArguments([0]))
        XCTAssertEqual(invoice.e8s, 123_456_789)
        XCTAssertEqual(invoice.paidE8s, 0)
        XCTAssertFalse(invoice.paid)
        XCTAssertEqual(invoice.account, [1, 2, 255])
        XCTAssertEqual(invoice.accountHex, "0102ff")
        XCTAssertEqual(invoice.amountICP, "1.23456789")
    }

    func testStorageCreationResumesFromExistingSettings() throws {
        let saved = ["bucket_creation_state": #"{"stage":"created","blockIndex":12,"canisterId":"bkyz2-fmaaa-aaaaa-qaaaq-cai"}"#]
        let state = try XCTUnwrap(TaggrAppCoordinator.storageCreationState(from: saved))
        XCTAssertEqual(state.stage, .created)
        XCTAssertEqual(state.blockIndex, 12)
        XCTAssertEqual(state.canisterId, "bkyz2-fmaaa-aaaaa-qaaaq-cai")
    }

    @MainActor
    func testStorageUpgradeDetectionComparesModuleHashes() {
        let state = makeCoordinator()
        state.storageExpectedWasmHash = "01020304"
        state.storageStatus = TaggrStorageCanisterStatus(
            status: "running",
            controllers: [],
            moduleHash: Data([0x01, 0x02, 0x03, 0x04]),
            memorySize: 0,
            cycles: 0,
            idleCyclesBurnedPerDay: 0
        )
        XCTAssertFalse(state.storageNeedsUpgrade)

        state.storageStatus = TaggrStorageCanisterStatus(
            status: "running",
            controllers: [],
            moduleHash: Data([0x04, 0x03, 0x02, 0x01]),
            memorySize: 0,
            cycles: 0,
            idleCyclesBurnedPerDay: 0
        )
        XCTAssertTrue(state.storageNeedsUpgrade)
    }

    func testCanisterStatusUsesManagementRequestIDAndBucketRoutingID() async throws {
        let bucketId = "bkyz2-fmaaa-aaaaa-qaaaq-cai"
        var requestPath: String?
        var requestCanister: Data?
        let api = makeStubbedAPI { request in
            requestPath = request.url?.path
            if let body = Self.requestBody(from: request),
               let envelope = self.cborMap(from: body),
               case .map(let content)? = self.value(named: "content", in: envelope),
               case .bytes(let canister)? = self.value(named: "canister_id", in: content) {
                requestCanister = canister
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(try Self.candidCanisterStatus()))
        }

        let status = try await api.storageCanisterStatus(
            bucketId,
            identity: makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        )

        XCTAssertEqual(status.status, "running")
        XCTAssertTrue(requestPath?.contains("/canister/\(bucketId)/query") == true)
        XCTAssertEqual(requestCanister, ICPrincipal.parse(TaggrAPI.managementCanisterId))
    }

    func testStorageInstallAndControllerRequestsUseBucketAndUser() async throws {
        let bucket = "a5dhi-k7777-77775-aaabq-cai"
        let user = "swqvp-ecw6b-psba6-673lj-2bnf4-z4n66-6mgzy-sbdaq-ksjck-m5zoz-wae"
        let calls = LockedTestValue<[(String, Data, String)]>([])
        let api = makeStubbedAPI { request in
            let call = try XCTUnwrap(self.requestMethodAndArg(from: request))
            calls.mutate { $0.append((call.method, call.arg, request.url!.path)) }
            let reply: Data
            if call.method == "notify_create_canister" {
                reply = try CandidArguments([CandidTypedValue(CMCNotifyCreateResult.ok(value: CandidPrincipal(bucket)))]).encode()
            } else {
                reply = try CandidArguments().encode()
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.queryReply(reply))
        }
        let identity = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        let created = try await api.notifyCreateCanister(blockIndex: 88, controller: user, identity: identity)
        XCTAssertEqual(created, bucket)
        try await api.installBucketCode(canisterId: bucket, wasm: Data([0, 1, 2]), userPrincipal: user, mode: "install", identity: identity)
        try await api.updateStorageControllers(canisterId: bucket, controllers: [user], identity: identity)
        let sent = calls.read { $0 }
        XCTAssertEqual(sent.map { $0.0 }, ["notify_create_canister", "install_code", "update_settings", "update_internal_controllers"])
        let notification = try CandidDecoder().decode(sent[0].1).decode(CMCNotifyCreateCanisterArgs.self)
        XCTAssertEqual(notification.controller.text, user)
        XCTAssertEqual(notification.blockIndex, 88)
        XCTAssertEqual(notification.settings?.controllers?.map(\.text), [user, "e3mmv-5qaaa-aaaah-aadma-cai"])
        XCTAssertTrue(sent[0].2.contains("rkp4c-7iaaa-aaaaa-aaaca-cai"))
        let install = try CandidDecoder().decode(sent[1].1).decode(ManagementInstallCodeArgs.self)
        XCTAssertEqual(install.canisterId.text, bucket)
        XCTAssertEqual(install.wasmModule, Data([0, 1, 2]))
        guard case .install = install.mode else { return XCTFail("Expected install mode") }
        XCTAssertEqual(try CandidDecoder().decode(install.arg).decode([CandidPrincipal].self).map(\.text), [user])
        let settings = try CandidDecoder().decode(sent[2].1).decode(ManagementUpdateSettingsArgs.self)
        XCTAssertEqual(settings.canisterId.text, bucket)
        XCTAssertEqual(settings.settings.controllers?.map(\.text), [user])
        XCTAssertEqual(try CandidDecoder().decode(sent[3].1).decode([CandidPrincipal].self).map(\.text), [user])
        XCTAssertTrue(sent.dropFirst().allSatisfy { $0.2.contains(bucket) })
        XCTAssertThrowsError(try TaggrCandidAdapter.installMode("unknown"))
    }

    func testICPAccountBalanceQueriesLedgerCanister() async throws {
        var calls: [(method: String, arg: Data, path: String)] = []
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append((call.method, call.arg, request.url?.path ?? ""))
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Self.candidTokens(123_456)))
        }

        let balance = try await api.icpAccountBalance(ownerPrincipal: "2vxsx-fae")

        XCTAssertEqual(balance, 123_456)
        XCTAssertEqual(calls.first?.method, "account_balance")
        XCTAssertTrue(calls.first?.path.contains(TaggrAPI.icpLedgerCanisterId) == true)
        let request = try CandidDecoder().decode(XCTUnwrap(calls.first?.arg)).decode(LedgerAccountBalanceArgs.self)
        XCTAssertEqual(request.account.icHexString, "1c7a48ba6a562aa9eaa2481a9049cdf0433b9738c992d698c31d8abf89cadc79")
    }

    func testTransferICPCallsLedgerTransfer() async throws {
        var calls: [(method: String, arg: Data, path: String)] = []
        let recipient = "1c7a48ba6a562aa9eaa2481a9049cdf0433b9738c992d698c31d8abf89cadc79"
        let api = makeStubbedAPI { request in
            if let call = self.requestMethodAndArg(from: request) {
                calls.append((call.method, call.arg, request.url?.path ?? ""))
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Self.candidLedgerTransferResultOk(77)))
        }

        let block = try await api.transferICP(
            to: recipient,
            e8s: 123_000_000,
            identity: makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        )

        XCTAssertEqual(block, 77)
        XCTAssertEqual(calls.first?.method, "transfer")
        XCTAssertTrue(calls.first?.path.contains(TaggrAPI.icpLedgerCanisterId) == true)
        let request = try CandidDecoder().decode(XCTUnwrap(calls.first?.arg)).decode(LedgerTransferArgs.self)
        XCTAssertEqual(request.to.icHexString, recipient)
        XCTAssertEqual(request.amount.e8s, 123_000_000)
        XCTAssertEqual(request.fee.e8s, 10_000)
        XCTAssertEqual(request.memo, 0)
    }

    func testAPIRejectsSessionForDifferentRuntimeConfig() async throws {
        let config = customRuntimeConfig()
        let api = TaggrAPI(config: config)
        let session = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())

        do {
            try await api.validateIdentity(session, requestCanisterId: config.canisterId)
            XCTFail("Expected invalidIdentity.")
        } catch {
            guard case TaggrAPIError.invalidIdentity = error else {
                return XCTFail("Expected invalidIdentity, got \(error).")
            }
        }
    }

    func testBucketWriteAcceptsUntargetedSession() async throws {
        let bucketId = "bkyz2-fmaaa-aaaaa-qaaaq-cai"
        var capturedURL: URL?
        let api = makeStubbedAPI { request in
            capturedURL = request.url
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data([0, 0, 0, 0, 0, 0, 0, 7])))
        }

        let offset = try await api.bucketWrite(
            bucketId: bucketId,
            blob: Data([1, 2, 3]),
            identity: makeAuthSession(privateKey: Curve25519.Signing.PrivateKey())
        )

        XCTAssertEqual(offset, 7)
        XCTAssertTrue(capturedURL?.path.contains("/canister/\(bucketId)/call") == true)
    }

    func testBucketWriteRejectsMainOnlyTargetBeforeSending() async throws {
        var didSend = false
        let bucketId = "bkyz2-fmaaa-aaaaa-qaaaq-cai"
        let mainTarget = try XCTUnwrap(ICPrincipal.parse(TaggrRuntimeConfig.productionCanisterId))
        let api = makeStubbedAPI { request in
            didSend = true
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data()))
        }
        let identity = makeAuthSession(
            privateKey: Curve25519.Signing.PrivateKey(),
            targets: [mainTarget]
        )

        do {
            _ = try await api.bucketWrite(bucketId: bucketId, blob: Data([1]), identity: identity)
            XCTFail("Expected invalidIdentity.")
        } catch TaggrAPIError.invalidIdentity {
        } catch {
            XCTFail("Expected invalidIdentity, got \(error).")
        }
        XCTAssertFalse(didSend)
    }

    func testBucketWriteAcceptsBucketTarget() async throws {
        let bucketId = "bkyz2-fmaaa-aaaaa-qaaaq-cai"
        let bucketTarget = try XCTUnwrap(ICPrincipal.parse(bucketId))
        let api = makeStubbedAPI { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Self.queryReply(Data()))
        }
        let identity = makeAuthSession(
            privateKey: Curve25519.Signing.PrivateKey(),
            targets: [bucketTarget]
        )

        try await api.validateIdentity(identity, requestCanisterId: bucketId)
    }

    func testPostEnvelopeDecodesTupleShape() throws {
        let post = try JSONDecoder.taggr.decode(TaggrPostEnvelope.self, from: postEnvelopeFixture())
        XCTAssertEqual(post.post.id, 42)
        XCTAssertEqual(post.post.parent, nil)
        XCTAssertEqual(post.post.children, [])
        XCTAssertEqual(post.post.reactions, [:])
        XCTAssertEqual(post.post.meta.authorName, "alice")
        XCTAssertEqual(post.post.meta.authorBadges, ["OG", "FUTURE_BADGE"])
        XCTAssertEqual(TaggrUserBadge.decoded(from: post.post.meta.authorBadges), [.og])
        XCTAssertEqual(post.post.meta.realmColor, "#123456")
        XCTAssertEqual(post.post.meta.viewerBlocked, false)
        XCTAssertEqual(post.post.encrypted, false)
        XCTAssertEqual(post.post.treeSize, 1)
        XCTAssertEqual(post.post.hiddenFor, [])
    }

    func testPostEnvelopeAllowsMissingAuthorNameFallback() throws {
        let post = try JSONDecoder.taggr.decode(TaggrPostEnvelope.self, from: postEnvelopeWithoutAuthorFixture())
        XCTAssertNil(post.post.meta.authorName)
        XCTAssertEqual(post.post.meta.authorBadges, [])
        XCTAssertEqual(post.post.user, 7)
    }

    func testPostEnvelopeRejectsObjectFallback() {
        let object = Data(#"{"post":{},"meta":{}}"#.utf8)
        let singlePost = Data(#"{"id":42,"body":"hello","user":7,"timestamp":1,"children":[],"reactions":{}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder.taggr.decode(TaggrPostEnvelope.self, from: object))
        XCTAssertThrowsError(try JSONDecoder.taggr.decode(TaggrPostEnvelope.self, from: singlePost))
    }

    func testConfigDecodesReactions() throws {
        let data = Data(#"{"name":"TAGGR","token_symbol":"TAGGR","token_decimals":2,"max_post_length":5000,"max_tag_length":30,"max_blob_size_bytes":460800,"max_report_length":1000,"reactions":[[11,1],[10,1],[1,-3]],"feed_page_size":25,"poll_revote_deadline_hours":2,"post_cost":10,"poll_cost":4,"post_deletion_penalty_factor":3}"#.utf8)
        let config = try JSONDecoder.taggr.decode(TaggrConfig.self, from: data)
        XCTAssertEqual(config.reactions, [[11, 1], [10, 1], [1, -3]])
        XCTAssertEqual(config.tokenSymbol, "TAGGR")
        XCTAssertEqual(config.tokenDecimals, 2)
        XCTAssertEqual(config.maxPostLength, 5000)
        XCTAssertEqual(config.maxTagLength, 30)
        XCTAssertEqual(config.maxBlobSizeBytes, 460_800)
        XCTAssertEqual(config.maxReportLength, 1000)
        XCTAssertEqual(config.feedPageSize, 25)
        XCTAssertEqual(config.pollRevoteDeadlineHours, 2)
        XCTAssertEqual(config.postCost, 10)
        XCTAssertEqual(config.pollCost, 4)
        XCTAssertEqual(config.postDeletionPenaltyFactor, 3)
    }
}
