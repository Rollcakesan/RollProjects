import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if canImport(AIAgentKit)
import AIAgentKit
#endif

struct ContentView: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(TerminalSession.self) private var terminal
    @Environment(AgentSession.self) private var agent
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 230
    @AppStorage("agentPanelWidth") private var agentPanelWidth: Double = 400

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            HSplitView {
                SidebarView()
                    .frame(minWidth: 160, idealWidth: sidebarWidth, maxWidth: 420)

                VSplitView {
                    EditorWorkspaceView()
                        .frame(minHeight: 260)

                    if terminal.isVisible {
                        TerminalView()
                            .frame(minHeight: 120, idealHeight: 210, maxHeight: 420)
                    }
                }
                .frame(minWidth: 400)

                if agent.isVisible {
                    AgentPanelView()
                        .frame(minWidth: 300, idealWidth: agentPanelWidth, maxWidth: 950)
                }
            }

            StatusBarView()
        }
        .background(RollCodeTheme.editorBackground)
        .toolbar {
            WorkspaceToolbarContent()
        }
        .workspaceModals()
        .fileExporter(
            isPresented: $workspace.isSavingActiveDocumentAs,
            document: workspace.documentBeingSavedAs.map { TextDocumentFile(text: $0.text) },
            contentType: .plainText,
            defaultFilename: workspace.documentBeingSavedAs?.name ?? "Untitled"
        ) { result in
            switch result {
            case .success(let destination):
                workspace.completeSaveActiveDocumentAs(destination: destination)
            case .failure:
                workspace.cancelSaveActiveDocumentAs()
            }
        }
        .fileImporter(
            isPresented: $workspace.isFolderPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                workspace.openWorkspace(url)
            }
        }
        .onAppear {
            if !terminal.isRunning {
                terminal.start(in: workspace.rootURL ?? FileManager.default.homeDirectoryForCurrentUser)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                workspace.checkForExternalChanges()
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard NSApp.isActive else { continue }
                workspace.checkForExternalChanges()
            }
        }
    }
}

@MainActor
enum RollCodeTheme {
    // SwiftUI Colors
    static let windowBackground = Color(red: 0.075, green: 0.078, blue: 0.09)
    static let sidebarBackground = Color(red: 0.09, green: 0.094, blue: 0.108)
    static let editorBackground = Color(red: 0.115, green: 0.12, blue: 0.14)
    static let elevatedBackground = Color(red: 0.145, green: 0.15, blue: 0.175)
    static let selection = Color(red: 0.20, green: 0.27, blue: 0.40)
    static let accent = Color(red: 0.40, green: 0.61, blue: 0.98)
    static let primaryText = Color(white: 0.88)
    static let secondaryText = Color(white: 0.56)
    static let divider = Color.white.opacity(0.08)

    // AppKit NSColors
    static let nsEditorBackground = NSColor(red: 0.115, green: 0.12, blue: 0.14, alpha: 1)
    static let nsForeground = NSColor(white: 0.86, alpha: 1)
    static let nsCaret = NSColor(red: 0.40, green: 0.61, blue: 0.98, alpha: 1)
    static let nsSelection = NSColor(red: 0.20, green: 0.32, blue: 0.52, alpha: 1)
    static let nsSearchMatch = NSColor(red: 0.64, green: 0.43, blue: 0.12, alpha: 0.9)
    static let editorFont = NSFont.monospacedSystemFont(ofSize: 14.5, weight: .regular)
}

struct EmptyStateView<Actions: View>: View {
    let systemImage: String
    let title: String
    var message: String? = nil
    var imageSize: CGFloat = 28
    @ViewBuilder var actions: Actions

    init(
        systemImage: String,
        title: String,
        message: String? = nil,
        imageSize: CGFloat = 28,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.imageSize = imageSize
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: imageSize, weight: .light))
                .foregroundStyle(RollCodeTheme.secondaryText.opacity(0.75))
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(RollCodeTheme.primaryText)
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(RollCodeTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            actions
                .padding(.top, 2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PanelHeader<Leading: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    init(
        _ title: String,
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 7) {
            leading
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(RollCodeTheme.secondaryText)
            Spacer()
            trailing
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
    }
}

private struct TextDocumentFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .utf8PlainText, .sourceCode] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

extension View {
    func workspaceModals() -> some View {
        modifier(WorkspaceModalsModifier())
    }
}

private struct WorkspaceModalsModifier: ViewModifier {
    @Environment(WorkspaceModel.self) private var workspace

    func body(content: Content) -> some View {
        @Bindable var workspace = workspace
        content
            .alert("RollCode", isPresented: Binding(
                get: { workspace.alertMessage != nil },
                set: { if !$0 { workspace.alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) { workspace.alertMessage = nil }
            } message: {
                Text(workspace.alertMessage ?? "")
            }
            .alert("Rename", isPresented: Binding(
                get: { workspace.renamingURL != nil },
                set: { if !$0 { workspace.cancelRename() } }
            )) {
                TextField("New name", text: $workspace.renamingName)
                Button("Rename") { workspace.confirmRename() }
                Button("Cancel", role: .cancel) { workspace.cancelRename() }
            } message: {
                Text("Enter a new name for \(workspace.renamingURL?.lastPathComponent ?? "this item").")
            }
            .alert(workspace.creatingItemIsDirectory ? "New Folder" : "New File", isPresented: Binding(
                get: { workspace.creatingItemParentURL != nil },
                set: { if !$0 { workspace.cancelCreateItem() } }
            )) {
                TextField("Name", text: $workspace.creatingItemName)
                Button("Create") { workspace.confirmCreateItem() }
                Button("Cancel", role: .cancel) { workspace.cancelCreateItem() }
            } message: {
                Text("Enter a name for the new \(workspace.creatingItemIsDirectory ? "folder" : "file").")
            }
            .sheet(item: $workspace.activeSheet) { sheet in
                switch sheet {
                case .quickOpen: QuickOpenView()
                case .workspaceSearch: WorkspaceSearchView()
                case .gitChanges: GitChangesView()
                case .shortcutCheatSheet: ShortcutCheatSheetView()
                }
            }
    }
}
