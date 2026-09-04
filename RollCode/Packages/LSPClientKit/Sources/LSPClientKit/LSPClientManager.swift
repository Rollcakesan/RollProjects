import Foundation

@MainActor
public final class LSPManager {
    public static let shared = LSPManager()

    private struct ClientKey: Hashable {
        let rootPath: String
        let serverProcessIdentifier: String
    }

    private var activeClients: [ClientKey: LSPClient] = [:]
    private var unavailableClients: Set<ClientKey> = []

    public init() {}

    public func requestCompletions(
        for language: LSPDocumentLanguage,
        url: URL,
        text: String,
        line: Int,
        character: Int,
        workspaceURL: URL? = nil
    ) async -> [LSPCompletionItem] {
        let rootURL = (workspaceURL ?? url.deletingLastPathComponent()).standardizedFileURL
        guard let resolvedServer = LanguageServerConfig.resolve(for: language, documentURL: url),
              let client = client(for: resolvedServer, rootURL: rootURL) else { return [] }
        return await client.requestCompletions(
            url: url,
            text: text,
            languageId: resolvedServer.languageId,
            line: line,
            character: character
        )
    }

    public func formatDocument(
        for language: LSPDocumentLanguage,
        url: URL,
        text: String,
        tabWidth: Int,
        workspaceURL: URL? = nil
    ) async -> String? {
        let rootURL = (workspaceURL ?? url.deletingLastPathComponent()).standardizedFileURL
        guard let resolvedServer = LanguageServerConfig.resolve(for: language, documentURL: url),
              let client = client(for: resolvedServer, rootURL: rootURL) else { return nil }
        return await client.requestFormatting(
            url: url,
            text: text,
            languageId: resolvedServer.languageId,
            tabWidth: tabWidth
        )
    }

    public func activateWorkspace(_ workspaceURL: URL) {
        let rootPath = workspaceURL.standardizedFileURL.path
        let inactiveKeys = activeClients.keys.filter { $0.rootPath != rootPath }
        for key in inactiveKeys {
            activeClients.removeValue(forKey: key)?.stopServer()
        }
        unavailableClients = unavailableClients.filter { $0.rootPath == rootPath }
    }

    public func closeDocument(_ url: URL) {
        for client in activeClients.values {
            client.closeDocument(url)
        }
    }

    public func stopAllServers() {
        activeClients.values.forEach { $0.stopServer() }
        activeClients.removeAll()
        unavailableClients.removeAll()
    }

    private func client(for server: ResolvedLanguageServer, rootURL: URL) -> LSPClient? {
        let key = ClientKey(
            rootPath: rootURL.standardizedFileURL.path,
            serverProcessIdentifier: server.processIdentifier
        )
        if let existing = activeClients[key] {
            if existing.isRunning { return existing }
            activeClients.removeValue(forKey: key)
            unavailableClients.insert(key)
            return nil
        }
        guard !unavailableClients.contains(key),
              let client = LSPClient(server: server, rootURL: rootURL) else {
            unavailableClients.insert(key)
            return nil
        }
        activeClients[key] = client
        return client
    }
}
