import SwiftUI

struct WorkspaceSearchView: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var replacement = ""
    @State private var matches: [WorkspaceSearchMatch] = []
    @State private var isSearching = false
    @State private var isReplacing = false
    @State private var statusMessage = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("SEARCH IN PROJECT") {
                if isSearching || isReplacing {
                    ProgressView().controlSize(.small)
                }
            } trailing: {
                Button { isPresented = false } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(RollCodeTheme.secondaryText)
            }

            VStack(spacing: 8) {
                SearchField(text: $query, prompt: "Search text")
                    .focused($searchFocused)
                HStack(spacing: 8) {
                    TextField("Replace with", text: $replacement)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .frame(height: 25)
                        .background(RollCodeTheme.elevatedBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(RollCodeTheme.divider))

                    Button("Replace All") { performReplaceAll() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(matches.isEmpty || isReplacing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider().overlay(RollCodeTheme.divider)

            HStack {
                Text(summary)
                Spacer()
                if !statusMessage.isEmpty { Text(statusMessage) }
            }
            .font(.system(size: 10))
            .foregroundStyle(RollCodeTheme.secondaryText)
            .padding(.horizontal, 12)
            .frame(height: 28)

            if query.isEmpty {
                EmptyStateView(
                    systemImage: "text.magnifyingglass",
                    title: "Search every file",
                    message: "Enter text to search across the open project."
                )
            } else if matches.isEmpty, !isSearching {
                EmptyStateView(systemImage: "magnifyingglass", title: "No matches")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches) { match in
                            WorkspaceSearchRow(match: match)
                                .onTapGesture {
                                    workspace.openSearchMatch(match)
                                    isPresented = false
                                }
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(width: 720, height: 520)
        .background(RollCodeTheme.windowBackground)
        .onAppear { searchFocused = true }
        .task(id: query) { await search() }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
    }

    private var summary: String {
        let occurrences = matches.reduce(0) { $0 + $1.occurrences }
        guard occurrences > 0 else { return "" }
        return "\(occurrences) matches in \(Set(matches.map(\.url)).count) files"
    }

    private func search() async {
        statusMessage = ""
        isSearching = false
        guard !query.isEmpty else {
            matches = []
            return
        }
        isSearching = true
        do {
            try await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let newMatches = await workspace.searchWorkspace(for: query)
            guard !Task.isCancelled else { return }
            matches = newMatches
        } catch {
            return
        }
        isSearching = false
    }

    private func performReplaceAll() {
        isReplacing = true
        Task {
            let result = await workspace.replaceWorkspaceOccurrences(of: query, with: replacement)
            if result.failedFiles.isEmpty {
                statusMessage = "Replaced \(result.occurrences) matches in \(result.files) files"
            } else {
                statusMessage = "Could not update \(result.failedFiles.count) files"
            }
            matches = await workspace.searchWorkspace(for: query)
            isReplacing = false
        }
    }
}

private struct WorkspaceSearchRow: View {
    let match: WorkspaceSearchMatch

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: CodeLanguage(url: match.url).systemImageName)
                    .font(.system(size: 10))
                    .foregroundStyle(RollCodeTheme.accent)
                Text(match.relativePath)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RollCodeTheme.primaryText)
                    .lineLimit(1)
                Spacer()
                Text("Line \(match.line)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(RollCodeTheme.secondaryText)
            }
            Text(match.preview.isEmpty ? " " : match.preview)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(RollCodeTheme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.clear)
        .contentShape(Rectangle())
    }
}
