import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: TaggrAppState

    var body: some View {
        ZStack {
            DiscordTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Account")
                        .font(.largeTitle.weight(.black))
                        .foregroundStyle(DiscordTheme.text)
                    SettingsPanel(title: "Identity") {
                        if let message = state.errorMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                        if let session = state.authSession {
                            Text(session.principal)
                                .font(.footnote.monospaced())
                                .foregroundStyle(DiscordTheme.text)
                                .textSelection(.enabled)
                            Button(role: .destructive) {
                                state.signOut()
                            } label: {
                                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        } else {
                            Button {
                                state.showingIdentity = true
                            } label: {
                                Label("Sign in with Internet Identity", systemImage: "infinity")
                            }
                        }
                    }
                    SettingsPanel(title: "App Store build") {
                        Text("Token, ICP, wallet, auction, minting, transfer, and exchange actions are disabled in this iOS build.")
                            .font(.footnote)
                            .foregroundStyle(DiscordTheme.secondaryText)
                        Button {
                            state.route = .readOnlyNotice
                        } label: {
                            Label("Read-only token policy", systemImage: "lock")
                        }
                    }
                    SettingsPanel(title: "Support") {
                        Link(destination: URL(string: "https://\(TaggrNavigation.canonicalHost)/#/privacy")!) {
                            Label("Privacy", systemImage: "hand.raised")
                        }
                        Link(destination: URL(string: "https://\(TaggrNavigation.canonicalHost)/#/support")!) {
                            Label("Support", systemImage: "questionmark.circle")
                        }
                    }
                }
                .padding(16)
            }
        }
        .toolbarBackground(DiscordTheme.background, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

private struct SettingsPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(DiscordTheme.secondaryText)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 12) {
                content
                    .foregroundStyle(DiscordTheme.accent)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DiscordTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
