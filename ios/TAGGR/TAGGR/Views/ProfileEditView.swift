import SwiftUI

struct ProfileEditView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TaggrProfileDraft?
    @State private var baseline: TaggrUser?
    @State private var busy = false
    @State private var error: String?
    @State private var confirmation = false
    @State private var confirmationText = ""
    @State private var validation = ""
    @State private var needsReconciliation = false

    var body: some View {
        NavigationStack {
            Form {
                if let value = draft {
                    Section("Profile") {
                        TextField("Name", text: binding(\.name))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        if !validation.isEmpty { Text(validation).font(.caption) }
                        TextField("About", text: binding(\.about), axis: .vertical)
                        TextField("Label: https://example.com (one per line)", text: binding(\.links), axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Picker("Usage mode", selection: binding(\.mode)) {
                            Text("Convert rewards to credits").tag("Credits")
                            Text("Receive ICP rewards").tag("Rewards")
                            Text("Mine tokens").tag("Mining")
                        }
                        Toggle("Participate in governance", isOn: binding(\.governance))
                    }
                    Section("Account Controllers") {
                        TextField("Principal (one per line)", text: binding(\.controllers), axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("Controllers can operate your TAGGR account. Only add Principals you trust.")
                            .font(.footnote)
                    }
                    if value.mode == "Credits", baseline?.mode != "Credits", (baseline?.rewards ?? 0) > 0 {
                        Text("Pending rewards must be received before switching to Credits.").foregroundStyle(.red)
                    }
                }
                FeatureStatus(loading: busy, error: error, retry: { Task { await load() } })
                if error != nil, !needsReconciliation, let draft, let baseline {
                    let unsaved = draft.unsavedFields(comparedTo: baseline)
                    Text(unsaved.isEmpty ? "All requested values are present on the server." : "Values reloaded. Unsaved fields: " + unsaved.joined(separator: ", "))
                        .font(.footnote)
                }
                if needsReconciliation { Button("Reload account to verify saved changes") { Task { await load() } } }
            }
            .navigationTitle("Edit profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { prepareSave() }.disabled(busy || draft == nil || needsReconciliation)
                }
            }
            .confirmationDialog("Save account changes?", isPresented: $confirmation, titleVisibility: .visible) {
                Button("Save changes") { Task { await save() } }
            } message: { Text(confirmationText) }
            .interactiveDismissDisabled(busy)
            .task { await load() }
            .task(id: draft?.name) { await validateName() }
        }
    }
    private func binding<Value>(_ path: WritableKeyPath<TaggrProfileDraft, Value>) -> Binding<Value> {
        Binding(get: { draft![keyPath: path] }, set: { draft?[keyPath: path] = $0 })
    }
    private func load() async {
        guard !busy else { return }
        busy = true; error = nil
        let context = TaggrFeatureContext(state)
        defer { busy = false }
        do {
            try await context.refreshUser(state)
            baseline = state.currentUser
            if let user = baseline {
                if draft == nil { draft = TaggrProfileDraft(user) }
                needsReconciliation = false
            }
        } catch { if context.matches(state) { self.error = error.localizedDescription } }
    }
    private func validateName() async {
        validation = ""
        guard let draft, let baseline, draft.name != baseline.name, !draft.name.isEmpty else { return }
        let name = draft.name
        let context = TaggrFeatureContext(state)
        do {
            try await Task.sleep(for: .milliseconds(300))
            let response = try await context.api.query("validate_username", args: [name], as: JSONValue.self)
            try context.requireCurrent(state)
            guard self.draft?.name == name else { return }
            validation = response?.objectValue?["Err"]?.stringValue ?? "Available"
        } catch is CancellationError {} catch { if context.matches(state) { validation = error.localizedDescription } }
    }
    private func prepareSave() {
        guard let draft, let baseline else { return }
        do {
            try draft.validate()
            if draft.mode == "Credits", baseline.mode != "Credits", (baseline.rewards ?? 0) > 0 {
                throw TaggrAPIError.rejected("Receive pending rewards before switching to Credits.")
            }
            var messages = [String]()
            if draft.name != baseline.name {
                guard let cost = state.cache?.config?.identityChangeCost else {
                    throw TaggrAPIError.rejected("Name-change cost unavailable. Reload account settings.")
                }
                messages.append("Name change costs \(cost) credits. Your old name will still route to your profile.")
            }
            if draft.controllerIDs != baseline.controllers {
                messages.append("Account Controllers will change from \(baseline.controllers.joined(separator: ", ")) to \(draft.controllerIDs.joined(separator: ", ")).")
            }
            confirmationText = messages.isEmpty ? "Save your profile changes?" : messages.joined(separator: "\n\n")
            confirmation = true
        } catch { self.error = error.localizedDescription }
    }
    private func save() async {
        guard !busy, let draft else { return }
        busy = true; error = nil
        let context = TaggrFeatureContext(state)
        defer { busy = false }
        var profileSaved = false
        do {
            guard let identity = context.identity else { throw TaggrAPIError.missingIdentity }
            let latest = try await context.api.featureUser(identity: identity)
            try context.requireCurrent(state)
            // A changed baseline requires a new confirmation, especially for paid renames.
            guard let baseline, TaggrProfileDraft(latest) == TaggrProfileDraft(baseline) else {
                self.baseline = latest
                throw TaggrAPIError.rejected("Your account changed. Review the latest values before saving again.")
            }
            if draft.profileChanged(from: latest) {
                if draft.mode == "Credits", latest.mode != "Credits", (latest.rewards ?? 0) > 0 {
                    throw TaggrAPIError.rejected("Receive pending rewards before switching to Credits.")
                }
                if draft.name != latest.name {
                    guard let response = try await context.api.query("validate_username", args: [draft.name], as: JSONValue.self) else {
                        throw TaggrAPIError.emptyResponse
                    }
                    if let reason = response.objectValue?["Err"]?.stringValue { throw TaggrAPIError.rejected(reason) }
                }
                try context.requireCurrent(state)
                try await context.api.updateProfile(draft, preserving: latest, identity: identity)
                profileSaved = true
            }
            try context.requireCurrent(state)
            if draft.links != (latest.settings["links"] ?? "") {
                let current = try await context.api.featureUser(identity: identity)
                try context.requireCurrent(state)
                try await context.api.updateLinks(draft.links, preserving: current.settings, identity: identity)
            }
            try await context.refreshUser(state)
            dismiss()
        } catch {
            guard context.matches(state) else { return }
            self.error = (profileSaved ? "Profile saved; links may not be saved. " : "") + error.localizedDescription
            needsReconciliation = true
            do {
                try await context.refreshUser(state)
                baseline = state.currentUser
                needsReconciliation = false
            } catch { self.error = (self.error ?? "") + " Reload the account before retrying." }
        }
    }
}
