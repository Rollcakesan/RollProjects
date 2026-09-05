import SwiftUI
#if canImport(AIAgentKit)
import AIAgentKit
#endif

struct SettingsView: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(TerminalSession.self) private var terminal
    @Environment(AgentSession.self) private var agent

    @State private var geminiKeyInput = ""
    @State private var geminiProjectInput = ""
    @State private var showingKeySaved = false

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            codexTab
                .tabItem {
                    Label("Codex", systemImage: "sparkles")
                }

            geminiTab
                .tabItem {
                    Label("Gemini", systemImage: "diamond.fill")
                }
        }
        .frame(width: 520, height: 440)
        .padding(20)
        .background(RollCodeTheme.windowBackground)
        .onAppear {
            agent.auth.refresh()
            agent.geminiAuth.refresh()
            geminiKeyInput = agent.geminiAuth.storedAPIKey
            geminiProjectInput = agent.geminiAuth.storedProjectID
        }
    }

    private var generalTab: some View {
        Form {
            Section("Editor & Display") {
                Picker("Tab Width", selection: Binding(
                    get: { workspace.tabWidth },
                    set: { workspace.setTabWidth($0) }
                )) {
                    Text("2 Spaces").tag(2)
                    Text("4 Spaces").tag(4)
                    Text("8 Spaces").tag(8)
                }

                Picker("Editor Font Size", selection: Binding(
                    get: { workspace.editorFontScale },
                    set: { workspace.setEditorFontScale($0) }
                )) {
                    ForEach(WorkspaceModel.EditorFontScale.allCases) { scale in
                        Text(scale.displayName).tag(scale)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Fine Adjustment")
                    Spacer()
                    Text(workspace.fontSize.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(workspace.fontSize)) pt" : String(format: "%.1f pt", workspace.fontSize))
                        .foregroundStyle(RollCodeTheme.secondaryText)
                    Button("-") { workspace.zoomOut() }
                    Button("+") { workspace.zoomIn() }
                    Button("Reset") { workspace.resetZoom() }
                }

                Picker("UI Font Size", selection: Binding(
                    get: { workspace.uiFontScale },
                    set: { workspace.setUIFontScale($0) }
                )) {
                    ForEach(WorkspaceModel.UIFontScale.allCases) { scale in
                        Text(scale.displayName).tag(scale)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Startup & Workspace") {
                Toggle("Reopen last project on startup", isOn: Binding(
                    get: { workspace.restoresLastWorkspace },
                    set: { workspace.setRestoresLastWorkspace($0) }
                ))

                HStack {
                    Text("Last Project")
                    Spacer()
                    if let path = workspace.lastWorkspacePath {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .foregroundStyle(RollCodeTheme.secondaryText)
                    } else {
                        Text("None")
                            .foregroundStyle(RollCodeTheme.secondaryText)
                    }
                }

                if workspace.lastWorkspacePath != nil {
                    Button("Clear Project History") {
                        workspace.clearLastWorkspace()
                    }
                    .controlSize(.small)
                }
            }

            Section("Default AI Provider") {
                Picker("Provider", selection: Binding(
                    get: { agent.selectedProvider },
                    set: { agent.selectProvider($0) }
                )) {
                    ForEach(AgentProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .disabled(agent.isRunning)
            }
        }
        .formStyle(.grouped)
    }

    private var codexTab: some View {
        Form {
            Section("ChatGPT Account & Codex CLI") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(agent.auth.status.displayText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isCodexLoggedIn ? Color.green : RollCodeTheme.secondaryText)
                }

                HStack {
                    Text("Login Method")
                    Spacer()
                    Text("ChatGPT OAuth (Browser)")
                        .foregroundStyle(RollCodeTheme.secondaryText)
                }

                Button {
                    agent.auth.requestLogin(in: terminal)
                } label: {
                    Label("Log In to ChatGPT", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

            Section("Model & Thinking Preferences") {
                Picker("Default Model", selection: Binding(
                    get: { agent.selectedCodexModel },
                    set: { agent.selectedCodexModel = $0 }
                )) {
                    ForEach(agent.modelCatalog.models(for: .codex)) { model in
                        Text("\(model.speedTier.badgeEmoji) \(model.displayName)").tag(model.id)
                    }
                }

                Picker("Reasoning Effort (Thinking)", selection: Binding(
                    get: { agent.selectedReasoningEffort },
                    set: { agent.selectedReasoningEffort = $0 }
                )) {
                    ForEach(ReasoningEffort.allCases) { effort in
                        Text(effort.displayName).tag(effort)
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        Task { await agent.refreshModelCatalog() }
                    } label: {
                        HStack(spacing: 4) {
                            if agent.modelCatalog.isRefreshing {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Fetch Latest Models")
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var geminiTab: some View {
        Form {
            Section("Google Login (Recommended)") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(agent.geminiAuth.status.displayText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isGeminiLoggedIn ? Color.green : RollCodeTheme.secondaryText)
                }

                Text("Direct Google login requires a Google Cloud Code Assist license (Enterprise/Workspace). For personal accounts, using Google AI Studio (Free) is recommended.")
                    .font(.system(size: 10))
                    .foregroundStyle(RollCodeTheme.secondaryText)

                HStack(spacing: 10) {
                    if agent.geminiAuth.isLoggingIn {
                        ProgressView().controlSize(.small)
                        Text("Waiting for browser login…")
                            .font(.system(size: 11))
                            .foregroundStyle(RollCodeTheme.secondaryText)
                        Button("Cancel") {
                            agent.geminiAuth.cancelLogin()
                        }
                        .controlSize(.small)
                    } else {
                        Button {
                            agent.geminiAuth.loginWithBrowser()
                        } label: {
                            Label("Log In with Google (Browser)", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.borderedProminent)

                        if isGeminiLoggedIn {
                            Button("Log Out") {
                                agent.geminiAuth.logout()
                            }
                        }
                    }
                }
            }

            Section("Google AI Studio (Recommended for Personal Accounts)") {
                Text("Google provides free Gemini access for personal Google accounts via AI Studio:")
                    .font(.system(size: 11))
                    .foregroundStyle(RollCodeTheme.secondaryText)

                Button {
                    if let url = URL(string: "https://aistudio.google.com/app/apikey") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Get Free API Key (Google AI Studio)", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)

                SecureField("Paste Gemini API Key here", text: $geminiKeyInput)
                    .textFieldStyle(.roundedBorder)

                TextField("Google Cloud Project ID (Optional)", text: $geminiProjectInput)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save API Key") {
                        agent.geminiAuth.storedAPIKey = geminiKeyInput
                        agent.geminiAuth.storedProjectID = geminiProjectInput
                        showingKeySaved = true
                        Task { await agent.refreshModelCatalog() }
                    }
                    .buttonStyle(.bordered)

                    if showingKeySaved {
                        Text("Saved!")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.green)
                    }
                }
            }

            Section("Model Preferences") {
                Picker("Default Model", selection: Binding(
                    get: { agent.selectedGeminiModel },
                    set: { agent.selectedGeminiModel = $0 }
                )) {
                    ForEach(agent.modelCatalog.models(for: .gemini)) { model in
                        Text("\(model.speedTier.badgeEmoji) \(model.displayName)").tag(model.id)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var isCodexLoggedIn: Bool {
        agent.auth.status != .unauthenticated && agent.auth.status != .cliNotInstalled
    }

    private var isGeminiLoggedIn: Bool {
        agent.geminiAuth.status != .unauthenticated && agent.geminiAuth.status != .cliNotInstalled
    }
}
