import SwiftUI
import UIKit
import WebKit

// MARK: - Hidden On-Screen Keyboard Responder

final class CustomTextField: UITextField {
    var onBackspace: (() -> Void)?

    override func deleteBackward() {
        super.deleteBackward()
        onBackspace?()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        false
    }
}

struct OnScreenKeyboardResponder: UIViewRepresentable {
    @Binding var isFocused: Bool
    let onCharacter: (String) -> Void
    let onBackspace: () -> Void
    let onReturn: () -> Void

    func makeUIView(context: Context) -> CustomTextField {
        let field = CustomTextField()
        field.delegate = context.coordinator
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.keyboardAppearance = .dark
        field.alpha = 0.001
        field.isUserInteractionEnabled = true
        context.coordinator.onBackspace = onBackspace
        return field
    }

    func updateUIView(_ uiView: CustomTextField, context: Context) {
        context.coordinator.onBackspace = onBackspace
        if isFocused {
            if !uiView.isFirstResponder {
                uiView.becomeFirstResponder()
            }
        } else {
            if uiView.isFirstResponder {
                uiView.resignFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let parent: OnScreenKeyboardResponder
        var onBackspace: (() -> Void)?

        init(parent: OnScreenKeyboardResponder) {
            self.parent = parent
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if string.isEmpty {
                onBackspace?()
            } else {
                for char in string {
                    parent.onCharacter(String(char))
                }
            }
            return false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onReturn()
            return false
        }
    }
}

// MARK: - GamePlayerView

struct GamePlayerView: View {

    let game: Game

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: GameStore
    @EnvironmentObject private var launcher: LauncherSettingsStore

    @StateObject private var session: GameSession
    @StateObject private var controls: ControlSettingsStore
    @StateObject private var playtime: PlaytimeTracker

    @State private var isUtilityBarCollapsed = false
    @State private var isKeyboardVisible = false
    @State private var isEditing = false
    @State private var scope: ControlSettingsStore.Scope = .game
    @State private var didConfigure = false
    @State private var speedMultiplier = 1
    @State private var hasCopiedError = false

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
                    .transition(.opacity.animation(.easeOut(duration: 0.35)))
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
            } else if let diagnostic = session.bootDiagnostic, !session.isDiagnosticDismissed, !session.isLoading, isFatalErrorDiagnostic(diagnostic) {
                errorOverlay(
                    message: diagnostic,
                    detail: diagnosticDetail,
                    showsContinue: true
                )
                .zIndex(22)
            }

            if !gameFailed {
                TouchControlsView(
                    config: $controls.config,
                    isEditing: isEditing,
                    onPress: { action in press(action) },
                    onRelease: { action in release(action) },
                    onEditCommitted: { controls.autosave(scope: scope) }
                )
                .zIndex(5)
            }

            if isEditing, !gameFailed {
                customizerPanel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(8)
            }

            if let diagnostic = session.bootDiagnostic, !session.isDiagnosticDismissed, !gameFailed, !session.isLoading, !isFatalErrorDiagnostic(diagnostic) {
                errorBanner(diagnostic)
                    .zIndex(15)
            }

            if !gameFailed {
                collapsibleUtilityBar
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }

            // Hidden on-screen keyboard responder
            OnScreenKeyboardResponder(
                isFocused: $isKeyboardVisible,
                onCharacter: handleKeyboardCharacter,
                onBackspace: handleKeyboardBackspace,
                onReturn: handleKeyboardReturn
            )
            .frame(width: 1, height: 1)
            .opacity(0.001)
            .allowsHitTesting(false)
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

    private func isFatalErrorDiagnostic(_ message: String) -> Bool {
        let lower = message.lowercased()
        if lower.contains("recovered:") || lower.contains("warning:") || lower.contains("timed out (1000ms); initialized _globalinfo = []") {
            return false
        }
        if message == GameSession.slowBootNotice || message == GameSession.missingEngineNotice {
            return false
        }
        return true
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

    @ViewBuilder
    private func errorOverlay(message: String, detail: String?, showsContinue: Bool = false) -> some View {
        let parsed = parseErrorMessage(message: message, detail: detail)
        let fullErrorText: String = {
            if let trace = parsed.trace, !trace.isEmpty {
                return "\(parsed.headline)\n\n\(trace)"
            }
            return parsed.headline
        }()

        ZStack {
            // Dark solid backdrop blocking raw canvas stack text
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .contentShape(Rectangle())

            VStack(spacing: 0) {
                // Pinned Header
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color.orange)

                        Text("Game Error")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(SparkTheme.textPrimary)

                        Spacer()
                    }

                    // Pinned Prominent Monospaced Error Title (TypeError: ...)
                    Text(parsed.headline)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(SparkTheme.textPrimary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.red.opacity(0.18))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.red.opacity(0.4), lineWidth: 1)
                        )
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 10)

