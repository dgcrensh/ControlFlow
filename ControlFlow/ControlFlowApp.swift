import SwiftUI

@main
struct ControlFlowApp: App {
    /// Gives an external display its own scene for presenting.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Documents are `.controlflow` packages in the Files app. The document browser
        // creates, opens, renames and autosaves them.
        DocumentGroup(newDocument: PresentationDocument()) { file in
            ContentView(document: file.$document)
        }
        .commands { EditorCommands() }
    }
}
