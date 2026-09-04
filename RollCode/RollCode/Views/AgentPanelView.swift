import SwiftUI

struct AgentPanelView: View {
    @Environment(AgentSession.self) private var agent
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(TerminalSession.self) private var terminal
    @State private var prompt = ""
    @State private var codexPromptDraft = ""
    @State private var geminiPromptDraft = ""
    @State private var fileMentionQuery: String?
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
            Task {
                await agent.refreshModelCatalog()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            providerToggle
            Divider().frame(height: 12).overlay(RollCodeTheme.divider)
            modelSelectorMenu
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

    private var modelSelectorMenu: some View {
        let currentID = agent.currentModel
        let currentInfo = agent.modelCatalog.findModel(id: currentID, provider: agent.selectedProvider)
        let tier = currentInfo?.speedTier ?? (currentID.contains("flash") || currentID.contains("mini") ? .fast : .standard)
        let supportsReasoning = currentInfo?.supportsReasoningEffort == true || currentID.hasPrefix("o") || currentID.hasPrefix("gpt-5")
        let availableModels = agent.modelCatalog.models(for: agent.selectedProvider)

        return Menu {
            Section("Select Model") {
                ForEach(availableModels) { model in
                    Button {
                        agent.setModel(model.id)
                    } label: {
                        HStack {
                            if model.id == currentID {
                                Image(systemName: "checkmark")
                            }
                            Text("\(model.speedTier.badgeEmoji) \(model.displayName)")
                        }
                    }
                }
            }

            if supportsReasoning && agent.selectedProvider == .codex {
                Divider()
                Menu {
                    ForEach(ReasoningEffort.allCases) { effort in
                        Button {
                            agent.setReasoningEffort(effort)
                        } label: {
                            HStack {
                                if agent.currentReasoningEffort == effort {
                                    Image(systemName: "checkmark")
                                }
                                Text(effort.displayName)
                            }
                        }
                    }
                } label: {
                    Label("Thinking Budget: \(agent.currentReasoningEffort.shortName)", systemImage: "brain")
                }
            }

            Divider()
            Button {
                Task {
                    await agent.refreshModelCatalog()
                }
            } label: {
                Label(agent.modelCatalog.isRefreshing ? "Refreshing Models…" : "Refresh Models from API", systemImage: "arrow.clockwise")
            }
            .disabled(agent.modelCatalog.isRefreshing)
        } label: {
            HStack(spacing: 3) {
                Text(tier.badgeEmoji)
                    .font(.system(size: 9))
                Text(currentInfo?.displayName ?? currentID)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(RollCodeTheme.primaryText)
                    .lineLimit(1)
                if supportsReasoning && agent.selectedProvider == .codex {
                    Text("(\(agent.currentReasoningEffort.shortName))")
                        .font(.system(size: 8.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(RollCodeTheme.accent)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7))
                    .foregroundStyle(RollCodeTheme.secondaryText)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2.5)
            .background(RollCodeTheme.windowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Select model and thinking/speed mode")
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
        ScrollViewReader { proxy in
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

                    Color.clear
                        .frame(height: 1)
                        .id("bottom_anchor")
                }
                .padding(10)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: agent.entries.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom_anchor", anchor: .bottom)
                }
            }
            .onChange(of: agent.isRunning) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom_anchor", anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo("bottom_anchor", anchor: .bottom)
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

            // File mention suggestions
            if let query = fileMentionQuery, let root = workspace.rootNode {
                let matches = Array(root.matchingFiles(query).prefix(5))
                if !matches.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FILES")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(RollCodeTheme.accent)
                            .padding(.horizontal, 6)
                            .padding(.top, 2)

                        ForEach(matches) { node in
                            Button {
                                insertFileMention(node)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 9))
                                    Text(node.url.relativePath(from: root.url))
                                        .font(.system(size: 10, design: .monospaced))
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3.5)
                                .background(RollCodeTheme.elevatedBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(5)
                    .background(RollCodeTheme.windowBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(RollCodeTheme.divider))
                    .padding(.horizontal, 9)
                    .padding(.top, 5)
                }
            }

            HStack(alignment: .bottom, spacing: 7) {
                ZStack(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("Ask \(agent.selectedProvider.rawValue) to change this project… (Shift+Return for newline, use @file)")
                            .font(.system(size: 11))
                            .foregroundStyle(RollCodeTheme.secondaryText.opacity(0.55))
                            .padding(.top, 4)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                    AgentPromptInputView(
                        text: $prompt,
                        onSubmit: submit,
                        onTextChange: { newPrompt in
                            checkFileMention(in: newPrompt)
                        }
                    )
                    .frame(minHeight: 28, maxHeight: 110)
                }
                .padding(4)
                .background(RollCodeTheme.windowBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(RollCodeTheme.divider))

                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(canSubmit ? RollCodeTheme.accent : RollCodeTheme.secondaryText.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .padding(.bottom, 4)
            }
            .padding(.horizontal, 9)
            .padding(.top, 9)
            .padding(.bottom, 5)

            // Status bar with auth indicator, elapsed latency, and token metrics
            HStack(spacing: 8) {
                authBadge

                Spacer()

                if let duration = agent.lastTurnDuration {
                    HStack(spacing: 3) {
                        Image(systemName: "timer")
                            .font(.system(size: 8.5))
                        Text(String(format: "%.1fs", duration))
                            .font(.system(size: 9, design: .monospaced))
                    }
                    .foregroundStyle(RollCodeTheme.secondaryText)
                    .help("Last turn duration: \(String(format: "%.2f", duration))s")
                }

                if agent.totalTokens > 0 {
                    tokenMetricsBadge
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .background(RollCodeTheme.windowBackground)
    }

    private var tokenMetricsBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "number.circle")
                .font(.system(size: 8.5))
            Text(formattedTokenCount(agent.totalTokens))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(RollCodeTheme.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 3.5))
        .foregroundStyle(RollCodeTheme.secondaryText)
        .help("Session tokens: \(agent.activeThread.inputTokens) in / \(agent.activeThread.cachedTokens) cached / \(agent.activeThread.outputTokens) out")
    }

    private func formattedTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM tok", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.1fk tok", Double(count) / 1_000.0)
        } else {
            return "\(count) tok"
        }
    }

    private func checkFileMention(in text: String) {
        guard let lastWord = text.components(separatedBy: .whitespacesAndNewlines).last,
              lastWord.hasPrefix("@") else {
            fileMentionQuery = nil
            return
        }
        fileMentionQuery = String(lastWord.dropFirst())
    }

    private func insertFileMention(_ node: FileNode) {
        guard let root = workspace.rootNode else { return }
        let relPath = node.url.relativePath(from: root.url)
        if let lastAt = prompt.lastIndex(of: "@") {
            prompt = String(prompt[..<lastAt]) + "@" + relPath + " "
        } else {
            prompt += "@" + relPath + " "
        }
        fileMentionQuery = nil
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
        var request = prompt
        prompt = ""
        fileMentionQuery = nil

        // Resolve @file mentions and attach contents into prompt
        let pattern = #"(?:^|\s)@([A-Za-z0-9_./\-]+)"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsReq = request as NSString
            let matches = regex.matches(in: request, range: NSRange(location: 0, length: nsReq.length))
            var referencedFiles: [String] = []
            for match in matches {
                guard match.numberOfRanges >= 2 else { continue }
                let pathRange = match.range(at: 1)
                let relPath = nsReq.substring(with: pathRange)
                let targetURL = rootURL.appending(path: relPath)
                if let content = try? String(contentsOf: targetURL, encoding: .utf8), content.count <= 100_000 {
                    referencedFiles.append("[Context File: \(relPath)]\n```\n\(content)\n```")
                }
            }
            if !referencedFiles.isEmpty {
                request += "\n\n" + referencedFiles.joined(separator: "\n\n")
            }
        }

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
    @Environment(WorkspaceModel.self) private var workspace
    let message: AgentMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.displayTitle)
                .font(.system(size: max(workspace.uiFontSize - 3, 8.5), weight: .bold))
                .foregroundStyle(roleColor)

            let blocks = MarkdownBlockParser.parse(from: message.text)
            ForEach(blocks) { block in
                switch block {
                case .text(let content):
                    if let attributed = try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                        Text(attributed)
                            .font(.system(size: workspace.uiFontSize))
                            .foregroundStyle(RollCodeTheme.primaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(content)
                            .font(.system(size: workspace.uiFontSize))
                            .foregroundStyle(RollCodeTheme.primaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .code(let language, let code):
                    MarkdownCodeBlockView(language: language, code: code)
                }
            }
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

// MARK: - Markdown Support

enum MarkdownBlock: Identifiable, Equatable {
    case text(String)
    case code(language: String?, code: String)

    var id: String {
        switch self {
        case .text(let t): return "text_\(t.hashValue)"
        case .code(let lang, let c): return "code_\(lang ?? "")_\(c.hashValue)"
        }
    }
}

enum MarkdownBlockParser {
    static func parse(from text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: "\n")
        var currentTextLines: [String] = []
        var currentCodeLines: [String] = []
        var currentLanguage: String? = nil
        var inCodeBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    // Close code block
                    blocks.append(.code(language: currentLanguage, code: currentCodeLines.joined(separator: "\n")))
                    currentCodeLines.removeAll()
                    currentLanguage = nil
                    inCodeBlock = false
                } else {
                    // Open code block
                    if !currentTextLines.isEmpty {
                        let textBlock = currentTextLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !textBlock.isEmpty {
                            blocks.append(.text(textBlock))
                        }
                        currentTextLines.removeAll()
                    }
                    let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    currentLanguage = lang.isEmpty ? nil : lang
                    inCodeBlock = true
                }
            } else if inCodeBlock {
                currentCodeLines.append(line)
            } else {
                currentTextLines.append(line)
            }
        }

        if inCodeBlock && !currentCodeLines.isEmpty {
            blocks.append(.code(language: currentLanguage, code: currentCodeLines.joined(separator: "\n")))
        } else if !currentTextLines.isEmpty {
            let remaining = currentTextLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty {
                blocks.append(.text(remaining))
            }
        }

        return blocks
    }
}