                Divider()
                    .background(SparkTheme.hairline)

                // Scrollable, Selectable Stack Trace Body
                ScrollView(.vertical, showsIndicators: true) {
                    Text(parsed.trace ?? "No additional stack trace available.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(SparkTheme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color.black.opacity(0.25))

                Divider()
                    .background(SparkTheme.hairline)

                // Action Buttons Bar: Copy Error, Dismiss, Back to Library
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = fullErrorText
                        withAnimation(.easeInOut(duration: 0.15)) {
                            hasCopiedError = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                hasCopiedError = false
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: hasCopiedError ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .medium))
                            Text(hasCopiedError ? "Copied!" : "Copy Error")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(hasCopiedError ? Color.green : SparkTheme.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(hasCopiedError ? Color.green.opacity(0.15) : Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(hasCopiedError ? Color.green.opacity(0.4) : SparkTheme.hairline, lineWidth: SparkTheme.hairlineWidth)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())

                    Spacer()

                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            session.dismissDiagnostic()
                        }
                    } label: {
                        Text("Dismiss")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(SparkTheme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(SparkTheme.hairline, lineWidth: SparkTheme.hairlineWidth)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button {
                        close()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.backward")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Back to Library")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(accent)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: 560, maxHeight: 360)
            .background(
                ZStack {
                    SparkTheme.panelRaised
                    VisualEffectBlur(style: .systemUltraThinMaterialDark)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(SparkTheme.hairlineStrong, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)
            .padding(24)
        }
    }

    private func parseErrorMessage(message: String, detail: String?) -> (headline: String, trace: String?) {
        let lines = message.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let headline = lines.first ?? message
        var traceParts: [String] = []
        if lines.count > 1 {
            traceParts.append(lines.dropFirst().joined(separator: "\n"))
        }
        if let d = detail, !d.isEmpty {
            let filteredDetail = d.replacingOccurrences(of: message, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !filteredDetail.isEmpty && !traceParts.contains(filteredDetail) {
                traceParts.append(filteredDetail)
            }
        }
        let trace = traceParts.isEmpty ? nil : traceParts.joined(separator: "\n\n")
        return (headline, trace)
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

    // MARK: - Collapsible Top-Center Utility Bar

    private var collapsibleUtilityBar: some View {
        VStack {
            if isUtilityBarCollapsed {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isUtilityBarCollapsed = false
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.85))
                        .frame(width: 44, height: 22)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.black.opacity(0.65))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.white.opacity(0.18), lineWidth: 0.75)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Expand utility bar")
                .padding(.top, 4)
            } else {
                HStack(spacing: 3) {
                    hudButton("chevron.left", action: close)
                        .accessibilityLabel("Back to Library")

                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 0.5, height: 16)
                        .padding(.horizontal, 2)

                    if !game.engine.isMKXP {
                        speedButton
                    }

                    hudButton("keyboard", active: isKeyboardVisible) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            isKeyboardVisible.toggle()
                        }
                    }
                    .accessibilityLabel("On-screen Keyboard")

