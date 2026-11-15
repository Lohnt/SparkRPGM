import SwiftUI
import UIKit
import WebKit

struct GamePlayerView: View {

    let game: Game

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: GameStore
    @EnvironmentObject private var launcher: LauncherSettingsStore

    @StateObject private var session: GameSession
    @StateObject private var controls: ControlSettingsStore
    @StateObject private var playtime: PlaytimeTracker

    @State private var isHUDHidden = false
    @State private var isEditing = false
    @State private var scope: ControlSettingsStore.Scope = .game
    @State private var didConfigure = false
    @State private var speedMultiplier = 1

    private static let haptic = UIImpactFeedbackGenerator(style: .light)

    private var accent: Color { launcher.settings.accentColor }

    init(game: Game) {
        self.game = game
        let entry: GameSession.Entry = game.engine.isEasyRPG ? .easyRPGHost : .gameIndex
        _session = StateObject(wrappedValue: GameSession(game: game, entry: entry))
        _controls = StateObject(wrappedValue: ControlSettingsStore(gameFolder: game.folderName))
        _playtime = StateObject(wrappedValue: PlaytimeTracker(gameFolder: game.folderName))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            gameContent
                .ignoresSafeArea()
                .zIndex(0)

            if session.isLoading, game.engine.isWebBased || game.engine.isEasyRPG {
                loadingOverlay
                    .zIndex(20)
            }

            if let error = session.loadError {
                errorOverlay(message: error, detail: nil)
                    .zIndex(22)
            } else if session.didStall {
                errorOverlay(
                    message: session.bootDiagnostic ?? "The game did not finish starting.",
                    detail: diagnosticDetail,
                    showsContinue: true
                )
                .zIndex(22)
            }

            if !isHUDHidden, !isEditing, !gameFailed {
                TouchControlsView(
                    config: $controls.config,
                    isEditing: false,
                    onPress: { action in press(action) },
                    onRelease: { action in release(action) },
                    onEditCommitted: {}
                )
                .zIndex(5)
            }

            if isEditing, !gameFailed {
                TouchControlsView(
                    config: $controls.config,
                    isEditing: true,
                    onPress: { _ in },
                    onRelease: { _ in },
                    onEditCommitted: { controls.autosave(scope: scope) }
                )
                .zIndex(6)

                customizerPanel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(8)
            }

            if let diagnostic = session.bootDiagnostic, !gameFailed, !session.isLoading {
                errorBanner(diagnostic)
                    .zIndex(15)
            }

            if !isHUDHidden, !gameFailed {
                hudPill
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            } else if isHUDHidden, !isEditing, !gameFailed {
                restoreHUDButton
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .statusBar(hidden: true)
        .preferredColorScheme(.dark)
        .onAppear(perform: configureOnce)
        .onDisappear(perform: teardown)
        .onChange(of: controls.config.orientation) { newValue in
            OrientationManager.shared.apply(newValue)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                playtime.start()
            case .inactive, .background:
                playtime.pause()
                store.refreshMetadata()
            @unknown default:
                playtime.pause()
                store.refreshMetadata()
            }
        }
    }

    private var gameFailed: Bool {
        session.loadError != nil || session.didStall
    }

