import SwiftUI

enum ProfileCreditAmount {
    static func parse(_ text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let amount = Int(value), amount > 0 else { return nil }
        return amount
    }

    static func total(amount: Int, fee: Int, balance: Int) -> Int? {
        guard amount > 0, fee >= 0 else { return nil }
        let (total, overflow) = amount.addingReportingOverflow(fee)
        return !overflow && total <= balance ? total : nil
    }
}

struct ProfileCreditTransferSheet: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var pendingAmount = 0
    @State private var pendingFee = 0
    @State private var confirming = false
    @State private var sent = false
    @State private var uncertain = false
    let recipient: TaggrUser

    private var fee: Int? { state.cache?.config?.creditTransactionFee }
    private var amount: Int? { ProfileCreditAmount.parse(amountText) }
    private var total: Int? {
        guard let amount, let fee, let balance = state.currentUser?.cycles else { return nil }
        return ProfileCreditAmount.total(amount: amount, fee: fee, balance: balance)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Recipient") { Text("@\(recipient.name)") }
                Section("Amount") {
                    TextField("Credits", text: $amountText)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("profile.credits.amount")
                    if let balance = state.currentUser?.cycles {
                        LabeledContent("Available credits", value: balance.formatted())
                    }
                    if let fee {
                        LabeledContent("Fee", value: "\(fee.formatted()) credits")
                    } else {
                        Text("The transfer fee is unavailable.")
                        Button("Reload fee") { Task { await state.reloadCache() } }
                    }
                    if let total {
                        LabeledContent("Total deducted", value: "\(total.formatted()) credits")
                    } else if !amountText.isEmpty {
                        Text("Enter a positive whole number within your balance, including the fee.")
                            .foregroundStyle(TaggrTheme.secondaryText)
                    }
                }
                if uncertain {
                    Section {
                        Text("The transfer result is unknown. Close this sheet and check your balance and the recipient before sending again.")
                    }
                }
                if let error = state.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button("Review transfer") {
                        guard let amount, let fee, total != nil else { return }
                        pendingAmount = amount
                        pendingFee = fee
                        confirming = true
                    }
                    .disabled(total == nil || uncertain || state.contentStore.profileActionInFlight || !state.canInteractWithProfile(userID: recipient.id))
                    if state.contentStore.profileActionInFlight { ProgressView("Sending credits") }
                }
            }
            .navigationTitle("Send credits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.disabled(state.contentStore.profileActionInFlight)
                }
            }
            .alert("Send credits to @\(recipient.name)?", isPresented: $confirming) {
                Button("Cancel", role: .cancel) {}
                Button("Send") { Task { await send() } }
            } message: {
                Text("Send \(pendingAmount.formatted()) credits plus \(pendingFee.formatted()) credits fee. Total deducted: \(pendingAmount.addingReportingOverflow(pendingFee).partialValue.formatted()) credits.")
            }
            .alert("Credits sent", isPresented: $sent) {
                Button("Done") { dismiss() }
            } message: {
                Text("Sent \(pendingAmount.formatted()) credits to @\(recipient.name).")
            }
            .task {
                if fee == nil { await state.reloadCache() }
            }
            .onChange(of: state.safetyScope) { _, _ in dismiss() }
        }
        .interactiveDismissDisabled(state.contentStore.profileActionInFlight)
    }

    private func send() async {
        let result = await state.sendProfileCredits(userID: recipient.id, amount: pendingAmount, expectedFee: pendingFee)
        sent = result == .applied
        uncertain = result == .uncertain
    }
}
