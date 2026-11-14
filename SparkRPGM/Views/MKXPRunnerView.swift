import SwiftUI
import UIKit

#if canImport(mkxp)
import mkxp
#endif

/// Launches RPG Maker XP / VX / VX Ace titles through the optional `mkxp`
/// engine module.
///
/// `mkxp` is a C++ player and is **not** part of the default SparkRPGM build
/// (the GitHub Actions workflow builds without it). The whole runner is
/// therefore gated behind `#if canImport(mkxp)`; when the module is absent the
/// player shows a polished explainer card instead of failing to compile.
struct MKXPRunnerView: View {

    let game: Game

    var body: some View {
        #if canImport(mkxp)
        MKXPContainerView(game: game)
            .ignoresSafeArea()
        #else
        MKXPUnavailableView(
            game: game,
            reason: "This SparkRPGM build does not include the optional mkxp module, so RPG Maker XP, VX and VX Ace titles cannot be played yet.",
            footnote: "Your game is installed and your save folder is ready. A build compiled with the mkxp module will pick it up automatically."
        )
        #endif
    }
}

// MARK: - mkxp host

#if canImport(mkxp)

/// Bridges an `mkxp` view controller into SwiftUI without hard-coding the
/// wrapper's class name. Different mkxp iOS ports expose different entry
/// points, so the runtime is discovered and configured through KVC.
private struct MKXPContainerView: UIViewControllerRepresentable {

    let game: Game

    func makeUIViewController(context: Context) -> UIViewController {
        let gameRoot = game.engineRootURL
        let saveRoot = AppPaths.ensureSaveFolder(forGame: game.folderName)

        let candidates = [
            "MKXPViewController",
            "MKXPPlayerViewController",
            "MKXPPlayerController",
            "MKXPRuntimeViewController",
            "MKXPViewController_iOS",
        ]

        for name in candidates {
            guard let type = NSClassFromString(name) as? NSObject.Type else { continue }
            let instance = type.init()
            guard let controller = instance as? UIViewController else { continue }
            configure(controller, gameRoot: gameRoot, saveRoot: saveRoot)
            return controller
        }

        let fallback = MKXPUnavailableView(
            game: game,
            reason: "The mkxp module is linked, but none of its known player controllers could be created.",
            footnote: "Check that the mkxp wrapper exports MKXPViewController, MKXPPlayerViewController or MKXPPlayerController."
        )
        let host = UIHostingController(rootView: fallback)
        host.view.backgroundColor = .black
        return host
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    private func configure(_ controller: UIViewController, gameRoot: URL, saveRoot: URL) {
        controller.view.backgroundColor = .black

        let values: [String: Any] = [
            "gamePath": gameRoot.path,
            "gameFolder": gameRoot.path,
            "rootPath": gameRoot.path,
            "savePath": saveRoot.path,
            "saveDirectory": saveRoot.path,
            "saveFolder": saveRoot.path,
            "title": game.title,
        ]

        for (key, value) in values {
            let setterName = "set" + key.prefix(1).uppercased() + String(key.dropFirst()) + ":"
            let selector = NSSelectorFromString(setterName)
            guard controller.responds(to: selector) else { continue }
            controller.setValue(value, forKey: key)
        }
    }
}
#endif

// MARK: - Explainer card

struct MKXPUnavailableView: View {

    let game: Game
    let reason: String
    let footnote: String

    @State private var didCopyPath = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        game.engine.badgeColor.opacity(0.42),
                                        game.engine.badgeColor.opacity(0.08),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 92, height: 92)
                        Image(systemName: "cpu")
                            .font(.system(size: 38, weight: .light))
                            .foregroundColor(.white.opacity(0.9))
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )

                    VStack(spacing: 6) {
                        Text(game.engine.displayName)
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.6)
                            .foregroundColor(game.engine.badgeColor)
                        Text(game.title)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                    }

                    Text(reason)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 6)

                    VStack(alignment: .leading, spacing: 10) {
                        infoRow(icon: "folder", title: "Game folder", value: game.rootURL.lastPathComponent)
                        infoRow(
                            icon: "internaldrive",
                            title: "Save folder",
                            value: "Documents/save/\(game.folderName)"
                        )
                        infoRow(icon: "shippingbox", title: "Size", value: game.formattedSize)
                    }
                    .padding(14)
                    .background(Color.white.opacity(0.045))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.07), lineWidth: 1)
                    )

                    HStack(spacing: 10) {
                        actionButton(title: "Open Files app", systemImage: "folder.badge.gearshape") {
                            openFilesApp()
                        }
                        actionButton(
                            title: didCopyPath ? "Copied" : "Copy path",
                            systemImage: didCopyPath ? "checkmark" : "doc.on.doc"
                        ) {
                            UIPasteboard.general.string = game.rootURL.path
                            didCopyPath = true
                        }
                    }

                    Text(footnote)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.36))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 34)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func infoRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.0)
                    .foregroundColor(.white.opacity(0.32))
                Text(value)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.76))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private func actionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white.opacity(0.86))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func openFilesApp() {
        let candidates = ["shareddocuments://", "files://"]
        for candidate in candidates {
            if let url = URL(string: candidate), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                return
            }
        }
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}
