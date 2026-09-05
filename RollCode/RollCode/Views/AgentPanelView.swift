#if canImport(AIAgentKit)
import AIAgentKit
#endif
import SwiftUI

struct AgentPanelView: View {
    @Environment(AgentSession.self) private var agent
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(TerminalSession.self) private var terminal
    @State private var prompt = ""
    @State private var codexPromptDraft = ""
    @State private var geminiPromptDraft = ""
    @State private var fileMentionQuery: String?
    @State private var sentMessageScrollTarget: AgentEntry.ID?
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
                    Button { agent.setModel(model.id) } label: {
                        HStack {
                            if model.id == currentID { Image(systemName: "checkmark") }
                            Text("\(model.speedTier.badgeEmoji) \(model.displayName)")
                        }
                    }
                }
            }

            if supportsReasoning && agent.selectedProvider == .codex {
                Divider()
                Menu {
                    ForEach(ReasoningEffort.allCases) { effort in
                        Button { agent.setReasoningEffort(effort) } label: {
                            HStack {
                                if agent.currentReasoningEffort == effort { Image(systemName: "checkmark") }
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
                .disabled(agent.isRunning)
                .help("Switch to \(provider.rawValue)'s latest thread")
            }
        }
        .padding(1.5)
        .background(RollCodeTheme.windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4.5))
    }

    private func selectProvider(_ provider: AgentProvider) {
        guard provider != agent.selectedProvider, !agent.isRunning else { return }
        if agent.selectedProvider == .codex {
            codexPromptDraft = prompt
        } else {
            geminiPromptDraft = prompt
        }
        agent.selectProvider(provider)
        prompt = (provider == .codex) ? codexPromptDraft : geminiPromptDraft
    }

    private var threadSwitcherMenu: some View {
        let currentProviderThreads = agent.threads(for: agent.selectedProvider)

        return Menu {
            Button {
                withAnimation { agent.newThread(); prompt = "" }
                promptFocused = true
            } label: {
                Label("New \(agent.selectedProvider.rawValue) Thread", systemImage: "plus")
            }

            if !currentProviderThreads.isEmpty {
                Divider()
                Section("\(agent.selectedProvider.rawValue) Sessions") {
                    ForEach(currentProviderThreads) { thread in
                        Button { withAnimation { agent.switchToThread(thread); prompt = "" } } label: {
                            HStack {
                                if thread.id == agent.activeThread.id { Image(systemName: "checkmark") }
                                Text(thread.title)
                            }
                        }
                    }
                }
            }

            if agent.selectedProvider == .codex && !agent.pastCodexSessions.isEmpty {
                Divider()
                Section("Past Codex Sessions") {
                    ForEach(agent.pastCodexSessions) { session in
                        Button { withAnimation { agent.resumePastCodexSession(session); prompt = "" } } label: {
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
        .disabled(agent.isRunning)
        .fixedSize()
    }

    @ViewBuilder
    private var authBadge: some View {
        let isGemini = agent.selectedProvider == .gemini
        let isAPIKey: Bool = {
            if isGemini {
                if case .apiKey = agent.geminiAuth.status { return true }
                return false
            } else {
                return agent.auth.status == .apiKey
            }
        }()
        let isLoggedIn = isGemini ? (agent.geminiAuth.status != .unauthenticated && agent.geminiAuth.status != .cliNotInstalled) : (agent.auth.status != .unauthenticated && agent.auth.status != .cliNotInstalled)
        let statusText = isGemini ? agent.geminiAuth.status.displayText : agent.auth.status.displayText

        if isLoggedIn {
            HStack(spacing: 4) {
                Circle().fill(isAPIKey ? Color.blue : Color.green).frame(width: 6, height: 6)
                Text(statusText).font(.system(size: 9)).foregroundStyle(RollCodeTheme.secondaryText).lineLimit(1)
            }
            .help(isAPIKey ? "Authenticated via API Key" : "Logged in account")
        } else if isGemini && agent.geminiAuth.isLoggingIn {
            ProgressView().controlSize(.mini)
        } else {
            Button {
                if isGemini { agent.geminiAuth.loginWithBrowser() } else { agent.auth.requestLogin(in: terminal) }
            } label: {
                Label("Log In", systemImage: isGemini ? "arrow.up.right.square" : "person.crop.circle.badge.plus")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    private var conversation: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(agent.entries) { entry in
                            entryView(entry)
                                .id(entry.id)
                        }

                        if agent.isRunning {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("\(agent.selectedProvider.rawValue) is working…")
                                    .font(.system(size: 10))
                                    .foregroundStyle(RollCodeTheme.secondaryText)
                            }
                        }

                        if sentMessageScrollTarget != nil && agent.isRunning {
                            Color.clear
                                .frame(height: geometry.size.height)
                                .accessibilityHidden(true)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("bottom_anchor")
                    }
                    .padding(10)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: sentMessageScrollTarget) { _, target in
                    guard let target else { return }
                    scrollToSentMessage(target, using: proxy)
                }
                .onChange(of: agent.entries.count) {
                    guard sentMessageScrollTarget == nil else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom_anchor", anchor: .bottom)
                    }
                }
                .onChange(of: agent.isRunning) { _, isRunning in
                    if isRunning, let target = sentMessageScrollTarget {
                        scrollToSentMessage(target, using: proxy)
                    } else if !isRunning {
                        sentMessageScrollTarget = nil
                    }
                }
                .onChange(of: agent.activeThread.id) {
                    sentMessageScrollTarget = nil
                    proxy.scrollTo("bottom_anchor", anchor: .bottom)
                }
                .onAppear {
                    proxy.scrollTo("bottom_anchor", anchor: .bottom)
                }
            }
        }
    }

    private func scrollToSentMessage(_ target: AgentEntry.ID, using proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(target, anchor: .top)
            }
        }
    }

    @ViewBuilder
    private func entryView(_ entry: AgentEntry) -> some View {
        switch entry {
        case .message(let message):
            AgentMessageRowView(message: message, uiFontSize: workspace.uiFontSize)
        case .activity(let activity):
            AgentActivityCardView(activity: activity)
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
                Text("CHANGES").font(.system(size: 9, weight: .bold))
                Spacer()
                Button { workspace.presentGitChanges() } label: {
                    Label("Review Diffs", systemImage: "arrow.triangle.merge")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(RollCodeTheme.accent)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(RollCodeTheme.secondaryText)

            ForEach(paths, id: \.self) { path in
                HStack(spacing: 4) {
                    Button { openChangedFile(path) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text").font(.system(size: 10))
                            Text(path).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 7)
                        .frame(height: 25)
                        .background(RollCodeTheme.elevatedBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)

                    Button { workspace.presentGitChanges() } label: {
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

            PromptInputBar(
                text: $prompt,
                placeholder: "Ask \(agent.selectedProvider.rawValue) to change this project… (Shift+Return for newline, use @file)",
                isRunning: agent.isRunning,
                canSubmit: canSubmit,
                onSubmit: submit,
                onStop: { agent.stop() },
                onTextChange: { newPrompt in
                    checkFileMention(in: newPrompt)
                }
            )
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
        count >= 1_000_000 ? String(format: "%.1fM tok", Double(count) / 1_000_000.0) : (count >= 1_000 ? String(format: "%.1fk tok", Double(count) / 1_000.0) : "\(count) tok")
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
        if let regex = try? NSRegularExpression(pattern: #"(?:^|\s)@([A-Za-z0-9_./\-]+)"#) {
            let nsReq = request as NSString
            let context = regex.matches(in: request, range: NSRange(location: 0, length: nsReq.length)).compactMap { match -> String? in
                guard match.numberOfRanges >= 2 else { return nil }
                let relPath = nsReq.substring(with: match.range(at: 1))
                guard let content = try? String(contentsOf: rootURL.appending(path: relPath), encoding: .utf8), content.count <= 100_000 else { return nil }
                return "[Context File: \(relPath)]\n```\n\(content)\n```"
            }
            if !context.isEmpty { request += "\n\n" + context.joined(separator: "\n\n") }
        }

        agent.send(request, in: rootURL, activeFileURL: workspace.activeDocument?.url)
        if case .message(let message) = agent.entries.last, message.role == .user {
            sentMessageScrollTarget = .message(message.id)
        }
    }

    private func openChangedFile(_ path: String) {
        guard let workspaceURL = workspace.rootURL else { return }
        let url = workspaceURL.appending(path: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return }
        workspace.openFile(url)
    }
}
