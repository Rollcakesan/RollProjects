import SwiftUI

struct EditorWorkspaceView: View {
    @EnvironmentObject private var workspace: WorkspaceModel

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
    @EnvironmentObject private var workspace: WorkspaceModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(workspace.documents) { document in
                    EditorTab(
                        document: document,
                        isActive: workspace.activeDocumentID == document.id,
                        select: { workspace.activeDocumentID = document.id },
                        close: { workspace.closeDocument(document) }
                    )
                }
            }
        }
        .frame(height: 34)
        .background(RollCodeTheme.windowBackground)
    }
}

private struct EditorTab: View {
    @ObservedObject var document: EditorDocument
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: document.language == .swift ? "swift" : "doc.text")
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
    }
}

private struct EditorDocumentView: View {
    @ObservedObject var document: EditorDocument
    @State private var searchTerm = ""
    @State private var showsSearch = false

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
                    Button { showsSearch = false; searchTerm = "" } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RollCodeTheme.secondaryText)
                }
                .padding(.horizontal, 10)
                .frame(height: 37)
                .background(RollCodeTheme.elevatedBackground)
            }

            CodeEditorView(text: $document.text, language: document.language, searchTerm: searchTerm)
        }
        .background {
            Button("") { showsSearch = true }
                .keyboardShortcut("f", modifiers: .command)
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .opacity(0)
        }
    }

    private var matchDescription: String {
        guard !searchTerm.isEmpty else { return "" }
        let count = document.text.lowercased().components(separatedBy: searchTerm.lowercased()).count - 1
        return count == 1 ? "1 match" : "\(count) matches"
    }
}

private struct EmptyEditorView: View {
    @EnvironmentObject private var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(RollCodeTheme.secondaryText.opacity(0.55))
            Text("A quiet place to write code")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(RollCodeTheme.primaryText)
            Text("Open a file from the project tree or create a new one.")
                .font(.system(size: 12))
                .foregroundStyle(RollCodeTheme.secondaryText)
            HStack(spacing: 8) {
                Button("Open Folder") { workspace.chooseFolder() }
                Button("New File") { workspace.createFile() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
