import Foundation
import Testing
@testable import ainkrad

/// Wave 1-D. Three tooling defects from the audit: the scaffolder silently
/// overwrote existing work, the template shipped a second publish path the
/// host rejects, and three call sites reproduced the pipe-buffer deadlock.

@Suite("ainkrad new does not destroy existing work")
struct ScaffoldOverwriteTests {

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ainkrad-overwrite-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func scaffold(into destination: URL) throws {
        try TemplateScaffolder().scaffold(
            name: "MyWidget", id: "myapp", displayName: "My Widget",
            icon: "star.fill", into: destination)
    }

    @Test("Scaffolding twice into the same directory is refused")
    func refusesToOverwrite() throws {
        let destination = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        try scaffold(into: destination)
        // Stand in for a developer's real work living where the template writes.
        let app = destination.appendingPathComponent("Sources/Plugin/PluginApp.swift")
        try "// months of real work\n".write(to: app, atomically: true, encoding: .utf8)

        #expect(throws: TemplateScaffolderError.self) { try self.scaffold(into: destination) }

        // The point of the guard: the file is still there, untouched.
        #expect(try String(contentsOf: app, encoding: .utf8) == "// months of real work\n")
    }

    @Test("The refusal names the files that would have been clobbered")
    func refusalNamesTheFiles() throws {
        let destination = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        try scaffold(into: destination)

        do {
            try scaffold(into: destination)
            Issue.record("second scaffold was allowed")
        } catch let error as TemplateScaffolderError {
            #expect(error.description.contains("project.yml"))
            #expect(error.description.contains("Refusing to overwrite"))
        }
    }

    @Test("An empty directory is still a valid target")
    func emptyDirectoryStillWorks() throws {
        let destination = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        try scaffold(into: destination)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("project.yml").path))
    }

    @Test("Unrelated files in the directory do not block scaffolding")
    func unrelatedFilesDoNotBlock() throws {
        let destination = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        try "# notes\n".write(to: destination.appendingPathComponent("README.md"),
                              atomically: true, encoding: .utf8)
        try scaffold(into: destination)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("project.yml").path))
    }
}

@Suite("The template has exactly one publish path")
struct TemplatePublishPathTests {

    private func scaffoldedTree() throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ainkrad-publishpath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try TemplateScaffolder().scaffold(
            name: "MyWidget", id: "myapp", displayName: "My Widget",
            icon: "star.fill", into: destination)
        return destination
    }

    @Test("The scaffold ships no second release script")
    func noRogueReleaseScript() throws {
        let root = try scaffoldedTree()
        defer { try? FileManager.default.removeItem(at: root) }
        // This script hardcoded "apiVersion": 1 — which the host REJECTS — and
        // omitted "author", producing manifests StorePolicy refuses. It was
        // also the reason the host installer carried an `author == nil`
        // grandfather clause.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("scripts/release.sh").path))
    }

    @Test("make release goes through ainkrad publish")
    func makefileUsesAinkradPublish() throws {
        let root = try scaffoldedTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let makefile = try String(contentsOf: root.appendingPathComponent("Makefile"), encoding: .utf8)
        #expect(makefile.contains("ainkrad publish"))
        #expect(!makefile.contains("scripts/release.sh"))
    }

    @Test("No scaffolded file hardcodes an apiVersion")
    func noHardcodedAPIVersion() throws {
        let root = try scaffoldedTree()
        defer { try? FileManager.default.removeItem(at: root) }
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            Issue.record("could not walk the scaffold"); return
        }
        for case let url as URL in walker {
            guard url.pathExtension != "plist",   // Info.plist is stamped from the SDK, correctly
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // The trailing COMMA matters. The template's literal is
            // `"apiVersion": 1,` and the check was written without it, which
            // was fine for one-digit generations and became a false positive
            // the moment the SDK reached 10 — `"apiVersion": 10,` contains
            // `"apiVersion": 1`. A correctly substituted scaffold would have
            // failed this test from generation 10 onward, with a message
            // saying the opposite of what was true.
            #expect(!text.contains("\"apiVersion\": 1,"),
                    "hardcoded apiVersion in \(url.lastPathComponent)")
        }
    }
}

@Suite("ProcessRunner")
struct ProcessRunnerTests {

    @Test("Output far larger than a pipe buffer does not deadlock")
    func largeOutputDoesNotDeadlock() throws {
        // ~4MB on stdout, ~64× the pipe buffer. Every raw-Pipe call site in the
        // family hung on exactly this.
        let result = try ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes abcdefghijklmnopqrstuvwxyz | head -n 150000"])
        #expect(result.succeeded)
        #expect(result.standardOutput.count > 1_000_000)
    }

    @Test("Large stderr does not deadlock either")
    func largeStderrDoesNotDeadlock() throws {
        // `gh` and `ditto` both report progress on stderr — this was the exact
        // shape of the ReleasePublisher hang.
        let result = try ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes abcdefghijklmnopqrstuvwxyz | head -n 150000 >&2"])
        #expect(result.succeeded)
        #expect(result.standardError.count > 1_000_000)
    }

    @Test("Both streams filling at once does not deadlock")
    func bothStreamsAtOnce() throws {
        let result = try ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes out | head -n 80000 & yes err | head -n 80000 >&2; wait"])
        #expect(result.succeeded)
        #expect(!result.standardOutput.isEmpty)
        #expect(!result.standardError.isEmpty)
    }

    @Test("A non-zero exit is a result, not a thrown error")
    func nonZeroExitIsAResult() throws {
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 3"])
        #expect(result.exitCode == 3)
        #expect(!result.succeeded)
    }

    @Test("A missing executable throws a launch failure")
    func missingExecutableThrows() {
        #expect(throws: ProcessRunner.LaunchFailure.self) {
            _ = try ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/binary-\(UUID().uuidString)"))
        }
    }

    @Test("output() returns nil rather than an empty string on failure")
    func outputProbeSemantics() {
        #expect(ProcessRunner.output("/bin/echo", arguments: ["hi"]) == "hi")
        #expect(ProcessRunner.output("/bin/sh", arguments: ["-c", "exit 1"]) == nil)
        #expect(ProcessRunner.output("/bin/sh", arguments: ["-c", "true"]) == nil)   // empty output
    }
}
