import AinkradAppKit
import Foundation

@testable import ainkrad

/// A golden `.bundle` fixture: a real directory on disk with a
/// `Contents/Info.plist`, written with `PropertyListSerialization` so no
/// actual Xcode build is needed to exercise validation or packaging.
func makeGoldenBundle(infoDictionary: [String: Any]) throws -> URL {
    let bundleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ainkrad-golden-\(UUID().uuidString).bundle")
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
/// so individual tests can knock one out.
func validInfoDictionary(overrides: [String: Any] = [:], removing: Set<String> = []) -> [String: Any] {
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

// Mirrors of the decodables the real host's `RemoteCatalogSource` decodes
// `catalog.json` into (`RemoteCatalog` in `RemoteCatalogSource.swift`,
// `CatalogEntry` + `ManifestLink` in `CatalogModel.swift`): the same required
// keys and types, so tests prove the entry we write decodes into what the real
// host expects — not just into our own writer's shape. `kind`/`mcp`/`skill`
// are omitted: plugin entries never carry them.
struct ManifestLink: Codable, Equatable {
    let title: String
    let url: URL
}

struct HostCatalogEntry: Decodable, Equatable {
    let appID: String
    let displayName: String
    let icon: String
    let description: String
    let version: String
    let apiVersion: Int
    let downloadURL: URL
    let sha256: String
    let sourceRepo: String
    let author: String?
    let longDescription: String?
    let screenshots: [URL]?
    let links: [ManifestLink]?
}

struct HostRemoteCatalog: Decodable {
    let schemaVersion: Int?
    let apps: [HostCatalogEntry]
}

/// A golden bundle that `codesign` accepts: its executable is a copy of
/// `/usr/bin/true`, a real Mach-O, so signing has code to sign.
func makeSignableBundle() throws -> URL {
    let bundleURL = try makeGoldenBundle(
        infoDictionary: validInfoDictionary(overrides: [
            PluginInfoKey.author: "Jane Developer",
            PluginInfoKey.description: "A short description of what this app does.",
            "CFBundleIdentifier": "com.example.widget",
        ]))
    let macOS = bundleURL.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("ExampleWidget"))
    return bundleURL
}

/// Whether this machine has the toolchain `ainkrad build` requires: an
/// Xcode install (the fixed `DEVELOPER_DIR` `BundleBuilder` targets) and
/// `xcodegen` on `PATH`. The real-build tests skip cleanly, not fail, without
/// either.
func buildToolchainAvailable() -> Bool {
    guard Environment().find("xcodegen") != nil else { return false }
    return FileManager.default.fileExists(
        atPath: "/Applications/Xcode.app/Contents/Developer"
    )
}
