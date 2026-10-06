import AinkradAppKit
import ArgumentParser
import Foundation
import Testing

@testable import ainkrad

@Test func validateSucceedsOnAValidGoldenBundle() throws {
    let bundleURL = try makeGoldenBundle(infoDictionary: validInfoDictionary())
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    // Should not throw: the validation-decision seam.
    try Validate.check(bundleURL: bundleURL, inspector: BundleInspector())

    // The full command, parsed and run in-process (no process spawning),
    // must complete without throwing an ExitCode.
    let command = try Validate.parse([bundleURL.path])
    try command.run()
}

@Test func validateFailsWithMissingExecutableMessage() throws {
    let bundleURL = try makeGoldenBundle(
        infoDictionary: validInfoDictionary(removing: ["CFBundleExecutable"])
    )
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    #expect(throws: PluginValidationError.self) {
        try Validate.check(bundleURL: bundleURL, inspector: BundleInspector())
    }

    do {
        try Validate.check(bundleURL: bundleURL, inspector: BundleInspector())
        Issue.record("expected Validate.check to throw")
    } catch {
        #expect(Validate.message(for: error).contains("missing CFBundleExecutable"))
    }

    let command = try Validate.parse([bundleURL.path])
    #expect(throws: ExitCode(1)) {
        try command.run()
    }
}

@Test func validateFailsWithGenerationRangeMessage() throws {
    let bundleURL = try makeGoldenBundle(
        infoDictionary: validInfoDictionary(overrides: [PluginInfoKey.apiVersion: 5])
    )
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    do {
        try Validate.check(bundleURL: bundleURL, inspector: BundleInspector())
        Issue.record("expected Validate.check to throw")
    } catch {
        let message = Validate.message(for: error)
        #expect(message.contains("generation 5"))
        #expect(message.contains("supports"))
    }

    let command = try Validate.parse([bundleURL.path])
    #expect(throws: ExitCode(1)) {
        try command.run()
    }
}

@Test func validateWithStoreFlagRunsBaseChecksAndDoesNotThrowOnAValidBundle() throws {
    let bundleURL = try makeGoldenBundle(
        infoDictionary: validInfoDictionary(overrides: [
            PluginInfoKey.author: "Jane Developer",
            PluginInfoKey.description: "A short description of what this app does.",
        ]))
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let command = try Validate.parse([bundleURL.path, "--store"])
    try command.run()
    #expect(command.store)
}

@Test func storeIssuesOnACompleteBundleReturnsNoIssues() throws {
    let bundleURL = try makeGoldenBundle(
        infoDictionary: validInfoDictionary(overrides: [
            PluginInfoKey.author: "Jane Developer",
            PluginInfoKey.description: "A short description of what this app does.",
        ]))
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let issues = try Validate.storeIssues(bundleURL: bundleURL, inspector: BundleInspector())
    #expect(issues == [])
}

@Test func storeIssuesOnABundleMissingAuthorReportsMissingAuthor() throws {
    let bundleURL = try makeGoldenBundle(
        infoDictionary: validInfoDictionary(overrides: [
            PluginInfoKey.description: "A short description of what this app does."
        ]))
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let issues = try Validate.storeIssues(bundleURL: bundleURL, inspector: BundleInspector())
    #expect(issues.contains { $0.code == "missing-author" })
}

@Test func validateWithStoreFlagFailsOnABundleMissingAuthor() throws {
    let bundleURL = try makeGoldenBundle(
        infoDictionary: validInfoDictionary(overrides: [
            PluginInfoKey.description: "A short description of what this app does."
        ]))
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let command = try Validate.parse([bundleURL.path, "--store"])
    #expect(throws: ExitCode(1)) {
        try command.run()
    }
}

@Test func bundleInspectorThrowsAClearErrorWhenInfoPlistIsMissing() throws {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ainkrad-validate-tests-missing-\(UUID().uuidString).bundle")
    try FileManager.default.createDirectory(
        at: bundleURL.appendingPathComponent("Contents"), withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    #expect(throws: BundleInspectorError.self) {
        _ = try BundleInspector().metadata(at: bundleURL)
    }
}
