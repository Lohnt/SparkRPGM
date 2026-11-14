import SwiftUI
import UIKit

@main
struct SparkRPGMApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var launcher = LauncherSettingsStore()
    @StateObject private var store: GameStore
    @StateObject private var coordinator: ImportCoordinator

    init() {
        AppPaths.bootstrap()
        AudioSessionConfigurator.activate()

        let gameStore = GameStore()
        _store = StateObject(wrappedValue: gameStore)
        _coordinator = StateObject(wrappedValue: ImportCoordinator(store: gameStore))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(launcher)
                .environmentObject(store)
                .environmentObject(coordinator)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppPaths.bootstrap()
        AudioSessionConfigurator.activate()

        if let urls = launchOptions?[.url] as? [URL] {
            ImportInbox.shared.enqueue(contentsOf: urls)
        }
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationManager.shared.supportedMask
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        ImportInbox.shared.enqueue(url)
        return true
    }
}
