import SwiftUI

struct SidebarView: View {
    @Environment(WorkspaceModel.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            PanelHeader("PROJECT") {
                if workspace.isLoadingTree {
                    ProgressView().controlSize(.small)
                }
            }

            SearchField(text: $workspace.fileFilter, prompt: "Filter files")
                .padding(.horizontal, 9)
                .padding(.bottom, 8)

            Divider().overlay(RollCodeTheme.divider)

            Group {
                if let root = workspace.rootNode {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            if workspace.fileFilter.isEmpty {
                                OutlineGroup(root.children ?? [], children: \.children) { node in
                                    FileNodeRow(node: node)
                                }
                            } else {
                                ForEach(root.matchingFiles(workspace.fileFilter)) { node in
                                    FilteredFileRow(node: node, rootURL: root.url)
                                }
                            }
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 5)
                    }
                } else {
                    EmptyStateView(
                        systemImage: "folder.badge.plus",
                        title: "No folder open",
                        message: "Open a folder to begin."
                    ) {
                        Button("Open Folder") { workspace.chooseFolder() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
        .background(RollCodeTheme.sidebarBackground)
    }
}

private struct FileNodeRow: View {
    @Environment(WorkspaceModel.self) private var workspace
    let node: FileNode

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.iconName)
                .font(.system(size: 11))
                .foregroundStyle(node.isDirectory ? Color(red: 0.45, green: 0.64, blue: 0.95) : RollCodeTheme.secondaryText)
                .frame(width: 14)

            Text(node.name)
                .font(.system(size: 12))
                .foregroundStyle(RollCodeTheme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 23)
        .contentShape(Rectangle())
        .onTapGesture {
            if !node.isDirectory {
                workspace.openFile(node.url)
            }
        }
        .contextMenu { FileContextMenu(node: node) }
    }
}

private struct FilteredFileRow: View {
    @Environment(WorkspaceModel.self) private var workspace
    let node: FileNode
    let rootURL: URL

    var body: some View {
        Button { workspace.openFile(node.url) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.system(size: 12))
                    .foregroundStyle(RollCodeTheme.primaryText)
                Text(node.url.relativeParentPath(from: rootURL))
                    .font(.system(size: 10))
                    .foregroundStyle(RollCodeTheme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { FileContextMenu(node: node) }
    }
}

private struct FileContextMenu: View {
    @Environment(WorkspaceModel.self) private var workspace
    let node: FileNode

    var body: some View {
        let targetFolder = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        Button("New File…") { workspace.requestCreateFile(in: targetFolder) }
        Button("New Folder…") { workspace.requestCreateFolder(in: targetFolder) }
        Divider()
        Button("Rename…") { workspace.requestRename(node.url) }
        Button("Move to Trash", role: .destructive) { workspace.deleteItem(at: node.url) }
        Divider()
        Button("Show in Finder") { workspace.revealInFinder(node.url) }
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(RollCodeTheme.secondaryText)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(RollCodeTheme.secondaryText)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 25)
        .background(RollCodeTheme.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(RollCodeTheme.divider))
    }
}
