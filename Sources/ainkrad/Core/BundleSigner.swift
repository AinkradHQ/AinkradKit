import Foundation

/// A failure resolving a signing identity, or signing / verifying a bundle.
struct BundleSignerError: Error, CustomStringConvertible {
    let description: String
}

/// Codesigns a built plugin `.bundle` with hardened runtime, inside-out, then
/// verifies it with `codesign --verify --strict` (decision 19).
///
/// Signed BEFORE packaging, deliberately: the catalog pins the sha256 of the
/// zip, so signing after packaging would ship an unsigned bundle whose checksum
/// still matched. A Developer-ID-signed host rejects unsigned and ad-hoc
/// plugins before `Bundle.load()`, so the release identity must be a
/// `Developer ID Application: …` one; `-` (ad-hoc) is for local tests only.
struct BundleSigner {
    /// The environment variable the identity is read from when no flag is given.
    static let identityVariable = "SIGN_IDENTITY"

    let identity: String

    /// The identity from `flag`, else `SIGN_IDENTITY`. No identity is an
    /// error, never a silent unsigned release.
    static func resolveIdentity(flag: String?, environment: [String: String]) throws -> String {
        if let identity = [flag, environment[identityVariable]].compactMap({ $0 }).first(where: { !$0.isEmpty }) {
            return identity
        }
        throw BundleSignerError(
            description: "No signing identity. Pass --sign-identity <identity> or set \(identityVariable) "
                + "(e.g. \"Developer ID Application: <Team> (<TEAMID>)\"). A Developer-ID host rejects "
                + "unsigned plugins; '-' signs ad-hoc for local testing only.")
    }

    /// Every `codesign` invocation, in order: nested code (deepest first), the
    /// bundle itself, then the strict verify.
    func commands(for bundle: URL) -> [[String]] {
        let sign = ["--force", "--options", "runtime", "--timestamp", "--sign", identity]
        let nested = Self.nestedCode(in: bundle).map { sign + [$0.path] }
        return nested + [sign + [bundle.path], ["--verify", "--strict", "--verbose=2", bundle.path]]
    }

    /// Runs `commands(for:)`; the first failing `codesign` throws with its stderr.
    /// A non-ad-hoc identity must also leave a `Developer ID Application:`
    /// authority on the bundle — any other certificate signs and verifies fine
    /// but is still rejected by a Developer-ID host.
    func sign(_ bundle: URL) throws {
        let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
        for arguments in commands(for: bundle) {
            let result = try ProcessRunner.run(codesign, arguments: arguments)
            guard result.succeeded else {
                throw BundleSignerError(
                    description: "codesign \(arguments.joined(separator: " ")) failed "
                        + "(exit \(result.exitCode)): \(result.standardError)")
            }
        }
        guard identity != "-" else { return }
        let details = try ProcessRunner.run(codesign, arguments: ["-dvv", bundle.path])
        try Self.requireDeveloperID(details.standardError)
    }

    /// Throws unless `codesign -dvv` output names a Developer ID Application authority.
    static func requireDeveloperID(_ codesignDetails: String) throws {
        guard codesignDetails.contains("Authority=Developer ID Application:") else {
            throw BundleSignerError(
                description: "The bundle is signed, but not by a \"Developer ID Application\" certificate; "
                    + "a Developer-ID host would reject it.")
        }
    }

    /// Code-bearing items under `Contents/`, deepest first, so each container is
    /// signed after what it holds. `--deep` is avoided (Apple discourages it).
    private static func nestedCode(in bundle: URL) -> [URL] {
        let contents = bundle.appendingPathComponent("Contents")
        guard let enumerator = FileManager.default.enumerator(at: contents, includingPropertiesForKeys: nil)
        else { return [] }
        let items = enumerator.compactMap { $0 as? URL }
            .filter { ["dylib", "framework", "bundle"].contains($0.pathExtension) }
        return items.sorted { $0.pathComponents.count > $1.pathComponents.count }
    }
}
