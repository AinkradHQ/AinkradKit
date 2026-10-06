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

// The EXACT decodable the real host decodes the published
// `ainkrad-plugin.json` asset into (copied verbatim from
// `Ainkrad/Sources/Ainkrad/Core/AppStore/CatalogModel.swift`'s
// `PluginManifest`), so tests prove the asset we write decodes cleanly into
// what the real host expects — not just into our own writer's shape.
struct ManifestLink: Codable, Equatable {
    let title: String
    let url: URL
}

struct PluginManifest: Codable, Equatable {
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
