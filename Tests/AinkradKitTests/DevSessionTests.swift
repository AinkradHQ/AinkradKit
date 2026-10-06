import Foundation
import Testing

@testable import ainkrad

// MARK: - Fakes

/// Records every build call; can be made to throw once via `nextBuildError`
/// (consumed on the next `build` call, as if a single bad edit was made)
/// or persistently via `alwaysThrows`.
private final class FakeBuilder: DevSessionBuilding {
    private(set) var buildCount = 0
    private(set) var projectDirs: [URL] = []
    var nextBuildError: Error?
    var bundleURL = URL(fileURLWithPath: "/tmp/ainkrad-dev-tests/fake.bundle")

    func build(projectDir: URL) throws -> URL {
        buildCount += 1
        projectDirs.append(projectDir)
        if let error = nextBuildError {
            nextBuildError = nil
            throw error
        }
        return bundleURL
    }
}

private final class FakeValidator: DevSessionValidating {
    private(set) var validateCount = 0
    var nextValidationError: Error?

    func validate(bundleURL: URL) throws {
        validateCount += 1
        if let error = nextValidationError {
            nextValidationError = nil
            throw error
        }
    }
}

private final class FakeLauncher: DevSessionLaunching {
    private(set) var launchCalls: [URL] = []
    private(set) var relaunchCalls: [URL] = []

    func launch(bundleURL: URL) throws { launchCalls.append(bundleURL) }
    func relaunch(bundleURL: URL) throws { relaunchCalls.append(bundleURL) }
}

/// A change-source the test drives directly: `fire()` simulates one raw
/// filesystem change notification, exactly as `FileWatcher` would deliver
/// one, but with no real FSEvents/DispatchSource involved.
private final class FakeChangeSource: DevSessionChangeSource {
    var onChange: (() -> Void)?
    private(set) var startCalled = false
    private(set) var stopCalled = false

    func start() throws { startCalled = true }
    func stop() { stopCalled = true }

    func fire() { onChange?() }
}

/// A deterministic stand-in for the real (`DispatchQueue`-based) scheduler.
/// `debounce` mirrors the real contract — each call replaces whatever was
/// previously pending — but nothing runs until the test explicitly calls
/// `advance()`, which simulates "the debounce window elapsed with no
/// further changes" exactly once. No real clock or sleep is involved.
private final class ManualScheduler: DevSessionScheduler {
    private(set) var debounceCallCount = 0
    private var pendingWork: (() -> Void)?

    func debounce(interval: TimeInterval, _ work: @escaping () -> Void) {
        debounceCallCount += 1
        pendingWork = work
    }

    func advance() {
        let work = pendingWork
        pendingWork = nil
        work?()
    }
}

private struct FakeValidationError: Error, CustomStringConvertible {
    let description: String
}

// MARK: - Tests

@Test func devSessionRunsInitialBuildValidateLaunchThenDebouncesABurstToExactlyOneRebuild() throws {
    let builder = FakeBuilder()
    let validator = FakeValidator()
    let launcher = FakeLauncher()
    let changeSource = FakeChangeSource()
    let scheduler = ManualScheduler()

    let session = DevSession(
        builder: builder, validator: validator, launcher: launcher,
        changeSource: changeSource, scheduler: scheduler
    )

    let projectDir = URL(fileURLWithPath: "/tmp/ainkrad-dev-tests/example-project")
    try session.run(projectDir: projectDir)

    // Happy path: exactly one build, one validate, one launch.
    #expect(builder.buildCount == 1)
    #expect(validator.validateCount == 1)
    #expect(launcher.launchCalls == [builder.bundleURL])
    #expect(launcher.relaunchCalls.isEmpty)
    #expect(changeSource.startCalled)

    // A burst of file changes within the debounce window: each re-arms the
    // debounce timer (5 calls to the scheduler) but nothing has rebuilt yet.
    for _ in 0..<5 { changeSource.fire() }
    #expect(scheduler.debounceCallCount == 5)
    #expect(builder.buildCount == 1)
    #expect(launcher.relaunchCalls.isEmpty)

    // The debounce window elapses exactly once: exactly one rebuild+relaunch,
    // not five.
    scheduler.advance()

    #expect(builder.buildCount == 2)
    #expect(validator.validateCount == 2)
    #expect(launcher.launchCalls.count == 1)
    #expect(launcher.relaunchCalls == [builder.bundleURL])
}

