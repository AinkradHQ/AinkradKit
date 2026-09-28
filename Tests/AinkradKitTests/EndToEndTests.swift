import AinkradAppKit
import ArgumentParser
import CryptoKit
import Foundation
import Testing
@testable import ainkrad

/// The exact host-decodable shape a published `ainkrad-plugin.json` must
/// decode into (mirrors `PublishTests.swift`'s copy of the real host's
/// `PluginManifest` from `Ainkrad/Sources/Ainkrad/Core/AppStore/CatalogModel.swift`).
private struct E2EPluginManifest: Codable {
    let id: String
    let name: String
    let icon: String
    let description: String
    let apiVersion: Int
    let sha256: String
}

/// Whether this machine has the toolchain the pipeline requires: an
/// Xcode install (the fixed `DEVELOPER_DIR` `BundleBuilder` targets)
/// and `xcodegen` on `PATH`. Mirrors `BundleBuilderTests`' guard — this test
/// must skip cleanly, not fail, on a machine that lacks either.
private func e2eToolchainAvailable() -> Bool {
    guard Environment().find("xcodegen") != nil else { return false }
    return FileManager.default.fileExists(
        atPath: "/Applications/Xcode.app/Contents/Developer"
    )
}

/// Recursively finds the first `.bundle` under `root` — the same convention
/// `ainkrad build` uses to place its output (`<projectDir>/.ainkrad-build/Build/Products/...`),
/// used here only to locate the artifact `ainkrad build` already produced,
/// not to reimplement any of its build or discovery logic.
private func findBundle(under root: URL) -> URL? {
    guard let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey]
    ) else { return nil }

    for case let url as URL in enumerator where url.pathExtension == "bundle" {
        return url
    }
    return nil
}

/// End-to-end happy path (Task 9): `ainkrad new` → `ainkrad build` →
/// `ainkrad validate` → `ainkrad publish --dry-run`, driving the real
/// `ParsableCommand` structs registered on the root command — the exact
/// code path `ainkrad <subcommand>` takes on the command line — rather than
/// any reimplementation of their logic. Every step must complete without
/// throwing (i.e. exit 0); the final step's packaged manifest must decode
/// into the host's `PluginManifest` shape with a sha256 that independently
/// verifies against the packaged zip.
///
/// Real `xcodegen generate` + `xcodebuild build`, so this is slow — skips
/// cleanly (like `BundleBuilderTests`) when the toolchain is absent.
@Test(
    "ainkrad new -> build -> validate -> publish --dry-run all exit 0 and publish a valid manifest",
    .enabled(if: e2eToolchainAvailable(), "requires Xcode and xcodegen on this machine"),
    .timeLimit(.minutes(15))
)
func endToEndHappyPath() throws {
    let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("ainkrad-e2e-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

    let projectDir = workspace.appendingPathComponent("SampleApp", isDirectory: true)

    // Step 1: `ainkrad new SampleApp` — name is the primary positional
    // argument; `--into` is only an explicit override of the (otherwise
    // `./<name>`-defaulting) destination, used here so the test doesn't
    // depend on process-wide current-directory state.
    let newCommand = try New.parse(["SampleApp", "--into", projectDir.path])
    #expect(newCommand.name == "SampleApp")
    #expect(newCommand.into == projectDir.path)
    try newCommand.run() // must not throw => exit 0

    #expect(FileManager.default.fileExists(atPath: projectDir.appendingPathComponent(".gitignore").path))

    // Step 2: `ainkrad build`.
    let buildCommand = try Build.parse([projectDir.path])
    try buildCommand.run() // must not throw => exit 0

    let derivedDataDir = projectDir.appendingPathComponent(".ainkrad-build", isDirectory: true)
    guard let bundleURL = findBundle(under: derivedDataDir) else {
        Issue.record("ainkrad build reported success but no .bundle was found under \(derivedDataDir.path)")
        return
    }
    #expect(FileManager.default.fileExists(atPath: bundleURL.path))

    // Step 3: `ainkrad validate` — expect a clean pass.
    let validateCommand = try Validate.parse([bundleURL.path])
    try validateCommand.run() // must not throw => exit 0

    // Step 4: `ainkrad publish --dry-run` — packages assets, never shells
    // out to `gh`.
    let publishCommand = try Publish.parse([bundleURL.path, "v1.0.0", "--dry-run"])
    #expect(publishCommand.dryRun)
    try publishCommand.run() // must not throw => exit 0

    // `Publish.run()` intentionally only prints asset file NAMES (never
    // full paths) in dry-run output, so — exactly as `PublishTests.swift`
    // does to assert on packaged content — package the SAME bundle through
    // the SAME `ReleasePublisher` the command wraps, to get the produced
    // asset URLs back and verify the manifest it publishes really is valid.
    let (zip, manifest) = try ReleasePublisher().package(bundle: bundleURL)
    defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }

    #expect(FileManager.default.fileExists(atPath: zip.path))
    #expect(FileManager.default.fileExists(atPath: manifest.path))

    let manifestData = try Data(contentsOf: manifest)
    let decoded = try JSONDecoder().decode(E2EPluginManifest.self, from: manifestData)

    #expect(decoded.id == "SampleApp")
    #expect(decoded.name == "SampleApp")
    #expect(decoded.apiVersion == AinkradAppKit.apiVersion)

    let zipData = try Data(contentsOf: zip)
    let expectedSHA = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
    #expect(decoded.sha256 == expectedSHA)
}
