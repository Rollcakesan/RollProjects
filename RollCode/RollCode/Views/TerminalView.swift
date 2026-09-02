import SwiftUI

struct TerminalView: View {
    @Environment(TerminalSession.self) private var terminal
    @State private var command = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("TERMINAL") {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                Circle()
                    .fill(terminal.isRunning ? Color.green.opacity(0.75) : Color.red.opacity(0.75))
                    .frame(width: 6, height: 6)
            } trailing: {
                HStack(spacing: 8) {
                    Button { terminal.interrupt() } label: {
                        Image(systemName: "stop.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Interrupt Running Command (Ctrl+C)")
                    Button("Clear") { terminal.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                    Button { terminal.restart() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Restart Terminal")
                }
                .foregroundStyle(RollCodeTheme.secondaryText)
            }
            .background(RollCodeTheme.windowBackground)

            Divider().overlay(RollCodeTheme.divider)

            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    Text(terminal.output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(RollCodeTheme.primaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .id("terminal-bottom")
                }
                .onChange(of: terminal.output) { _, _ in
                    proxy.scrollTo("terminal-bottom", anchor: .bottom)
                }
            }

            HStack(spacing: 7) {
                Text("❯")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(RollCodeTheme.accent)
                TextField("Enter a command", text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .focused($inputFocused)
                    .onSubmit(runCommand)
                    .onKeyPress(.upArrow) {
                        command = terminal.previousCommand()
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        command = terminal.nextCommand()
                        return .handled
                    }
            }
            .padding(.horizontal, 10)
            .frame(height: 29)
            .background(RollCodeTheme.elevatedBackground)
            .onTapGesture { inputFocused = true }
        }
        .background(RollCodeTheme.windowBackground)
    }

    private func runCommand() {
        terminal.send(command)
        command = ""
    }
}
