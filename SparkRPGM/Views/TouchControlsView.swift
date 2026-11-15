import SwiftUI
import UIKit

// MARK: - Sculpted Cross D-Pad

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
                .fill(Color.black.opacity(0.38))

            CrossShape()
                .stroke(Color.white.opacity(0.20), lineWidth: 1)

            ForEach(directions) { direction in
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(active.contains(direction) ? 0.28 : 0.001))
                    .frame(width: thickness - 2, height: thickness - 2)
                    .offset(segmentOffset(for: direction))
            }

            ForEach(directions) { direction in
                Image(systemName: chevron(for: direction))
                    .font(.system(size: size * 0.14, weight: .bold))
                    .foregroundColor(Color.white.opacity(active.contains(direction) ? 1.0 : 0.45))
                    .offset(labelOffset(for: direction))
            }

            Circle()
                .fill(Color.black.opacity(0.55))
                .frame(width: size * 0.16, height: size * 0.16)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        .frame(width: size * 0.16, height: size * 0.16)
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

// MARK: - Sleek Floating Virtual Button

struct FloatingButtonView: View {

    let button: VirtualButtonID
    let scale: CGFloat
    let inputEnabled: Bool
    let onPress: (ControlAction) -> Void
    let onRelease: (ControlAction) -> Void

    @State private var pressed = false

    private var isPill: Bool { button.isPill }

    private var pillWidth: CGFloat {
        if button == .space { return 84 * scale }
        if button == .shift || button == .ctrl { return 64 * scale }
        return 58 * scale
    }

    private var pillHeight: CGFloat { 32 * scale }

    private var circleDiameter: CGFloat {
        button.isPrimary ? (64 * scale) : (54 * scale)
    }

    var body: some View {
        Group {
            if isPill {
                pillBody
            } else {
                circleBody
            }
        }
        .scaleEffect(pressed ? 0.93 : 1.0)
        .animation(.easeOut(duration: 0.08), value: pressed)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard inputEnabled, !pressed else { return }
                    pressed = true
                    onPress(button.action)
                }
                .onEnded { _ in
                    release()
                },
            including: inputEnabled ? .all : .none
        )
        .onDisappear(perform: release)
        .accessibilityLabel(button.label)
    }

    private var pillBody: some View {
        Text(button.label)
            .font(.system(size: 11 * scale, weight: .bold, design: .rounded))
            .foregroundColor(Color.white.opacity(pressed ? 1.0 : 0.90))
            .frame(width: pillWidth, height: pillHeight)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(pressed ? 0.65 : 0.38))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(pressed ? 0.55 : 0.20), lineWidth: 1)
            )
            .contentShape(Capsule(style: .continuous))
    }

    private var circleBody: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(pressed ? 0.65 : (button.isPrimary ? 0.45 : 0.38)))

            Circle()
                .stroke(Color.white.opacity(pressed ? 0.55 : (button.isPrimary ? 0.30 : 0.20)), lineWidth: 1)

            Text(button.label)
                .font(.system(
                    size: button.label.count > 1 ? (14 * scale) : (20 * scale),
                    weight: .bold,
                    design: .rounded
                ))
                .foregroundColor(Color.white.opacity(pressed ? 1.0 : 0.92))
        }
        .frame(width: circleDiameter, height: circleDiameter)
        .contentShape(Circle())
    }

    private func release() {
        guard pressed else { return }
        pressed = false
        onRelease(button.action)
    }
}

// MARK: - Overlay Container

struct TouchControlsView: View {

    @Binding var config: ControlConfig
    let isEditing: Bool
    let onPress: (ControlAction) -> Void
    let onRelease: (ControlAction) -> Void
    var onEditCommitted: () -> Void

    @State private var dragStartPoints: [String: CGPoint] = [:]
    @State private var idle = false
    @State private var idleWorkItem: DispatchWorkItem?

