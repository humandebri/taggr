import SwiftUI
import ICNativeClient
import UIKit

struct SettingsView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var accountCreationPresented = false
    @State private var sendICPPresented = false
    @State private var mintConfirmationPresented = false

    var body: some View {
        ZStack {
            TaggrTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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
                                .foregroundStyle(TaggrTheme.text)
                                .textSelection(.enabled)
                            if state.currentUser == nil {
                                Button {
                                    state.icpInvoice = nil
                                    accountCreationPresented = true
                                } label: {
                                    Label("Create TAGGR user", systemImage: "person.badge.plus")
                                        .font(.subheadline.weight(.bold))
                                }
                            } else if let user = state.currentUser {
                                Label(user.name, systemImage: "checkmark.seal")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(TaggrTheme.text)
                                Button {
                                    state.navigateToProfile(user.name)
                                } label: {
                                    Label("Open journal", systemImage: "person.crop.square")
                                        .font(.subheadline.weight(.bold))
                                }
                                Button {
                                    state.route = .userPhotos(user.name)
                                } label: {
                                    Label("Photos", systemImage: "photo.on.rectangle")
                                        .font(.subheadline.weight(.bold))
                                }
                            }
                            Button(role: .destructive) {
                                state.signOut()
                            } label: {
                                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        } else {
                            Button {
                                state.presentIdentitySignInMethodPicker()
                            } label: {
                                Label(
                                    state.isAuthenticatingIdentity ? "Signing in..." : "Sign in with Internet Identity",
                                    systemImage: "infinity"
                                )
                            }
                            .disabled(state.isAuthenticatingIdentity)
                        }
                    }
                    if state.authSession != nil {
                        if let user = state.currentUser {
                            SettingsPanel(title: "Storage") {
                                StorageSettingsPanel(user: user)
                            }
                        }
                        SettingsPanel(title: "Wallet") {
                            walletPanel(state.currentUser)
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
            .taggrRefreshable()
        }
        .taggrNavigationChrome()
        .sheet(isPresented: $accountCreationPresented) {
            AccountCreationSheet()
                .environment(state)
        }
        .sheet(isPresented: $sendICPPresented) {
            SendICPSheet()
                .environment(state)
        }
        .alert("Mint 1k credits", isPresented: $mintConfirmationPresented, presenting: state.icpInvoice) { _ in
            Button("Cancel", role: .cancel) {}
            Button("Mint") {
                Task { await state.mintOneKCredits() }
            }
        } message: { invoice in
            Text("Transfers \(ICPAmount.format(invoice.e8s)) plus \(ICPAmount.format(ICPAmount.feeE8s)) fee from your ICP wallet.")
        }
        .task {
            if state.authSession != nil {
                await state.refreshWallet()
                await state.loadStorageStatus()
            }
        }
    }

    private func walletPanel(_ user: TaggrUser?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if user == nil {
                Button {
                    state.icpInvoice = nil
                    accountCreationPresented = true
                } label: {
                    Label("Create TAGGR user", systemImage: "person.badge.plus")
                        .font(.subheadline.weight(.bold))
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], spacing: 8) {
                walletMetric("TAGGR", value: user.map { TaggrTokenAmount.format($0.balance ?? 0, decimals: state.cache?.config?.tokenDecimals) } ?? "-")
                walletMetric("Credits", value: user.map { ($0.cycles ?? 0).formatted() } ?? "-")
                walletMetric("ICP", value: state.icpBalanceE8s.map { ICPAmount.format($0, units: false) } ?? "...")
                walletMetric("Rewards", value: user.map { ICPAmount.format(UInt64(max(0, $0.treasuryE8s ?? 0)), units: false) } ?? "-")
            }
            HStack(spacing: 10) {
                Button {
                    Task {
                        await state.prepareCreditMint()
                        if state.icpInvoice != nil {
                            mintConfirmationPresented = true
                        }
                    }
                } label: {
                    Label("Mint 1k credits", systemImage: "plus.circle")
                        .font(.subheadline.weight(.bold))
                }
                .disabled(state.isBusy || user == nil)
                Button {
                    sendICPPresented = true
                } label: {
                    Label("Send ICP", systemImage: "paperplane")
                        .font(.subheadline.weight(.bold))
                }
                .disabled(state.isBusy)
            }
            if let user, (user.treasuryE8s ?? 0) > 0 {
                Button {
                    Task { await state.withdrawRewards() }
                } label: {
                    Label("Withdraw rewards", systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.bold))
                }
                .disabled(state.isBusy)
            }
        }
    }

    private func walletMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(TaggrTheme.secondaryText)
            Text(value)
                .font(.headline.weight(.black))
                .foregroundStyle(TaggrTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TaggrTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct StorageSettingsPanel: View {
    @Environment(TaggrAppCoordinator.self) private var state
    let user: TaggrUser
    @State private var createConfirmationPresented = false
    @State private var upgradeConfirmationPresented = false
    @State private var blackholeConfirmationPresented = false
    @State private var topUpPresented = false

    private var hasBucket: Bool {
        !(user.bucket?.isEmpty ?? true)
    }

    private var hasBlackholeController: Bool {
        state.storageStatus?.controllers.contains(TaggrAPI.blackholeCanisterId) == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let creation = state.storageCreationState {
                Label(creation.title, systemImage: "externaldrive.badge.plus")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(TaggrTheme.text)
                if state.isBusy {
                    ProgressView()
                        .tint(TaggrTheme.clickable)
                }
            }
            if let message = state.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if hasBucket {
                storageStatusContent
            } else {
                Text("Images require a personal storage canister.")
                    .font(.footnote)
                    .foregroundStyle(TaggrTheme.secondaryText)
                Button {
                    createConfirmationPresented = true
                } label: {
                    Label(state.storageCreationState == nil ? "Create storage" : "Resume storage", systemImage: "externaldrive.badge.plus")
                        .font(.subheadline.weight(.bold))
                }
                .disabled(state.isBusy)
            }
        }
        .sheet(isPresented: $topUpPresented) {
            StorageTopUpSheet()
                .environment(state)
        }
        .alert("Create storage", isPresented: $createConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                Task { await state.createStorageCanister() }
            }
        } message: {
            Text("Transfers about 1 XDR of ICP plus ledger fee, creates a storage canister, installs TAGGR storage code, and registers it to this account.")
        }
        .alert("Upgrade storage", isPresented: $upgradeConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Upgrade") {
                Task { await state.upgradeStorageCanister() }
            }
        } message: {
            Text("Installs the current TAGGR storage wasm on your storage canister.")
        }
        .alert("Add Blackhole controller", isPresented: $blackholeConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                Task { await state.addBlackholeStorageController() }
            }
        } message: {
            Text("Adds the TAGGR Blackhole controller to match web storage management.")
        }
    }

    @ViewBuilder private var storageStatusContent: some View {
        if let bucket = user.bucket {
            storageRow("Bucket", bucket)
        }
        if let status = state.storageStatus {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], spacing: 8) {
                storageMetric("Status", value: status.status)
                storageMetric("Memory", value: byteCount(status.memorySize))
                storageMetric("Cycles", value: cycleCount(status.cycles))
                storageMetric("Daily burn", value: cycleCount(status.idleCyclesBurnedPerDay))
                storageMetric("Days", value: status.daysToLive.map(String.init) ?? "-")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Controllers")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TaggrTheme.secondaryText)
                    .textCase(.uppercase)
                ForEach(status.controllers, id: \.self) { controller in
                    Text(controller)
                        .font(.caption.monospaced())
                        .foregroundStyle(TaggrTheme.text)
                        .textSelection(.enabled)
                }
            }
        } else {
            Button {
                Task { await state.loadStorageStatus() }
            } label: {
                Label("Load storage status", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.bold))
            }
            .disabled(state.isBusy)
        }
        HStack(spacing: 10) {
            Button {
                topUpPresented = true
            } label: {
                Label("Top up", systemImage: "plus.circle")
                    .font(.subheadline.weight(.bold))
            }
            .disabled(state.isBusy)
            if state.storageNeedsUpgrade {
                Button {
                    upgradeConfirmationPresented = true
                } label: {
                    Label("Upgrade storage", systemImage: "arrow.up.circle")
                        .font(.subheadline.weight(.bold))
                }
                .disabled(state.isBusy)
            }
        }
        if !hasBlackholeController {
            Button {
                blackholeConfirmationPresented = true
            } label: {
                Label("Add Blackhole controller", systemImage: "lock.shield")
                    .font(.subheadline.weight(.bold))
            }
            .disabled(state.isBusy || state.storageStatus == nil)
        }
    }

    private func storageRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(TaggrTheme.secondaryText)
            Text(value)
                .font(.footnote.monospaced())
                .foregroundStyle(TaggrTheme.text)
                .textSelection(.enabled)
        }
    }

    private func storageMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(TaggrTheme.secondaryText)
            Text(value)
                .font(.headline.weight(.black))
                .foregroundStyle(TaggrTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TaggrTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }

    private func cycleCount(_ cycles: UInt64) -> String {
        if cycles >= 1_000_000_000_000 {
            return String(format: "%.2fT", Double(cycles) / 1_000_000_000_000)
        }
        if cycles >= 1_000_000_000 {
            return String(format: "%.2fB", Double(cycles) / 1_000_000_000)
        }
        return cycles.formatted()
    }
}

