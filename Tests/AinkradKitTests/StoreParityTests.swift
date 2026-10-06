import AinkradAppKit
import ArgumentParser
import Foundation
import Testing

@testable import ainkrad

/// The parity guarantee under test, now stated end-to-end: "`validate
/// --store` passes ⟺ `publish` succeeds ⟺ the published artifact installs
/// clean." For the COMPLETE row, both `Validate.storeIssues` (Path A, reading
/// the bundle's own `Info.plist`) and a reconstruction of the installer's
/// `StoreManifestInput` from the REAL `ainkrad-plugin.json` that
/// `ReleasePublisher.package` produces (Path B) agree the bundle is clean —
/// so a bundle that passes local validation also produces an installable
/// artifact. For each INCOMPLETE row, `Validate.storeIssues` reports the same
/// codes `validate --store` would print, AND the `Publish` command (the
/// gate Fix 1 added) REFUSES to publish it — i.e. the same incompleteness
/// that fails `validate --store` also fails `publish`, so an incomplete
/// bundle never reaches the catalog in the first place.
///
/// This is what makes the host installer's legacy `author == nil`
/// grandfather clause safe: because `publish` now refuses any bundle
/// `StorePolicy` rejects, a catalog entry with a nil author can only be a
/// genuinely legacy entry published before store-listing completeness
/// existed — never a new submission that "skipped" the check. This table
/// intentionally does NOT assert that the installer grandfathers an
/// incomplete submission through; it asserts incomplete bundles never get
/// that far.

/// The exact JSON shape the host's `GitHubReleasesCatalogSource` decodes the
/// published `ainkrad-plugin.json` asset into (mirrors `PublishTests`'
/// private `PluginManifest`, copied from
/// `Ainkrad/Sources/Ainkrad/Core/AppStore/CatalogModel.swift`).
private struct PluginManifest: Codable {
    let id: String
    let name: String
    let icon: String
    let description: String
    let apiVersion: Int
    let sha256: String
    let author: String?
}

/// A golden `.bundle` fixture: a real directory on disk with a
/// `Contents/Info.plist`, written with `PropertyListSerialization` so no
/// actual Xcode build is needed to exercise validation or packaging.
private func makeGoldenBundle(infoDictionary: [String: Any]) throws -> URL {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ainkrad-store-parity-tests-\(UUID().uuidString).bundle")
    let contentsURL = bundleURL.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

    let data = try PropertyListSerialization.data(
        fromPropertyList: infoDictionary, format: .xml, options: 0
    )
    try data.write(to: contentsURL.appendingPathComponent("Info.plist"))

    return bundleURL
}

/// A complete, valid Info.plist dictionary built against the CLI's own
/// target generation (`AinkradAppKit.apiVersion`), with every key overridable
/// so individual golden rows can knock one out.
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

/// One golden bundle and the store-issue codes both paths must agree on.
private struct GoldenRow {
    let name: String
    let overrides: [String: Any]
    let removing: Set<String>
    let expectedCodes: Set<String>
}

private func goldenRows() -> [GoldenRow] {
    [
        GoldenRow(
            name: "complete",
            overrides: [
                PluginInfoKey.author: "Jane Developer",
                PluginInfoKey.description: "A short description of what this app does.",
            ],
            removing: [],
            expectedCodes: []
        ),
        GoldenRow(
            name: "missing author",
            overrides: [
                PluginInfoKey.description: "A short description of what this app does."
            ],
            removing: [],
            expectedCodes: ["missing-author"]
        ),
        GoldenRow(
            name: "missing description",
            overrides: [
                PluginInfoKey.author: "Jane Developer"
            ],
            removing: [],
            expectedCodes: ["missing-description"]
        ),
        GoldenRow(
            name: "unresolvable icon",
            overrides: [
                PluginInfoKey.author: "Jane Developer",
                PluginInfoKey.description: "A short description of what this app does.",
                PluginInfoKey.iconSymbol: "definitely-not-a-symbol-xyz",
            ],
            removing: [],
            expectedCodes: ["missing-icon"]
        ),
    ]
}