private struct MarkdownCodeBlockView: View {
    let language: String?
    let code: String
    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((language ?? "code").uppercased())
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(RollCodeTheme.secondaryText)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    isCopied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        isCopied = false
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                        Text(isCopied ? "Copied" : "Copy")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(isCopied ? Color.green : RollCodeTheme.secondaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RollCodeTheme.elevatedBackground.opacity(0.8))

            Divider().overlay(RollCodeTheme.divider)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(RollCodeTheme.primaryText)
                    .textSelection(.enabled)
                    .padding(8)
            }
        }
        .background(RollCodeTheme.editorBackground)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(RollCodeTheme.divider))
        .padding(.vertical, 2)
    }
}

// MARK: - Prompt Input (Shift+Return for newline, Return for submit)

private struct AgentPromptInputView: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onTextChange: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = PromptTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 11)
        textView.textColor = RollCodeTheme.nsForeground
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 2
        textView.string = text
        textView.onSubmit = onSubmit

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? PromptTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.onSubmit = onSubmit
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AgentPromptInputView
        weak var textView: PromptTextView?

        init(_ parent: AgentPromptInputView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            let newText = tv.string
            parent.text = newText
            parent.onTextChange?(newText)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // If IME is currently composing/converting text, don't submit; let IME confirm
                if textView.hasMarkedText() {
                    return false
                }
                // Shift + Return: insert newline
                if let currentEvent = NSApp.currentEvent, currentEvent.modifierFlags.contains(.shift) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                // Plain Return: trigger submit
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

private final class PromptTextView: NSTextView {
    var onSubmit: (() -> Void)?
}
