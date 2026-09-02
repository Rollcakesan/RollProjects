import SwiftUI

struct QuickOpenView: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selectedURL: URL?
    @FocusState private var searchFocused: Bool

    private var matches: [FileNode] {
        workspace.quickOpenFiles(matching: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(RollCodeTheme.secondaryText)
                TextField("Search files by path", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .onSubmit(openSelectedFile)
                Text("⌘P")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(RollCodeTheme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RollCodeTheme.elevatedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 14)
            .frame(height: 48)

            Divider().overlay(RollCodeTheme.divider)

            if matches.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text("No matching files")
                }
                .font(.system(size: 12))
                .foregroundStyle(RollCodeTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(matches) { node in
                                QuickOpenRow(
                                    node: node,
                                    path: workspace.relativePath(for: node.url),
                                    isSelected: selectedURL == node.url
                                )
                                .id(node.url)
                                .onTapGesture {
                                    selectedURL = node.url
                                    openSelectedFile()
                                }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: selectedURL) { _, url in
                        guard let url else { return }
                        proxy.scrollTo(url, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 620, height: 410)
        .background(RollCodeTheme.windowBackground)
        .onAppear {
            selectedURL = matches.first?.url
            searchFocused = true
        }
        .onChange(of: query) { _, _ in
            selectedURL = matches.first?.url
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
    }

    private func moveSelection(by offset: Int) {
        guard !matches.isEmpty else { return }
        let currentIndex = selectedURL.flatMap { selected in
            matches.firstIndex(where: { $0.url == selected })
        } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), matches.count - 1)
        selectedURL = matches[nextIndex].url
    }

    private func openSelectedFile() {
        guard let url = selectedURL ?? matches.first?.url else { return }
        workspace.openFile(url)
        isPresented = false
    }
}

private struct QuickOpenRow: View {
    let node: FileNode
    let path: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: node.iconName)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? RollCodeTheme.accent : RollCodeTheme.secondaryText)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RollCodeTheme.primaryText)
                Text(path)
                    .font(.system(size: 10))
                    .foregroundStyle(RollCodeTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            Text(node.url.pathExtension.isEmpty ? "text" : node.url.pathExtension.lowercased())
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(RollCodeTheme.secondaryText)
        }
        .padding(.horizontal, 10)
        .frame(height: 43)
        .background(isSelected ? RollCodeTheme.selection : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }
}
