import ArgumentParser
import Foundation

/// `ainkrad dev` — a thin front-end to sub-project C (the Dev Host): build
/// → validate → launch the Dev Host with the bundle, then watch the project
/// for changes and rebuild+relaunch on each debounced batch. All
/// orchestration logic lives in `DevSession`; this command's only jobs are
/// locating the Dev Host and wiring `DevSession`'s real collaborators.
struct Dev: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dev",
        abstract: "Build, validate, launch, and live-reload an Ainkrad App in the Dev Host."
    )

    @Argument(help: "Path to the app's project directory. Defaults to the current directory.")
    var projectDir: String?

    func run() throws {
        let directory = URL(fileURLWithPath: projectDir ?? ".")

        guard let devHostURL = Dev.locateDevHost() else {
            printError(Dev.devHostNotInstalledMessage)
            throw ExitCode(1)
        }

        let session = DevSession(
            builder: RealDevSessionBuilder(),
            validator: RealDevSessionValidator(),
            launcher: DevHostProcessLauncher(devHostURL: devHostURL),
            changeSource: FileWatcher(directory: directory),
            scheduler: DispatchQueueDebounceScheduler()
        )
        try session.run(projectDir: directory)

        // `DevSession.run` only performs the initial launch and arms the
        // watcher; park this thread forever so the process stays alive while
        // the watcher keeps firing.
        //
        // Crucially, the keep-alive must NOT depend on the main run loop or
        // the main dispatch queue. `ainkrad`'s entry point is an async
        // top-level `main` (see main.swift), so the main thread is owned by
        // Swift concurrency's main-actor executor — there is no running
        // `CFRunLoop` draining `DispatchQueue.main`. Both `RunLoop.run()` and
        // `CFRunLoopRun()` therefore return immediately (no sources), and
        // `dispatchMain()` traps. The watcher and its debounce run on their
        // own background queues (see `FileWatcher` and
        // `DispatchQueueDebounceScheduler`), so all this thread must do is
        // block: a semaphore that is never signalled parks it cleanly until
        // the developer Ctrl-Cs.
        DispatchSemaphore(value: 0).wait()
    }

    /// Sub-project C is not built yet on every machine, so this is a real
    /// lookup, not a hardcoded assumption: an `AINKRAD_DEV_HOST_PATH`
    /// environment override first (for developers building it elsewhere),
    /// then the documented default install location.
    static func locateDevHost() -> URL? {
        let fileManager = FileManager.default
        if let overridePath = ProcessInfo.processInfo.environment["AINKRAD_DEV_HOST_PATH"] {
            let url = URL(fileURLWithPath: overridePath)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
        let defaultURL = URL(fileURLWithPath: "/Applications/AinkradDevHost.app")
        return fileManager.fileExists(atPath: defaultURL.path) ? defaultURL : nil
    }

    static let devHostNotInstalledMessage =
        "Dev Host not installed. Build sub-project C (AinkradDevHost) and either install it "
        + "at /Applications/AinkradDevHost.app, or point AINKRAD_DEV_HOST_PATH at its .app bundle."
}

// MARK: - Real DevSession collaborators

/// Wraps the real `BundleBuilder` behind `DevSessionBuilding`.
private struct RealDevSessionBuilder: DevSessionBuilding {
    private let bundleBuilder = BundleBuilder()

    func build(projectDir: URL) throws -> URL {
        try bundleBuilder.build(projectDir: projectDir)
    }
}

/// Wraps the real `Validate.check(bundleURL:inspector:)` behind
/// `DevSessionValidating` — the SAME validation path `ainkrad validate`
/// runs, so a bundle `ainkrad dev` launches cannot diverge from one
/// `ainkrad validate` would accept.
private struct RealDevSessionValidator: DevSessionValidating {
    private let inspector = BundleInspector()

    func validate(bundleURL: URL) throws {
        try Validate.check(bundleURL: bundleURL, inspector: inspector)
    }
}

/// Launches and relaunches `AinkradDevHost.app`'s executable directly
/// (rather than via `open`, which would detach and hide the child's
/// stdout/stderr from the developer's terminal), passing the bundle to load
/// as `--bundle <path>`. On relaunch, the newly-spawned process replaces
/// the previous one only after successfully starting.
private final class DevHostProcessLauncher: DevSessionLaunching {
    private let devHostURL: URL
    private var runningProcess: Process?

    init(devHostURL: URL) {
        self.devHostURL = devHostURL
    }

    func launch(bundleURL: URL) throws {
        runningProcess = try DevHostProcessLauncher.spawn(devHostURL: devHostURL, bundleURL: bundleURL)
    }

    func relaunch(bundleURL: URL) throws {
        let previousProcess = runningProcess
        let nextProcess = try DevHostProcessLauncher.spawn(devHostURL: devHostURL, bundleURL: bundleURL)
        previousProcess?.terminate()
        runningProcess = nextProcess
    }

    private static func spawn(devHostURL: URL, bundleURL: URL) throws -> Process {
        let executableURL = devHostURL.appendingPathComponent("Contents/MacOS/AinkradDevHost")
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--bundle", bundleURL.path]
        try process.run()
        return process
    }
}

/// The real `DevSessionScheduler`: debounces on the main `DispatchQueue` by
/// cancelling any previously scheduled work item before scheduling the new
/// one, exactly the contract `DevSessionTests`' `ManualScheduler` fake
/// mirrors deterministically.
private final class DispatchQueueDebounceScheduler: DevSessionScheduler {
    private var pendingWorkItem: DispatchWorkItem?

    /// A dedicated serial queue, never `DispatchQueue.main`: `ainkrad dev`'s
    /// main thread is owned by Swift concurrency's main-actor executor and
    /// never drains the main queue (see the keep-alive note in `Dev.run`),
    /// so work scheduled on `.main` would never fire.
    private let queue = DispatchQueue(label: "com.ainkrad.dev.debounce")

    func debounce(interval: TimeInterval, _ work: @escaping () -> Void) {
        pendingWorkItem?.cancel()
        let workItem = DispatchWorkItem(block: work)
        pendingWorkItem = workItem
        queue.asyncAfter(deadline: .now() + interval, execute: workItem)
    }
}