    private var diagnosticDetail: String? {
        guard !session.missingResources.isEmpty else { return session.bootDiagnostic }
        var lines = session.missingResources.suffix(6).map { "Missing file: \($0)" }
        if let diagnostic = session.bootDiagnostic {
            lines.insert(diagnostic, at: 0)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Content

    @ViewBuilder
    private var gameContent: some View {
        if game.engine.isMKXP {
            MKXPRunnerView(game: game)
        } else {
            WebViewHost(session: session)
        }
    }

    private var loadingOverlay: some View {
        ZStack {
            SparkTheme.canvas.opacity(0.97).ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.05)

                Text(game.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(SparkTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)

                Text(session.bootStage ?? (game.engine.isEasyRPG ? "Starting EasyRPG Player" : "Starting \(game.engine.displayName)"))
                    .font(.system(size: 11))
                    .foregroundColor(SparkTheme.textSecondary)

                if let diagnostic = session.bootDiagnostic {
                    Text(diagnostic)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(SparkTheme.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 34)
                        .padding(.top, 2)

                    HStack(spacing: 10) {
                        overlayButton("Retry", highlighted: false) {
                            session.loadGame()
                        }
                        overlayButton("Close", highlighted: true) {
                            close()
                        }
                    }
                    .padding(.top, 4)
                } else {
                    Text("This can take a moment on first launch.")
                        .font(.system(size: 10))
                        .foregroundColor(SparkTheme.textTertiary)
                        .padding(.top, 2)

                    Button {
                        close()
                    } label: {
                        Text("Close")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(SparkTheme.textSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(SparkTheme.hairline, lineWidth: SparkTheme.hairlineWidth)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
    }

    private func errorOverlay(message: String, detail: String?, showsContinue: Bool = false) -> some View {
        ZStack {
            SparkTheme.canvas.opacity(0.97).ignoresSafeArea()

            VStack(spacing: 13) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(SparkTheme.textSecondary)

                Text("The game could not start")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(SparkTheme.textPrimary)

                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(SparkTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 30)

                if let detail = detail, !detail.isEmpty {
                    ScrollView {
                        Text(detail)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundColor(SparkTheme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                    }
                    .frame(maxWidth: 320, maxHeight: 120)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .padding(.horizontal, 26)
                }

                HStack(spacing: 10) {
                    overlayButton("Retry", highlighted: false) {
                        session.loadGame()
                    }
                    overlayButton("Close", highlighted: true) {
                        close()
                    }
                    if showsContinue {
                        overlayButton("Continue", highlighted: false) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                session.dismissDiagnostic()
                            }
                        }
                    }
                }
            }
        }
    }

    private func overlayButton(_ title: String, highlighted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: highlighted ? .semibold : .medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .foregroundColor(highlighted && launcher.settings.highlightPrimaryButtons ? Color.white : SparkTheme.textPrimary)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(highlighted && launcher.settings.highlightPrimaryButtons ? accent : Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            highlighted && launcher.settings.highlightPrimaryButtons ? Color.clear : SparkTheme.hairline,
                            lineWidth: SparkTheme.hairlineWidth
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - HUD

    /// Compact floating capsule: Back, Speed, Controls, Hide. Sits centred at
    /// the top instead of spanning the screen.
    private var hudPill: some View {
        VStack {
            HStack(spacing: 2) {
                hudButton("chevron.left", action: close)

                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 0.5, height: 15)
                    .padding(.horizontal, 2)

                if !game.engine.isMKXP {
                    speedButton
                }

                hudButton("slider.horizontal.3", active: isEditing) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isEditing.toggle()
                    }
                }

                hudButton("eye.slash") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isEditing = false
                        isHUDHidden = true
                    }
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .frame(width: 180)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(hex: "141418").opacity(0.75))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
            .padding(.top, 8)

            Spacer()
        }
    }

    private var speedButton: some View {
        Button(action: cycleSpeed) {
            Text("\(speedMultiplier)×")
                .font(.system(size: 10.5, weight: .semibold))
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(speedMultiplier > 1 ? accent.opacity(0.85) : Color.white.opacity(0.05))
                )
                .foregroundColor(SparkTheme.textPrimary)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Game speed")
        .accessibilityValue("\(speedMultiplier) times")
    }

    private func hudButton(_ name: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? accent.opacity(0.85) : Color.white.opacity(0.05))
                )
                .foregroundColor(SparkTheme.textPrimary)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// Top-right corner chip shown while the HUD is hidden. It stays small so
    /// it never covers gameplay, and the whole 36×30 frame is tappable.
    private var restoreHUDButton: some View {
        VStack {
            HStack {
                Spacer()

                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isHUDHidden = false
                    }
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(SparkTheme.textSecondary)
                        .frame(width: 36, height: 30)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(hex: "141418").opacity(0.72))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Show controls")
                .padding(.trailing, 10)
            }

            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Diagnostics banner

    private func errorBanner(_ message: String) -> some View {
        VStack {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(red: 0.95, green: 0.62, blue: 0.36))
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Game load issue")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(SparkTheme.textPrimary)

                    Text(message)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(SparkTheme.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    if !session.missingResources.isEmpty {
                        Text(missingSummary)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(SparkTheme.textTertiary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 4)

                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        session.dismissDiagnostic()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(SparkTheme.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Dismiss")
            }
            .padding(11)
            .frame(maxWidth: 380, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(hex: "141418").opacity(0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .padding(.horizontal, 16)
            .padding(.top, 52)

            Spacer()
        }
    }

    private var missingSummary: String {
        let count = session.missingResources.count
        let names = session.missingResources.suffix(2).joined(separator: ", ")
        return "\(count) missing file\(count == 1 ? "" : "s"): \(names)"
    }

    // MARK: - Control customizer

    private var customizerPanel: some View {
        VStack {
            HStack {
                Spacer()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Controls")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(SparkTheme.textPrimary)
                            Spacer()
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    isEditing = false
                                    controls.save(scope: scope)
                                }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(SparkTheme.textSecondary)
                            }
                        }

                        Text("Drag the D-Pad or the buttons to reposition them.")
                            .font(.system(size: 10))
                            .foregroundColor(SparkTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        Picker("Save to", selection: $scope) {
                            Text("This Game").tag(ControlSettingsStore.Scope.game)
                            Text("Global").tag(ControlSettingsStore.Scope.global)
                        }
                        .pickerStyle(SegmentedPickerStyle())

                        labeledSlider(
                            "D-Pad size",
                            value: $controls.config.dpadScale,
                            range: 0.6...1.8,
                            display: String(format: "%.1fx", controls.config.dpadScale)
                        )

                        labeledSlider(
                            "Action size",
                            value: $controls.config.actionScale,
                            range: 0.6...1.8,
                            display: String(format: "%.1fx", controls.config.actionScale)
                        )

                        labeledSlider(
                            "Button opacity",
                            value: $controls.config.opacity,
                            range: 0.1...1.0,
                            display: "\(Int(controls.config.opacity * 100))%"
                        )

                        toggleRow("Auto-fade when idle", isOn: $controls.config.autoFade)
                        toggleRow("8-way D-Pad", isOn: $controls.config.eightWay)
                        toggleRow("Haptic feedback", isOn: $controls.config.haptics)
                        toggleRow("Mirror left / right", isOn: $controls.config.mirrored)
                        toggleRow("Show Shift button", isOn: $controls.config.showShift)
                        toggleRow("Show Ctrl / Skip button", isOn: $controls.config.showCtrl)

                        Text("ORIENTATION")
                            .sparkSectionLabel()

                        Picker("Orientation", selection: $controls.config.orientation) {
                            ForEach(OrientationMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())

                        HStack(spacing: 8) {
                            Button("Reload") {
                                session.reload()
                                withAnimation(.easeOut(duration: 0.2)) {
                                    isEditing = false
                                }
                            }
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(0.06))
                            .foregroundColor(SparkTheme.textSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                            Button("Reset") {
                                controls.reset()
                            }
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(0.06))
                            .foregroundColor(SparkTheme.textSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                            Button("Save") {
                                controls.save(scope: scope)
                                withAnimation(.easeOut(duration: 0.2)) {
                                    isEditing = false
                                }
                                store.toast("Controls saved")
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(accent)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .padding(.top, 2)
                    }
                    .padding(15)
                }
                .frame(maxHeight: 520)
                .frame(width: 300)
                .sparkPanel(cornerRadius: 14, fill: SparkTheme.panel, borderOpacity: 0.12)
                .padding(.trailing, 16)
                .padding(.top, 66)
            }
            Spacer()
        }
    }

    private func labeledSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(SparkTheme.textSecondary)
                Spacer()
                Text(display)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(SparkTheme.textTertiary)
            }
            Slider(value: value, in: range)
                .accentColor(accent)
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(SparkTheme.textSecondary)
        }
        .toggleStyle(SwitchToggleStyle(tint: accent))
    }

