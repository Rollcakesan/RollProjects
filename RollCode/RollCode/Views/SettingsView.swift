import SwiftUI

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
        .frame(width: 520, height: 380)
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
            Section("Editor") {
                Picker("Tab Width", selection: Binding(
                    get: { workspace.tabWidth },
                    set: { workspace.setTabWidth($0) }
                )) {
                    Text("2 Spaces").tag(2)
                    Text("4 Spaces").tag(4)
                    Text("8 Spaces").tag(8)
                }

                HStack {
                    Text("Font Size")
                    Spacer()
                    Text("\(Int(workspace.fontSize)) pt")
                        .foregroundStyle(RollCodeTheme.secondaryText)
                    Button("-") { workspace.zoomOut() }
                    Button("+") { workspace.zoomIn() }
                    Button("Reset") { workspace.resetZoom() }
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

                Text("Log in with your Google account via browser. Works directly with Gemini CLI.")
                    .font(.system(size: 11))
                    .foregroundStyle(RollCodeTheme.secondaryText)

                HStack {
                    Button {
                        agent.geminiAuth.requestLogin(in: terminal)
                    } label: {
                        Label("Log In with Google", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .buttonStyle(.borderedProminent)

                    if isGeminiLoggedIn {
                        Button("Log Out") {
                            agent.geminiAuth.logout()
                        }
                    }
                }
            }

            Section("Alternative: Gemini API Key") {
                Text("If you prefer using an API key from Google AI Studio:")
                    .font(.system(size: 11))
                    .foregroundStyle(RollCodeTheme.secondaryText)

                SecureField("Gemini API Key (AI Studio)", text: $geminiKeyInput)
                    .textFieldStyle(.roundedBorder)

                TextField("Google Cloud Project ID (Optional)", text: $geminiProjectInput)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save Settings") {
                        agent.geminiAuth.storedAPIKey = geminiKeyInput
                        agent.geminiAuth.storedProjectID = geminiProjectInput
                        showingKeySaved = true
                    }
                    .buttonStyle(.bordered)

                    if showingKeySaved {
                        Text("Saved!")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.green)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var isCodexLoggedIn: Bool {
        if case .loggedIn = agent.auth.status { return true }
        if case .apiKey = agent.auth.status { return true }
        return false
    }

    private var isGeminiLoggedIn: Bool {
        if case .loggedIn = agent.geminiAuth.status { return true }
        if case .apiKey = agent.geminiAuth.status { return true }
        return false
    }
}