private struct StorageTopUpSheet: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var pendingE8s: UInt64?
    @State private var validationMessage: String?
    @State private var confirmationPresented = false

    var body: some View {
        NavigationStack {
            ZStack {
                TaggrTheme.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    if let validationMessage {
                        Text(validationMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    TextField("Amount ICP", text: $amount)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                        .textFieldStyle(.plain)
                        .foregroundStyle(TaggrTheme.text)
                        .padding(12)
                        .background(TaggrTheme.panelRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Button {
                        validate()
                    } label: {
                        Label("Review top-up", systemImage: "checkmark.seal")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isBusy)
                    Spacer()
                }
                .padding(16)
            }
            .navigationTitle("Top up storage")
            .taggrInlineNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Confirm storage top-up", isPresented: $confirmationPresented) {
                Button("Cancel", role: .cancel) {}
                Button("Top up") {
                    Task {
                        if let pendingE8s {
                            await state.topUpStorageCanister(amountE8s: pendingE8s)
                            if state.errorMessage == nil {
                                dismiss()
                            }
                        }
                    }
                }
            } message: {
                Text("Transfers \(ICPAmount.format(pendingE8s ?? 0)) plus \(ICPAmount.format(ICPAmount.feeE8s)) fee to the CMC top-up account.")
            }
        }
    }

    private func validate() {
        validationMessage = nil
        guard let e8s = ICPAmount.parse(amount), e8s > ICPAmount.feeE8s else {
            validationMessage = "Enter a valid ICP amount greater than the ledger fee."
            return
        }
        pendingE8s = e8s
        confirmationPresented = true
    }
}

