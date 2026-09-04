import Foundation

/// Represents a node in the hierarchical file tree.
public struct FileNode: Identifiable, Hashable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    public var children: [FileNode]?

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public var iconName: String {
        if isDirectory { return "folder.fill" }
        return FileNode.systemIcon(for: url)
    }

    public static let ignoredDirectoryNames: Set<String> = [
        ".git", ".build", ".swiftpm", "DerivedData", "node_modules", "Pods"
    ]

    public init(url: URL, isDirectory: Bool, children: [FileNode]? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.children = children
    }

    public static func buildTree(at url: URL, fileManager: FileManager = .default) -> FileNode {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]
        let childURLs = (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []

        let nodes = childURLs.compactMap { childURL -> FileNode? in
            guard let values = try? childURL.resourceValues(forKeys: keys) else { return nil }
            let isDirectory = values.isDirectory == true
            if isDirectory && ignoredDirectoryNames.contains(childURL.lastPathComponent) { return nil }
            if values.isSymbolicLink == true && isDirectory { return nil }

            return FileNode(
                url: childURL,
                isDirectory: isDirectory,
                children: isDirectory ? buildTree(at: childURL, fileManager: fileManager).children : nil
            )
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        return FileNode(url: url, isDirectory: true, children: nodes)
    }

    public func matchingFiles(_ query: String) -> [FileNode] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        var matches: [FileNode] = []
        if !isDirectory && name.localizedCaseInsensitiveContains(normalized) {
            matches.append(self)
        }
        for child in children ?? [] {
            matches.append(contentsOf: child.matchingFiles(normalized))
        }
        return matches
    }

    public var flattenedFiles: [FileNode] {
        if !isDirectory { return [self] }
        return (children ?? []).flatMap(\.flattenedFiles)
    }

    public static func systemIcon(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let filename = url.lastPathComponent.lowercased()
        if filename == "dockerfile" || filename.hasPrefix(".zsh") || filename.hasPrefix(".bash") {
            return "terminal"
        }
        switch ext {
        case "swift": return "swift"
        case "json", "jsonc": return "curlybraces"
        case "sh", "zsh", "bash": return "terminal"
        case "md", "markdown": return "text.document"
        case "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm": return "c.square"
        case "html", "htm", "css", "scss", "sass": return "globe"
        default: return "doc.text"
        }
    }
}

public extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
