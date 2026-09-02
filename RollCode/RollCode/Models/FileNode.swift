import Foundation

struct FileNode: Identifiable, Hashable, Sendable {
    let url: URL
    let isDirectory: Bool
    var children: [FileNode]?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var iconName: String {
        if isDirectory { return "folder.fill" }
        return CodeLanguage(url: url).systemImageName
    }

    static let ignoredDirectoryNames: Set<String> = [
        ".git", ".build", ".swiftpm", "DerivedData", "node_modules", "Pods"
    ]

    static func buildTree(at url: URL, fileManager: FileManager = .default) -> FileNode {
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

    func matchingFiles(_ query: String) -> [FileNode] {
        let normalized = query.trimmed
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

    var flattenedFiles: [FileNode] {
        if !isDirectory { return [self] }
        return (children ?? []).flatMap(\.flattenedFiles)
    }
}

extension URL {
    func relativePath(from base: URL?) -> String {
        guard let base else { return path }
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard path.hasPrefix(basePath) else { return path }
        return String(path.dropFirst(basePath.count))
    }

    func relativeParentPath(from base: URL?) -> String {
        let parent = deletingLastPathComponent()
        var relative = String(parent.relativePath(from: base).trimmingPrefix("/"))
        if relative.hasSuffix("/") {
            relative.removeLast()
        }
        return relative.isEmpty ? "." : relative
    }

    var modificationDate: Date? {
        var url = self
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
