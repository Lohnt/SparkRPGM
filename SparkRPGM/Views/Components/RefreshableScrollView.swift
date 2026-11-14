import SwiftUI

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Pull-to-refresh for a `ScrollView`.
///
/// `.refreshable` only works on `List` on iOS 15, and `List` would fight the
/// full-bleed wallpaper. This is a small, predictable replacement.
struct RefreshableScrollView<Content: View>: View {

    var coordinateSpaceName: String = "spark-library-scroll"
    var threshold: CGFloat = 78
    let onRefresh: () -> Void
    @ViewBuilder var content: Content

    @State private var pull: CGFloat = 0
    @State private var isRefreshing = false
    @State private var workItem: DispatchWorkItem?

    var body: some View {
        ScrollView {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ScrollOffsetKey.self,
                    value: proxy.frame(in: .named(coordinateSpaceName)).minY
                )
            }
            .frame(height: 0)

            content
        }
        .coordinateSpace(name: coordinateSpaceName)
        .onPreferenceChange(ScrollOffsetKey.self) { value in
            pull = value
            if value > threshold, !isRefreshing {
                trigger()
            }
        }
        .overlay(
            VStack(spacing: 6) {
                if isRefreshing {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    Text("Scanning games…")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                } else {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(pull > 20 ? 0.8 : 0.0))
                        .rotationEffect(.degrees(pull > threshold ? 180 : 0))
                }
            }
            .padding(.top, 8)
            .animation(.easeOut(duration: 0.2)),
            alignment: .top
        )
    }

    private func trigger() {
        isRefreshing = true
        onRefresh()

        workItem?.cancel()
        let item = DispatchWorkItem {
            isRefreshing = false
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }
}
