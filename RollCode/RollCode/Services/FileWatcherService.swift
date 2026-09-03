import Foundation
import os

@MainActor
final class FileWatcherService {
    private let logger = Logger(subsystem: "com.rollprojects.RollCode", category: "filesystem")
    nonisolated(unsafe) private var eventStream: FSEventStreamRef?
    private let url: URL
    private let onChange: @MainActor () -> Void

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
        startWatching()
    }

    deinit {
        stopWatching()
    }

    func startWatching() {
        stopWatching()

        let pathsToWatch = [url.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<FileWatcherService>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, clientInfo, numEvents, eventPaths, eventFlags, _) in
                guard let clientInfo else { return }
                let watcher = Unmanaged<FileWatcherService>.fromOpaque(clientInfo).takeUnretainedValue()
                Task { @MainActor in
                    watcher.onChange()
                }
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else {
            logger.error("Could not create file watcher stream")
            return
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.eventStream = stream
        logger.debug("Started file watcher")
    }

    nonisolated func stopWatching() {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }
    }
}
