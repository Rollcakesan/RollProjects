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
              let data = try? Data(contentsOf: authFileURL) else {
            status = .unauthenticated
            return
        }

        struct AuthConfig: Decodable {
            struct Tokens: Decodable {
                let idToken: String?

                enum CodingKeys: String, CodingKey {
                    case idToken = "id_token"
                }
            }

            let apiKey: String?
            let authMode: String?
            let tokens: Tokens?

            enum CodingKeys: String, CodingKey {
                case apiKey = "OPENAI_API_KEY"
                case authMode = "auth_mode"
                case tokens
            }
        }

        struct JWTPayload: Decodable {
            struct AuthInfo: Decodable {
                let planType: String?

                enum CodingKeys: String, CodingKey {
                    case planType = "chatgpt_plan_type"
                }
            }

            let email: String?
            let auth: AuthInfo?

            enum CodingKeys: String, CodingKey {
                case email
                case auth = "https://api.openai.com/auth"
            }
        }

        guard let config = try? JSONDecoder().decode(AuthConfig.self, from: data) else {
            status = .unauthenticated
            return
        }

        if let apiKey = config.apiKey, !apiKey.isEmpty {
            status = .apiKey
            return
        }

        if config.authMode == "chatgpt", let tokens = config.tokens {
            var email: String?
            var plan: String?

            if let idToken = tokens.idToken {
                let parts = idToken.split(separator: ".")
                if parts.count >= 2,
                   let payloadData = Data(base64Encoded: paddedBase64(String(parts[1]))),
                   let jwt = try? JSONDecoder().decode(JWTPayload.self, from: payloadData) {
                    email = jwt.email
                    plan = jwt.auth?.planType
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

    func requestLogin(in terminal: (any TerminalCommandExecuting)? = nil) {
        guard let terminal else { return }
        terminal.isVisible = true
        terminal.send("codex login")
    }

    func requestLogout(in terminal: (any TerminalCommandExecuting)? = nil) {
        guard let terminal else { return }
        terminal.isVisible = true
        terminal.send("codex logout")
    }
}
