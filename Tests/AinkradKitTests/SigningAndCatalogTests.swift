import AinkradAppKit
import Foundation
import Testing

@testable import ainkrad

/// `codesign` against a scratch bundle in a temp dir — ad-hoc (`-`) only, never
/// a Developer ID identity.
@Suite("BundleSigner")
struct BundleSignerTests {
    private func codesignVerify(_ bundle: URL) throws -> Bool {
        try ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--verify", "--strict", bundle.path]
        ).succeeded
    }

    @Test("ad-hoc signs with hardened runtime and passes the strict verify")
    func adHocSignAndVerify() throws {
        let bundle = try makeSignableBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        #expect(try !codesignVerify(bundle))

        try BundleSigner(identity: "-").sign(bundle)

        #expect(try codesignVerify(bundle))
        let details = try ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["-dv", "--verbose=4", bundle.path])
        #expect(details.standardError.contains("Signature=adhoc"))
        #expect(details.standardError.contains("runtime"))
    }

    @Test("signs nested code deepest first, then the bundle, then verifies strictly")
    func commandOrder() throws {
        let bundle = try makeSignableBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
        let framework = frameworks.appendingPathComponent("Kit.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        let dylib = framework.appendingPathComponent("libInner.dylib")
        FileManager.default.createFile(atPath: dylib.path, contents: nil)

        let commands = BundleSigner(identity: "-").commands(for: bundle)

        // By name: the enumerator may hand back the /private-resolved temp path.
        let targets = commands.compactMap { $0.last.map { URL(fileURLWithPath: $0).lastPathComponent } }
        #expect(targets == [dylib.lastPathComponent, framework.lastPathComponent, bundle.lastPathComponent, bundle.lastPathComponent])
        #expect(commands[0].starts(with: ["--force", "--options", "runtime", "--timestamp", "--sign", "-"]))
        #expect(commands[3] == ["--verify", "--strict", "--verbose=2", bundle.path])
    }

    @Test("a failing codesign throws with its stderr")
    func failingSignThrows() throws {
        let bundle = try makeGoldenBundle(infoDictionary: validInfoDictionary())
        defer { try? FileManager.default.removeItem(at: bundle) }
        let error = try #require(throws: BundleSignerError.self) {
            try BundleSigner(identity: "no such identity \(UUID().uuidString)").sign(bundle)
        }
        #expect(error.description.contains("codesign"))
    }

    @Test("the flag wins over SIGN_IDENTITY, which is the fallback")
    func identityResolution() throws {
        #expect(try BundleSigner.resolveIdentity(flag: "-", environment: ["SIGN_IDENTITY": "Env ID"]) == "-")
        #expect(try BundleSigner.resolveIdentity(flag: nil, environment: ["SIGN_IDENTITY": "Env ID"]) == "Env ID")
        #expect(try BundleSigner.resolveIdentity(flag: "", environment: ["SIGN_IDENTITY": "Env ID"]) == "Env ID")
    }

    @Test("no identity, or an empty one, is a loud error naming the fix")
    func missingIdentityThrows() throws {
        for environment in [[:], ["SIGN_IDENTITY": ""]] {
            let error = try #require(throws: BundleSignerError.self) {
                try BundleSigner.resolveIdentity(flag: nil, environment: environment)
            }
            #expect(error.description.contains("--sign-identity"))
            #expect(error.description.contains("SIGN_IDENTITY"))
        }
    }
}

@Suite("Catalog entry")
struct CatalogEntryTests {
    private let entry = CatalogEntryRecord(
        appID: "widget", displayName: "Widget", icon: "star.fill", description: "Does widget things.",
        version: "v1.2.3", apiVersion: AinkradAppKit.apiVersion,
        downloadURL: CatalogEntryRecord.downloadURL(
            sourceRepo: "AinkradHQ/AinkradWidget", version: "v1.2.3", appID: "widget"),
        sha256: String(repeating: "a", count: 64), sourceRepo: "AinkradHQ/AinkradWidget", author: "Jane")

    /// The `RemoteCatalogSource` keys every entry must carry (the host decodes
    /// them with `decode`, not `decodeIfPresent`), as in a real catalog entry.
    private let requiredKeys: Set<String> = [
        "appID", "displayName", "icon", "description", "version", "apiVersion", "downloadURL", "sha256",
        "sourceRepo",
    ]

