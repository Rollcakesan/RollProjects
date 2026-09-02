import SwiftUI

struct AgentPanelView: View {
    @Environment(AgentSession.self) private var agent
    @Environment(WorkspaceModel.self) private var workspace
    @State private var prompt = ""
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(RollCodeTheme.divider)

            if !agent.isAvailable {
                unavailableView
            } else if workspace.rootURL == nil {
                noWorkspaceView
            } else {
                conversation
                composer
            }
        }
        .background(RollCodeTheme.sidebarBackground)
    }

    private var header: some View {
        PanelHeader("AGENT") {
            Image(systemName: "sparkles")
                .foregroundStyle(RollCodeTheme.accent)
            Text("AUTO APPLY")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.green.opacity(0.9))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.12))
                .clipShape(Capsule())
        } trailing: {
            HStack(spacing: 7) {
                if agent.isRunning {
                    Button { agent.stop() } label: {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(Color.red.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    .help("Stop Agent")
                }
                Button { agent.newThread() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .disabled(agent.isRunning)
                .help("New Thread")
            }
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if agent.entries.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("What should I change?")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(RollCodeTheme.primaryText)
                            Text("Codex can inspect the workspace, edit files, and run tests. Changes are applied automatically.")
                                .font(.system(size: 11))
                                .foregroundStyle(RollCodeTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 8)
                    }

                    ForEach(agent.entries) { entry in
                        entryView(entry)
                    }

                    if agent.isRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Codex is working…")
                                .font(.system(size: 10))
                                .foregroundStyle(RollCodeTheme.secondaryText)
                        }
                    }
                    Color.clear.frame(height: 1).id("agent-bottom")
                }
                .padding(10)
            }
            .onChange(of: agent.entries) { _, _ in
                proxy.scrollTo("agent-bottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func entryView(_ entry: AgentEntry) -> some View {
        switch entry {
        case .message(let message):
            AgentMessageView(message: message)
        case .activity(let activity):
            AgentActivityView(activity: activity)
        case .changes(let paths):
            changedFilesView(paths)
        case .usage(let description):
            Text(description)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(RollCodeTheme.secondaryText)
        }
    }

    private func changedFilesView(_ paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("CHANGES")
                    .font(.system(size: 9, weight: .bold))
                Spacer()
                Label("Applied", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.green.opacity(0.85))
            }
            .foregroundStyle(RollCodeTheme.secondaryText)

            ForEach(paths, id: \.self) { path in
                Button { openChangedFile(path) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10))
                        Text(path)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 25)
                    .background(RollCodeTheme.elevatedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Divider().overlay(RollCodeTheme.divider)
            HStack(alignment: .bottom, spacing: 7) {
                TextField("Ask Codex to change this project…", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .lineLimit(2...6)
                    .focused($promptFocused)
                    .onSubmit(submit)
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(canSubmit ? RollCodeTheme.accent : RollCodeTheme.secondaryText.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
            }
            .padding(9)
        }
        .background(RollCodeTheme.windowBackground)
    }

    private var unavailableView: some View {
        EmptyStateView(
            systemImage: "exclamationmark.triangle",
            title: "Codex CLI was not found",
            message: "Install Codex with Homebrew, then reopen RollCode."
        ) {
            Text("brew install --cask codex")
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(20)
    }

    private var noWorkspaceView: some View {
        EmptyStateView(
            systemImage: "folder",
            title: "No folder open",
            message: "Open a folder to start an agent."
        ) {
            Button("Open Folder") { workspace.chooseFolder() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var canSubmit: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !agent.isRunning && workspace.rootURL != nil
    }

    private func submit() {
        guard canSubmit, let rootURL = workspace.rootURL, workspace.saveAllDocuments() else { return }
        let request = prompt
        prompt = ""
        agent.send(request, in: rootURL, activeFileURL: workspace.activeDocument?.url)
    }

    private func openChangedFile(_ path: String) {
        guard let rootURL = workspace.rootURL else { return }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : rootURL.appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return }
        workspace.openFile(url)
    }
}

private struct AgentMessageView: View {
    let message: AgentMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role.title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(roleColor)
            Text(message.text)
                .font(.system(size: 11))
                .foregroundStyle(RollCodeTheme.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var roleColor: Color {
        switch message.role {
        case .user: return RollCodeTheme.accent
        case .assistant: return Color.purple.opacity(0.9)
        case .system: return Color.orange.opacity(0.9)
        }
    }

    private var backgroundColor: Color {
        message.role == .user ? RollCodeTheme.selection.opacity(0.7) : RollCodeTheme.elevatedBackground
    }
}

private struct AgentActivityView: View {
    let activity: AgentActivity
    @State private var isExpanded = false

    var body: some View {
        Button { isExpanded.toggle() } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: activity.state.iconName)
                        .foregroundStyle(color)
                        .font(.system(size: 9))
                    Text(activity.title)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !activity.detail.isEmpty {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8))
                    }
                }
                if isExpanded && !activity.detail.isEmpty {
                    Text(activity.detail)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(RollCodeTheme.secondaryText)
                        .textSelection(.enabled)
                        .lineLimit(12)
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RollCodeTheme.windowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private var color: Color {
        switch activity.state {
        case .running: return RollCodeTheme.accent
        case .completed: return Color.green.opacity(0.8)
        case .failed: return Color.red.opacity(0.85)
        }
    }
}
