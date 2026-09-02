import SwiftUI

struct WorkspaceToolbarContent: ToolbarContent {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(TerminalSession.self) private var terminal
    @Environment(AgentSession.self) private var agent

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 13, weight: .semibold))
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
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { agent.isVisible.toggle() } label: {
                Image(systemName: "sparkles")
            }
            .help("Toggle Agent (⇧⌘A)")

            Button { workspace.presentQuickOpen() } label: {
                Image(systemName: "magnifyingglass")
            }
            .disabled(workspace.rootURL == nil)
            .help("Quick Open (⌘P)")

            Button { workspace.presentWorkspaceSearch() } label: {
                Image(systemName: "text.magnifyingglass")
            }
            .disabled(workspace.rootURL == nil)
            .help("Search in Project (⇧⌘F)")

            Button { workspace.presentGitChanges() } label: {
                Image(systemName: "arrow.triangle.branch")
            }
            .disabled(workspace.rootURL == nil)
            .help("Git Changes (⇧⌘G)")

            Button { workspace.chooseFolder() } label: {
                Image(systemName: "folder")
            }
            .help("Open Folder")

            Button { workspace.refreshTree() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(workspace.rootURL == nil)
            .help("Refresh Files")

            Button { workspace.createFile() } label: {
                Image(systemName: "doc.badge.plus")
            }
            .help("New File")

            Button { terminal.isVisible.toggle() } label: {
                Image(systemName: terminal.isVisible ? "terminal.fill" : "terminal")
            }
            .help(terminal.isVisible ? "Hide Terminal" : "Show Terminal")
        }
    }
}

