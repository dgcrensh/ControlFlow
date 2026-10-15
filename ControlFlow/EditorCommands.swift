import ControlFlowCore
import SwiftUI

extension FocusedValues {
    /// The canvas of the document in front, for keyboard shortcuts.
    @Entry var canvasStore: CanvasStore?
}

/// Keyboard shortcuts for a hardware keyboard. Hold Command to see them listed.
struct EditorCommands: Commands {
    @FocusedValue(\.canvasStore) private var store

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { store?.undo() }
                .keyboardShortcut("z")
                .disabled(store == nil)
            Button("Redo") { store?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(store == nil)
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { store?.cut() }
                .keyboardShortcut("x")
            Button("Copy") { store?.copy() }
                .keyboardShortcut("c")
            Button("Paste") { store?.paste() }
                .keyboardShortcut("v")
            Button("Duplicate") { store?.duplicate() }
                .keyboardShortcut("d")
            Button("Duplicate Mirrored") { store?.duplicateMirrored() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Delete") { store?.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [])
        }
        CommandMenu("Select") {
            Button("Select Layer") { store?.selectParent() }
                .keyboardShortcut(.upArrow)
            Button("Select All in Layer") { store?.selectAllInLayer() }
                .keyboardShortcut("a")
            Button("Invert Selection") { store?.invertSelection() }
            Divider()
            Button("Same Fill") { store?.selectSameFill() }
            Button("Same Outline") { store?.selectSameOutline() }
        }
        CommandMenu("Arrange") {
            Button("Bring to Front") { store?.arrange(.bringToFront) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Bring Forward") { store?.arrange(.bringForward) }
                .keyboardShortcut("]")
            Button("Send Backward") { store?.arrange(.sendBackward) }
                .keyboardShortcut("[")
            Button("Send to Back") { store?.arrange(.sendToBack) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            Button("Hide") { store?.hideSelection() }
                .keyboardShortcut("3")
            Button("Show All") { store?.showAll() }
                .keyboardShortcut("3", modifiers: [.command, .option])
            Button("Lock") { store?.lockSelection() }
                .keyboardShortcut("2")
            Button("Unlock All") { store?.unlockAll() }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Divider()
            Button("Group") { store?.groupSelection() }
                .keyboardShortcut("g")
            Button("Ungroup") { store?.ungroupSelection() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("Isolate Layer") { store?.isolateSelection() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Exit Isolation") { store?.stepOutOfIsolation() }
                .keyboardShortcut(.escape, modifiers: [])
            Divider()
            Button("Nudge Left") { store?.nudge(-1, 0) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Nudge Right") { store?.nudge(1, 0) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Nudge Up") { store?.nudge(0, -1) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("Nudge Down") { store?.nudge(0, 1) }
                .keyboardShortcut(.downArrow, modifiers: [])
        }
        CommandGroup(after: .toolbar) {
            Button("Outline View") { if let store { store.setOutlineView(!store.ui.outlineView) } }
                .keyboardShortcut("y")
            Button("Ghost Unselected") { if let store { store.setGhostsUnselected(!store.ui.ghostsUnselected) } }
                .keyboardShortcut("g", modifiers: [.command, .option])
            Button("Zoom to Fit") { store?.zoomToFit() }
                .keyboardShortcut("0")
        }
        CommandMenu("Tools") {
            tool(.select, "Select", key: "v")
            tool(.directSelect, "Direct Select", key: "a")
            tool(.pen, "Pen", key: "p")
            tool(.pencil, "Pencil", key: "n")
            tool(.shape, "Shapes", key: "m")
            tool(.eraser, "Eraser", key: "e")
            tool(.scissors, "Scissors", key: "c")
        }
    }

    private func tool(_ tool: Tool, _ title: String, key: KeyEquivalent) -> some View {
        Button(title) { store?.setTool(tool) }
            .keyboardShortcut(key, modifiers: [])
    }
}