private struct SendICPSheet: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var recipient = ""
    @State private var amount = ""
    @State private var pendingE8s: UInt64?
    @State private var confirmationPresented = false
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                TaggrTheme.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    if let validationMessage {
                        Text(validationMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    TextField("Recipient principal or ICP account", text: $recipient)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.plain)
                        .foregroundStyle(TaggrTheme.text)
                        .padding(12)
                        .background(TaggrTheme.panelRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    TextField("Amount ICP", text: $amount)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                        .textFieldStyle(.plain)
                        .foregroundStyle(TaggrTheme.text)
                        .padding(12)
                        .background(TaggrTheme.panelRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Button {
                        validate()
                    } label: {
                        Label("Review transfer", systemImage: "checkmark.seal")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isBusy)
                    Spacer()
                }
                .padding(16)
            }
            .navigationTitle("Send ICP")
            .taggrInlineNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Confirm ICP transfer", isPresented: $confirmationPresented) {
                Button("Cancel", role: .cancel) {}
                Button("Send") {
                    Task {
                        if let pendingE8s {
                            await state.sendICP(to: recipient, amountE8s: pendingE8s)
                            if state.errorMessage == nil {
                                dismiss()
                            }
                        }
                    }
                }
            } message: {
                Text("Transfer \(ICPAmount.format(pendingE8s ?? 0)) plus \(ICPAmount.format(ICPAmount.feeE8s)) fee.")
            }
        }
    }

    private func validate() {
        validationMessage = nil
        guard let e8s = ICPAmount.parse(amount), e8s > 0 else {
            validationMessage = "Enter a valid ICP amount."
            return
        }
        do {
            _ = try ICPAccountIdentifier.parse(recipient)
        } catch {
            validationMessage = error.localizedDescription
            return
        }
        pendingE8s = e8s
        confirmationPresented = true
    }
}