/// Asserts the COMPLETE-bundle half of the parity guarantee: `validate
/// --store` reports no issues, `publish` (dry-run) succeeds, and the
/// resulting published artifact reconstructs into a clean `StorePolicy`
/// check with non-empty author/description — the published, installable
/// artifact is genuinely clean end-to-end.
private func assertRowPublishesClean(_ row: GoldenRow) throws {
    let bundleURL = try makeGoldenBundle(
        infoDictionary: validInfoDictionary(overrides: row.overrides, removing: row.removing)
    )
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    // Path A: the CLI's own `validate --store` seam, reading the bundle's
    // Info.plist directly.
    let codesA = Set(
        try Validate.storeIssues(bundleURL: bundleURL, inspector: BundleInspector())
            .map(\.code))
    #expect(codesA == row.expectedCodes, "Path A (CLI validate) diverged from the expected codes for '\(row.name)'.")

    // Path B: `publish` itself (dry-run) must succeed — the exact gate Fix 1
    // added to the real command, not a hand-rolled reconstruction.
    let command = try Publish.parse([bundleURL.path, "v1.0.0", "--dry-run"])
    try command.run()

    // And the artifact it produced decodes into a genuinely clean, installable
    // manifest: non-empty author/description, and a fresh `StorePolicy.check`
    // over the reconstructed installer input reports zero issues too.
    let (zip, manifest) = try ReleasePublisher().package(bundle: bundleURL)
    defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }

    let manifestData = try Data(contentsOf: manifest)
    let decoded = try JSONDecoder().decode(PluginManifest.self, from: manifestData)
    #expect(!(decoded.author?.isEmpty ?? true), "Published manifest for '\(row.name)' must carry a non-empty author.")
    #expect(!decoded.description.isEmpty, "Published manifest for '\(row.name)' must carry a non-empty description.")

    let (metadata, infoDictionary) = try BundleInspector().metadata(at: bundleURL)
    let input = StoreManifestInput(
        metadata: metadata,
        infoDictionary: infoDictionary,
        author: decoded.author,
        description: decoded.description,
        iconSymbol: decoded.icon,
        declaredSHA256: decoded.sha256,
        computedSHA256: decoded.sha256
    )
    let codesB = Set(
        StorePolicy.check(
            manifest: input,
            minSupported: AinkradAppKit.apiVersion,
            current: AinkradAppKit.apiVersion
        ).map(\.code))
    #expect(codesB.isEmpty, "Published artifact for '\(row.name)' must reconstruct into a clean StorePolicy check.")
}

/// Asserts the INCOMPLETE-bundle half of the parity guarantee: `validate
/// --store` reports the row's expected issue code(s), AND `publish`
/// (dry-run) REFUSES the exact same bundle with a non-zero exit — the same
/// incompleteness that fails local validation also prevents publication, so
/// the bundle never reaches the catalog/installer at all. This does NOT
/// assert (and must never assert) that the installer would grandfather it
/// through.
private func assertRowIsRefusedByPublish(_ row: GoldenRow) throws {
    let bundleURL = try makeGoldenBundle(
        infoDictionary: validInfoDictionary(overrides: row.overrides, removing: row.removing)
    )
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let codesA = Set(
        try Validate.storeIssues(bundleURL: bundleURL, inspector: BundleInspector())
            .map(\.code))
    #expect(codesA == row.expectedCodes, "Path A (CLI validate) diverged from the expected codes for '\(row.name)'.")
    #expect(!codesA.isEmpty, "'\(row.name)' is meant to be an incomplete row — expected codes must be non-empty.")

    // Path B: the SAME bundle, driven through the real `publish` command's
    // gate (Fix 1). It must refuse — never package, never release — because
    // the same StorePolicy issues Path A found also gate `publish`.
    let command = try Publish.parse([bundleURL.path, "v1.0.0", "--dry-run"])
    #expect(throws: ExitCode(1)) {
        try command.run()
    }
}

@Test func cliValidateAndPublishAgreeACompleteBundlePublishesClean() throws {
    try assertRowPublishesClean(goldenRows()[0])
}

@Test func publishRefusesABundleMissingAuthor() throws {
    try assertRowIsRefusedByPublish(goldenRows()[1])
}

@Test func publishRefusesABundleMissingDescription() throws {
    try assertRowIsRefusedByPublish(goldenRows()[2])
}

@Test func publishRefusesABundleWithAnUnresolvableIcon() throws {
    try assertRowIsRefusedByPublish(goldenRows()[3])
}
