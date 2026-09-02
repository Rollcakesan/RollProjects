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
    let document: EditorDocument
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void

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
            }

            CodeEditorView(
                text: $document.text,
                language: document.language,
                searchTerm: searchTerm,
                searchRequest: searchRequest,
                navigationRequest: workspace.editorNavigationRequest,
                tabWidth: workspace.tabWidth
            )
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
        guard !searchTerm.isEmpty,
              let regex = try? Regex(NSRegularExpression.escapedPattern(for: searchTerm)).ignoresCase() else { return "" }
        let count = document.text.matches(of: regex).count
        return count == 1 ? "1 match" : "\(count) matches"
    }

    private func find(_ direction: EditorSearchRequest.Direction) {
        guard !searchTerm.isEmpty else { return }
        searchRequest = EditorSearchRequest(direction: direction)
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
