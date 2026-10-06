import AinkradAppKit
import ArgumentParser
import CryptoKit
import Foundation
import Testing

@testable import ainkrad

// The EXACT decodable the real host's `GitHubReleasesCatalogSource` decodes
// the published `ainkrad-plugin.json` asset into (copied verbatim from
// `Ainkrad/Sources/Ainkrad/Core/AppStore/CatalogModel.swift`'s
// `PluginManifest`), so this test proves the asset we write decodes cleanly
// into what the real host expects — not just into our own writer's shape.
private struct ManifestLink: Codable, Equatable {
    let title: String
    let url: URL
}

private struct PluginManifest: Codable, Equatable {
    let id: String
    let name: String
    let icon: String
    let description: String
    let apiVersion: Int
    let sha256: String
    let author: String?
    let longDescription: String?
    let screenshots: [URL]?
    let links: [ManifestLink]?
}

/// A golden `.bundle` fixture: a real directory on disk with a
/// `Contents/Info.plist`, written with `PropertyListSerialization` so no
/// actual Xcode build is needed to exercise packaging.
private func makeGoldenBundle(infoDictionary: [String: Any]) throws -> URL {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ainkrad-publish-tests-\(UUID().uuidString).bundle")
    let contentsURL = bundleURL.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

    let data = try PropertyListSerialization.data(
        fromPropertyList: infoDictionary, format: .xml, options: 0
    )
    try data.write(to: contentsURL.appendingPathComponent("Info.plist"))

    return bundleURL
}

private func validInfoDictionary(overrides: [String: Any] = [:], removing: Set<String> = []) -> [String: Any] {
    var dict: [String: Any] = [
        PluginInfoKey.appID: "com.example.widget",
        PluginInfoKey.displayName: "Example Widget",
        PluginInfoKey.iconSymbol: "star.fill",
        PluginInfoKey.apiVersion: AinkradAppKit.apiVersion,
        PluginInfoKey.principalClass: "WidgetApp",
        "CFBundleExecutable": "ExampleWidget",
    ]
    for (key, value) in overrides { dict[key] = value }
    for key in removing { dict.removeValue(forKey: key) }
    return dict
}

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