    private func catalogFile(_ apps: [[String: Any]]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ainkrad-catalog-\(UUID().uuidString).json")
        let data = try JSONSerialization.data(
            withJSONObject: ["schemaVersion": 1, "apps": apps], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
        return url
    }

    @Test("encodes to the RemoteCatalogSource schema with no stray keys")
    func encodesToHostSchema() throws {
        let json = try entry.json()
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(requiredKeys.isSubset(of: Set(object.keys)))
        #expect(Set(object.keys).subtracting(requiredKeys) == ["author"])
        #expect(!json.contains("\\/"))

        let decoded = try JSONDecoder().decode(HostCatalogEntry.self, from: Data(json.utf8))
        #expect(decoded.appID == "widget")
        #expect(decoded.downloadURL.absoluteString == entry.downloadURL)
    }

    @Test("a new appID is appended whole and the catalog still decodes")
    func appendsNewEntry() throws {
        let file = try catalogFile([])
        defer { try? FileManager.default.removeItem(at: file) }

        try CatalogPublisher().apply(entry, toCatalogAt: file)

        let catalog = try JSONDecoder().decode(HostRemoteCatalog.self, from: Data(contentsOf: file))
        #expect(catalog.schemaVersion == 1)
        #expect(catalog.apps.map(\.appID) == ["widget"])
        #expect(catalog.apps[0].sha256 == entry.sha256)
    }

    @Test("an existing entry updates its release fields and keeps its curated ones")
    func updatesExistingEntry() throws {
        let existing: [String: Any] = [
            "appID": "widget", "displayName": "Curated Widget", "icon": "star", "description": "Curated.",
            "version": "v1.0.0", "apiVersion": 1, "downloadURL": "https://example.com/old.zip",
            "sha256": "old", "sourceRepo": "AinkradHQ/AinkradWidget", "longDescription": "Long.",
            "links": [["title": "Release notes", "url": "https://example.com/old"]],
        ]
        let file = try catalogFile([existing])
        defer { try? FileManager.default.removeItem(at: file) }

        try CatalogPublisher().apply(entry, toCatalogAt: file)

        let app = try #require(
            try JSONDecoder().decode(HostRemoteCatalog.self, from: Data(contentsOf: file)).apps.first)
        #expect(app.version == "v1.2.3")
        #expect(app.apiVersion == AinkradAppKit.apiVersion)
        #expect(app.sha256 == entry.sha256)
        #expect(app.downloadURL.absoluteString == entry.downloadURL)
        #expect(app.displayName == "Curated Widget")
        #expect(app.longDescription == "Long.")
        #expect(
            app.links?.first?.url.absoluteString == "https://github.com/AinkradHQ/AinkradWidget/releases/tag/v1.2.3")
    }

    @Test("two entries claiming one appID refuse the update and leave the file alone")
    func duplicateAppIDRefuses() throws {
        let duplicate: [String: Any] = ["appID": "widget"]
        let file = try catalogFile([duplicate, duplicate])
        defer { try? FileManager.default.removeItem(at: file) }
        let before = try Data(contentsOf: file)

        #expect(throws: CatalogPublisherError.self) {
            try CatalogPublisher().apply(entry, toCatalogAt: file)
        }
        #expect(try Data(contentsOf: file) == before)
    }
}

@Test func publishDryRunPrintsTheSignPlanAndCatalogEntryWithoutSigning() throws {
    let bundle = try makeSignableBundle()
    defer { try? FileManager.default.removeItem(at: bundle) }

    let (zip, entry) = try ReleasePublisher().package(bundle: bundle, tag: "v1.0.0", sourceRepo: "<owner>/<repo>")
    defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
    let plan = try Publish.dryRunPlan(signer: BundleSigner(identity: "-"), bundle: bundle, zip: zip, entry: entry)

    #expect(plan.contains("codesign --force --options runtime --timestamp --sign - \(bundle.path)"))
    #expect(plan.contains("codesign --verify --strict --verbose=2 \(bundle.path)"))
    #expect(plan.contains(try entry.json()))
    #expect(plan.contains(CatalogPublisher.catalogRepo))

    // The command itself must leave the bundle unsigned: dry-run signs nothing.
    try Publish.parse([bundle.path, "v1.0.0", "--dry-run", "--sign-identity", "-"]).run()
    let verify = try ProcessRunner.run(
        URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--verify", bundle.path])
    #expect(!verify.succeeded)
}

@Test("a non-Developer-ID signer is refused; a Developer ID one passes")
func developerIDAuthority() throws {
    #expect(throws: BundleSignerError.self) {
        try BundleSigner.requireDeveloperID("Authority=Apple Development: someone (ABC)\n")
    }
    try BundleSigner.requireDeveloperID(
        "Authority=Developer ID Application: Example Team (TEAM123456)\nAuthority=Developer ID Certification Authority\n")
}
