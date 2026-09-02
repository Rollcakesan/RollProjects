import Foundation
import Observation

enum CodexAuthStatus: Equatable, Sendable {
    case loggedIn(mode: String, email: String?, plan: String?)
    case apiKey
    case unauthenticated
    case cliNotInstalled

    var displayText: String {
        switch self {
        case .loggedIn(_, let email, let plan):
            if let email, let plan {
                return "\(email) (\(plan.capitalized))"
            } else if let email {
                return email
            } else {
                return "ChatGPT Logged In"
            }
        case .apiKey:
            return "API Key"
        case .unauthenticated:
            return "Not Logged In"
        case .cliNotInstalled:
            return "Codex CLI Not Found"
        }
    }
}

@Observable
@MainActor
final class CodexAuthService {
    private(set) var status: CodexAuthStatus = .unauthenticated
    private let authFileURL: URL
    private let isCLIAvailable: () -> Bool

    init(
        authFileURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/auth.json"),
        isCLIAvailable: @escaping () -> Bool = { CodexExecutableLocator.locate() != nil }
    ) {
        self.authFileURL = authFileURL
        self.isCLIAvailable = isCLIAvailable
        refresh()
    }

    func refresh() {
        guard isCLIAvailable() else {
            status = .cliNotInstalled
            return
        }

        guard FileManager.default.fileExists(atPath: authFileURL.path),
              let data = try? Data(contentsOf: authFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            status = .unauthenticated
            return
        }

        if let apiKey = json["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            status = .apiKey
            return
        }

        let authMode = json["auth_mode"] as? String ?? ""
        if authMode == "chatgpt", let tokens = json["tokens"] as? [String: Any], !tokens.isEmpty {
            var email: String?
            var plan: String?

            if let idToken = tokens["id_token"] as? String {
                let parts = idToken.split(separator: ".")
                if parts.count >= 2,
                   let payloadData = Data(base64Encoded: paddedBase64(String(parts[1]))),
                   let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
                    email = payload["email"] as? String
                    if let authDict = payload["https://api.openai.com/auth"] as? [String: Any] {
                        plan = authDict["chatgpt_plan_type"] as? String
                    }
                }
            }
            status = .loggedIn(mode: "ChatGPT", email: email, plan: plan)
            return
        }

        status = .unauthenticated
    }

    private func paddedBase64(_ string: String) -> String {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return base64
    }

    func requestLogin(in terminal: TerminalSession) {
        terminal.isVisible = true
        terminal.send("codex login")
    }

    func requestLogout(in terminal: TerminalSession) {
        terminal.isVisible = true
        terminal.send("codex logout")
    }
}
