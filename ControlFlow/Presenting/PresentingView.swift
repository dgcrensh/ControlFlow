import ControlFlowCore
import SwiftUI

/// Presentation mode on the iPad: the viewport full-screen, or the presenter view while
/// an external display shows the presentation.
struct PresentingView: View {
    let controller: PresentationController
    private var hub: PresentationHub { .shared }

    var body: some View {
        Group {
            if hub.hasExternalDisplay {
                PresenterView(controller: controller)
            } else {
                PresentationCanvas(controller: controller)
                    .ignoresSafeArea()
                    .accessibilityLabel("Presentation, \(controller.counter)")
                    .accessibilityHint("Tap the right half to advance and the left half to go back. Pinch in to exit.")
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}

/// The iPad's view while an external display shows the presentation: the current state,
/// the next sequence's end state, a counter, and large Back and Advance targets.
private struct PresenterView: View {
    let controller: PresentationController

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text(controller.counter)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Spacer()
                Button("End Presentation", systemImage: "xmark.circle.fill") { controller.perform(.exit) }
                    .font(.title3)
            }
            HStack(alignment: .top, spacing: 24) {
                panel("Now") {
                    PresentationCanvas(controller: controller)
                }
                .frame(maxWidth: .infinity)
                panel(controller.nextTitle.map { "Next: \($0)" } ?? "End of presentation") {
                    if let image = controller.nextImage {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        Color.black
                    }
                }
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: 20) {
                target("Back", systemImage: "chevron.left", action: .back)
                target("Advance", systemImage: "chevron.right", action: .advance)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(24)
        .foregroundStyle(.white)
    }

    /// A titled picture of the viewport.
    private func panel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            content()
                .aspectRatio(CGFloat(controller.viewport.width / max(controller.viewport.height, 1)), contentMode: .fit)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.25)))
        }
    }

    private func target(_ title: String, systemImage: String, action: PresentationAction) -> some View {
        Button { controller.perform(action) } label: {
            Label(title, systemImage: systemImage)
                .font(.title.weight(.semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// What an external display shows: the presentation being given, filling the screen
/// and letterboxed, or black while there is none.
struct ExternalDisplayView: View {
    private var hub: PresentationHub { .shared }

    var body: some View {
        ZStack {
            Color.black
            if let controller = hub.active {
                PresentationCanvas(controller: controller, takesInput: false)
                    .id(ObjectIdentifier(controller))
            }
        }
        .ignoresSafeArea()
        .persistentSystemOverlays(.hidden)
    }
}
