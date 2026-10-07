import AinkradAppKit
import ArgumentParser
import Foundation

/// `ainkrad validate` — runs the EXACT same metadata checks the real host
/// runs against a built `.bundle`, by calling straight into the shared
/// `AinkradAppKit.PluginValidation` module. This is parity by construction:
/// "passes `ainkrad validate`" and "passes install" cannot diverge, because
/// both paths call the same code.
struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate a built .bundle against the host's plugin metadata checks."
    )

    @Argument(help: "Path to the built .bundle to validate.")
    var bundlePath: String

    @Flag(help: "Also run App Store submission checks.")
    var store = false

    func run() throws {
        let bundleURL = URL(fileURLWithPath: bundlePath)

        do {
            try Validate.check(bundleURL: bundleURL, inspector: BundleInspector())
        } catch {
            printError(Validate.message(for: error))
            throw ExitCode(1)
        }

        if store {
            let issues = try Validate.storeIssues(bundleURL: bundleURL, inspector: BundleInspector())
            if issues.isEmpty {
                print("\(bundlePath) passed App Store submission checks.")
            } else {
                for issue in issues {
                    printError("\(issue.code): \(issue.message)")
                }
                throw ExitCode(1)
            }
        } else {
            print("\(bundlePath) is valid.")
        }
    }

    /// The validation-decision seam: reads the bundle's metadata and runs
    /// the shared `PluginValidation.validate` against the CLI's own single
    /// target generation. Kept separate from `run()` so tests can assert on
    /// the thrown error directly, without going through process spawning.
    ///
    /// The CLI validates against its own single target generation — there is
    /// no "min supported" concept for it distinct from `AinkradAppKit.apiVersion`.
    static func check(bundleURL: URL, inspector: BundleInspector) throws {
        let (metadata, infoDictionary) = try inspector.metadata(at: bundleURL)
        switch PluginValidation.validate(
            metadata: metadata,
            infoDictionary: infoDictionary,
            minSupported: AinkradAppKit.apiVersion,
            current: AinkradAppKit.apiVersion
        ) {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    /// The store-validation-decision seam: mirrors `check` but runs the
    /// shared `StorePolicy`, which layers catalog-completeness checks
    /// (author, description, icon) and zip/sha integrity on top of the same
    /// base `PluginValidation` check. Kept separate from `run()` so tests
    /// can assert on the returned issues directly, without process spawning.
    ///
    /// There is no published artifact at validate time — the sha-integrity
    /// check is a transport/publish-time concern this command can't observe
    /// — so `declaredSHA256` and `computedSHA256` are passed the same value
    /// to trivially satisfy that check here rather than inventing a fake
    /// mismatch.
    static func storeIssues(bundleURL: URL, inspector: BundleInspector) throws -> [StoreIssue] {
        let (metadata, infoDictionary) = try inspector.metadata(at: bundleURL)
        let manifest = StoreManifestInput(
            metadata: metadata,
            infoDictionary: infoDictionary,
            author: infoDictionary[PluginInfoKey.author] as? String,
            description: infoDictionary[PluginInfoKey.description] as? String,
            iconSymbol: metadata.iconSymbol,
            declaredSHA256: "",
            computedSHA256: ""
        )
        return StorePolicy.check(
            manifest: manifest,
            minSupported: AinkradAppKit.apiVersion,
            current: AinkradAppKit.apiVersion
        )
    }

    /// Renders a thrown validation-path error to the exact message a
    /// developer should see: the raw failure reason, with no CLI-added
    /// wrapping that could obscure it.
    static func message(for error: Error) -> String {
        switch error {
        case let error as PluginValidationError:
            return error.reason
        case let error as BundleInspectorError:
            return error.description
        default:
            return "\(error)"
        }
    }
}
