import AppKit
import SwiftUI
#if canImport(AIAgentKit)
import AIAgentKit
#endif

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
                        agent.loadThreads(for: url)
                    }
                    if let rootURL = workspace.rootURL {
                        agent.loadThreads(for: rootURL)
                    }
                    agent.onRunCompleted = {
                        workspace.refreshTree()
                        workspace.checkForExternalChanges()
                    }
                }
                .frame(minWidth: agent.isVisible ? 1120 : 860, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified(showsTitle: false))

        Settings {
            SettingsView()
                .environment(workspace)
                .environment(terminal)
                .environment(agent)
                .preferredColorScheme(.dark)
        }
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
                Button("Zoom In") { workspace.zoomIn() }
                    .keyboardShortcut("+", modifiers: [.command])
                Button("Zoom Out") { workspace.zoomOut() }
                    .keyboardShortcut("-", modifiers: [.command])
                Button("Actual Size") { workspace.resetZoom() }
                    .keyboardShortcut("0", modifiers: [.command])
                Divider()
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
                Button("Search in Project…") { workspace.presentWorkspaceSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Git Changes…") { workspace.presentGitChanges() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button("Close Editor") { workspace.closeActiveDocument() }
                    .keyboardShortcut("w", modifiers: [.command])
                    .disabled(workspace.activeDocument == nil)
            }
            CommandMenu("Editor") {
                Button("Format & Check") { workspace.formatAndCheckActiveDocument() }
                    .keyboardShortcut("f", modifiers: [.option, .shift])
                    .disabled(workspace.activeDocument == nil || workspace.activeDocument?.isCheckingSyntax == true)
                Divider()
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
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    workspace.activeSheet = .shortcutCheatSheet
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])
            }
        }
    }
}
@MainActor
final class RollCodeAppDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: WorkspaceModel?

    func applicationWillTerminate(_ notification: Notification) {
        LSPManager.shared.stopAllServers()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace, workspace.hasUnsavedDocuments else { return .terminateNow }

        let response = NSAlert.confirm(
            title: "You have unsaved changes.",
            message: "Save all edited files before quitting RollCode?",
            buttons: ["Save All", "Cancel", "Discard Changes"]
        )

        switch response {
        case .alertFirstButtonReturn:
            return workspace.saveAllDocuments() ? .terminateNow : .terminateCancel
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

@MainActor
extension NSAlert {
    static func confirm(
        title: String,
        message: String,
        buttons: [String],
        accessoryView: NSView? = nil
    ) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = accessoryView
        for button in buttons {
            alert.addButton(withTitle: button)
        }
        return alert.runModal()
    }
}
