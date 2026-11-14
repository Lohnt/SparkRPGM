import SwiftUI
import UIKit

// MARK: - D-Pad

/// Crisp plus-shaped control surface used for the left thumb.
private struct CrossShape: Shape {

    func path(in rect: CGRect) -> Path {
        let thickness = rect.width / 3
        let x0 = rect.minX
        let x1 = rect.minX + thickness
        let x2 = rect.minX + thickness * 2
        let x3 = rect.maxX
        let y0 = rect.minY
        let y1 = rect.minY + thickness
        let y2 = rect.minY + thickness * 2
        let y3 = rect.maxY

        var path = Path()
        path.move(to: CGPoint(x: x1, y: y0))
        path.addLine(to: CGPoint(x: x2, y: y0))
        path.addLine(to: CGPoint(x: x2, y: y1))
        path.addLine(to: CGPoint(x: x3, y: y1))
        path.addLine(to: CGPoint(x: x3, y: y2))
        path.addLine(to: CGPoint(x: x2, y: y2))
        path.addLine(to: CGPoint(x: x2, y: y3))
        path.addLine(to: CGPoint(x: x1, y: y3))
        path.addLine(to: CGPoint(x: x1, y: y2))
        path.addLine(to: CGPoint(x: x0, y: y2))
        path.addLine(to: CGPoint(x: x0, y: y1))
        path.addLine(to: CGPoint(x: x1, y: y1))
        path.closeSubpath()
        return path
    }
}

struct DPadView: View {

    let size: CGFloat
    let eightWay: Bool
    let inputEnabled: Bool
    let onPress: (ControlAction) -> Void
    let onRelease: (ControlAction) -> Void

    @State private var active: Set<ControlAction> = []

    private var directions: [ControlAction] { [.up, .down, .left, .right] }
    private var thickness: CGFloat { size / 3 }

    var body: some View {
        ZStack {
            CrossShape()
                .fill(Color(hex: "16161A").opacity(0.62))

            CrossShape()
                .stroke(Color.white.opacity(0.18), lineWidth: 1)

            ForEach(directions) { direction in
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(active.contains(direction) ? 0.20 : 0.001))
                    .frame(width: thickness - 2, height: thickness - 2)
                    .offset(segmentOffset(for: direction))
            }

            ForEach(directions) { direction in
                Image(systemName: chevron(for: direction))
                    .font(.system(size: size * 0.14, weight: .semibold))
                    .foregroundColor(Color.white.opacity(active.contains(direction) ? 0.95 : 0.42))
                    .offset(labelOffset(for: direction))
            }

            Circle()
                .fill(Color(hex: "16161A").opacity(0.9))
                .frame(width: size * 0.15, height: size * 0.15)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                        .frame(width: size * 0.15, height: size * 0.15)
                )
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    guard inputEnabled else { return }
                    update(location: value.location)
                }
                .onEnded { _ in
                    releaseAll()
                },
            including: inputEnabled ? .all : .none
        )
        .onDisappear(perform: releaseAll)
    }

    private func chevron(for direction: ControlAction) -> String {
        switch direction {
        case .up: return "chevron.up"
        case .down: return "chevron.down"
        case .left: return "chevron.left"
        case .right: return "chevron.right"
        default: return "circle"
        }
    }

    private func segmentOffset(for direction: ControlAction) -> CGSize {
        switch direction {
        case .up: return CGSize(width: 0, height: -thickness)
        case .down: return CGSize(width: 0, height: thickness)
        case .left: return CGSize(width: -thickness, height: 0)
        case .right: return CGSize(width: thickness, height: 0)
        default: return .zero
        }
    }

    private func labelOffset(for direction: ControlAction) -> CGSize {
        let distance = size * 0.35
        switch direction {
        case .up: return CGSize(width: 0, height: -distance)
        case .down: return CGSize(width: 0, height: distance)
        case .left: return CGSize(width: -distance, height: 0)
        case .right: return CGSize(width: distance, height: 0)
        default: return .zero
        }
    }

    private func update(location: CGPoint) {
        let center = CGPoint(x: size / 2, y: size / 2)
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        let deadZone = size * 0.14

        let next: Set<ControlAction>
        if distance < deadZone {
            next = []
        } else if eightWay {
            var set: Set<ControlAction> = []
            let axisThreshold = deadZone * 0.55
            if abs(dx) > axisThreshold { set.insert(dx > 0 ? .right : .left) }
            if abs(dy) > axisThreshold { set.insert(dy > 0 ? .down : .up) }
            next = set
        } else {
            next = [abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)]
        }

        guard next != active else { return }

        let released = active.subtracting(next)
        let pressed = next.subtracting(active)

        for action in released { onRelease(action) }
        for action in pressed { onPress(action) }
        active = next
    }

    private func releaseAll() {
        guard !active.isEmpty else { return }
        for action in active { onRelease(action) }
        active = []
    }
}

