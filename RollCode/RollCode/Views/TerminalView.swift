import SwiftUI

struct TerminalView: View {
    @Environment(TerminalSession.self) private var terminal
    @State private var command = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            headerBar

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
                .onChange(of: terminal.activeTabID) { _, _ in
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

    private var headerBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(terminal.tabs) { tab in
                        tabButton(tab)
                    }

                    Button {
                        terminal.createTab()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(RollCodeTheme.secondaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New Terminal Tab")
                }
                .padding(.horizontal, 6)
            }

            Spacer()

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
                .help("Restart Active Terminal")
            }
            .foregroundStyle(RollCodeTheme.secondaryText)
            .padding(.trailing, 10)
        }
        .frame(height: 30)
        .background(RollCodeTheme.windowBackground)
    }

    private func tabButton(_ tab: TerminalInstance) -> some View {
        let isSelected = (terminal.activeTabID == tab.id)
        return HStack(spacing: 5) {
            Circle()
                .fill(tab.isRunning ? Color.green.opacity(0.85) : Color.red.opacity(0.6))
                .frame(width: 6, height: 6)

            Text(tab.title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? RollCodeTheme.primaryText : RollCodeTheme.secondaryText)

            if terminal.tabs.count > 1 {
                Button {
                    terminal.closeTab(id: tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8))
                        .foregroundStyle(RollCodeTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(isSelected ? RollCodeTheme.elevatedBackground : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            terminal.selectTab(id: tab.id)
        }
    }

    private func runCommand() {
        terminal.send(command)
        command = ""
    }
}
