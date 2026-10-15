import SwiftUI

@main
struct ControlFlowApp: App {
    var body: some Scene {
        // Documents are `.charstudio` packages in the Files app (until the presentation
        // format replaces it). The document browser creates, opens, renames and autosaves them.
        DocumentGroup(newDocument: CharacterDocument()) { file in
            ContentView(document: file.$document)
        }
        .commands { EditorCommands() }
    }
}
