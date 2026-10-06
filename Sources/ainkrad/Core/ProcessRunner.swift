import Foundation

/// The single way this tool spawns a child process.
///
/// ## Why this exists
///
/// `Process` was invoked ad hoc at every call site, so each site re-learned the
/// same lesson independently — and most of them learned it wrong.
/// `BundleBuilder.run` documented the pipe-buffer deadlock and avoided it;
/// `ReleasePublisher.release`, `ReleasePublisher.ditto` and
/// `Environment.run` each reproduced it. The audit found the same defect a
/// fourth time in GitMage, where it was a shipped release blocker: a `git show`
/// over ~64KB wedged an actor permanently.
///
/// The bug is always the same shape:
///
/// ```swift
/// try process.run()
/// process.waitUntilExit()                       // ← blocks here forever
/// let out = pipe.fileHandleForReading.readDataToEndOfFile()
/// ```
///
/// A pipe holds ~64KB. Once the child fills it, the child blocks on `write`;
/// the parent is in `waitUntilExit` waiting for a child that can never finish;
/// nobody is reading. `gh release create` and `ditto` both emit progress on
/// stderr and both hit this on a large enough asset.
///
/// ## How this avoids it
///
/// stdout and stderr go to **temp files**, not pipes. A file has no fixed
/// buffer, so the child never blocks on write and the ordering of read-vs-wait
/// stops mattering at all. This is deliberately the *simpler* fix rather than
/// concurrent pipe draining: a CLI's child output is bounded by the tool that
/// produced it, and correctness that doesn't depend on getting concurrency
/// right is worth more here than saving a temp file.
enum ProcessRunner {

    struct Result {
        let exitCode: Int32
        let standardOutput: String
        let standardError: String
        var succeeded: Bool { exitCode == 0 }
    }

    struct LaunchFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// Runs `executable` to completion and returns its exit code plus both
    /// captured streams, trimmed. Throws only when the process could not be
    /// *launched* — a non-zero exit is a `Result`, not an error, so callers
    /// decide what a failure means.
    static func run(
        _ executable: URL,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment { merged[key] = value }
            process.environment = merged
        }

        let fileManager = FileManager.default
        let stdoutURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stderrURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        defer {
            try? fileManager.removeItem(at: stdoutURL)
            try? fileManager.removeItem(at: stderrURL)
        }

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            throw LaunchFailure(
                description: "Failed to launch \(executable.path) \(arguments.joined(separator: " ")): \(error)")
        }
        process.waitUntilExit()
        try? stdoutHandle.close()
        try? stderrHandle.close()

        return Result(
            exitCode: process.terminationStatus,
            standardOutput: ((try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            standardError: ((try? String(contentsOf: stderrURL, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Convenience for probes: trimmed stdout on success, `nil` on any failure
    /// (launch error, non-zero exit, or empty output).
    static func output(
        _ executablePath: String,
        arguments: [String] = [],
        currentDirectory: URL? = nil
    ) -> String? {
        guard
            let result = try? run(
                URL(fileURLWithPath: executablePath),
                arguments: arguments,
                currentDirectory: currentDirectory),
            result.succeeded, !result.standardOutput.isEmpty
        else { return nil }
        return result.standardOutput
    }
}
