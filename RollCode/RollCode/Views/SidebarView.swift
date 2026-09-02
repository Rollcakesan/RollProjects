import SwiftUI

struct SidebarView: View {
    @Environment(WorkspaceModel.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            HStack {
                Text("PROJECT")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(RollCodeTheme.secondaryText)
                Spacer()
                if workspace.isLoadingTree {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)

            SearchField(text: $workspace.fileFilter, prompt: "Filter files")
                .padding(.horizontal, 9)
                .padding(.bottom, 8)

            Divider().overlay(RollCodeTheme.divider)

            Group {
                if let root = workspace.rootNode {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            if workspace.fileFilter.isEmpty {
                                ForEach(root.children ?? []) { node in
                                    FileTreeItem(node: node, depth: 0)
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
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(RollCodeTheme.secondaryText)
                        Text("Open a folder to begin")
                            .font(.system(size: 12))
                            .foregroundStyle(RollCodeTheme.secondaryText)
                        Button("Open Folder") { workspace.chooseFolder() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(RollCodeTheme.sidebarBackground)
    }
}

private struct FileTreeItem: View {
    @Environment(WorkspaceModel.self) private var workspace
    let node: FileNode
    let depth: Int
    @State private var isExpanded = false

    var body: some View {
        if node.isDirectory {
            VStack(alignment: .leading, spacing: 1) {
                Button {
                    isExpanded.toggle()
                } label: {
                    FileRowLabel(
                        node: node,
                        depth: depth,
                        disclosureIcon: isExpanded ? "chevron.down" : "chevron.right"
                    )
                }
                .buttonStyle(.plain)
                .contextMenu { FileContextMenu(node: node) }

                if isExpanded {
                    ForEach(node.children ?? []) { child in
                        FileTreeItem(node: child, depth: depth + 1)
                    }
                }
            }
        } else {
            Button { workspace.openFile(node.url) } label: {
                FileRowLabel(node: node, depth: depth, disclosureIcon: nil)
            }
            .buttonStyle(.plain)
            .contextMenu { FileContextMenu(node: node) }
        }
    }
}

private struct FileRowLabel: View {
    let node: FileNode
    let depth: Int
    let disclosureIcon: String?

    var body: some View {
        HStack(spacing: 5) {
            if let disclosureIcon {
                Image(systemName: disclosureIcon)
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 10)
                    .foregroundStyle(RollCodeTheme.secondaryText)
            } else {
                Color.clear.frame(width: 10, height: 1)
            }

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
        .padding(.leading, CGFloat(depth) * 13)
        .padding(.horizontal, 5)
        .frame(height: 23)
        .contentShape(Rectangle())
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
        Button("Rename…") { workspace.requestRename(node.url) }
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
