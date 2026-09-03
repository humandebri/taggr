import SwiftUI

extension View {
    func taggrRefreshable() -> some View {
        modifier(TaggrRefreshableModifier(extraRefresh: nil))
    }

    func taggrRefreshable(extraRefresh: @escaping () async -> Void) -> some View {
        modifier(TaggrRefreshableModifier(extraRefresh: extraRefresh))
    }
}

private struct TaggrRefreshableModifier: ViewModifier {
    @Environment(TaggrAppCoordinator.self) private var state
    let extraRefresh: (() async -> Void)?

    func body(content: Content) -> some View {
        content.refreshable {
            await state.refreshVisibleRoute()
            if let extraRefresh {
                await extraRefresh()
            }
        }
    }
}
