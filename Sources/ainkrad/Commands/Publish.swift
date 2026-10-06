import ArgumentParser
import Foundation

/// `ainkrad publish` — packages a built `.bundle` into the catalog format
/// the real host's `GitHubReleasesCatalogSource` consumes
/// (`<appID>.bundle.zip` + `ainkrad-plugin.json`) and creates the GitHub
/// Release carrying them.
///
/// Refuses to package or release a bundle that fails the SAME base
/// validation `ainkrad validate` runs (`Validate.check`), OR the store
/// completeness checks `ainkrad validate --store` runs (`Validate.storeIssues`),
/// so nothing that would fail at install time — or fail store review — ever
/// reaches a release. Enforcing StorePolicy here is what makes the host
/// installer's `author == nil` grandfather clause safe: a new submission can
/// no longer reach the catalog author-less, so a nil author on an installed
/// entry can only mean a genuinely legacy, pre-completeness entry.
///
/// NOT registered as a root subcommand yet (Task 9's job).
struct Publish: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "publish",
        abstract: "Package a built .bundle and create its GitHub Release."
    )

    @Argument(help: "Path to the built .bundle to publish.")
    var bundlePath: String

    @Argument(help: "The release tag (e.g. v1.0.0).")
    var tag: String

    @Flag(help: "Package the release assets but skip creating the GitHub Release (no network).")
    var dryRun = false

    func run() throws {
        let bundleURL = URL(fileURLWithPath: bundlePath)

        do {
            try Validate.check(bundleURL: bundleURL, inspector: BundleInspector())
        } catch {
            print("Refusing to publish: \(Validate.message(for: error))")
            throw ExitCode(1)
        }

        let storeIssues = try Validate.storeIssues(bundleURL: bundleURL, inspector: BundleInspector())
        if !storeIssues.isEmpty {
            print("Refusing to publish:")
            for issue in storeIssues {
                print("\(issue.code): \(issue.message)")
            }
            throw ExitCode(1)
        }

        let publisher = ReleasePublisher()
        let (zip, manifest) = try publisher.package(bundle: bundleURL)

        if dryRun {
            print(
                "Dry run: packaged \(zip.lastPathComponent) and \(manifest.lastPathComponent). Skipping gh release create."
            )
            return
        }

        try publisher.release(tag: tag, assets: [manifest, zip])
        print("Released \(tag): \(zip.lastPathComponent), \(manifest.lastPathComponent)")
    }
}
