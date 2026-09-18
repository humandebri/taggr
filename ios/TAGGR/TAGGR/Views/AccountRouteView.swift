import SwiftUI

struct AccountRouteView: View {
    @Environment(TaggrAppCoordinator.self) private var state
    var body: some View {
        Group {
            switch state.route {
            case .bookmarks: BookmarksView()
            case .invites: InvitesView()
            case .proposals: ProposalsView()
            case .proposal(let id): ProposalDetailView(id: id).id(id)
            default: SettingsView()
            }
        }.id("\(state.safetyScope):\(state.runtimeGeneration)")
    }
}