// MARK: - Dash pill

struct ShiftPillView: View {

    let width: CGFloat
    let inputEnabled: Bool
    let onPress: (ControlAction) -> Void
    let onRelease: (ControlAction) -> Void

    @State private var pressed = false

    var body: some View {
        Text("SHIFT")
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundColor(.white.opacity(0.86))
            .frame(width: width, height: 26)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(hex: "16161A").opacity(pressed ? 0.88 : 0.60))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(pressed ? 0.45 : 0.18), lineWidth: 1)
            )
            .scaleEffect(pressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.08), value: pressed)
            .contentShape(Capsule(style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard inputEnabled, !pressed else { return }
                        pressed = true
                        onPress(.shift)
                    }
                    .onEnded { _ in
                        release()
                    },
                including: inputEnabled ? .all : .none
            )
            .onDisappear(perform: release)
            .accessibilityLabel("Shift")
    }

    private func release() {
        guard pressed else { return }
        pressed = false
        onRelease(.shift)
    }
}

// MARK: - Action cluster

struct ActionClusterView: View {

    let size: CGFloat
    let showCtrl: Bool
    let inputEnabled: Bool
    let onPress: (ControlAction) -> Void
    let onRelease: (ControlAction) -> Void

    var body: some View {
        ZStack {
            // JoiPlay-style diamond: Z bottom-right, X to its left, CTRL above
            // X and ESC above Z.
            button(.ok, label: "Z", diameter: size * 0.34, position: CGPoint(x: 0.68, y: 0.70), primary: true)
            button(.cancel, label: "X", diameter: size * 0.28, position: CGPoint(x: 0.30, y: 0.78), primary: false)

            if showCtrl {
                button(.control, label: "CTRL", diameter: size * 0.21, position: CGPoint(x: 0.24, y: 0.44), primary: false)
            }
            button(.escape, label: "ESC", diameter: size * 0.21, position: CGPoint(x: 0.64, y: 0.32), primary: false)
        }
        .frame(width: size, height: size)
    }

    private func button(
        _ action: ControlAction,
        label: String,
        diameter: CGFloat,
        position: CGPoint,
        primary: Bool
    ) -> some View {
        ActionButtonView(
            action: action,
            label: label,
            diameter: diameter,
            primary: primary,
            inputEnabled: inputEnabled,
            onPress: onPress,
            onRelease: onRelease
        )
        .position(x: size * position.x, y: size * position.y)
    }
}

struct ActionButtonView: View {

    let action: ControlAction
    let label: String
    let diameter: CGFloat
    let primary: Bool
    let inputEnabled: Bool
    let onPress: (ControlAction) -> Void
    let onRelease: (ControlAction) -> Void

    @State private var pressed = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: "16161A").opacity(primary ? 0.72 : 0.58))
            Circle()
                .stroke(Color.white.opacity(pressed ? 0.52 : 0.18), lineWidth: pressed ? 1.6 : 1)
            Text(label)
                .font(.system(size: label.count > 1 ? diameter * 0.26 : diameter * 0.36, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.90))
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(pressed ? 0.93 : 1)
        .animation(.easeOut(duration: 0.08), value: pressed)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard inputEnabled, !pressed else { return }
                    pressed = true
                    onPress(action)
                }
                .onEnded { _ in
                    release()
                },
            including: inputEnabled ? .all : .none
        )
        .onDisappear(perform: release)
        .accessibilityLabel(accessibilityTitle)
    }

    private var accessibilityTitle: String {
        switch action {
        case .ok: return "Confirm"
        case .cancel: return "Cancel"
        case .control: return "Fast forward"
        case .escape: return "Menu"
        case .shift: return "Dash"
        default: return label
        }
    }

    private func release() {
        guard pressed else { return }
        pressed = false
        onRelease(action)
    }
}

// MARK: - Overlay container

struct TouchControlsView: View {

    @Binding var config: ControlConfig
    let isEditing: Bool
    let onPress: (ControlAction) -> Void
    let onRelease: (ControlAction) -> Void
    var onEditCommitted: () -> Void

    @State private var dpadDragStart: CGPoint?
    @State private var actionsDragStart: CGPoint?
    @State private var idle = false
    @State private var idleWorkItem: DispatchWorkItem?

