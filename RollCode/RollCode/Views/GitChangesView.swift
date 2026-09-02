import SwiftUI

struct GitChangesView: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Binding var isPresented: Bool
    @State private var changes: [GitChange] = []
    @State private var selectedPath: String?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var selectedChange: GitChange? {
        changes.first { $0.path == selectedPath }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("GIT CHANGES") {
                if isLoading { ProgressView().controlSize(.small) }
            } trailing: {
                Button { Task { await loadChanges() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                Button { isPresented = false } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }

            Divider().overlay(RollCodeTheme.divider)

            if let errorMessage {
                EmptyStateView(
                    systemImage: "exclamationmark.triangle",
                    title: "Git diff unavailable",
                    message: errorMessage
                )
            } else if changes.isEmpty, !isLoading {
                EmptyStateView(
                    systemImage: "checkmark.circle",
                    title: "No changes",
                    message: "The working tree matches HEAD."
                )
            } else {
                HSplitView {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(changes) { change in
                                GitChangeRow(change: change, isSelected: selectedPath == change.path)
                                    .onTapGesture { selectedPath = change.path }
                            }
                        }
                        .padding(6)
                    }
                    .frame(minWidth: 210, idealWidth: 250, maxWidth: 320)
                    .background(RollCodeTheme.sidebarBackground)

                    GitDiffPreview(change: selectedChange)
                        .frame(minWidth: 520)
                }
            }
        }
        .frame(width: 900, height: 580)
        .background(RollCodeTheme.windowBackground)
        .task { await loadChanges() }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
    }

    private func loadChanges() async {
        isLoading = true
        errorMessage = nil
        do {
            changes = try await workspace.gitChanges()
            if !changes.contains(where: { $0.path == selectedPath }) {
                selectedPath = changes.first?.path
            }
        } catch {
            changes = []
            selectedPath = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct GitChangeRow: View {
    let change: GitChange
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(change.status)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 22)
            Text(change.path)
                .font(.system(size: 11))
                .foregroundStyle(RollCodeTheme.primaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(isSelected ? RollCodeTheme.selection : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        if change.status == "??" || change.status.contains("A") { return .green }
        if change.status.contains("D") { return .red }
        return .orange
    }
}

private struct GitDiffPreview: View {
    let change: GitChange?

    var body: some View {
        if let change {
            VStack(spacing: 0) {
                HStack {
                    Text(change.path)
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(RollCodeTheme.elevatedBackground)

                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(change.diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                            Text(String(line).isEmpty ? " " : String(line))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .background(background(for: line))
                        }
                    }
                    .textSelection(.enabled)
                }
                .background(RollCodeTheme.editorBackground)
            }
        } else {
            EmptyStateView(systemImage: "doc.text", title: "Select a changed file")
        }
    }

    private func color(for line: Substring) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Color(red: 0.52, green: 0.82, blue: 0.57) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Color(red: 0.92, green: 0.50, blue: 0.50) }
        if line.hasPrefix("@@") { return RollCodeTheme.accent }
        return RollCodeTheme.secondaryText
    }

    private func background(for line: Substring) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Color.green.opacity(0.08) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Color.red.opacity(0.08) }
        return .clear
    }
}
