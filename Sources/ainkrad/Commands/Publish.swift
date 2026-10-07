import ArgumentParser
import Foundation

/// `ainkrad publish` — signs a built `.bundle` (hardened runtime, then
/// `codesign --verify --strict`), packages it as `<appID>.bundle.zip`, creates
/// the GitHub Release carrying it, and lists it in AinkradCatalog in the
/// `RemoteCatalogSource` format (decisions 19, 20). `--dry-run` prints the sign
/// plan and the catalog entry and touches neither the bundle nor the network.
///
/// Refuses to package or release a bundle that fails the SAME base
/// validation `ainkrad validate` runs (`Validate.check`), OR the store
/// completeness checks `ainkrad validate --store` runs (`Validate.storeIssues`),
/// so nothing that would fail at install time — or fail store review — ever
/// reaches a release. Enforcing StorePolicy here is what makes the host
/// installer's `author == nil` grandfather clause safe: a new submission can
/// no longer reach the catalog author-less, so a nil author on an installed
/// entry can only mean a genuinely legacy, pre-completeness entry.
struct Publish: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "publish",
        abstract: "Sign a built .bundle, release it on GitHub and list it in AinkradCatalog."
    )

    @Argument(help: "Path to the built .bundle to publish.")
    var bundlePath: String

    @Argument(help: "The release tag (e.g. v1.0.0).")
    var tag: String

    @Flag(help: "Print the sign plan and catalog entry; sign nothing, release nothing, push nothing.")
    var dryRun = false

    @Option(help: "codesign identity (overrides $SIGN_IDENTITY); '-' signs ad-hoc for local testing only.")
    var signIdentity: String?

    @Option(help: "The plugin's GitHub repo, owner/repo (default: `gh repo view` of the current directory).")
    var sourceRepo: String?

    func run() throws {
        let bundleURL = URL(fileURLWithPath: bundlePath)

        do {
            try Validate.check(bundleURL: bundleURL, inspector: BundleInspector())
        } catch {
            printError("Refusing to publish: \(Validate.message(for: error))")
            throw ExitCode(1)
        }

        let storeIssues = try Validate.storeIssues(bundleURL: bundleURL, inspector: BundleInspector())
        if !storeIssues.isEmpty {
            printError("Refusing to publish:")
            for issue in storeIssues {
                printError("\(issue.code): \(issue.message)")
            }
            throw ExitCode(1)
        }

        let signer: BundleSigner
        do {
            signer = BundleSigner(
                identity: try BundleSigner.resolveIdentity(
                    flag: signIdentity, environment: ProcessInfo.processInfo.environment))
        } catch {
            printError("Refusing to publish: \(error)")
            throw ExitCode(1)
        }

        if dryRun {
            let repo = sourceRepo ?? "<owner>/<repo>"
            let (zip, entry) = try ReleasePublisher().package(bundle: bundleURL, tag: tag, sourceRepo: repo)
            print(try Publish.dryRunPlan(signer: signer, bundle: bundleURL, zip: zip, entry: entry))
            return
        }

        try signer.sign(bundleURL)
        let repo = try sourceRepo ?? CatalogPublisher.currentSourceRepo()
        let (zip, entry) = try ReleasePublisher().package(bundle: bundleURL, tag: tag, sourceRepo: repo)
        try ReleasePublisher().release(tag: tag, target: try CatalogPublisher.headCommit(), assets: [zip])
        print("Released \(tag): \(zip.lastPathComponent) (sha256 \(entry.sha256))")
        try CatalogPublisher().push(entry)
    }

    /// What a real run would do, step by step, with the exact `codesign`
    /// arguments and the catalog entry it would push. The dry-run zip is of the
    /// still-unsigned bundle, so its `sha256` changes once the bundle is signed.
    static func dryRunPlan(signer: BundleSigner, bundle: URL, zip: URL, entry: CatalogEntryRecord) throws -> String {
        let sign = signer.commands(for: bundle).map { "  codesign " + $0.map(quoted).joined(separator: " ") }
        return (["Dry run — nothing is signed, released or pushed.", "Sign plan (identity: \(signer.identity)):"]
            + sign
            + [
                "Package: \(zip.lastPathComponent) (dry-run zip of the unsigned bundle)",
                "Release: gh release create \(entry.version) --target <HEAD commit> \(zip.lastPathComponent)",
                "Catalog: upsert into \(CatalogPublisher.catalogRepo) catalog.json (RemoteCatalogSource entry):",
                try entry.json(),
            ]).joined(separator: "\n")
    }

    private static func quoted(_ argument: String) -> String {
        argument.contains(" ") ? "\"\(argument)\"" : argument
    }
}
