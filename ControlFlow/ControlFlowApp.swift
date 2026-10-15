import SwiftUI

@main
struct ControlFlowApp: App {
    var body: some Scene {
        // Documents are `.controlflow` packages in the Files app. The document browser
        // creates, opens, renames and autosaves them.
        DocumentGroup(newDocument: PresentationDocument()) { file in
            ContentView(document: file.$document)
        }
        .commands { EditorCommands() }
    }
}