    private let baseDPad: CGFloat = 190
    private let baseActions: CGFloat = 210
    private let coordinateSpace = "spark-player-space"

    var body: some View {
        GeometryReader { geo in
            ZStack {
                dpad(in: geo.size)
                actions(in: geo.size)
            }
            .coordinateSpace(name: coordinateSpace)
        }
        .onDisappear {
            idleWorkItem?.cancel()
        }
    }

    private var effectiveOpacity: Double {
        if isEditing { return max(config.opacity, 0.55) }
        if config.autoFade && idle { return min(config.opacity, 0.20) }
        return config.opacity
    }

    // MARK: D-Pad

    private func dpad(in size: CGSize) -> some View {
        let dimension = baseDPad * CGFloat(config.dpadScale)
        let center = CGPoint(
            x: size.width * CGFloat(config.dpadPoint.x),
            y: size.height * CGFloat(config.dpadPoint.y)
        )
        return ZStack {
            if isEditing {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(
                        Color.white.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
                    .frame(width: dimension + 18, height: dimension + 18)
            }

            DPadView(
                size: dimension,
                eightWay: config.eightWay,
                inputEnabled: !isEditing,
                onPress: handlePress,
                onRelease: handleRelease
            )

            if config.showShift {
                ShiftPillView(
                    width: dimension * 0.64,
                    inputEnabled: !isEditing,
                    onPress: handlePress,
                    onRelease: handleRelease
                )
                .offset(y: -(dimension / 2 + 20))
            }
        }
        .position(x: center.x, y: center.y)
        .opacity(effectiveOpacity)
        .gesture(editDrag(for: .dpad, in: size), including: isEditing ? .all : .none)
    }

    // MARK: Actions

    private func actions(in size: CGSize) -> some View {
        let dimension = baseActions * CGFloat(config.actionScale)
        return ZStack {
            if isEditing {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(
                        Color.white.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
                    .frame(width: dimension + 18, height: dimension + 18)
            }

            ActionClusterView(
                size: dimension,
                showCtrl: config.showCtrl,
                inputEnabled: !isEditing,
                onPress: handlePress,
                onRelease: handleRelease
            )
        }
        .position(
            x: size.width * CGFloat(config.actionsPoint.x),
            y: size.height * CGFloat(config.actionsPoint.y)
        )
        .opacity(effectiveOpacity)
        .gesture(editDrag(for: .actions, in: size), including: isEditing ? .all : .none)
    }

    // MARK: Drag to reposition

    private enum Cluster {
        case dpad
        case actions
    }

    private func editDrag(for cluster: Cluster, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
            .onChanged { value in
                guard isEditing else { return }
                let startLocation: CGPoint
                switch cluster {
                case .dpad:
                    if dpadDragStart == nil {
                        dpadDragStart = CGPoint(
                            x: size.width * CGFloat(config.dpadPoint.x),
                            y: size.height * CGFloat(config.dpadPoint.y)
                        )
                    }
                    startLocation = dpadDragStart ?? value.startLocation
                case .actions:
                    if actionsDragStart == nil {
                        actionsDragStart = CGPoint(
                            x: size.width * CGFloat(config.actionsPoint.x),
                            y: size.height * CGFloat(config.actionsPoint.y)
                        )
                    }
                    startLocation = actionsDragStart ?? value.startLocation
                }

                let offset = CGSize(
                    width: value.location.x - value.startLocation.x,
                    height: value.location.y - value.startLocation.y
                )
                let newX = (startLocation.x + offset.width) / max(size.width, 1)
                let newY = (startLocation.y + offset.height) / max(size.height, 1)

                switch cluster {
                case .dpad:
                    config.dpadX = min(max(Double(newX), 0.08), 0.92)
                    config.dpadY = min(max(Double(newY), 0.10), 0.92)
                case .actions:
                    config.actionsX = min(max(Double(newX), 0.08), 0.92)
                    config.actionsY = min(max(Double(newY), 0.10), 0.92)
                }
            }
            .onEnded { _ in
                guard isEditing else { return }
                dpadDragStart = nil
                actionsDragStart = nil
                onEditCommitted()
            }
    }

    // MARK: Input plumbing

    private func handlePress(_ action: ControlAction) {
        markActive()
        onPress(action)
    }

    private func handleRelease(_ action: ControlAction) {
        markActive()
        onRelease(action)
    }

    private func markActive() {
        if idle { idle = false }
        idleWorkItem?.cancel()
        let item = DispatchWorkItem {
            if config.autoFade {
                withAnimation(.easeOut(duration: 0.4)) {
                    idle = true
                }
            }
        }
        idleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: item)
    }
}
