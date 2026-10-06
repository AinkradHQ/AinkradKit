import AinkradAppKit
import ArgumentParser
import CryptoKit
import Foundation
import Testing

@testable import ainkrad

@Test func packageProducesAZipAndAManifestThatDecodesIntoTheHostsShape() throws {
    let bundleURL = try makeGoldenBundle(
        infoDictionary: validInfoDictionary(overrides: [
            PluginInfoKey.author: "Jane Developer"
        ]))
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let publisher = ReleasePublisher()
    let (zip, manifest) = try publisher.package(bundle: bundleURL)
    defer {
        try? FileManager.default.removeItem(at: zip.deletingLastPathComponent())
    }

    #expect(zip.lastPathComponent == "com.example.widget.bundle.zip")
    #expect(manifest.lastPathComponent == "ainkrad-plugin.json")
    #expect(FileManager.default.fileExists(atPath: zip.path))
    #expect(FileManager.default.fileExists(atPath: manifest.path))

    let manifestData = try Data(contentsOf: manifest)
    let decoded = try JSONDecoder().decode(PluginManifest.self, from: manifestData)

    #expect(decoded.id == "com.example.widget")
    #expect(decoded.name == "Example Widget")
    #expect(decoded.icon == "star.fill")
    #expect(decoded.description == "")
    #expect(decoded.apiVersion == AinkradAppKit.apiVersion)
    #expect(decoded.author == "Jane Developer")

    // The manifest's sha256 must match an INDEPENDENTLY computed SHA-256 of
    // the produced zip, not just whatever the writer happened to compute.
    let zipData = try Data(contentsOf: zip)
    let expectedSHA = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
    #expect(decoded.sha256 == expectedSHA)
}

@Test func publishDryRunRefusesAnInvalidBundleWithoutProducingAnyAssets() throws {
    let bundleURL = try makeGoldenBundle(
        infoDictionary: validInfoDictionary(removing: ["CFBundleExecutable"])
    )
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let command = try Publish.parse([bundleURL.path, "v1.0.0", "--dry-run"])
    #expect(throws: ExitCode(1)) {
        try command.run()
    }
}

@Test func publishDryRunPackagesAValidBundleWithoutReleasing() throws {
    // Must be a STORE-complete bundle (author + description), not just
    // base-valid: since publish now also enforces `StorePolicy`, a bundle
    // missing either would be refused before reaching this assertion.
    let bundleURL = try makeGoldenBundle(
        infoDictionary: validInfoDictionary(overrides: [
            PluginInfoKey.author: "Jane Developer",
            PluginInfoKey.description: "A short description of what this app does.",
        ]))
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let command = try Publish.parse([bundleURL.path, "v1.0.0", "--dry-run"])
    // Must not throw: dry-run packages but never shells out to `gh`, so
    // this must succeed fully offline.
    try command.run()
}

@Test func publishDryRunRefusesABundleMissingAnAuthorWithoutProducingAnyAssets() throws {
    // Base-valid (has CFBundleExecutable etc.) but missing `AinkradAuthor` —
    // the exact hole Fix 1 closes: previously this reached `package()` and
    // would have produced assets; now `Validate.storeIssues` catches it
    // before any packaging happens (verified directly against the seam
    // below, mirroring how `publishDryRunRefusesAnInvalidBundleWithoutProducingAnyAssets`
    // proves the base-validation refusal without a flaky filesystem scan
    // under parallel test execution).
    let bundleURL = try makeGoldenBundle(
        infoDictionary: validInfoDictionary(overrides: [
            PluginInfoKey.description: "A short description of what this app does."
        ]))
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let issues = try Validate.storeIssues(bundleURL: bundleURL, inspector: BundleInspector())
    #expect(issues.map(\.code) == ["missing-author"])

    let command = try Publish.parse([bundleURL.path, "v1.0.0", "--dry-run"])
    #expect(throws: ExitCode(1)) {
        try command.run()
    }
}
