import AinkradAppKit
import CryptoKit
import Foundation

/// A failure while packaging a `.bundle` into catalog assets or shelling
/// out to `gh` to create the release.
struct ReleasePublisherError: Error, CustomStringConvertible {
    let description: String
}

/// Packages a built `.bundle` into its release asset — `<appID>.bundle.zip` —
/// and the AinkradCatalog entry that lists it (`RemoteCatalogSource` format,
/// decision 20), and creates the GitHub Release carrying the zip. This is the
/// template's only release path: its `make release` calls `ainkrad publish`.
struct ReleasePublisher {
    private let inspector: BundleInspector

    init(inspector: BundleInspector = BundleInspector()) {
        self.inspector = inspector
    }

    /// Zips `bundle` with `ditto` into a fresh temporary directory, hashes the
    /// zip, and builds its catalog entry for release `tag` of `sourceRepo`.
    ///
    /// Identity comes entirely from the bundle's own `Contents/Info.plist`
    /// (via `BundleInspector`, the SAME parse the host runs): `appID` ←
    /// `AinkradAppID`, `displayName` ← `AinkradDisplayName`, `icon` ←
    /// `AinkradIconSymbol`, `apiVersion` ← `AinkradAPIVersion`, `author` ←
    /// `AinkradAuthor`, `description` ← `description` (`""` when absent — it
    /// is required on the host's decodable).
    func package(bundle: URL, tag: String, sourceRepo: String) throws -> (zip: URL, entry: CatalogEntryRecord) {
        let (metadata, infoDictionary) = try inspector.metadata(at: bundle)

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ainkrad-publish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let zipURL = outputDirectory.appendingPathComponent("\(metadata.appID).bundle.zip")
        try ReleasePublisher.ditto(bundle: bundle, to: zipURL)

        let entry = CatalogEntryRecord(
            appID: metadata.appID,
            displayName: metadata.displayName,
            icon: metadata.iconSymbol,
            description: infoDictionary[PluginInfoKey.description] as? String ?? "",
            version: tag,
            apiVersion: metadata.apiVersion,
            downloadURL: CatalogEntryRecord.downloadURL(sourceRepo: sourceRepo, version: tag, appID: metadata.appID),
            sha256: try ReleasePublisher.sha256Hex(of: zipURL),
            sourceRepo: sourceRepo,
            author: infoDictionary[PluginInfoKey.author] as? String
        )
        return (zip: zipURL, entry: entry)
    }

    /// Shells `gh release create <tag> --target <commit> <assets...>`. Networked,
    /// like the catalog push; callers gate both behind `--dry-run`. `target` pins
    /// the tag to the commit that was built — without it `gh` tags the default
    /// branch head, which shipped a mismatched host release once (v0.17.1).
    func release(
        tag: String, target: String? = nil, assets: [URL], environment: Environment = Environment()
    ) throws {
        guard let gh = environment.find("gh") else {
            throw ReleasePublisherError(description: "gh not found on PATH.")
        }

        // Via `ProcessRunner`, not a raw `Pipe`: `gh` streams upload progress on
        // stderr, and a large enough asset filled the pipe buffer while this
        // code was still in `waitUntilExit` — a publish that hung forever.
        let result: ProcessRunner.Result
        do {
            result = try ProcessRunner.run(gh, arguments: ["release", "create", tag] + (target.map { ["--target", $0] } ?? []) + assets.map(\.path))
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
