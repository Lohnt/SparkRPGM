import SwiftUI
import UIKit

// MARK: - D-Pad

struct DPadView: View {

    let size: CGFloat
    let eightWay: Bool
    let inputEnabled: Bool
    let onPress: (ControlAction) -> Void
    let onRelease: (ControlAction) -> Void

    @State private var active: Set<ControlAction> = []

    private var directions: [ControlAction] { [.up, .down, .left, .right] }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.30))
                .overlay(Circle().fill(Color.white.opacity(0.02)))

            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
                .padding(1)

            // Crosshair guides
            Rectangle()
                .fill(Color.white.opacity(0.05))
                .frame(width: 1, height: size * 0.62)
            Rectangle()
                .fill(Color.white.opacity(0.05))
                .frame(width: size * 0.62, height: 1)

            ForEach(directions) { direction in
                Image(systemName: chevron(for: direction))
                    .font(.system(size: size * 0.15, weight: .bold))
                    .foregroundColor(Color.white.opacity(active.contains(direction) ? 0.95 : 0.45))
                    .offset(offset(for: direction))
            }

            Circle()
                .fill(Color.white.opacity(0.10))
                .frame(width: size * 0.16, height: size * 0.16)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        .frame(width: size * 0.16, height: size * 0.16)
                )
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
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

    private func offset(for direction: ControlAction) -> CGSize {
        let distance = size * 0.34
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

// MARK: - Action cluster

struct ActionClusterView: View {

    let size: CGFloat
    let showShift: Bool
    let showCtrl: Bool
    let inputEnabled: Bool
    let onPress: (ControlAction) -> Void
    let onRelease: (ControlAction) -> Void

    var body: some View {
        ZStack {
            button(.ok, label: "Z", diameter: size * 0.36, position: CGPoint(x: 0.68, y: 0.68), primary: true)
            button(.cancel, label: "X", diameter: size * 0.30, position: CGPoint(x: 0.24, y: 0.74), primary: false)

            if showShift {
                button(.shift, label: "⇧", diameter: size * 0.24, position: CGPoint(x: 0.54, y: 0.20), primary: false)
            }
            if showCtrl {
                button(.control, label: "⌃", diameter: size * 0.24, position: CGPoint(x: 0.13, y: 0.30), primary: false)
            }
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
                .fill(
                    LinearGradient(
                        colors: primary
                            ? [Color.white.opacity(0.30), Color.white.opacity(0.12)]
                            : [Color.white.opacity(0.16), Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .stroke(Color.white.opacity(pressed ? 0.55 : 0.22), lineWidth: pressed ? 2 : 1)
            Text(label)
                .font(.system(size: diameter * 0.36, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(pressed ? 0.92 : 1)
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
        }
        .position(
            x: size.width * CGFloat(config.dpadPoint.x),
            y: size.height * CGFloat(config.dpadPoint.y)
        )
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
                showShift: config.showShift,
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