private struct AccountCreationSheet: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var registrationName = ""
    @State private var inviteCode = ""
    @State private var paymentConfirmationPresented = false

    private var trimmedName: String {
        registrationName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedInvite: String {
        inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasInvite: Bool {
        !trimmedInvite.isEmpty
    }

    private var canCreate: Bool {
        hasInvite || state.icpInvoice?.paid == true
    }

    private var primaryLabel: String {
        if hasInvite {
            return "Create with invite"
        }
        if state.icpInvoice?.paid == true {
            return "Create account"
        }
        if state.icpInvoice == nil {
            return "Get ICP payment info"
        }
        return "Check payment"
    }

    private var primaryDisabled: Bool {
        state.isBusy || (canCreate && trimmedName.isEmpty)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TaggrTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let message = state.errorMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                        TextField("Username", text: $registrationName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.plain)
                            .foregroundStyle(TaggrTheme.text)
                            .padding(12)
                            .background(TaggrTheme.panelRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        TextField("Invite code", text: $inviteCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.plain)
                            .foregroundStyle(TaggrTheme.text)
                            .padding(12)
                            .background(TaggrTheme.panelRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        if !hasInvite {
                            invoiceSection
                        }
                        Button {
                            Task { await runPrimaryAction() }
                        } label: {
                            Label(primaryLabel, systemImage: canCreate ? "person.badge.plus" : "creditcard")
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(primaryDisabled)
                        if state.isBusy {
                            ProgressView()
                                .tint(TaggrTheme.clickable)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Create TAGGR user")
            .taggrInlineNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Pay ICP invoice", isPresented: $paymentConfirmationPresented, presenting: state.icpInvoice) { _ in
                Button("Cancel", role: .cancel) {}
                Button("Pay") {
                    Task { await state.payICPInvoice() }
                }
            } message: { invoice in
                Text("Transfers \(ICPAmount.format(invoice.e8s)) plus \(ICPAmount.format(ICPAmount.feeE8s)) fee from your ICP wallet.")
            }
            .onChange(of: state.currentUser?.id) { _, userId in
                if userId != nil {
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder private var invoiceSection: some View {
        if let invoice = state.icpInvoice {
            if invoice.paid {
                Label("Credits minted. Create your account now.", systemImage: "checkmark.seal")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(TaggrTheme.text)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Send ICP from your wallet, then check payment.")
                        .font(.footnote)
                        .foregroundStyle(TaggrTheme.secondaryText)
                    invoiceRow(title: "Amount", value: "\(invoice.amountICP) ICP")
                    invoiceRow(title: "Account", value: invoice.accountHex)
                    Button {
                        paymentConfirmationPresented = true
                    } label: {
                        Label("Pay ICP with TAGGR wallet", systemImage: "creditcard")
                            .font(.subheadline.weight(.bold))
                    }
                    .disabled(state.isBusy)
                }
                .padding(12)
                .background(TaggrTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        } else {
            Text("Without an invite, TAGGR uses the same ICP invoice flow as the web app.")
                .font(.footnote)
                .foregroundStyle(TaggrTheme.secondaryText)
        }
    }

    private func invoiceRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(TaggrTheme.secondaryText)
                .textCase(.uppercase)
            HStack(alignment: .top, spacing: 8) {
                Text(value)
                    .font(.footnote.monospaced())
                    .foregroundStyle(TaggrTheme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    UIPasteboard.general.string = value
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("Copy \(title)")
            }
        }
    }

    private func runPrimaryAction() async {
        if canCreate {
            let created = await state.createUser(name: trimmedName, invite: trimmedInvite)
            if created {
                dismiss()
            }
        } else {
            await state.checkICPInvoice()
        }
    }
}

private struct SettingsPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(TaggrTheme.secondaryText)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 12) {
                content
                    .foregroundStyle(TaggrTheme.clickable)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TaggrTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
