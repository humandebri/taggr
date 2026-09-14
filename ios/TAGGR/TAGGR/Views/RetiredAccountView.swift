import SwiftUI
import ICNativeClient

struct RetiredAccountView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var sendPresented = false
    var body: some View {
        Form {
            Section("Account") {
                Text(state.retirementStatusTitle)
                Text(state.retirementStatusDetail)
                if let message = state.retirementMessage { Text(message).foregroundStyle(.red) }
                if state.retirementStage == "preparing", let cost = state.cache?.config?.accountActivationCost {
                    Text("Required: \(cost) credits")
                }
                if state.retirementStage != nil {
                    Button(state.retirementActionTitle) {
                        Task { await state.retireAccount() }
                    }.disabled(state.retirementBusy || state.isBusy)
                }
                if state.retirementBusy { ProgressView() }
            }
            Section("Asset recovery") {
                if let user = state.currentUser {
                    Text("TAGGR: \(TaggrTokenAmount.format(user.balance ?? 0, decimals: state.cache?.config?.tokenDecimals))")
                    Text("ICP rewards: \(ICPAmount.format(UInt64(max(0, user.treasuryE8s ?? 0))))")
                }
                Text("ICP: \(state.icpBalanceE8s.map { ICPAmount.format($0) } ?? "…")")
                Button("Withdraw rewards") { Task { await state.withdrawRewards() } }.disabled(state.retirementBusy || state.isBusy)
                Button("Send ICP") { sendPresented = true }.disabled(state.retirementBusy || state.isBusy)
                if let error = state.errorMessage { Text(error).foregroundStyle(.red) }
            }
            Button("Sign out") { state.signOut() }.disabled(state.retirementBusy)
        }
        .navigationTitle("Account")
        .task { await state.refreshWallet() }
        .sheet(isPresented: $sendPresented) { SendICPSheet().environment(state) }
    }
}
