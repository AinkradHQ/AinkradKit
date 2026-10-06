import AinkradAppKit
import CryptoKit
import Foundation

/// A failure while packaging a `.bundle` into catalog assets or shelling
/// out to `gh` to create the release.
struct ReleasePublisherError: Error, CustomStringConvertible {
    let description: String
}

/// Packages a built `.bundle` into the exact asset pair the real host's
/// `GitHubReleasesCatalogSource` consumes — `<appID>.bundle.zip` +
/// `ainkrad-plugin.json` — and creates the GitHub Release carrying them.
/// This is the template's only release path: its `make release` calls
/// `ainkrad publish`.
struct ReleasePublisher {
    private let inspector: BundleInspector

    init(inspector: BundleInspector = BundleInspector()) {
        self.inspector = inspector
    }

    /// Zips `bundle` with `ditto`, computes the zip's SHA-256, and writes a
    /// `PluginManifest`-shaped `ainkrad-plugin.json` next to it — both into
    /// a fresh temporary output directory. Returns both asset URLs.
    ///
    /// Field sourcing is entirely from the bundle's own `Contents/Info.plist`
    /// (via `BundleInspector`, the SAME parse the host runs), so a bundle
    /// that inspects clean also publishes with matching identity: `id` ←
    /// `AinkradAppID`, `name` ← `AinkradDisplayName`, `icon` ←
    /// `AinkradIconSymbol`, `apiVersion` ← `AinkradAPIVersion`. `description`
    /// is read from the Info.plist's `description` key when present, else
    /// defaults to `""` — it is a required field on the host's decodable, so
    /// it must always be present in the JSON. `author` ← `PluginInfoKey.author`
    /// (`AinkradAuthor`), an optional field on the host's decodable.
    func package(bundle: URL) throws -> (zip: URL, manifest: URL) {
        let (metadata, infoDictionary) = try inspector.metadata(at: bundle)

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ainkrad-publish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let zipURL = outputDirectory.appendingPathComponent("\(metadata.appID).bundle.zip")
        try ReleasePublisher.ditto(bundle: bundle, to: zipURL)

        let sha256 = try ReleasePublisher.sha256Hex(of: zipURL)

        let description = infoDictionary["description"] as? String ?? ""
        let author = infoDictionary[PluginInfoKey.author] as? String
        let manifest = PublishedManifest(
            id: metadata.appID,
            name: metadata.displayName,
            icon: metadata.iconSymbol,
            description: description,
            apiVersion: metadata.apiVersion,
            sha256: sha256,
            author: author
        )

        let manifestURL = outputDirectory.appendingPathComponent("ainkrad-plugin.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL)

        return (zip: zipURL, manifest: manifestURL)
    }

    /// Shells `gh release create <tag> <assets...>`. This is the only
    /// networked part of publishing; callers gate it behind `--dry-run`.
    func release(tag: String, assets: [URL]) throws {
        guard let gh = Environment().find("gh") else {
            throw ReleasePublisherError(description: "gh not found on PATH.")
        }

        // Via `ProcessRunner`, not a raw `Pipe`: `gh` streams upload progress on
        // stderr, and a large enough asset filled the pipe buffer while this
        // code was still in `waitUntilExit` — a publish that hung forever.
        let result: ProcessRunner.Result
        do {
            result = try ProcessRunner.run(gh, arguments: ["release", "create", tag] + assets.map(\.path))
        } catch {
            throw ReleasePublisherError(description: "Failed to launch gh release create: \(error)")
        }
        guard result.succeeded else {
            throw ReleasePublisherError(
                description: "gh release create \(tag) failed (exit \(result.exitCode)): \(result.standardError)"
            )
        }
    }

    /// Runs `/usr/bin/ditto -c -k --keepParent <bundle> <zipURL>`, so the zip
    /// unpacks to `<Name>.bundle` itself.
    private static func ditto(bundle: URL, to zipURL: URL) throws {
        // Same reason as `release` above — `ditto` reports per-file progress on
        // stderr, so a bundle with enough files deadlocked the old raw-pipe form.
        let result: ProcessRunner.Result
        do {
            result = try ProcessRunner.run(
                URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-c", "-k", "--keepParent", bundle.path, zipURL.path])
        } catch {
            throw ReleasePublisherError(description: "Failed to launch ditto: \(error)")
        }
        guard result.succeeded else {
            throw ReleasePublisherError(
                description: "ditto \(bundle.path) -> \(zipURL.path) failed "
                    + "(exit \(result.exitCode)): \(result.standardError)"
            )
        }
    }

    /// The SHA-256 of `fileURL`'s contents, hex-encoded, computed with
    /// CryptoKit over the whole file's `Data`.
    private static func sha256Hex(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The exact JSON shape the host's `GitHubReleasesCatalogSource` decodes
/// the `ainkrad-plugin.json` asset into (see
/// `Ainkrad/Sources/Ainkrad/Core/AppStore/CatalogModel.swift`'s
/// `PluginManifest`). Named distinctly here since this target only ever
/// WRITES this shape; the four optional fields the host also accepts
/// (`author`, `longDescription`, `screenshots`, `links`) are omitted, which
/// is legal since they're all optional there. `author` is now emitted (this
/// task); the remaining three (`longDescription`, `screenshots`, `links`)
/// stay omitted.
private struct PublishedManifest: Codable {
    let id: String
    let name: String
    let icon: String
    let description: String
    let apiVersion: Int
    let sha256: String
    let author: String?
}
