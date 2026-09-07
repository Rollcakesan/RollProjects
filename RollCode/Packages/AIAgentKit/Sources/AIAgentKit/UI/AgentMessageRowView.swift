import SwiftUI
import AppKit

public enum AIAgentColors {
    public static var windowBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.075, green: 0.078, blue: 0.09, alpha: 1)
                : NSColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
        })
    }

    public static var cardBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.145, green: 0.15, blue: 0.175, alpha: 1)
                : NSColor(red: 0.92, green: 0.925, blue: 0.94, alpha: 1)
        })
    }

    public static var activityBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.075, green: 0.078, blue: 0.09, alpha: 1)
                : NSColor(red: 0.94, green: 0.945, blue: 0.955, alpha: 1)
        })
    }

    public static var userBubbleBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.20, green: 0.27, blue: 0.40, alpha: 0.7)
                : NSColor(red: 0.85, green: 0.91, blue: 0.99, alpha: 0.9)
        })
    }

    public static var codeHeaderBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.145, green: 0.15, blue: 0.175, alpha: 0.8)
                : NSColor(red: 0.88, green: 0.89, blue: 0.91, alpha: 0.9)
        })
    }

    public static var codeBodyBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.115, green: 0.12, blue: 0.14, alpha: 1)
                : NSColor(red: 0.94, green: 0.945, blue: 0.96, alpha: 1)
        })
    }

    public static var inputBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.075, green: 0.078, blue: 0.09, alpha: 1)
                : NSColor(white: 1.0, alpha: 1)
        })
    }

    public static var divider: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(0.08)
                : NSColor.black.withAlphaComponent(0.08)
        })
    }

    public static var primaryText: Color {
        Color(nsColor: .labelColor)
    }

    public static var secondaryText: Color {
        Color(nsColor: .secondaryLabelColor)
    }

    public static var disabledText: Color {
        Color(nsColor: .disabledControlTextColor)
    }

    public static let accent = Color(red: 0.40, green: 0.61, blue: 0.98)
}

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
                            .foregroundStyle(AIAgentColors.primaryText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(content)
                            .font(.system(size: uiFontSize))
                            .foregroundStyle(AIAgentColors.primaryText)
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
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(AIAgentColors.divider))
    }

    private var roleColor: Color {
        switch message.role {
        case .user: return AIAgentColors.accent
        case .assistant:
            return message.senderName == "GEMINI" ? Color.blue.opacity(0.9) : Color.purple.opacity(0.9)
        case .system: return Color.orange.opacity(0.9)
        }
    }

    private var backgroundColor: Color {
        message.role == .user ? AIAgentColors.userBubbleBackground : AIAgentColors.cardBackground
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
                        .foregroundStyle(AIAgentColors.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !activity.detail.isEmpty {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8))
                            .foregroundStyle(AIAgentColors.secondaryText)
                    }
                }
                if isExpanded && !activity.detail.isEmpty {
                    Text(activity.detail)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(AIAgentColors.secondaryText)
                        .textSelection(.enabled)
                        .lineLimit(12)
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AIAgentColors.activityBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(AIAgentColors.divider))
        }
        .buttonStyle(.plain)
    }

    private var color: Color {
        switch activity.state {
        case .running: return AIAgentColors.accent
        case .completed: return Color.green.opacity(0.8)
        case .failed: return Color.red.opacity(0.85)
        }
    }
}
