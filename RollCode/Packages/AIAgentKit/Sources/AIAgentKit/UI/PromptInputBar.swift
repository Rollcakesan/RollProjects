import SwiftUI
import AppKit

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
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .padding(.top, 4)
                        .padding(.leading, 4)
                        .allowsHitTesting(false)
                }
                AgentPromptTextViewRepresentable(
                    text: $text,
                    onSubmit: onSubmit,
                    onTextChange: onTextChange
                )
                .frame(minHeight: 28, maxHeight: 110)
            }
            .padding(4)
            .background(Color(red: 0.075, green: 0.078, blue: 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08)))

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

private struct AgentPromptTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onTextChange: ((String) -> Void)?

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
        textView.textColor = NSColor(white: 0.86, alpha: 1)
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
        var parent: AgentPromptTextViewRepresentable
        weak var textView: PromptTextView?

        init(_ parent: AgentPromptTextViewRepresentable) {
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
                if textView.hasMarkedText() {
                    return false
                }
                if let currentEvent = NSApp.currentEvent, currentEvent.modifierFlags.contains(.shift) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
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
