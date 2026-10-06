import Foundation

/// A `DevSession`-path failure not already carrying its own error type
/// (e.g. a watch-source that couldn't start).
struct DevSessionError: Error, CustomStringConvertible {
    let description: String
}

/// Builds the app for `projectDir`, returning the built bundle's URL.
/// The real implementation wraps `BundleBuilder`; tests inject a fake that
/// can throw to simulate a bad build without touching xcodebuild.
protocol DevSessionBuilding {
    func build(projectDir: URL) throws -> URL
}

/// Validates a built bundle. The real implementation wraps
/// `Validate.check(bundleURL:inspector:)`; tests inject a fake that can
/// throw to simulate an invalid bundle without touching the filesystem.
protocol DevSessionValidating {
    func validate(bundleURL: URL) throws
}

/// Starts (and restarts) the Dev Host process for a bundle. `launch` is the
/// very first start of a session; `relaunch` replaces an already-running
/// session after a successful rebuild. Kept as two methods (rather than
/// one) so tests can assert which one fired.
protocol DevSessionLaunching {
    func launch(bundleURL: URL) throws
    func relaunch(bundleURL: URL) throws
}

/// A source of raw (un-debounced) filesystem change notifications.
/// `DevSession` owns debouncing itself (via the injected `DevSessionScheduler`)
/// so tests can fire synthetic events and control time deterministically.
/// The real implementation is `FileWatcher`; class-bound so both it and test
/// fakes can be handed to `DevSession` by reference and fire `onChange`
/// asynchronously (real) or synchronously (fake).
protocol DevSessionChangeSource: AnyObject {
    var onChange: (() -> Void)? { get set }
    func start() throws
    func stop()
}

/// Schedules debounced work. `debounce` cancels any previously scheduled
/// work from a prior call and schedules `work` to run after `interval`
/// elapses with no further calls — the standard debounce contract. Real
/// implementation uses `DispatchQueue`; tests inject a manual scheduler so
/// "the debounce window elapsed" is a single deterministic method call
/// rather than a real sleep.
protocol DevSessionScheduler {
    func debounce(interval: TimeInterval, _ work: @escaping () -> Void)
}

/// Orchestrates `ainkrad dev`: build → validate → launch the Dev Host, then
/// watch for filesystem changes and, after they settle (debounced), rebuild
/// and validate again before relaunching. A failed rebuild or validation
/// leaves the previously-launched session running untouched — the developer
/// keeps working against the last good build — and the failure is surfaced
/// via `reportError` rather than thrown, since watching continues.
///
/// Every collaborator is injected so this type can be exercised without a
/// real GUI, `xcodebuild`, or filesystem events — see `DevSessionTests`.
struct DevSession {
    private let builder: DevSessionBuilding
    private let validator: DevSessionValidating
    private let launcher: DevSessionLaunching
    private let changeSource: DevSessionChangeSource
    private let scheduler: DevSessionScheduler
    private let debounceInterval: TimeInterval
    private let reportError: (String) -> Void

    init(
        builder: DevSessionBuilding,
        validator: DevSessionValidating,
        launcher: DevSessionLaunching,
        changeSource: DevSessionChangeSource,
        scheduler: DevSessionScheduler,
        debounceInterval: TimeInterval = 0.3,
        reportError: @escaping (String) -> Void = { printError($0) }
    ) {
        self.builder = builder
        self.validator = validator
        self.launcher = launcher
        self.changeSource = changeSource
        self.scheduler = scheduler
        self.debounceInterval = debounceInterval
        self.reportError = reportError
    }

    /// Runs the initial build → validate → launch, then starts watching.
    /// A failure at this stage (nothing is running yet to preserve) is
    /// thrown to the caller. Once watching starts, this method returns;
    /// the caller (the real `Dev` command) is responsible for keeping the
    /// process alive (e.g. running the run loop) so the change source can
    /// keep delivering events.
    func run(projectDir: URL) throws {
        let bundleURL = try builder.build(projectDir: projectDir)
        try validator.validate(bundleURL: bundleURL)
        try launcher.launch(bundleURL: bundleURL)

        let builder = self.builder
        let validator = self.validator
        let launcher = self.launcher
        let scheduler = self.scheduler
        let debounceInterval = self.debounceInterval
        let reportError = self.reportError

        changeSource.onChange = {
            scheduler.debounce(interval: debounceInterval) {
                DevSession.rebuildAndRelaunch(
                    projectDir: projectDir,
                    builder: builder,
                    validator: validator,
                    launcher: launcher,
                    reportError: reportError
                )
            }
        }
        try changeSource.start()
    }

    /// One rebuild cycle triggered by a settled batch of file changes. On
    /// any failure, the previous (already-running) session is left alone —
    /// `launcher.relaunch` is simply never called for this cycle — and the
    /// failure is reported so watching can continue.
    private static func rebuildAndRelaunch(
        projectDir: URL,
        builder: DevSessionBuilding,
        validator: DevSessionValidating,
        launcher: DevSessionLaunching,
        reportError: (String) -> Void
    ) {
        do {
            let bundleURL = try builder.build(projectDir: projectDir)
            try validator.validate(bundleURL: bundleURL)
            try launcher.relaunch(bundleURL: bundleURL)
        } catch {
            reportError("ainkrad dev: rebuild failed, keeping previous session running: \(error)")
        }
    }
}
