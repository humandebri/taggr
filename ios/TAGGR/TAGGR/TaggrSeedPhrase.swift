import CryptoKit
import Foundation
import ICNativeClient
import SwiftUI

enum TaggrSeedPhrase {
    nonisolated static func privateKey(from phrase: String) throws -> Data {
        guard !phrase.isEmpty else {
            throw TaggrSeedPhraseError.empty
        }
        // Match authentication.tsx/common.tsx exactly, including whitespace and UTF-8 bytes.
        var seed = Data(phrase.utf8)
        for _ in 0..<15_000 {
            seed = Data(SHA256.hash(data: seed))
        }
        return seed
    }
}

enum TaggrSeedPhraseError: LocalizedError, Equatable {
    case empty
    case signInInProgress
    case userNotFound

    var errorDescription: String? {
        switch self {
        case .empty: "Enter your password."
        case .signInInProgress: "Sign-in is already in progress."
        case .userNotFound: "No TAGGR account was found for this password. Check the password, including spaces and capitalization."
        }
    }
}

extension TaggrAppCoordinator {
    func signInWithSeedPhrase(_ phrase: String) async throws {
        guard !isAuthenticatingIdentity else { throw TaggrSeedPhraseError.signInInProgress }
        isAuthenticatingIdentity = true
        defer { isAuthenticatingIdentity = false }
        let config = runtimeConfig.config(for: .passkey)
        let candidateAPI = injectedAPI ?? apiFactory(config)
        let candidateStore = injectedIdentityStore ?? identityStoreFactory(config)
        let session = try await Task.detached(priority: .userInitiated) {
            let key = try TaggrSeedPhrase.privateKey(from: phrase)
            return try ICAuthSession.delegating(
                ed25519PrivateKey: key,
                configuration: config.icClientConfiguration
            )
        }.value
        try Task.checkCancellation()
        let user = try await candidateAPI.signedQuery(
            "user", args: [candidateAPI.domain, []], identity: session, as: Optional<TaggrUser>.self
        ) ?? nil
        if user == nil {
            let result = try await candidateAPI.signedQuery("account_deletion_status", args: [], identity: session, as: TaggrDeletionResponse.self)
            guard let state = result?.Ok?.state, state == "deleting" || state == "deleted" else {
                throw TaggrSeedPhraseError.userNotFound
            }
        }
        try Task.checkCancellation()
        try await finishIdentity(session, user: user, api: candidateAPI, store: candidateStore)
    }
}

struct SeedPhraseSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var phrase = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    let signIn: (String) async throws -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $phrase)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("seedPhraseInput")
                        .disabled(isSigningIn)
                } footer: {
                    Text("Enter the same password you use on TAGGR's website. Spaces and capitalization must match. Internet Identity accounts use their original sign-in method.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("seedPhraseError")
                    }
                }
                Section {
                    Button(isSigningIn ? "Signing in..." : "Sign in") {
                        isSigningIn = true
                        errorMessage = nil
                        Task {
                            do {
                                try await signIn(phrase)
                                phrase = ""
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                            isSigningIn = false
                        }
                    }
                    .disabled(phrase.isEmpty || isSigningIn)
                    .accessibilityIdentifier("seedPhraseSignIn")
                }
            }
            .navigationTitle("Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        phrase = ""
                        dismiss()
                    }
                    .disabled(isSigningIn)
                }
            }
        }
        .interactiveDismissDisabled(isSigningIn)
        .onDisappear { phrase = "" }
    }
}
