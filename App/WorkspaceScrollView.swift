import SwiftUI

#if os(macOS)
import AppKit
#endif

struct WorkspaceScrollView<Content: View>: View {
    private let axes: Axis.Set
    private let content: Content
    #if os(macOS)
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    #endif

    init(_ axes: Axis.Set = .vertical, @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.content = content()
    }

    var body: some View {
        ScrollView(axes) {
            content
                #if os(macOS)
                .background(alignment: .topLeading) {
                    ScrollbarStyleView(opacity: contrast == .increased || reduceTransparency ? 1 : 0.86)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
                #endif
        }
    }
}

#if os(macOS)
private struct ScrollbarStyleView: NSViewRepresentable {
    let opacity: CGFloat

    func makeNSView(context: Context) -> ScrollContentMarker {
        let view = ScrollContentMarker()
        view.opacity = opacity
        return view
    }

    func updateNSView(_ view: ScrollContentMarker, context: Context) {
        guard view.opacity != opacity else { return }
        view.opacity = opacity
        view.applyStyle()
    }

    final class ScrollContentMarker: NSView {
        var opacity: CGFloat = 1

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // Let SwiftUI finish mounting the native clip and document views.
            DispatchQueue.main.async { [weak self] in
                self?.applyStyle()
            }
        }

        func applyStyle() {
            guard let scrollView = enclosingScrollView else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.horizontalScroller?.alphaValue = opacity
            scrollView.verticalScroller?.alphaValue = opacity
        }
    }
}
#endif
