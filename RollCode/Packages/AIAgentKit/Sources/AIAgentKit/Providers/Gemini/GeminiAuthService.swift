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

    func effectiveProjectID(for workspaceURL: URL?) -> String? {
        let explicit = storedProjectID
        if !explicit.isEmpty { return explicit }

        if let envProject = ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"], !envProject.isEmpty {
            return envProject
        }

        // Read ~/.gemini/projects.json
        let projectsURL = geminiDirURL.appending(path: "projects.json")
        struct ProjectsConfig: Decodable {
            let projects: [String: String]?
        }
        guard FileManager.default.fileExists(atPath: projectsURL.path),
              let data = try? Data(contentsOf: projectsURL),
              let config = try? JSONDecoder().decode(ProjectsConfig.self, from: data),
              let projects = config.projects else {
            return nil
        }

        if let workspacePath = workspaceURL?.standardizedFileURL.path {
            if let matched = projects[workspacePath] {
                return matched
            }
            // Check prefix matches
            for (folder, proj) in projects where folder != "/" {
                if workspacePath.hasPrefix(folder) {
                    return proj
                }
            }
        }

        // Fallback to default project or first entry
        return projects["/"] ?? projects.values.first
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

    struct OAuthCredentialsFile: Codable, Sendable {
        let access_token: String?
        let refresh_token: String?
        let expiry_date: Double?
        let scope: String?
        let token_type: String?
    }

    func validOAuthAccessToken() async -> String? {
        let credsURL = geminiDirURL.appending(path: "oauth_creds.json")
        if FileManager.default.fileExists(atPath: credsURL.path),
           let data = try? Data(contentsOf: credsURL),
           let creds = try? JSONDecoder().decode(OAuthCredentialsFile.self, from: data) {
            let now = Date().timeIntervalSince1970 * 1000
            if let expiry = creds.expiry_date, expiry > (now + 60_000), let token = creds.access_token, !token.isEmpty {
                return token
            }
            if let token = creds.access_token, !token.isEmpty {
                return token
            }
        }

        return await fetchGCloudAccessToken()
    }

    private func fetchGCloudAccessToken() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["gcloud", "auth", "print-access-token"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let token, !token.isEmpty {
                            continuation.resume(returning: token)
                            return
                        }
                    }
                } catch {}
                continuation.resume(returning: nil)
            }
        }
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
