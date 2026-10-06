import CoreServices
import Foundation

/// The real `DevSessionChangeSource`: watches `directory` for filesystem
/// activity via an FSEvents stream, and calls `onChange` for each raw
/// notification. Deliberately dumb — no debouncing, no diffing of which
/// file changed — because `DevSession` owns debouncing (via its injected
/// `DevSessionScheduler`) so that logic can be unit-tested without FSEvents.
///
/// FSEvents (rather than a single `DispatchSource` on the directory's own
/// fd) is the correct API here because it is natively **recursive**: it
/// reports changes anywhere under `directory`'s subtree, not just to
/// `directory`'s own entries. A scaffolded Ainkrad app's editable sources
/// live two levels down (`Sources/Plugin/PluginApp.swift`), so a
/// non-recursive watch on the project root would never see the mainline
/// "edit a source file and save" event — the whole point of `ainkrad dev`.
final class FileWatcher: DevSessionChangeSource {
    private let directory: URL
    private var stream: FSEventStreamRef?

    /// FSEvents delivers on a **dedicated background queue**, never
    /// `DispatchQueue.main`. `ainkrad`'s entry point is an async top-level
    /// `main` (see `main.swift`), so the main thread is driven by Swift
    /// concurrency's main-actor executor, not a running `CFRunLoop`/main
    /// dispatch queue. Callbacks scheduled on `DispatchQueue.main` would
    /// therefore never be drained (the process would sit idle, deaf to
    /// every file change). A private serial queue is drained by libdispatch
    /// independently of whatever owns the main thread.
    private let deliveryQueue = DispatchQueue(label: "com.ainkrad.filewatcher")

    var onChange: (() -> Void)?

    init(directory: URL) {
        self.directory = directory
    }

    func start() throws {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let pathsToWatch = [directory.path] as CFArray
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                FileWatcher.eventCallback,
                &context,
                pathsToWatch,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.05,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            )
        else {
            throw DevSessionError(
                description: "Could not create an FSEvents stream to watch \(directory.path) for changes."
            )
        }

        FSEventStreamSetDispatchQueue(stream, deliveryQueue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw DevSessionError(
                description: "Could not start the FSEvents stream watching \(directory.path)."
            )
        }

        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }

    /// The C callback FSEvents invokes on the stream's delivery queue for
    /// every batch of events. `clientCallBackInfo` is the `FileWatcher`
    /// instance passed in unretained via the stream's context. We decode the
    /// changed paths (not to diff them, but to filter out build noise — see
    /// `onlyBuildArtifactsChanged`) and collapse the whole batch into at most
    /// one `onChange` call; `DevSession`'s injected scheduler is what turns a
    /// burst of these into a single rebuild.
    private static let eventCallback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, _, _ in
        guard let clientCallBackInfo else { return }
        let watcher = Unmanaged<FileWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()

        // Without kFSEventStreamCreateFlagUseCFTypes, `eventPaths` is a C
        // array of C strings (one per changed path).
        let cPaths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        var paths: [String] = []
        paths.reserveCapacity(numEvents)
        for index in 0..<numEvents {
            paths.append(String(cString: cPaths[index]))
        }

        // Break the rebuild loop: `ainkrad dev`'s own build regenerates the
        // `.xcodeproj` and writes DerivedData under the watched tree, and
        // those writes arrive here as events. Firing on them would trigger
        // another build, whose writes fire again — forever. A real developer
        // edit is always accompanied by at least one non-artifact path, so we
        // fire only when the batch contains one.
        guard !FileWatcher.onlyBuildArtifactsChanged(paths) else { return }
        watcher.onChange?()
    }

    /// True when every path in a batch is something the build (or VCS/tooling)
    /// produces, so the batch must not trigger a rebuild. An empty batch is
    /// treated as ignorable. Pure and static so it is unit-tested directly,
    /// without FSEvents.
    static func onlyBuildArtifactsChanged(_ paths: [String]) -> Bool {
        !paths.contains { !FileWatcher.isBuildArtifact($0) }
    }

    /// True for a path the build, version control, or the OS writes on its
    /// own — never something a developer edits to mean "reload me".
    static func isBuildArtifact(_ path: String) -> Bool {
        for component in (path as NSString).pathComponents {
            if FileWatcher.ignoredComponents.contains(component) { return true }
            if component.hasSuffix(".xcodeproj") || component.hasSuffix(".xcworkspace") { return true }
        }
        return false
    }

    /// Path components whose entire subtree is build/VCS/OS output. Kept in
    /// sync with `BundleBuilder` (which writes DerivedData into
    /// `.ainkrad-build`) and the conventions of the surrounding toolchain.
    private static let ignoredComponents: Set<String> = [
        ".ainkrad-build",  // BundleBuilder's -derivedDataPath (holds the built .bundle)
        ".build",  // SwiftPM output
        "DerivedData",  // Xcode's default DerivedData, if ever used
        ".git",  // version control internals
        ".DS_Store",  // Finder metadata
    ]
}