    // MARK: - Lifecycle and input

    private func configureOnce() {
        guard !didConfigure else { return }
        didConfigure = true
        AudioSessionConfigurator.activate()
        OrientationManager.shared.apply(controls.config.orientation)
        store.markPlayed(game)
        playtime.start()
        Self.haptic.prepare()
    }

    private func teardown() {
        playtime.pause()
        store.refreshMetadata()
        session.stop()
        OrientationManager.shared.restoreAuto()
    }

    private func close() {
        playtime.pause()
        store.refreshMetadata()
        session.stop()
        OrientationManager.shared.restoreAuto()
        dismiss()
    }

    private func press(_ action: ControlAction) {
        send(action, pressed: true)
        if controls.config.haptics {
            Self.haptic.impactOccurred(intensity: 0.6)
        }
    }

    private func release(_ action: ControlAction) {
        send(action, pressed: false)
    }

    private func send(_ action: ControlAction, pressed: Bool) {
        let type = pressed ? "keydown" : "keyup"
        session.sendKey(type: type, key: action.key, keyCode: action.keyCode, button: action.rpgmButton)

        if let secondary = action.secondaryKeyCode {
            session.sendKey(type: type, key: action.key, keyCode: secondary, button: action.rpgmButton)
        }
    }

    /// 1x → 2x → 3x → 1x. Applied live through `window.__sparkSetSpeed`.
    private func cycleSpeed() {
        let next = speedMultiplier >= 3 ? 1 : speedMultiplier + 1
        withAnimation(.easeOut(duration: 0.15)) {
            speedMultiplier = next
        }
        session.setSpeed(next)
    }
}

/// Keeps the WKWebView creation inside `makeUIView` so it is only built once,
/// and never during a SwiftUI body evaluation.
struct WebViewHost: UIViewRepresentable {

    let session: GameSession

    func makeUIView(context: Context) -> WKWebView {
        session.makeWebViewIfNeeded()
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
