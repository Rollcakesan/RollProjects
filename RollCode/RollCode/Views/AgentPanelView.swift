import SwiftUI

struct AgentPanelView: View {
    @Environment(AgentSession.self) private var agent
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(TerminalSession.self) private var terminal
    @State private var prompt = ""
    @State private var codexPromptDraft = ""
    @State private var geminiPromptDraft = ""
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
        .onAppear {
            agent.auth.refresh()
            agent.geminiAuth.refresh()
            agent.loadPastCodexSessions()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            providerToggle
            Divider().frame(height: 12).overlay(RollCodeTheme.divider)
            threadSwitcherMenu

            Spacer()

            if agent.isRunning {
                Button { agent.stop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.red.opacity(0.9))
                }
                .buttonStyle(.plain)
                .help("Stop Agent")
            }

            Button {
                agent.newThread()
                prompt = ""
                promptFocused = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .foregroundStyle(RollCodeTheme.secondaryText)
            }
            .buttonStyle(.plain)
            .disabled(agent.isRunning)
            .help("New Thread (Clear conversation)")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RollCodeTheme.sidebarBackground)
    }

    private var providerToggle: some View {
        HStack(spacing: 2) {
            ForEach(AgentProvider.allCases) { provider in
                Button {
                    selectProvider(provider)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: provider.iconName)
                            .font(.system(size: 8))
                        Text(provider.rawValue)
                            .font(.system(size: 10, weight: agent.selectedProvider == provider ? .bold : .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(agent.selectedProvider == provider ? RollCodeTheme.accent.opacity(0.2) : Color.clear)
                    .foregroundStyle(agent.selectedProvider == provider ? RollCodeTheme.accent : RollCodeTheme.secondaryText)
                    .clipShape(RoundedRectangle(cornerRadius: 3.5))
                }
                .buttonStyle(.plain)
                .help("Switch to \(provider.rawValue)'s latest thread")
            }
        }
        .padding(1.5)
        .background(RollCodeTheme.windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4.5))
    }

    private func selectProvider(_ provider: AgentProvider) {
        guard provider != agent.selectedProvider else { return }
        if agent.selectedProvider == .codex {
            codexPromptDraft = prompt
        } else {
            geminiPromptDraft = prompt
        }
        agent.selectProvider(provider)
        prompt = (provider == .codex) ? codexPromptDraft : geminiPromptDraft
    }

    private var threadSwitcherMenu: some View {
        Menu {
            Button {
                withAnimation {
                    agent.newThread()
                    prompt = ""
                }
                promptFocused = true
            } label: {
                Label("New Thread", systemImage: "plus")
            }

            if !agent.threads.isEmpty {
                Divider()
                Section("Current Sessions") {
                    ForEach(agent.threads) { thread in
                        Button {
                            withAnimation {
                                agent.switchToThread(thread)
                                prompt = ""
                            }
                        } label: {
                            HStack {
                                if thread.id == agent.activeThread.id {
                                    Image(systemName: "checkmark")
                                }
                                Text(thread.title)
                            }
                        }
                    }
                }
            }

            if !agent.pastCodexSessions.isEmpty {
                Divider()
                Section("Past Codex Sessions") {
                    ForEach(agent.pastCodexSessions) { session in
                        Button {
                            withAnimation {
                                agent.resumePastCodexSession(session)
                                prompt = ""
                            }
                        } label: {
                            Text(session.displayTitle)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 9))
                    .foregroundStyle(RollCodeTheme.accent)
                Text(agent.activeThreadTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(RollCodeTheme.primaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(RollCodeTheme.secondaryText)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(RollCodeTheme.windowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var authBadge: some View {
        if agent.selectedProvider == .gemini {
            switch agent.geminiAuth.status {
            case .loggedIn(let account):
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text(account ?? "Google")
                        .font(.system(size: 9))
                        .foregroundStyle(RollCodeTheme.secondaryText)
                        .lineLimit(1)
                }
                .help("Logged in via Google Account")
            case .apiKey:
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 6, height: 6)
                    Text("API Key")
                        .font(.system(size: 9))
                        .foregroundStyle(RollCodeTheme.secondaryText)
                }
                .help("Authenticated via GEMINI_API_KEY")
            case .unauthenticated:
                if agent.geminiAuth.isLoggingIn {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        agent.geminiAuth.loginWithBrowser()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.right.square")
                            Text("Log In")
                        }
                        .font(.system(size: 9, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Log in with Google account via browser")
                }
            case .cliNotInstalled:
                EmptyView()
            }
        } else {
            switch agent.auth.status {
            case .loggedIn(_, let email, _):
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text(email ?? "ChatGPT")
                        .font(.system(size: 9))
                        .foregroundStyle(RollCodeTheme.secondaryText)
                        .lineLimit(1)
                }
                .help("Logged in to Codex via ChatGPT")
            case .apiKey:
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 6, height: 6)
                    Text("API Key")
                        .font(.system(size: 9))
                        .foregroundStyle(RollCodeTheme.secondaryText)
                }
                .help("Authenticated via OPENAI_API_KEY")
            case .unauthenticated:
                Button {
                    agent.auth.requestLogin(in: terminal)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "person.crop.circle.badge.plus")
                        Text("Log In")
                    }
                    .font(.system(size: 9, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Log in with ChatGPT account via 'codex login'")
            case .cliNotInstalled:
                EmptyView()
            }
        }
    }

    private var conversation: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if agent.selectedProvider == .codex && agent.auth.status == .unauthenticated {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.key.fill")
                            .foregroundStyle(RollCodeTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Codex Login")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(RollCodeTheme.primaryText)
                            Text("Log in with your ChatGPT account to use Codex without an API key.")
                                .font(.system(size: 10))
                                .foregroundStyle(RollCodeTheme.secondaryText)
                        }
                        Spacer()
                        Button("Log In") {
                            agent.auth.requestLogin(in: terminal)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(8)
                    .background(RollCodeTheme.elevatedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else if agent.selectedProvider == .gemini && agent.geminiAuth.status == .unauthenticated {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.key.fill")
                            .foregroundStyle(Color.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Gemini Login")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(RollCodeTheme.primaryText)
                            Text("Log in with Google via browser, or enter an API key in Settings (⌘,).")
                                .font(.system(size: 10))
                                .foregroundStyle(RollCodeTheme.secondaryText)
                        }
                        Spacer()
                        if agent.geminiAuth.isLoggingIn {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("Waiting…")
                                    .font(.system(size: 10))
                                    .foregroundStyle(RollCodeTheme.secondaryText)
                            }
                        } else {
                            Button("Log In with Google") {
                                agent.geminiAuth.loginWithBrowser()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(8)
                    .background(RollCodeTheme.elevatedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if agent.entries.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("What should I change?")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(RollCodeTheme.primaryText)
                        Text("\(agent.selectedProvider.rawValue) can inspect the workspace, edit files, and run tests. Changes are applied automatically.")
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
                        Text("\(agent.selectedProvider.rawValue) is working…")
                            .font(.system(size: 10))
                            .foregroundStyle(RollCodeTheme.secondaryText)
                    }
                }
            }
            .padding(10)
        }
        .defaultScrollAnchor(.bottom)
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
                Button {
                    workspace.presentGitChanges()
                } label: {
                    Label("Review Diffs", systemImage: "arrow.triangle.merge")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(RollCodeTheme.accent)
                }
                .buttonStyle(.plain)
                .help("Open Git diff preview (⇧⌘G)")
            }
            .foregroundStyle(RollCodeTheme.secondaryText)

            ForEach(paths, id: \.self) { path in
                HStack(spacing: 4) {
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

                    Button {
                        workspace.presentGitChanges()
                    } label: {
                        Image(systemName: "plus.forwardslash.minus")
                            .font(.system(size: 10))
                            .foregroundStyle(RollCodeTheme.secondaryText)
                            .frame(width: 25, height: 25)
                            .background(RollCodeTheme.elevatedBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Inspect Diff")
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Divider().overlay(RollCodeTheme.divider)
            HStack(alignment: .bottom, spacing: 7) {
                TextField("Ask \(agent.selectedProvider.rawValue) to change this project…", text: $prompt, axis: .vertical)
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
            title: "\(agent.selectedProvider.rawValue) CLI was not found",
            message: agent.selectedProvider == .codex
                ? "Install Codex or ChatGPT.app, then reopen RollCode."
                : "Install Gemini CLI with Homebrew or npm, then reopen RollCode."
        ) {
            Text(agent.selectedProvider == .codex ? "brew install --cask codex" : "npm install -g @google/gemini-cli")
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
        guard let workspaceURL = workspace.rootURL else { return }
        let url = workspaceURL.appending(path: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return }
        workspace.openFile(url)
    }
}

private struct AgentMessageView: View {
    let message: AgentMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.displayTitle)
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
        case .assistant:
            return message.senderName == "GEMINI" ? Color.blue.opacity(0.9) : Color.purple.opacity(0.9)
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
