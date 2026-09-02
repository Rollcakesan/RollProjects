import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(TerminalSession.self) private var terminal
    @Environment(AgentSession.self) private var agent

    var body: some View {
        @Bindable var workspace = workspace
        VStack(spacing: 0) {
            WorkspaceToolbar()
            Divider().overlay(RollCodeTheme.divider)

            HSplitView {
                SidebarView()
                    .frame(minWidth: 180, idealWidth: 230, maxWidth: 360)

                VSplitView {
                    EditorWorkspaceView()
                        .frame(minHeight: 260)

                    if terminal.isVisible {
                        TerminalView()
                            .frame(minHeight: 120, idealHeight: 210, maxHeight: 420)
                    }
                }
                .frame(minWidth: 520)

                if agent.isVisible {
                    AgentPanelView()
                        .frame(minWidth: 280, idealWidth: 350, maxWidth: 520)
                }
            }

            StatusBarView()
        }
        .background(RollCodeTheme.editorBackground)
        .alert("RollCode", isPresented: alertBinding) {
            Button("OK", role: .cancel) { workspace.alertMessage = nil }
        } message: {
            Text(workspace.alertMessage ?? "")
        }
        .sheet(isPresented: $workspace.isQuickOpenPresented) {
            QuickOpenView(isPresented: $workspace.isQuickOpenPresented)
        }
        .onAppear {
            if !terminal.isRunning {
                terminal.start(in: workspace.rootURL ?? FileManager.default.homeDirectoryForCurrentUser)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.checkForExternalChanges()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            guard NSApp.isActive else { return }
            workspace.checkForExternalChanges()
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { workspace.alertMessage != nil },
            set: { if !$0 { workspace.alertMessage = nil } }
        )
    }
}

enum RollCodeTheme {
    static let windowBackground = Color(red: 0.075, green: 0.078, blue: 0.09)
    static let sidebarBackground = Color(red: 0.09, green: 0.094, blue: 0.108)
    static let editorBackground = Color(red: 0.115, green: 0.12, blue: 0.14)
    static let elevatedBackground = Color(red: 0.145, green: 0.15, blue: 0.175)
    static let selection = Color(red: 0.20, green: 0.27, blue: 0.40)
    static let accent = Color(red: 0.40, green: 0.61, blue: 0.98)
    static let primaryText = Color(white: 0.88)
    static let secondaryText = Color(white: 0.56)
    static let divider = Color.white.opacity(0.08)
}
