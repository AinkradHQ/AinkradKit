import CryptoKit
import Foundation
import Testing

@testable import ainkrad

/// The standalone `AinkradPluginTemplate` is canonical; `Resources/Template`
/// is a copy `scripts/sync-template.sh` writes. These tests fail when the copy
/// drifts from the template beyond the scaffolder tokens, and when a scaffold
/// of the template's layout points at paths that do not exist.
@Suite("Embedded template parity")
struct TemplateParityTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AinkradKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root

    /// Offline parity: `scripts/template-manifest.sha256` holds the standalone
    /// template's file hashes at the synced commit. Undo the one rewrite the
    /// sync makes (the AppKit pin -> placeholder) and every embedded file must
    /// hash to its standalone original, with no file missing or extra.
    @Test("the embedded copy is the standalone template plus the pin token only")
    func embeddedCopyMatchesManifest() throws {
        let manifest = try String(
            contentsOf: Self.root.appendingPathComponent("scripts/template-manifest.sha256"), encoding: .utf8)
        var pin: String?
        var expected: [String: String] = [:]
        for line in manifest.split(separator: "\n") {
            if line.hasPrefix("# pin ") {
                pin = String(line.dropFirst("# pin ".count))
            } else if !line.hasPrefix("#") {
                let parts = line.split(separator: " ", maxSplits: 1)
                expected[String(parts[1].drop(while: { $0 == " " }))] = String(parts[0])
            }
        }
        let standalonePin = try #require(pin, "manifest has no `# pin` line")
        #expect(expected.count > 10, "manifest lists too few files to be the template")

        let template = Self.root.appendingPathComponent("Sources/ainkrad/Resources/Template")
        var actual: [String: String] = [:]
        for relative in try TemplateScaffolder.templateRelativePaths(under: template, fileManager: .default)
        where relative != ".DS_Store" && !relative.hasSuffix("/.DS_Store") {
            var data = try Data(contentsOf: template.appendingPathComponent(relative))
            if relative == "project.yml" {
                let text = try #require(String(data: data, encoding: .utf8))
                #expect(text.contains(TemplateScaffolder.templateSDKRevision))
                data = Data(
                    text.replacingOccurrences(of: TemplateScaffolder.templateSDKRevision, with: standalonePin).utf8)
            }
            actual[relative] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        #expect(Set(actual.keys) == Set(expected.keys), "file set differs; re-run scripts/sync-template.sh")
        for (path, hash) in expected where actual[path] != nil {
            #expect(actual[path] == hash, "\(path) differs from the standalone template")
        }
    }

    /// The template's paths carry tokens (`Sources/TemplatePlugin`,
    /// `Tests/TemplateFeatureTests`). The scaffolder renames them, so every
    /// path project.yml names exists in the scaffold.
    @Test("a scaffold's project.yml points at directories the scaffold has")
    func scaffoldLayoutMatchesProject() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ainkrad-parity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        try TemplateScaffolder().scaffold(
            name: "MyWidget", id: "myapp", displayName: "My Widget", icon: "star.fill", into: destination)

        let project = try String(contentsOf: destination.appendingPathComponent("project.yml"), encoding: .utf8)
        for line in [
            "  MyWidgetFeature:", "sources: [Sources/MyWidgetFeature]", "sources: [Sources/MyWidget]",
            "INFOPLIST_FILE: Sources/MyWidget/Info.plist", "-lMyWidgetFeature",
            "  MyWidgetFeatureTests:", "sources: [Tests/MyWidgetFeatureTests]",
        ] {
            #expect(project.contains(line), "project.yml lacks \(line)")
        }
        for directory in ["Sources/MyWidget", "Sources/MyWidgetFeature", "Tests/MyWidgetFeatureTests"] {
            var isDirectory: ObjCBool = false
            #expect(
                FileManager.default.fileExists(
                    atPath: destination.appendingPathComponent(directory).path, isDirectory: &isDirectory)
                    && isDirectory.boolValue, "missing \(directory)")
        }
        let entryPoint = try String(
            contentsOf: destination.appendingPathComponent("Sources/MyWidget/PluginEntryPoint.swift"), encoding: .utf8)
        #expect(entryPoint.contains("import MyWidgetFeature"))
        let stamp = destination.appendingPathComponent("scripts/stamp-api-version.sh").path
        #expect(FileManager.default.isExecutableFile(atPath: stamp))
    }
}
