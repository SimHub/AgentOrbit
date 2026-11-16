import CoreServices
import Foundation

final class FSEventsWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "de.agentkoordinator.fsevents", qos: .utility)
    private var debounceWorkItem: DispatchWorkItem?
    private let onChange: @Sendable () -> Void

    init(paths: [String], onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        start(paths: paths)
    }

    deinit {
        stop()
    }

    func update(paths: [String]) {
        stop()
        start(paths: paths)
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func start(paths: [String]) {
        let validPaths = Array(Set(paths.filter { PathResolver.existsDirectory(URL(fileURLWithPath: $0)) }))
        guard !validPaths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, _, _ in
            guard let clientCallBackInfo else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
            let pathsPointer = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)

            var hasRelevantChange = false
            for idx in 0..<numEvents {
                let path = String(cString: pathsPointer[idx])
                if !FSEventsWatcher.shouldIgnore(path: path) {
                    hasRelevantChange = true
                    break
                }
            }

            if hasRelevantChange {
                watcher.scheduleDebouncedNotify()
            }
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            validPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15,
            flags
        ) else {
            return
        }

        self.stream = newStream
        FSEventStreamSetDispatchQueue(newStream, queue)
        FSEventStreamStart(newStream)
    }

    private func scheduleDebouncedNotify() {
        queue.async { [weak self] in
            guard let self else { return }
            self.debounceWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.onChange()
            }
            self.debounceWorkItem = item
            self.queue.asyncAfter(deadline: .now() + 0.18, execute: item)
        }
    }

    private static func shouldIgnore(path: String) -> Bool {
        let ignoredSegments = [
            "/.build/",
            "/node_modules/",
            "/DerivedData/",
            "/.git/objects/",
            "/.tmp/",
            "/cache/"
        ]
        if ignoredSegments.contains(where: { path.contains($0) }) {
            return true
        }
        return path.hasSuffix(".DS_Store")
    }
}
