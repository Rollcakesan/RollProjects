import Foundation

public extension URL {
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
