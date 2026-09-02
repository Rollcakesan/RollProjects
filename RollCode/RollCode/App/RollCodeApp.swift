import AppKit
import SwiftUI

@main
struct RollCodeApp: App {
    @State private var workspace = WorkspaceModel()
    @State private var terminal = TerminalSession()
    @State private var agent = AgentSession()
    @NSApplicationDelegateAdaptor private var appDelegate: RollCodeAppDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(workspace)
                .environment(terminal)
                .environment(agent)
                .preferredColorScheme(.dark)
                .onAppear {
                    appDelegate.workspace = workspace
                    workspace.onWorkspaceChanged = { url in
                        terminal.start(in: url)
                        agent.newThread()
                    }
                    agent.onRunCompleted = {
                        workspace.refreshTree()
                        workspace.checkForExternalChanges()
                    }
                }
                .frame(minWidth: agent.isVisible ? 1080 : 860, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { workspace.chooseFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("New File…") { workspace.createFile() }
                    .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { workspace.saveActiveDocument() }
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(workspace.activeDocument == nil)
                Button("Save As…") { workspace.saveActiveDocumentAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(workspace.activeDocument == nil)
            }
            CommandMenu("View") {
                Button(terminal.isVisible ? "Hide Terminal" : "Show Terminal") {
                    terminal.isVisible.toggle()
                }
                .keyboardShortcut("j", modifiers: [.command])
                Button(agent.isVisible ? "Hide Agent" : "Show Agent") {
                    agent.isVisible.toggle()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            CommandMenu("Navigate") {
                Button("Quick Open…") { workspace.presentQuickOpen() }
                    .keyboardShortcut("p", modifiers: [.command])
                Divider()
                Button("Close Editor") { workspace.closeActiveDocument() }
                    .keyboardShortcut("w", modifiers: [.command])
                    .disabled(workspace.activeDocument == nil)
            }
            CommandMenu("Editor") {
                Picker(
                    "Tab Width",
                    selection: Binding(
                        get: { workspace.tabWidth },
                        set: { workspace.setTabWidth($0) }
                    )
                ) {
                    Text("2 Spaces").tag(2)
                    Text("4 Spaces").tag(4)
                    Text("8 Spaces").tag(8)
                }
            }
        }
    }
}
@MainActor
final class RollCodeAppDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: WorkspaceModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace, workspace.hasUnsavedDocuments else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "You have unsaved changes."
        alert.informativeText = "Save all edited files before quitting RollCode?"
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return workspace.saveAllDocuments() ? .terminateNow : .terminateCancel
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