    private let baseDPad: CGFloat = 190
    private let coordinateSpace = "spark-player-space"

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if !config.hideAllControls || isEditing {
                    dpad(in: geo.size)
                    buttons(in: geo.size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: coordinateSpace)
            // Empty space does not block touches so canvas receives native clicks/taps
            .allowsHitTesting(isEditing)
        }
        .onDisappear {
            idleWorkItem?.cancel()
        }
    }

    private var effectiveOpacity: Double {
        if isEditing { return max(config.opacity, 0.65) }
        if config.autoFade && idle { return min(config.opacity, 0.20) }
        return config.opacity
    }

    // MARK: - D-Pad Rendering

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
                        Color.white.opacity(0.40),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                    .frame(width: dimension + 16, height: dimension + 16)
            }

            DPadView(
                size: dimension,
                eightWay: config.eightWay,
                inputEnabled: !isEditing,
                onPress: handlePress,
                onRelease: handleRelease
            )
        }
        .position(x: center.x, y: center.y)
        .opacity(effectiveOpacity)
        .allowsHitTesting(true)
        .gesture(editDragForDPad(in: size), including: isEditing ? .all : .none)
    }

    // MARK: - Virtual Buttons Rendering

    private func buttons(in size: CGSize) -> some View {
        ForEach(VirtualButtonID.allCases) { btn in
            if config.isEnabled(btn) || isEditing {
                buttonView(btn, in: size)
            }
        }
    }

    private func buttonView(_ btn: VirtualButtonID, in size: CGSize) -> some View {
        let pos = config.position(for: btn)
        let center = CGPoint(x: size.width * CGFloat(pos.x), y: size.height * CGFloat(pos.y))
        let isEnabled = config.isEnabled(btn)

        return ZStack {
            if isEditing {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isEnabled ? Color.white.opacity(0.40) : Color.red.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])
                    )
                    .frame(
                        width: (btn.isPill ? 72 : 62) * CGFloat(config.buttonScale) + 10,
                        height: (btn.isPill ? 36 : 62) * CGFloat(config.buttonScale) + 10
                    )
            }

            FloatingButtonView(
                button: btn,
                scale: CGFloat(config.buttonScale),
                inputEnabled: !isEditing && isEnabled,
                onPress: handlePress,
                onRelease: handleRelease
            )
        }
        .position(x: center.x, y: center.y)
        .opacity(isEnabled ? effectiveOpacity : (isEditing ? 0.35 : 0))
        .allowsHitTesting(true)
        .gesture(editDragForButton(btn, in: size), including: isEditing ? .all : .none)
    }

    // MARK: - Drag to Reposition

    private func editDragForDPad(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
            .onChanged { value in
                guard isEditing else { return }
                if dragStartPoints["dpad"] == nil {
                    dragStartPoints["dpad"] = CGPoint(
                        x: size.width * CGFloat(config.dpadPoint.x),
                        y: size.height * CGFloat(config.dpadPoint.y)
                    )
                }
                let start = dragStartPoints["dpad"] ?? value.startLocation
                let offset = CGSize(
                    width: value.location.x - value.startLocation.x,
                    height: value.location.y - value.startLocation.y
                )
                let newX = Double((start.x + offset.width) / max(size.width, 1))
                let newY = Double((start.y + offset.height) / max(size.height, 1))

                config.dpadX = min(max(newX, 0.06), 0.94)
                config.dpadY = min(max(newY, 0.08), 0.92)
            }
            .onEnded { _ in
                guard isEditing else { return }
                dragStartPoints.removeValue(forKey: "dpad")
                onEditCommitted()
            }
    }

    private func editDragForButton(_ btn: VirtualButtonID, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
            .onChanged { value in
                guard isEditing else { return }
                let key = btn.rawValue
                if dragStartPoints[key] == nil {
                    let p = config.position(for: btn)
                    dragStartPoints[key] = CGPoint(x: size.width * CGFloat(p.x), y: size.height * CGFloat(p.y))
                }
                let start = dragStartPoints[key] ?? value.startLocation
                let offset = CGSize(
                    width: value.location.x - value.startLocation.x,
                    height: value.location.y - value.startLocation.y
                )
                let newX = Double((start.x + offset.width) / max(size.width, 1))
                let newY = Double((start.y + offset.height) / max(size.height, 1))

                config.setPosition(for: btn, x: newX, y: newY)
            }
            .onEnded { _ in
                guard isEditing else { return }
                dragStartPoints.removeValue(forKey: btn.rawValue)
                onEditCommitted()
            }
    }

    // MARK: - Input Plumbing

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
