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

    @State private var showTopBar = true
    @State private var showControls = true
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

            if session.isLoading, game.engine.isWebBased || game.engine.isEasyRPG {
                loadingOverlay
            }

            if let error = session.loadError {
                errorOverlay(message: error)
            }

            if showControls, !isEditing {
                TouchControlsView(
                    config: $controls.config,
                    isEditing: false,
                    onPress: { action in press(action) },
                    onRelease: { action in release(action) },
                    onEditCommitted: {}
                )
            }

            if isEditing {
                TouchControlsView(
                    config: $controls.config,
                    isEditing: true,
                    onPress: { _ in },
                    onRelease: { _ in },
                    onEditCommitted: { controls.autosave(scope: scope) }
                )

                customizerPanel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if showTopBar {
                topBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if !isEditing {
                restoreBarButton
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

                Text(game.engine.isEasyRPG ? "Starting EasyRPG Player" : "Starting \(game.engine.displayName)")
                    .font(.system(size: 11))
                    .foregroundColor(SparkTheme.textSecondary)
            }
        }
    }

    private func errorOverlay(message: String) -> some View {
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

                HStack(spacing: 10) {
                    Button("Retry") {
                        session.loadGame()
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.08))
                    .foregroundColor(SparkTheme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Button("Close") {
                        close()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .foregroundColor(launcher.settings.highlightPrimaryButtons ? Color.white : SparkTheme.textPrimary)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(launcher.settings.highlightPrimaryButtons ? accent : Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                launcher.settings.highlightPrimaryButtons ? Color.clear : SparkTheme.hairline,
                                lineWidth: SparkTheme.hairlineWidth
                            )
                    )
                }
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        VStack {
            HStack(spacing: 8) {
                Button(action: close) {
                    barIcon("chevron.left")
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(game.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(SparkTheme.textPrimary)
                        .lineLimit(1)
                    Text(game.engine.displayName)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundColor(SparkTheme.textSecondary)
                }

                Spacer(minLength: 6)

                if !game.engine.isMKXP {
                    Button(action: cycleSpeed) {
                        Text("\(speedMultiplier)×")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(speedMultiplier > 1 ? accent : Color.white.opacity(0.08))
                            )
                            .foregroundColor(SparkTheme.textPrimary)
                    }
                    .accessibilityLabel("Game speed")
                    .accessibilityValue("\(speedMultiplier) times")
                }

                Button(action: cycleOrientation) {
                    barIcon(controls.config.orientation.symbolName)
                }

                Button(action: { session.reload() }) {
                    barIcon("arrow.clockwise")
                }

                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isEditing.toggle()
                    }
                } label: {
                    barIcon("slider.horizontal.3", active: isEditing)
                }

                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showTopBar = false
                        showControls = false
                    }
                } label: {
                    barIcon("eye.slash")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(
                ZStack {
                    BlurView(style: .systemThinMaterialDark)
                    Color.black.opacity(0.30)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: SparkTheme.hairlineWidth)
            )
            .padding(.horizontal, 14)
            .padding(.top, 8)

            Spacer()
        }
    }

    private func barIcon(_ name: String, active: Bool = false) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? accent : Color.white.opacity(0.08))
            )
            .foregroundColor(SparkTheme.textPrimary)
    }

    private var restoreBarButton: some View {
        VStack {
            HStack {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showTopBar = true
                        showControls = true
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Show")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(SparkTheme.textSecondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.40))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: SparkTheme.hairlineWidth)
                    )
                }
                .padding(.leading, 14)
                .padding(.top, 10)
                Spacer()
            }
            Spacer()
        }
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

    private func cycleOrientation() {
        let modes = OrientationMode.allCases
        let index = modes.firstIndex(of: controls.config.orientation) ?? 0
        let next = modes[(index + 1) % modes.count]
        controls.config.orientation = next
        OrientationManager.shared.apply(next)
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
