import Foundation

/// A failure building, merging or pushing an AinkradCatalog entry.
struct CatalogPublisherError: Error, CustomStringConvertible {
    let description: String
}

/// One `apps[]` entry of AinkradCatalog's `catalog.json` — the document the
/// host's `RemoteCatalogSource` decodes into `CatalogEntry`
/// (`Ainkrad/Sources/Ainkrad/Core/AppStore/CatalogModel.swift`). Carries every
/// field that type requires plus `author`; the presentation-only optionals
/// (`longDescription`, `screenshots`, `links`) are curated in the catalog and
/// preserved on update, never written from here.
struct CatalogEntryRecord: Codable, Equatable {
    let appID: String
    let displayName: String
    let icon: String
    let description: String
    let version: String
    let apiVersion: Int
    let downloadURL: String
    let sha256: String
    let sourceRepo: String
    let author: String?

    /// The release asset URL `gh release create <version>` serves the zip at.
    static func downloadURL(sourceRepo: String, version: String, appID: String) -> String {
        "https://github.com/\(sourceRepo)/releases/download/\(version)/\(appID).bundle.zip"
    }

    /// Pretty, sorted, unescaped-slash JSON — what `--dry-run` prints.
    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

/// Lists a release in AinkradCatalog — ported from Quest's `scripts/release.sh`
/// catalog step. The GitHub release is not the release: the storefront reads
/// only `catalog.json`, so a publish that stops at the release ships to nobody.
struct CatalogPublisher {
    static let catalogRepo = "AinkradHQ/AinkradCatalog"

    /// Upserts `entry` into the `catalog.json` at `catalogFile`, in place. An
    /// existing entry (matched by `appID`) gets only its release fields updated,
    /// keeping its curated presentation; a new `appID` is appended whole.
    /// Edited with a real JSON parser (python3, which keeps key order, so the
    /// diff is just the changed fields), validated, and written atomically — a
    /// half-written catalog takes down the storefront for every app.
    func apply(_ entry: CatalogEntryRecord, toCatalogAt catalogFile: URL) throws {
        let result = try ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", "-c", Self.upsertScript, catalogFile.path],
            environment: ["ENTRY": try entry.json()])
        guard result.succeeded else {
            throw CatalogPublisherError(description: "Catalog update failed: \(result.standardError)")
        }
        if !result.standardOutput.isEmpty { print(result.standardOutput) }
    }

    /// Fresh clone of AinkradCatalog, `apply`, commit, push to `main`. A clone
    /// every time, never a local checkout, so no unrelated edit rides along. A
    /// re-run that changes nothing pushes nothing. GATED: networked; callers
    /// reach it only without `--dry-run`.
    func push(_ entry: CatalogEntryRecord, environment: Environment = Environment()) throws {
        guard let gh = environment.find("gh"), let git = environment.find("git") else {
            throw CatalogPublisherError(description: "gh and git must both be on PATH to update the catalog.")
        }
        let clone = FileManager.default.temporaryDirectory
            .appendingPathComponent("ainkrad-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: clone) }

        try Self.check(gh, ["repo", "clone", Self.catalogRepo, clone.path, "--", "--quiet"])
        try apply(entry, toCatalogAt: clone.appendingPathComponent("catalog.json"))

        let diff = try ProcessRunner.run(
            git, arguments: ["diff", "--quiet", "--", "catalog.json"], currentDirectory: clone)
        if diff.succeeded {
            print("Catalog already lists \(entry.displayName) \(entry.version) — nothing to push.")
            return
        }
        try Self.check(git, ["add", "catalog.json"], in: clone)
        try Self.check(git, ["commit", "-q", "-m", "catalog: list \(entry.displayName) \(entry.version)"], in: clone)
        try Self.check(git, ["push", "-q", "origin", "HEAD:main"], in: clone)
        print("Catalog updated: \(entry.displayName) \(entry.version) is now live in the storefront.")
    }

    /// `owner/repo` of the current directory's GitHub remote, via `gh`.
    static func currentSourceRepo(environment: Environment = Environment()) throws -> String {
        guard let gh = environment.find("gh") else {
            throw CatalogPublisherError(description: "gh not found on PATH; pass --source-repo owner/repo.")
        }
        let result = try ProcessRunner.run(gh, arguments: ["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"])
        guard result.succeeded, !result.standardOutput.isEmpty else {
            throw CatalogPublisherError(
                description: "Could not resolve the source repo (\(result.standardError)); pass --source-repo owner/repo.")
        }
        return result.standardOutput
    }

    /// The commit being released, so the tag lands on what was built.
    static func headCommit() throws -> String {
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/git"), arguments: ["rev-parse", "HEAD"])
        guard result.succeeded, !result.standardOutput.isEmpty else {
            throw CatalogPublisherError(description: "Could not resolve HEAD (\(result.standardError)).")
        }
        return result.standardOutput
    }

    private static func check(_ tool: URL, _ arguments: [String], in directory: URL? = nil) throws {
        let result = try ProcessRunner.run(tool, arguments: arguments, currentDirectory: directory)
        guard result.succeeded else {
            throw CatalogPublisherError(
                description: "\(tool.lastPathComponent) \(arguments.joined(separator: " ")) failed "
                    + "(exit \(result.exitCode)): \(result.standardError)")
        }
    }

    private static let upsertScript = """
        import json, os, sys

        path = sys.argv[1]
        entry = json.loads(os.environ["ENTRY"])
        app_id, version = entry["appID"], entry["version"]

        original = open(path, encoding="utf-8").read()
        catalog = json.loads(original)

        matches = [a for a in catalog["apps"] if a.get("appID") == app_id]
        if len(matches) > 1:
            sys.exit(f"error: {len(matches)} catalog entries claim appID '{app_id}'")
        if matches:
            current = matches[0]
            previous_api = current.get("apiVersion")
            for key in ("version", "apiVersion", "sha256", "downloadURL"):
                current[key] = entry[key]
            for link in current.get("links", []):
                if link.get("title") == "Release notes":
                    link["url"] = f"https://github.com/{entry['sourceRepo']}/releases/tag/{version}"
            if previous_api != entry["apiVersion"]:
                print(f"note: apiVersion {previous_api} -> {entry['apiVersion']}")
        else:
            catalog["apps"].append(entry)
            print(f"note: new catalog entry '{app_id}'")

        updated = json.dumps(catalog, indent=2, ensure_ascii=False) + "\\n"
        json.loads(updated)
        if len(updated) < len(original) // 2:
            sys.exit("error: rewritten catalog is implausibly small; refusing to write")

        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(updated)
        os.replace(tmp, path)
        """
}