@Test func devSessionKeepsThePreviousSessionAndSurfacesTheErrorWhenARebuildFails() throws {
    let builder = FakeBuilder()
    let validator = FakeValidator()
    let launcher = FakeLauncher()
    let changeSource = FakeChangeSource()
    let scheduler = ManualScheduler()
    var reportedErrors: [String] = []

    let session = DevSession(
        builder: builder, validator: validator, launcher: launcher,
        changeSource: changeSource, scheduler: scheduler,
        reportError: { reportedErrors.append($0) }
    )

    try session.run(projectDir: URL(fileURLWithPath: "/tmp/ainkrad-dev-tests/example-project"))
    #expect(launcher.launchCalls.count == 1)

    // A build failure on rebuild: previous session must be left running.
    builder.nextBuildError = BundleBuilderError(description: "compile error: unexpected token")
    changeSource.fire()
    scheduler.advance()

    #expect(builder.buildCount == 2)
    #expect(launcher.relaunchCalls.isEmpty, "a failed rebuild must never relaunch")
    #expect(launcher.launchCalls.count == 1, "the original launch must not be duplicated")
    #expect(reportedErrors.count == 1)
    #expect(reportedErrors[0].contains("compile error: unexpected token"))

    // A validation failure on rebuild: same resilience.
    validator.nextValidationError = FakeValidationError(description: "missing CFBundleExecutable")
    changeSource.fire()
    scheduler.advance()

    #expect(builder.buildCount == 3)
    // The failed-build cycle above never reached validate; this is the
    // second call overall (the first being the initial launch).
    #expect(validator.validateCount == 2)
    #expect(launcher.relaunchCalls.isEmpty, "a failed validation must never relaunch")
    #expect(reportedErrors.count == 2)
    #expect(reportedErrors[1].contains("missing CFBundleExecutable"))

    // A subsequent good rebuild still succeeds and relaunches normally.
    changeSource.fire()
    scheduler.advance()

    #expect(launcher.relaunchCalls == [builder.bundleURL])
    #expect(reportedErrors.count == 2)
}

@Test func devSessionThrowsAndNeverLaunchesWhenTheInitialBuildFails() throws {
    let builder = FakeBuilder()
    builder.nextBuildError = BundleBuilderError(description: "initial build boom")
    let launcher = FakeLauncher()
    let changeSource = FakeChangeSource()

    let session = DevSession(
        builder: builder, validator: FakeValidator(), launcher: launcher,
        changeSource: changeSource, scheduler: ManualScheduler()
    )

    #expect(throws: BundleBuilderError.self) {
        try session.run(projectDir: URL(fileURLWithPath: "/tmp/ainkrad-dev-tests/example-project"))
    }
    #expect(launcher.launchCalls.isEmpty)
    #expect(changeSource.startCalled == false, "must not start watching if the initial launch never happened")
}

@Test func devSessionThrowsAndNeverLaunchesWhenTheInitialValidationFails() throws {
    let builder = FakeBuilder()
    let validator = FakeValidator()
    validator.nextValidationError = FakeValidationError(description: "initial validation boom")
    let launcher = FakeLauncher()

    let session = DevSession(
        builder: builder, validator: validator, launcher: launcher,
        changeSource: FakeChangeSource(), scheduler: ManualScheduler()
    )

    #expect(throws: FakeValidationError.self) {
        try session.run(projectDir: URL(fileURLWithPath: "/tmp/ainkrad-dev-tests/example-project"))
    }
    #expect(launcher.launchCalls.isEmpty)
}
