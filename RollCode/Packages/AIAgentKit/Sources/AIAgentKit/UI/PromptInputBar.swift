import SwiftUI

public struct PromptInputBar: View {
    @Binding public var text: String
    public var placeholder: String
    public var isRunning: Bool
    public var canSubmit: Bool
    public var onSubmit: () -> Void
    public var onStop: () -> Void
    public var onTextChange: ((String) -> Void)?

    public init(
        text: Binding<String>,
        placeholder: String = "Ask AI to change this project… (Shift+Return for newline)",
        isRunning: Bool,
        canSubmit: Bool,
        onSubmit: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onTextChange: ((String) -> Void)? = nil
    ) {
        self._text = text
        self.placeholder = placeholder
        self.isRunning = isRunning
        self.canSubmit = canSubmit
        self.onSubmit = onSubmit
        self.onStop = onStop
        self.onTextChange = onTextChange
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 7) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.88))
                .lineLimit(1...6)
                .padding(8)
                .background(Color(red: 0.075, green: 0.078, blue: 0.09))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08)))
                .onSubmit {
                    if canSubmit {
                        onSubmit()
                    }
                }
                .onChange(of: text) { _, newValue in
                    onTextChange?(newValue)
                }

            if isRunning {
                Button(action: onStop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.red.opacity(0.85))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
                .help("Stop Generation")
            } else {
                Button(action: onSubmit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(canSubmit ? Color(red: 0.40, green: 0.61, blue: 0.98) : Color.white.opacity(0.25))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .padding(.bottom, 4)
                .help("Send Prompt (Return)")
            }
        }
    }
}
