import SwiftUI

public struct AgentMessageRowView: View {
    public let message: AgentMessage
    public var uiFontSize: CGFloat

    public init(message: AgentMessage, uiFontSize: CGFloat = 13) {
        self.message = message
        self.uiFontSize = uiFontSize
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.displayTitle)
                .font(.system(size: max(uiFontSize - 3, 8.5), weight: .bold))
                .foregroundStyle(roleColor)

            let blocks = MarkdownBlockParser.parse(from: message.text)
            ForEach(blocks) { block in
                switch block {
                case .text(let content):
                    if let attributed = try? AttributedString(markdown: content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                        Text(attributed)
                            .font(.system(size: uiFontSize))
                            .foregroundStyle(Color(white: 0.88))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(content)
                            .font(.system(size: uiFontSize))
                            .foregroundStyle(Color(white: 0.88))
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
        case .user: return Color(red: 0.40, green: 0.61, blue: 0.98)
        case .assistant:
            return message.senderName == "GEMINI" ? Color.blue.opacity(0.9) : Color.purple.opacity(0.9)
        case .system: return Color.orange.opacity(0.9)
        }
    }

    private var backgroundColor: Color {
        message.role == .user ? Color(red: 0.20, green: 0.27, blue: 0.40).opacity(0.7) : Color(red: 0.145, green: 0.15, blue: 0.175)
    }
}

public struct AgentActivityCardView: View {
    public let activity: AgentActivity
    @State private var isExpanded = false

    public init(activity: AgentActivity) {
        self.activity = activity
    }

    public var body: some View {
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
                        .foregroundStyle(Color.white.opacity(0.55))
                        .textSelection(.enabled)
                        .lineLimit(12)
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.075, green: 0.078, blue: 0.09))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private var color: Color {
        switch activity.state {
        case .running: return Color(red: 0.40, green: 0.61, blue: 0.98)
        case .completed: return Color.green.opacity(0.8)
        case .failed: return Color.red.opacity(0.85)
        }
    }
}
