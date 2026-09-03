import Foundation
import Observation

enum GeminiAuthStatus: Equatable, Sendable {
    case loggedIn(account: String?)
    case apiKey(masked: String)
    case unauthenticated
    case cliNotInstalled

    var displayText: String {
        switch self {
        case .loggedIn(let account):
            if let account, !account.isEmpty {
                return "Google: \(account)"
            }
            return "Google Logged In"
        case .apiKey(let masked):
            return "API Key (\(masked))"
        case .unauthenticated:
            return "Not Logged In"
        case .cliNotInstalled:
            return "Gemini CLI Not Found"
        }
    }
}

@Observable
@MainActor
final class GeminiAuthService {
    private(set) var status: GeminiAuthStatus = .unauthenticated
    private let geminiDirURL: URL
    private let isCLIAvailable: () -> Bool
    private let defaults: UserDefaults

    static let apiKeyDefaultsKey = "RollCode_GeminiAPIKey"
    static let projectDefaultsKey = "RollCode_GeminiProjectID"

    init(
        geminiDirURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".gemini"),
        defaults: UserDefaults = .standard,
        isCLIAvailable: @escaping () -> Bool = { GeminiExecutableLocator.locate() != nil }
    ) {
        self.geminiDirURL = geminiDirURL
        self.defaults = defaults
        self.isCLIAvailable = isCLIAvailable
        refresh()
    }

    var storedAPIKey: String {
        get { defaults.string(forKey: Self.apiKeyDefaultsKey) ?? "" }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.apiKeyDefaultsKey)
            refresh()
        }
    }

    var storedProjectID: String {
        get { defaults.string(forKey: Self.projectDefaultsKey) ?? "" }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.projectDefaultsKey)
            refresh()
        }
    }

    func refresh() {
        guard isCLIAvailable() else {
            status = .cliNotInstalled
            return
        }

        let key = storedAPIKey
        if !key.isEmpty {
            let masked = key.count > 8 ? "\(key.prefix(4))…\(key.suffix(4))" : "••••"
            status = .apiKey(masked: masked)
            return
        }

        let credsURL = geminiDirURL.appending(path: "oauth_creds.json")
        if FileManager.default.fileExists(atPath: credsURL.path) {
            let accountIdURL = geminiDirURL.appending(path: "google_account_id")
            let accountId = (try? String(contentsOf: accountIdURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            status = .loggedIn(account: accountId)
            return
        }

        status = .unauthenticated
    }

    func requestLogin(in terminal: TerminalSession) {
        terminal.isVisible = true
        terminal.send("gemini\n")
    }

    func logout() {
        let credsURL = geminiDirURL.appending(path: "oauth_creds.json")
        try? FileManager.default.removeItem(at: credsURL)
        storedAPIKey = ""
        refresh()
    }
}
