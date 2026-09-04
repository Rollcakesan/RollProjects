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
                        if workspace.fileFilter.isEmpty {
                            FileTreeList(nodes: root.children ?? [])
                                .padding(.vertical, 4)
                                .padding(.horizontal, 4)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(root.matchingFiles(workspace.fileFilter)) { node in
                                    FilteredFileRow(node: node, rootURL: root.url)
                                }
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 4)
                        }
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
        .background(.ultraThinMaterial)
    }
}

private struct FileTreeList: View {
    let nodes: [FileNode]
    @State private var expandedURLs: Set<URL> = []

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(nodes) { node in
                FileTreeNodeView(node: node, depth: 0, expandedURLs: $expandedURLs)
            }
        }
        .onAppear {
            for node in nodes where node.isDirectory {
                expandedURLs.insert(node.url)
            }
        }
    }
}

private struct FileTreeNodeView: View {
    @Environment(WorkspaceModel.self) private var workspace
    let node: FileNode
    let depth: Int
    @Binding var expandedURLs: Set<URL>
    @State private var isHovered = false

    var isExpanded: Bool { expandedURLs.contains(node.url) }
    var isSelected: Bool { workspace.activeDocument?.url == node.url }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowContent

            if node.isDirectory && isExpanded, let children = node.children {
                ForEach(children) { child in
                    FileTreeNodeView(node: child, depth: depth + 1, expandedURLs: $expandedURLs)
                }
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 0) {
            // Indent guides: vertical ruler lines for each parent level
            ForEach(0..<depth, id: \.self) { _ in
                HStack(spacing: 0) {
                    Spacer()
                    Rectangle()
                        .fill(RollCodeTheme.divider.opacity(0.85))
                        .frame(width: 1)
                        .padding(.vertical, 1)
                    Spacer()
                }
                .frame(width: 14)
            }

            // Expand / collapse chevron for directories
            Group {
                if node.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(RollCodeTheme.secondaryText)
                } else {
                    Spacer().frame(width: 8)
                }
            }
            .frame(width: 14)

            // File / Folder icon
            Image(systemName: node.iconName)
                .font(.system(size: max(workspace.uiFontSize - 1, 9)))
                .foregroundStyle(nodeIconColor)
                .frame(width: 16)
                .padding(.trailing, 3)

            // Name label
            Text(node.name)
                .font(.system(size: workspace.uiFontSize, weight: (node.isDirectory && isExpanded) ? .medium : .regular))
                .foregroundStyle(isSelected ? RollCodeTheme.primaryText : (node.isDirectory ? RollCodeTheme.primaryText.opacity(0.9) : RollCodeTheme.secondaryText.opacity(0.95)))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: max(workspace.uiFontSize * 1.9, 22))
        .background(
            isSelected
                ? RollCodeTheme.elevatedBackground
                : (isHovered ? RollCodeTheme.elevatedBackground.opacity(0.45) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            if node.isDirectory {
                if isExpanded {
                    expandedURLs.remove(node.url)
                } else {
                    expandedURLs.insert(node.url)
                }
            } else {
                workspace.openFile(node.url)
            }
        }
        .contextMenu { FileContextMenu(node: node) }
    }

    private var nodeIconColor: Color {
        if node.isDirectory {
            return Color(red: 0.45, green: 0.64, blue: 0.95)
        }
        let ext = node.url.pathExtension.lowercased()
        switch ext {
        case "swift":
            return Color(red: 0.96, green: 0.52, blue: 0.28)
        case "js", "jsx", "ts", "tsx":
            return Color(red: 0.95, green: 0.82, blue: 0.35)
        case "py":
            return Color(red: 0.35, green: 0.72, blue: 0.92)
        case "json":
            return Color(red: 0.95, green: 0.75, blue: 0.30)
        case "md", "markdown":
            return Color(red: 0.45, green: 0.75, blue: 0.95)
        case "html", "htm":
            return Color(red: 0.92, green: 0.42, blue: 0.28)
        case "css":
            return Color(red: 0.35, green: 0.65, blue: 0.95)
        case "sh", "zsh", "bash":
            return Color(red: 0.48, green: 0.85, blue: 0.55)
        default:
            return RollCodeTheme.secondaryText
        }
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
        Button("Move to Trash", role: .destructive) { workspace.requestDeleteItem(at: node.url) }
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
