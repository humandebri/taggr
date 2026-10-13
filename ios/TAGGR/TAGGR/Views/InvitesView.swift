import SwiftUI
import CoreImage.CIFilterBuiltins

struct InvitesView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @State private var entries: [TaggrInviteEntry] = []
    @State private var busy = false
    @State private var error: String?
    @State private var creating = false
    @State private var editing: TaggrInviteEntry?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                FeatureStatus(loading: busy, error: error, retry: { Task { await load() } })
                if state.currentUser == nil { Text("Sign in to manage invites.") }
                else {
                    Text("Credits are charged when an invite is used. It stops working if your balance is insufficient.")
                    Button("Create invite", systemImage: "plus") { creating = true }
                    if entries.isEmpty && !busy && error == nil { Text("No invites.") }
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.id.uppercased()).font(.headline.monospaced()).textSelection(.enabled)
                            Text("Credits: \(entry.invite.credits) · Per user: \(entry.invite.creditsPerUser)")
                            Text("Realm: \(entry.invite.realmId ?? "Global")")
                            Text(entry.invite.credits == 0 ? "Stopped" : "Active")
                            ForEach(entry.invite.joinedUserIds, id: \.self) { id in
                                if !state.isUserRestricted(id) {
                                    Button(state.authorNamesByUserID[id] ?? "User #\(id)") { state.navigateToProfile(String(id)) }
                                }
                            }
                            HStack {
                                Button("Copy code") { UIPasteboard.general.string = entry.id.uppercased() }
                                Button("Copy URL") { UIPasteboard.general.url = inviteURL(entry.id) }
                                ShareLink(item: inviteURL(entry.id))
                                Button("Edit") { editing = entry }
                            }
                            InviteQRCode(url: inviteURL(entry.id))
                        }.padding().background(TaggrTheme.panel).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.padding()
        }
        .navigationTitle("Invites")
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Back") { state.returnFromFeature(fallback: .settings) } } }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) {
            InviteEditView(entry: nil, reservedCredits: entries.reduce(0) { $0 + $1.invite.credits })
        }
        .sheet(item: $editing, onDismiss: { Task { await load() } }) { entry in
            InviteEditView(entry: entry, reservedCredits: entries.reduce(0) { $0 + $1.invite.credits })
        }
    }
    private func inviteURL(_ code: String) -> URL {
        var components = URLComponents()
        components.scheme = state.runtimeConfig.apiBaseURL.scheme == "http" ? "http" : "https"
        components.host = state.runtimeConfig.domain
        components.fragment = "/welcome/\(code)"
        return components.url!
    }
    private func load() async {
        guard !busy else { return }
        let context = TaggrFeatureContext(state)
        guard let identity = context.identity, context.userID != nil else { entries = []; return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let values = try await context.api.invites(identity: identity)
            try context.requireCurrent(state)
            entries = values.sorted { $0.id < $1.id }
            let names = try await state.loadAuthorNames(userIDs: values.flatMap { $0.invite.joinedUserIds }, generation: context.generation, api: context.api)
            try context.requireCurrent(state)
            for (id, name) in names { state.cacheAuthorName(name, userID: id) }
        } catch { if context.matches(state) { self.error = error.localizedDescription } }
    }
}

struct InviteQRCode: View {
    let url: URL
    private var image: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    var body: some View {
        if let image {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 180, height: 180)
                .padding(8).background(.white).accessibilityLabel("Invite QR code")
        }
    }
}

struct InviteEditView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @Environment(\.dismiss) private var dismiss
    let entry: TaggrInviteEntry?
    let reservedCredits: Int
    @State private var credits = ""
    @State private var perUser = ""
    @State private var realm = ""
    @State private var busy = false
    @State private var error: String?
    @State private var stopConfirmation = false
    @State private var uncertain = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("Total credits", text: $credits).keyboardType(.numberPad)
                if let entry { Text("Credits per user: \(entry.invite.creditsPerUser)") }
                else { TextField("Credits per user", text: $perUser).keyboardType(.numberPad) }
                TextField("Realm (optional)", text: $realm).textInputAutocapitalization(.characters).autocorrectionDisabled()
                if let minimum = state.cache?.config?.minCreditsForInviting { Text("Minimum per user: \(minimum) credits") }
                if let entry {
                    if entry.invite.canStop {
                        Button("Stop invite", role: .destructive) { stopConfirmation = true }.disabled(busy || uncertain)
                    } else if entry.invite.joinedUserIds.isEmpty {
                        Text("Unused invites cannot be stopped by the current API.").font(.footnote)
                    }
                }
                FeatureStatus(loading: busy, error: error)
                if uncertain { Text("Close and reload the invite list to verify the result before trying again.") }
            }
            .navigationTitle(entry == nil ? "Create invite" : "Edit invite")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save(stop: false) } }.disabled(busy || uncertain)
                }
            }
            .confirmationDialog("Stop this invite?", isPresented: $stopConfirmation) {
                Button("Stop invite", role: .destructive) { Task { await save(stop: true) } }
            } message: { Text("Remaining credits become zero. Existing invitation history is kept.") }
            .interactiveDismissDisabled(busy)
            .onAppear {
                credits = String(entry?.invite.credits ?? state.cache?.config?.minCreditsForInviting ?? 0)
                perUser = String(entry?.invite.creditsPerUser ?? state.cache?.config?.minCreditsForInviting ?? 0)
                realm = entry?.invite.realmId ?? ""
            }
        }
    }
    private func save(stop: Bool) async {
        guard !busy else { return }
        let context = TaggrFeatureContext(state)
        busy = true; error = nil
        defer { busy = false }
        var sent = false
        do {
            guard let identity = context.identity, let user = state.currentUser else { throw TaggrAPIError.missingIdentity }
            guard let amount = stop ? 0 : Int(credits), let each = Int(perUser), each > 0 else {
                throw TaggrAPIError.rejected("Enter valid whole credit amounts.")
            }
            if let entry { try entry.invite.validateCredits(amount) }
            else {
                guard let minimum = state.cache?.config?.minCreditsForInviting, amount > 0, each >= minimum, amount % each == 0 else {
                    throw TaggrAPIError.rejected("Total credits must be a positive multiple of credits per user, meeting the minimum.")
                }
            }
            guard amount <= (user.cycles ?? 0) - (reservedCredits - (entry?.invite.credits ?? 0)) else { throw TaggrAPIError.rejected("Insufficient credits.") }
            let name = realm.uppercased().replacingOccurrences(of: "/", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                let realms = try await context.api.query("realms", args: [[name]], as: [TaggrRealm].self) ?? []
                guard realms.first != nil else { throw TaggrAPIError.rejected("Realm not found.") }
            }
            try context.requireCurrent(state)
            sent = true
            if let entry { try await context.api.updateInvite(code: entry.id, credits: amount, realm: name, identity: identity) }
            else { try await context.api.createInvite(credits: amount, perUser: each, realm: name, identity: identity) }
            try await context.refreshUser(state)
            dismiss()
        } catch {
            if context.matches(state) {
                self.error = error.localizedDescription
                if sent, !(error is CancellationError) {
                    if case TaggrAPIError.rejected = error {} else { uncertain = true }
                }
            }
        }
    }
}
