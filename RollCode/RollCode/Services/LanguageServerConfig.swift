import Foundation

struct ResolvedLanguageServer: Hashable, Sendable {
    let identifier: String
    let executablePath: String
    let arguments: [String]
    let languageId: String

    var processIdentifier: String {
        ([identifier, executablePath] + arguments).joined(separator: "\u{0}")
    }
}

enum LanguageServerConfig {
    static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        paths.append(contentsOf: [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "\(home)/.cargo/bin",
            "\(home)/go/bin",
            "\(home)/.local/bin"
        ])
        environment["PATH"] = Array(NSOrderedSet(array: paths).compactMap { $0 as? String })
            .joined(separator: ":")
        return environment
    }

    static func resolve(for language: CodeLanguage, documentURL: URL? = nil) -> ResolvedLanguageServer? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path

        var searchDirectories = [
            "/usr/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "\(home)/.cargo/bin",
            "\(home)/go/bin",
            "\(home)/.local/bin"
        ]
        if let path = processEnvironment()["PATH"] {
            searchDirectories.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        searchDirectories = Array(NSOrderedSet(array: searchDirectories).compactMap { $0 as? String })

        let configs: [(id: String, names: [String], args: [String])]

        switch language {
        case .swift:
            configs = [("sourcekit-lsp", ["sourcekit-lsp"], [])]
        case .cFamily:
            configs = [
                ("sourcekit-lsp", ["sourcekit-lsp"], []),
                ("clangd", ["clangd"], ["--background-index"])
            ]
        case .javascript:
            configs = [("typescript-language-server", ["typescript-language-server"], ["--stdio"])]
        case .typescript:
            configs = [("typescript-language-server", ["typescript-language-server"], ["--stdio"])]
        case .python:
            configs = [
                ("pyright", ["pyright-langserver"], ["--stdio"]),
                ("pylsp", ["pylsp"], [])
            ]
        case .rust:
            configs = [("rust-analyzer", ["rust-analyzer"], [])]
        case .go:
            configs = [("gopls", ["gopls"], [])]
        case .html:
            configs = [("vscode-html-language-server", ["html-languageserver", "vscode-html-language-server"], ["--stdio"])]
        case .css:
            configs = [("vscode-css-language-server", ["css-languageserver", "vscode-css-language-server"], ["--stdio"])]
        case .json:
            configs = [("vscode-json-language-server", ["vscode-json-language-server"], ["--stdio"])]
        case .shell:
            configs = [("bash-language-server", ["bash-language-server"], ["start"])]
        case .yaml:
            configs = [("yaml-language-server", ["yaml-language-server"], ["--stdio"])]
        case .markdown, .plainText:
            return nil
        }

        let languageId = languageIdentifier(for: language, documentURL: documentURL)
        for config in configs {
            for name in config.names {
                if name.hasPrefix("/") && fileManager.isExecutableFile(atPath: name) {
                    return ResolvedLanguageServer(
                        identifier: config.id,
                        executablePath: URL(fileURLWithPath: name).standardizedFileURL.path,
                        arguments: config.args,
                        languageId: languageId
                    )
                }

                for dir in searchDirectories {
                    let fullPath = (dir as NSString).appendingPathComponent(name)
                    if fileManager.isExecutableFile(atPath: fullPath) {
                        return ResolvedLanguageServer(
                            identifier: config.id,
                            executablePath: URL(fileURLWithPath: fullPath).standardizedFileURL.path,
                            arguments: config.args,
                            languageId: languageId
                        )
                    }
                }
            }
        }

        return nil
    }

    static func languageIdentifier(for language: CodeLanguage, documentURL: URL? = nil) -> String {
        guard language == .cFamily else {
            switch language {
            case .javascript: return "javascript"
            case .typescript: return "typescript"
            case .shell: return "shellscript"
            case .plainText: return "plaintext"
            default: return language.rawValue
            }
        }

        switch documentURL?.pathExtension.lowercased() {
        case "cc", "cpp", "cxx", "hpp": return "cpp"
        case "m": return "objective-c"
        case "mm": return "objective-cpp"
        default: return "c"
        }
    }
}
