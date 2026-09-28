import Foundation

/// A shell-out or discovery failure while building an Ainkrad App.
/// `description` includes the failing child process's stderr verbatim so
/// the real compiler/toolchain message reaches the developer.
struct BundleBuilderError: Error, CustomStringConvertible {
    let description: String
}

/// The ONE blessed build path for an Ainkrad App: wraps `xcodegen generate`
/// and `xcodebuild build` with the fixed environment every `ainkrad`
/// developer should use, so nobody has to guess which Xcode or which
/// xcodebuild flags to invoke by hand.
///
/// `xcodegen`/`xcodebuild` are resolved via `PATH` (through `Environment`,
/// not hardcoded paths); the toolchain itself is pinned by setting
/// `DEVELOPER_DIR` to Xcode in the child process environment.
struct BundleBuilder {
    /// The one true toolchain every `ainkrad build` invocation targets.
    private static let developerDirectoryPath = "/Applications/Xcode.app/Contents/Developer"

    private let environment: Environment

    /// Injectable for tests that only need to stub tool lookup; the
    /// integration test in `BundleBuilderTests` uses the real
    /// `Environment()` and the real toolchain.
    init(environment: Environment = Environment()) {
        self.environment = environment
    }

    /// Generates the Xcode project for `projectDir` with XcodeGen, builds
    /// its scheme with xcodebuild against Xcode, and returns the path
    /// to the produced `.bundle`.
    func build(projectDir: URL) throws -> URL {
        guard let xcodegen = environment.find("xcodegen") else {
            throw BundleBuilderError(description: "xcodegen not found on PATH.")
        }
        guard let xcodebuild = environment.find("xcodebuild") else {
            throw BundleBuilderError(description: "xcodebuild not found on PATH.")
        }

        try BundleBuilder.run(xcodegen, arguments: ["generate"], currentDirectory: projectDir)

        // Derive the scheme from the project XcodeGen just generated, rather
        // than assuming it matches any particular field of project.yml.
        let scheme = try BundleBuilder.scheme(in: projectDir, xcodebuild: xcodebuild)

        // Build into a derived data directory scoped to this run so the
        // produced .bundle is easy to locate deterministically, independent
        // of the caller's (or CI's) global DerivedData location.
        let derivedDataPath = projectDir.appendingPathComponent(".ainkrad-build", isDirectory: true)
        try BundleBuilder.run(
            xcodebuild,
            arguments: ["-scheme", scheme, "-derivedDataPath", derivedDataPath.path, "build"],
            currentDirectory: projectDir
        )

        return try BundleBuilder.locateBundle(under: derivedDataPath, scheme: scheme)
    }

    /// Asks xcodebuild for the generated project's schemes and returns the
    /// first one. This queries the project XcodeGen just produced (rather
    /// than re-parsing `project.yml`'s YAML by hand), so it stays correct
    /// even if the scaffold's scheme-naming convention changes.
    private static func scheme(in projectDir: URL, xcodebuild: URL) throws -> String {
        let output = try BundleBuilder.run(xcodebuild, arguments: ["-list", "-json"], currentDirectory: projectDir)

        guard
            let data = output.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let project = json["project"] as? [String: Any],
            let schemes = project["schemes"] as? [String],
            let scheme = schemes.first
        else {
            throw BundleBuilderError(
                description: "Could not determine a scheme from `xcodebuild -list -json` in " +
                    "\(projectDir.path). Output was:\n\(output)"
            )
        }
        return scheme
    }

    /// Recursively finds the built `.bundle`, preferring one whose name
    /// matches `scheme` (the scaffold's convention) but falling back to any
    /// `.bundle` under the build products directory.
    private static func locateBundle(under derivedDataPath: URL, scheme: String) throws -> URL {
        let productsDir = derivedDataPath.appendingPathComponent("Build/Products")
        guard let enumerator = FileManager.default.enumerator(
            at: productsDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            throw BundleBuilderError(
                description: "xcodebuild reported success but no build products directory was found at " +
                    "\(productsDir.path)."
            )
        }

        var bundles: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "bundle" {
            bundles.append(url)
        }

        if let match = bundles.first(where: { $0.deletingPathExtension().lastPathComponent == scheme }) {
            return match
        }
        guard let first = bundles.first else {
            throw BundleBuilderError(
                description: "xcodebuild reported success but no .bundle was found under \(productsDir.path)."
            )
        }
        return first
    }

    /// Runs `executable` with `arguments` in `currentDirectory`, with
    /// `DEVELOPER_DIR` pinned to Xcode in the child environment.
    /// Returns trimmed stdout on success (exit code 0); on failure, throws
    /// with the child's stderr included verbatim so the real
    /// xcodegen/xcodebuild failure reaches the developer.
    ///
    /// Delegates to `ProcessRunner`, which is where this file's temp-file
    /// capture strategy now lives — it was the one call site in the family that
    /// got the pipe-deadlock question right, so it became the shared
    /// implementation rather than staying a local lesson.
    @discardableResult
    private static func run(_ executable: URL, arguments: [String], currentDirectory: URL) throws -> String {
        let result: ProcessRunner.Result
        do {
            result = try ProcessRunner.run(
                executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                environment: ["DEVELOPER_DIR": BundleBuilder.developerDirectoryPath])
        } catch {
            throw BundleBuilderError(
                description: "Failed to launch \(executable.path) \(arguments.joined(separator: " ")): \(error)"
            )
        }
        guard result.succeeded else {
            throw BundleBuilderError(
                description: "\(executable.lastPathComponent) \(arguments.joined(separator: " ")) " +
                    "failed (exit \(result.exitCode)) in \(currentDirectory.path):\n\(result.standardError)"
            )
        }
        return result.standardOutput
    }
}
