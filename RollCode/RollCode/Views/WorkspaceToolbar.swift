import SwiftUI

struct WorkspaceToolbar: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @EnvironmentObject private var terminal: TerminalSession
    @EnvironmentObject private var agent: AgentSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RollCodeTheme.accent)

            Text("RollCode")
                .font(.system(size: 13, weight: .semibold))

            if let rootURL = workspace.rootURL {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(RollCodeTheme.secondaryText)
                Text(rootURL.lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(RollCodeTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            ToolbarButton(icon: "sparkles", help: "Toggle Agent (⇧⌘A)") { agent.isVisible.toggle() }
            ToolbarButton(icon: "magnifyingglass", help: "Quick Open (⌘P)") { workspace.presentQuickOpen() }
                .disabled(workspace.rootURL == nil)
            ToolbarButton(icon: "folder", help: "Open Folder") { workspace.chooseFolder() }
            ToolbarButton(icon: "arrow.clockwise", help: "Refresh Files") { workspace.refreshTree() }
                .disabled(workspace.rootURL == nil)
            ToolbarButton(icon: "doc.badge.plus", help: "New File") { workspace.createFile() }
            ToolbarButton(
                icon: terminal.isVisible ? "terminal.fill" : "terminal",
                help: terminal.isVisible ? "Hide Terminal" : "Show Terminal"
            ) {
                terminal.isVisible.toggle()
            }
        }
        .padding(.leading, 78)
        .padding(.trailing, 10)
        .frame(height: 42)
        .background(RollCodeTheme.windowBackground)
    }
}
private struct ToolbarButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(RollCodeTheme.secondaryText)
        .contentShape(Rectangle())
        .help(help)
    }
}
