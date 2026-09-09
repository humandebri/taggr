import CryptoKit
import Foundation
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

enum TaggrSeedPhraseError: LocalizedError {
    case empty

    var errorDescription: String? {
        "Enter your seed phrase."
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
                    SecureField("Seed phrase", text: $phrase)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("seedPhraseInput")
                        .disabled(isSigningIn)
                } footer: {
                    Text("Enter the same seed phrase you use on TAGGR's website. Spaces and capitalization must match. Internet Identity accounts use their original sign-in method.")
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
            .navigationTitle("Seed phrase")
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