                    hudButton(controls.config.hideAllControls ? "eye.slash" : "gamecontroller", active: controls.config.hideAllControls) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            controls.config.hideAllControls.toggle()
                            controls.autosave(scope: scope)
                        }
                    }
                    .accessibilityLabel("Toggle Controls")

                    hudButton("slider.horizontal.3", active: isEditing) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            isEditing.toggle()
                        }
                    }
                    .accessibilityLabel("Customize Controls")

                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 0.5, height: 16)
                        .padding(.horizontal, 2)

                    hudButton("chevron.up") {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isUtilityBarCollapsed = true
                        }
                    }
                    .accessibilityLabel("Collapse Utility Bar")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.black.opacity(0.65))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 0.75)
                )
                .padding(.top, 8)
            }

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
                        .lineLimit(10)
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

    // MARK: - Control Customizer Panel

    private var customizerPanel: some View {
        VStack {
            HStack {
                Spacer()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Customize Controls")
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
                                    .frame(width: 24, height: 24)
                            }
                        }

                        Text("Tap buttons to enable or disable them. Drag any button or the D-Pad directly on screen to reposition.")
                            .font(.system(size: 10))
                            .foregroundColor(SparkTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("BUTTON LIBRARY")
                            .sparkSectionLabel()

                        buttonLibraryGrid

                        Text("SAVE CONFIGURATION")
                            .sparkSectionLabel()

                        Picker("Save to", selection: $scope) {
                            Text("This Game").tag(ControlSettingsStore.Scope.game)
                            Text("Global").tag(ControlSettingsStore.Scope.global)
                        }
                        .pickerStyle(SegmentedPickerStyle())

                        Text("SIZES & OPACITY")
                            .sparkSectionLabel()

                        labeledSlider(
                            "D-Pad size",
                            value: $controls.config.dpadScale,
                            range: 0.6...1.8,
                            display: String(format: "%.1fx", controls.config.dpadScale)
                        )

                        labeledSlider(
                            "Button size",
                            value: $controls.config.buttonScale,
                            range: 0.6...1.8,
                            display: String(format: "%.1fx", controls.config.buttonScale)
                        )

                        labeledSlider(
                            "Button opacity",
                            value: $controls.config.opacity,
                            range: 0.15...1.0,
                            display: "\(Int(controls.config.opacity * 100))%"
                        )

                        Text("BEHAVIOR")
                            .sparkSectionLabel()

                        toggleRow("Auto-fade when idle", isOn: $controls.config.autoFade)
                        toggleRow("8-way D-Pad", isOn: $controls.config.eightWay)
                        toggleRow("Haptic feedback", isOn: $controls.config.haptics)
                        toggleRow("Mirror left / right", isOn: $controls.config.mirrored)
                        toggleRow("Hide All Controls", isOn: $controls.config.hideAllControls)

                        Text("ORIENTATION")
                            .sparkSectionLabel()

                        Picker("Orientation", selection: $controls.config.orientation) {
                            ForEach(OrientationMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())

                        HStack(spacing: 8) {
                            Button("Reset Default") {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    controls.reset()
                                }
                            }
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(0.06))
                            .foregroundColor(SparkTheme.textSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                            Button("Done") {
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
                        .padding(.top, 4)
                    }
                    .padding(15)
                }
                .frame(maxHeight: 560)
                .frame(width: 310)
                .sparkPanel(cornerRadius: 14, fill: SparkTheme.panel, borderOpacity: 0.12)
                .padding(.trailing, 16)
                .padding(.top, 56)
            }
            Spacer()
        }
    }

    private var buttonLibraryGrid: some View {
        let columns = [
            GridItem(.adaptive(minimum: 52), spacing: 6)
        ]
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(VirtualButtonID.allCases) { btn in
                let enabled = controls.config.isEnabled(btn)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        controls.config.setEnabled(btn, !enabled)
                    }
                } label: {
                    Text(btn.label)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(enabled ? .white : SparkTheme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(enabled ? accent.opacity(0.85) : Color.white.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(
                                    enabled ? Color.white.opacity(0.35) : SparkTheme.hairline,
                                    lineWidth: SparkTheme.hairlineWidth
                                )
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private func labeledSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(SparkTheme.textSecondary)
                Spacer()
                Text(display)
                    .font(.system(size: 11, design: .monospaced))
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

    // MARK: - Lifecycle

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

    // MARK: - Software Keyboard Keystroke Routing

    private func handleKeyboardCharacter(_ char: String) {
        let keyCode: Int
        if let ascii = char.uppercased().utf8.first {
            keyCode = Int(ascii)
        } else {
            keyCode = Int(char.unicodeScalars.first?.value ?? 0)
        }
        session.sendKey(type: "keydown", key: char, keyCode: keyCode, button: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            self.session.sendKey(type: "keyup", key: char, keyCode: keyCode, button: nil)
        }
    }

    private func handleKeyboardBackspace() {
        session.sendKey(type: "keydown", key: "Backspace", keyCode: 8, button: "cancel")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            self.session.sendKey(type: "keyup", key: "Backspace", keyCode: 8, button: "cancel")
        }
    }

    private func handleKeyboardReturn() {
        session.sendKey(type: "keydown", key: "Enter", keyCode: 13, button: "ok")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            self.session.sendKey(type: "keyup", key: "Enter", keyCode: 13, button: "ok")
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

/// Keeps the WKWebView creation inside `makeUIView` and tracks loaded URLs
/// in Coordinator so that `@Published` state changes never restart the page mid-boot.
struct WebViewHost: UIViewRepresentable {

    let session: GameSession

    final class Coordinator {
        var loadedURL: URL?
        var loadedGameID: String?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let view = session.makeWebViewIfNeeded()
        let target = session.targetURL
        if context.coordinator.loadedURL != target || context.coordinator.loadedGameID != session.game.id {
            context.coordinator.loadedURL = target
            context.coordinator.loadedGameID = session.game.id
            session.loadGame()
        }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let target = session.targetURL
        if context.coordinator.loadedURL != target || context.coordinator.loadedGameID != session.game.id {
            context.coordinator.loadedURL = target
            context.coordinator.loadedGameID = session.game.id
            session.loadGame()
        }
    }
}
