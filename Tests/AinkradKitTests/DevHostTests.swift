import Foundation
import Testing

@testable import ainkrad

private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ainkrad-devhost-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("Dev.locateDevHost")
struct LocateDevHostTests {
    @Test("an override that exists wins over the default")
    func overrideWins() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = Dev.locateDevHost(
            environment: ["AINKRAD_DEV_HOST_PATH": dir.path],
            defaultURL: URL(fileURLWithPath: "/nonexistent/AinkradDevHost.app"))
        #expect(found?.path == dir.path)
    }

    @Test("an override that points at nothing is a miss, even with a default installed")
    func missingOverrideDoesNotFallThrough() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = Dev.locateDevHost(
            environment: ["AINKRAD_DEV_HOST_PATH": "/nonexistent/Host.app"], defaultURL: dir)
        #expect(found == nil)
    }

    @Test("without an override, the default is used only when it exists")
    func defaultLocation() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Dev.locateDevHost(environment: [:], defaultURL: dir)?.path == dir.path)
        #expect(
            Dev.locateDevHost(environment: [:], defaultURL: dir.appendingPathComponent("missing.app")) == nil)
    }
}

@Suite("DevHostProcessLauncher")
struct DevHostProcessLauncherTests {
    /// A fake `AinkradDevHost.app` whose executable records its arguments and
    /// then stays alive until terminated.
    private func makeFakeDevHost(in dir: URL, log: URL) throws -> URL {
        let app = dir.appendingPathComponent("AinkradDevHost.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("AinkradDevHost")
        try "#!/bin/sh\necho \"$@\" >> '\(log.path)'\nexec sleep 30\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return app
    }

    private func waitForLines(_ count: Int, in log: URL) -> [String] {
        let deadline = Date().addingTimeInterval(10)
        var lines: [String] = []
        while Date() < deadline {
            lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
            if lines.count >= count { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return lines
    }

    @Test("launch passes --bundle; relaunch starts the new host, then stops the old one")
    func launchAndRelaunch() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("args.log")
        let launcher = DevHostProcessLauncher(devHostURL: try makeFakeDevHost(in: dir, log: log))

        try launcher.launch(bundleURL: URL(fileURLWithPath: "/tmp/One.bundle"))
        let first = try #require(launcher.runningProcess)
        defer { first.terminate() }
        #expect(waitForLines(1, in: log) == ["--bundle /tmp/One.bundle"])

        try launcher.relaunch(bundleURL: URL(fileURLWithPath: "/tmp/Two.bundle"))
        let second = try #require(launcher.runningProcess)
        defer { second.terminate() }
        #expect(second !== first)
        #expect(waitForLines(2, in: log) == ["--bundle /tmp/One.bundle", "--bundle /tmp/Two.bundle"])

        first.waitUntilExit()
        #expect(first.terminationReason == .uncaughtSignal)
        #expect(second.isRunning)
    }

    @Test("a relaunch that cannot start keeps the running host")
    func failedRelaunchKeepsPrevious() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("args.log")
        let app = try makeFakeDevHost(in: dir, log: log)
        let launcher = DevHostProcessLauncher(devHostURL: app)

        try launcher.launch(bundleURL: URL(fileURLWithPath: "/tmp/One.bundle"))
        let first = try #require(launcher.runningProcess)
        defer { first.terminate() }
        // Let the shell open its script before it is deleted out from under it.
        #expect(waitForLines(1, in: log).count == 1)

        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/MacOS/AinkradDevHost"))
        #expect(throws: (any Error).self) {
            try launcher.relaunch(bundleURL: URL(fileURLWithPath: "/tmp/Two.bundle"))
        }
        #expect(launcher.runningProcess === first)
        #expect(first.isRunning)
    }
}
