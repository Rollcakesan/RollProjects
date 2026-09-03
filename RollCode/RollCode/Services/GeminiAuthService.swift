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
    private(set) var isLoggingIn = false
    private let geminiDirURL: URL
    private let isCLIAvailable: () -> Bool
    private let defaults: UserDefaults
    @ObservationIgnored private var activeLoginProcess: Process?

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

    func loginWithBrowser() {
        guard !isLoggingIn else { return }
        guard let corePath = Self.findGeminiCorePath() else {
            return
        }

        let nodePath = Self.findNodePath() ?? "/opt/homebrew/bin/node"
        guard FileManager.default.fileExists(atPath: nodePath) else { return }

        isLoggingIn = true

        let script = """
        import("file://\(corePath)").then(async m => {
            await m.clearCachedCredentialFile();
            await m.getOauthClient();
            process.exit(0);
        }).catch(err => {
            console.error(err);
            process.exit(1);
        });
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = ["--input-type=module", "-e", script]

        var env = ProcessInfo.processInfo.environment
        var paths = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        if !paths.contains("/opt/homebrew/bin") {
            paths.insert("/opt/homebrew/bin", at: 0)
        }
        env["PATH"] = paths.joined(separator: ":")
        process.environment = env
        activeLoginProcess = process

        Task { @MainActor [weak self] in
            do {
                try process.run()
                await Task.detached(priority: .userInitiated) {
                    process.waitUntilExit()
                }.value
            } catch {}

            self?.isLoggingIn = false
            self?.activeLoginProcess = nil
            self?.refresh()
        }
    }

    func cancelLogin() {
        activeLoginProcess?.terminate()
        activeLoginProcess = nil
        isLoggingIn = false
    }

    func logout() {
        cancelLogin()
        let credsURL = geminiDirURL.appending(path: "oauth_creds.json")
        try? FileManager.default.removeItem(at: credsURL)
        storedAPIKey = ""
        refresh()
    }

    private static func findNodePath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func findGeminiCorePath() -> String? {
        let candidates = [
            "/opt/homebrew/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/index.js",
            "/usr/local/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/index.js",
            "/opt/homebrew/lib/node_modules/@google/gemini-cli-core/dist/src/index.js"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }
}
