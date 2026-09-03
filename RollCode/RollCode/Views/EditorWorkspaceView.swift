import AppKit
import SwiftUI

struct EditorWorkspaceView: View {
    @Environment(WorkspaceModel.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            EditorTabBar()
            Divider().overlay(RollCodeTheme.divider)

            if let document = workspace.activeDocument {
                EditorDocumentView(document: document)
                    .id(document.id)
            } else {
                EmptyEditorView()
            }
        }
        .background(RollCodeTheme.editorBackground)
    }
}

private struct EditorTabBar: View {
    @Environment(WorkspaceModel.self) private var workspace
    @State private var draggedDocumentID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(workspace.documents.enumerated()), id: \.element.id) { index, document in
                    EditorTab(
                        document: document,
                        isActive: workspace.activeDocumentID == document.id,
                        select: { workspace.activeDocumentID = document.id },
                        close: { workspace.closeDocument(document) },
                        closeOthers: { workspace.closeOtherDocuments(except: document) },
                        closeRight: { workspace.closeDocumentsToTheRight(of: document) },
                        save: { workspace.save(document) }
                    )
                    .onDrag {
                        draggedDocumentID = document.id
                        return NSItemProvider(object: document.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: TabDropDelegate(
                        destinationIndex: index,
                        documents: workspace.documents,
                        draggedID: $draggedDocumentID,
                        moveAction: { from, to in
                            workspace.moveDocument(from: from, to: to)
                        }
                    ))
                }
            }
        }
        .frame(height: 34)
        .background(RollCodeTheme.windowBackground)
    }
}

private struct TabDropDelegate: DropDelegate {
    let destinationIndex: Int
    let documents: [EditorDocument]
    @Binding var draggedID: UUID?
    let moveAction: (Int, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedID,
              let sourceIndex = documents.firstIndex(where: { $0.id == draggedID }),
              sourceIndex != destinationIndex else { return }
        moveAction(sourceIndex, destinationIndex)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }
}

private struct EditorTab: View {
    let document: EditorDocument
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void
    let closeOthers: () -> Void
    let closeRight: () -> Void
    let save: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: document.language.systemImageName)
                .font(.system(size: 10))
                .foregroundStyle(isActive ? RollCodeTheme.accent : RollCodeTheme.secondaryText)
            Text(document.name)
                .font(.system(size: 11, weight: isActive ? .medium : .regular))
                .lineLimit(1)
            if document.isDirty {
                Circle()
                    .fill(RollCodeTheme.accent)
                    .frame(width: 6, height: 6)
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(RollCodeTheme.secondaryText)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(isActive ? RollCodeTheme.editorBackground : RollCodeTheme.windowBackground)
        .overlay(alignment: .bottom) {
            if isActive { RollCodeTheme.accent.frame(height: 1) }
        }
        .overlay(alignment: .trailing) { RollCodeTheme.divider.frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .contextMenu {
            Button("Close") { close() }
            Button("Close Others") { closeOthers() }
            Button("Close to the Right") { closeRight() }
            Divider()
            Button("Save") { save() }
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([document.url])
            }
        }
    }
}

private struct EditorDocumentView: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Bindable var document: EditorDocument
    @State private var searchTerm = ""
    @State private var showsSearch = false
    @State private var searchRequest: EditorSearchRequest?
    @State private var showsGoToLine = false
    @State private var targetLine = ""
    @FocusState private var goToLineFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showsSearch {
                HStack(spacing: 8) {
                    SearchField(text: $searchTerm, prompt: "Find in file")
                        .frame(width: 230)
                    Text(matchDescription)
                        .font(.system(size: 10))
                        .foregroundStyle(RollCodeTheme.secondaryText)
                    Spacer()
                    Button { find(.previous) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.plain)
                    .help("Previous Match")
                    Button { find(.next) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .help("Next Match")
                    Button { showsSearch = false; searchTerm = "" } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RollCodeTheme.secondaryText)
                }
                .padding(.horizontal, 10)
                .frame(height: 37)
                .background(RollCodeTheme.elevatedBackground)
            } else if showsGoToLine {
                HStack(spacing: 8) {
                    Text("Go to line:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RollCodeTheme.secondaryText)
                    TextField("1..\(document.lineCount)", text: $targetLine)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .frame(width: 80, height: 24)
                        .padding(.horizontal, 6)
                        .background(RollCodeTheme.windowBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(RollCodeTheme.divider))
                        .focused($goToLineFocused)
                        .onSubmit(performGoToLine)
                    Button("Go") { performGoToLine() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Spacer()
                    Button { showsGoToLine = false; targetLine = "" } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RollCodeTheme.secondaryText)
                }
                .padding(.horizontal, 10)
                .frame(height: 37)
                .background(RollCodeTheme.elevatedBackground)
                .onAppear { goToLineFocused = true }
            }

            if document.language == .markdown {
                HStack {
                    Spacer()
                    Button {
                        document.isPreviewMode.toggle()
                    } label: {
                        Label(
                            document.isPreviewMode ? "Source" : "Preview",
                            systemImage: document.isPreviewMode ? "doc.plaintext" : "eye"
                        )
                        .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RollCodeTheme.windowBackground)
            }

            if document.isPreviewMode && document.language == .markdown {
                MarkdownPreviewView(text: document.text)
            } else {
                CodeEditorView(
                    text: $document.text,
                    language: document.language,
                    searchTerm: searchTerm,
                    searchRequest: searchRequest,
                    navigationRequest: workspace.editorNavigationRequest,
                    errorLines: Set(document.diagnostics.map(\.line)),
                    gitAddedLines: document.gitAddedLines,
                    gitModifiedLines: document.gitModifiedLines,
                    documentURL: document.url,
                    workspaceURL: workspace.rootURL,
                    tabWidth: workspace.tabWidth,
                    fontSize: workspace.fontSize
                )
            }
        }
        .background {
            Group {
                Button("") { showsSearch = true; showsGoToLine = false }
                    .keyboardShortcut("f", modifiers: .command)
                Button("") { showsGoToLine = true; showsSearch = false }
                    .keyboardShortcut("l", modifiers: .command)
            }
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)
        }
    }

    private var matchDescription: String {
        guard !searchTerm.isEmpty,
              let regex = try? Regex(NSRegularExpression.escapedPattern(for: searchTerm)).ignoresCase() else { return "" }
        let count = document.text.matches(of: regex).count
        return count == 1 ? "1 match" : "\(count) matches"
    }

    private func find(_ direction: EditorSearchRequest.Direction) {
        guard !searchTerm.isEmpty else { return }
        searchRequest = EditorSearchRequest(direction: direction)
    }

    private func performGoToLine() {
        guard let line = Int(targetLine.trimmed), line > 0 else { return }
        workspace.editorNavigationRequest = EditorNavigationRequest(line: line)
        showsGoToLine = false
        targetLine = ""
    }
}

private struct MarkdownPreviewView: View {
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let attributed = try? AttributedString(
                    markdown: text,
                    options: .init(interpretedSyntax: .full)
                ) {
                    Text(attributed)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RollCodeTheme.editorBackground)
    }
}

private struct EmptyEditorView: View {
    @Environment(WorkspaceModel.self) private var workspace

    var body: some View {
        EmptyStateView(
            systemImage: "chevron.left.forwardslash.chevron.right",
            title: "A quiet place to write code",
            message: "Open a file from the project tree or create a new one.",
            imageSize: 40
        ) {
            HStack(spacing: 8) {
                Button("Open Folder") { workspace.chooseFolder() }
                Button("New File") { workspace.createFile() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
