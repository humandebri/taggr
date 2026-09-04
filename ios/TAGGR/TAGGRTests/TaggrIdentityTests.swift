import CryptoKit
@testable import ICNativeClient
import XCTest
@testable import TAGGR

extension TaggrTests {
    func testStoredAuthSessionUsesRuntimeConfigurationAndValidSignature() throws {
        let config = TaggrRuntimeConfig.from(info: [:])
        let session = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey(), config: config)

        XCTAssertEqual(session.formatVersion, ICAuthSession.currentFormatVersion)
        XCTAssertEqual(session.canisterId, TaggrRuntimeConfig.productionCanisterId)
        XCTAssertEqual(session.internetIdentityURL, "https://id.ai/authorize")
        XCTAssertEqual(session.derivationOrigin, TaggrRuntimeConfig.productionDerivationOrigin)
        XCTAssertNoThrow(try ICIdentityValidation.validateSession(session, configuration: config.icClientConfiguration))
    }

    func testStoredAuthSessionRejectsTamperedDelegationSignature() {
        let config = TaggrRuntimeConfig.from(info: [:])
        let valid = makeAuthSession(privateKey: Curve25519.Signing.PrivateKey(), config: config)
        let signed = valid.delegation.delegations[0]
        let brokenChain = ICDelegationChain(
            publicKey: valid.delegation.publicKey,
            delegations: [.init(delegation: signed.delegation, signature: Data(repeating: 7, count: 64))]
        )
        let broken = ICAuthSession(storage: ICStoredAuthSession(
            formatVersion: valid.formatVersion,
            principal: valid.principal,
            canisterId: valid.canisterId,
            internetIdentityURL: valid.internetIdentityURL,
            derivationOrigin: valid.derivationOrigin,
            sessionPublicKey: valid.sessionPublicKey,
            sessionPrivateKey: valid.storage.sessionPrivateKey,
            delegation: brokenChain,
            requestedAt: valid.requestedAt,
            maxTimeToLiveNanoseconds: valid.maxTimeToLiveNanoseconds
        ))

        XCTAssertThrowsError(try ICIdentityValidation.validateSession(broken, configuration: config.icClientConfiguration))
    }
}
