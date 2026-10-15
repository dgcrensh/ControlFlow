import SwiftUI

/// Hosts the Metal canvas view in SwiftUI.
struct CanvasRepresentable: UIViewRepresentable {
    let store: CanvasStore

    func makeUIView(context: Context) -> MetalCanvasView {
        MetalCanvasView(store: store)
    }

    func updateUIView(_ view: MetalCanvasView, context: Context) {}
}
