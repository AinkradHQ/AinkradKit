import AinkradAppKit
import ArgumentParser
import CryptoKit
import Foundation
import Testing

@testable import ainkrad

/// Recursively finds the first `.bundle` under `root` — the same convention
/// `ainkrad build` uses to place its output (`<projectDir>/.ainkrad-build/Build/Products/...`),
/// used here only to locate the artifact `ainkrad build` already produced,
/// not to reimplement any of its build or discovery logic.
private func findBundle(under root: URL) -> URL? {
    guard
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        )
    else { return nil }

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
/// into the host's `RemoteCatalogSource` entry shape with a sha256 that independently
/// verifies against the packaged zip, and the built bundle ad-hoc signs and verifies.
///
/// Real `xcodegen generate` + `xcodebuild build`, so this is slow — skips
/// cleanly (like `BundleBuilderTests`) when the toolchain is absent.
@Test(
    "ainkrad new -> build -> validate -> publish --dry-run all exit 0 and publish a valid manifest",
    .enabled(if: buildToolchainAvailable(), "requires Xcode and xcodegen on this machine"),
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
    try newCommand.run()  // must not throw => exit 0

    #expect(FileManager.default.fileExists(atPath: projectDir.appendingPathComponent(".gitignore").path))

    // Step 2: `ainkrad build`.
    let buildCommand = try Build.parse([projectDir.path])
    try buildCommand.run()  // must not throw => exit 0

    let derivedDataDir = projectDir.appendingPathComponent(".ainkrad-build", isDirectory: true)
    guard let bundleURL = findBundle(under: derivedDataDir) else {
        Issue.record("ainkrad build reported success but no .bundle was found under \(derivedDataDir.path)")
        return
    }
    #expect(FileManager.default.fileExists(atPath: bundleURL.path))

    // Step 3: `ainkrad validate` — expect a clean pass.
    let validateCommand = try Validate.parse([bundleURL.path])
    try validateCommand.run()  // must not throw => exit 0

    // Step 4: `ainkrad publish --dry-run` — prints the sign + catalog plan;
    // never signs, never shells out to `gh`, never pushes the catalog.
    let publishCommand = try Publish.parse([bundleURL.path, "v1.0.0", "--dry-run", "--sign-identity", "-"])
    #expect(publishCommand.dryRun)
    try publishCommand.run()  // must not throw => exit 0

    // Package the SAME bundle through the SAME `ReleasePublisher` the command
    // wraps, to get the zip and catalog entry back and verify the entry
    // decodes into the host's `RemoteCatalogSource` shape.
    let (zip, entry) = try ReleasePublisher().package(bundle: bundleURL, tag: "v1.0.0", sourceRepo: "o/r")
    defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }

    #expect(FileManager.default.fileExists(atPath: zip.path))

    let decoded = try JSONDecoder().decode(HostCatalogEntry.self, from: Data(try entry.json().utf8))

    #expect(decoded.appID == "SampleApp")
    #expect(decoded.displayName == "SampleApp")
    #expect(decoded.apiVersion == AinkradAppKit.apiVersion)
    #expect(decoded.version == "v1.0.0")

    let zipData = try Data(contentsOf: zip)
    let expectedSHA = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
    #expect(decoded.sha256 == expectedSHA)

    // A real (ad-hoc) sign of the built bundle passes the strict verify.
    try BundleSigner(identity: "-").sign(bundleURL)
}
