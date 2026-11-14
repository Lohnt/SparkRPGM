import SwiftUI

struct RootView: View {

    @EnvironmentObject private var store: GameStore
    @EnvironmentObject private var coordinator: ImportCoordinator
    @EnvironmentObject private var launcher: LauncherSettingsStore

    var body: some View {
        LibraryView()
            .onAppear {
                store.scan()
                coordinator.drainInbox()
            }
            .onReceive(NotificationCenter.default.publisher(for: ImportInbox.didReceiveURLNotification)) { _ in
                coordinator.drainInbox()
            }
            .onOpenURL { url in
                coordinator.enqueue(urls: [url])
            }
    }
}
