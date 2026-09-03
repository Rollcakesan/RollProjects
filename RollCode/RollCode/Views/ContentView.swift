import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(TerminalSession.self) private var terminal
    @Environment(AgentSession.self) private var agent
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            HSplitView {
                SidebarView()
                    .frame(minWidth: 180, idealWidth: 230, maxWidth: 360)

                VSplitView {
                    EditorWorkspaceView()
                        .frame(minHeight: 260)

                    if terminal.isVisible {
                        TerminalView()
                            .frame(minHeight: 120, idealHeight: 210, maxHeight: 420)
                    }
                }
                .frame(minWidth: 520)

                if agent.isVisible {
                    AgentPanelView()
                        .frame(minWidth: 320, idealWidth: 525, maxWidth: 900)
                }
            }

            StatusBarView()
        }
        .background(RollCodeTheme.editorBackground)
        .toolbar {
            WorkspaceToolbarContent()
        }
        .alert("RollCode", isPresented: alertBinding) {
            Button("OK", role: .cancel) { workspace.alertMessage = nil }
        } message: {
            Text(workspace.alertMessage ?? "")
        }
        .alert("Rename", isPresented: renameBinding) {
            TextField("New name", text: $workspace.renamingName)
            Button("Rename") { workspace.confirmRename() }
            Button("Cancel", role: .cancel) { workspace.cancelRename() }
        } message: {
            Text("Enter a new name for \(workspace.renamingURL?.lastPathComponent ?? "this item").")
        }
        .alert(workspace.creatingItemIsDirectory ? "New Folder" : "New File", isPresented: createBinding) {
            TextField("Name", text: $workspace.creatingItemName)
            Button("Create") { workspace.confirmCreateItem() }
            Button("Cancel", role: .cancel) { workspace.cancelCreateItem() }
        } message: {
            Text("Enter a name for the new \(workspace.creatingItemIsDirectory ? "folder" : "file").")
        }
        .sheet(isPresented: $workspace.isQuickOpenPresented) {
            QuickOpenView(isPresented: $workspace.isQuickOpenPresented)
        }
        .sheet(isPresented: $workspace.isWorkspaceSearchPresented) {
            WorkspaceSearchView(isPresented: $workspace.isWorkspaceSearchPresented)
        }
        .sheet(isPresented: $workspace.isGitChangesPresented) {
            GitChangesView(isPresented: $workspace.isGitChangesPresented)
        }
        .confirmationDialog(
            "Save changes to \(workspace.unconfirmedClosingDocument?.name ?? "file")?",
            isPresented: confirmCloseBinding,
            titleVisibility: .visible
        ) {
            Button("Save") { workspace.confirmCloseDocument(save: true) }
            Button("Don't Save", role: .destructive) { workspace.confirmCloseDocument(save: false) }
            Button("Cancel", role: .cancel) { workspace.cancelCloseDocument() }
        } message: {
            Text("Your changes will be lost if you close this tab without saving.")
        }
        .confirmationDialog(
            "Move \(workspace.deletingURL?.lastPathComponent ?? "item") to Trash?",
            isPresented: deleteBinding,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { workspace.confirmDeleteItem() }
            Button("Cancel", role: .cancel) { workspace.cancelDeleteItem() }
        } message: {
            Text("The item can be recovered from Trash.")
        }
        .confirmationDialog(
            "\(workspace.externalConflict?.documentName ?? "File") changed on disk.",
            isPresented: externalConflictBinding,
            titleVisibility: .visible
        ) {
            Button("Reload from Disk") { workspace.resolveExternalConflict(reload: true) }
            Button("Keep Editor Version", role: .cancel) { workspace.resolveExternalConflict(reload: false) }
        } message: {
            Text("Reload the file or keep the changes currently open in RollCode?")
        }
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

    private var confirmCloseBinding: Binding<Bool> {
        Binding(
            get: { workspace.unconfirmedClosingDocument != nil },
            set: { if !$0 { workspace.cancelCloseDocument() } }
        )
    }

    private var externalConflictBinding: Binding<Bool> {
        Binding(
            get: { workspace.externalConflict != nil },
            set: { if !$0 { workspace.resolveExternalConflict(reload: false) } }
        )
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { workspace.deletingURL != nil },
            set: { if !$0 { workspace.cancelDeleteItem() } }
        )
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { workspace.alertMessage != nil },
            set: { if !$0 { workspace.alertMessage = nil } }
        )
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { workspace.renamingURL != nil },
            set: { if !$0 { workspace.cancelRename() } }
        )
    }

    private var createBinding: Binding<Bool> {
        Binding(
            get: { workspace.creatingItemParentURL != nil },
            set: { if !$0 { workspace.cancelCreateItem() } }
        )
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
    static let editorFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
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
