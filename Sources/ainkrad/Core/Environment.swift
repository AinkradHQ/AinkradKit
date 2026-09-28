import AinkradAppKit
import Foundation

/// Probes the local toolchain the `ainkrad` CLI depends on: an
/// Xcode developer directory, and external tools such as `xcodegen`
/// and `gh` on `PATH`.
///
/// The real machine probes (`Environment()`) shell out to `xcode-select`
/// and `which`. For deterministic tests, use the injecting initializer to
/// stub tool lookup and Xcode detection without touching the real
/// machine.
struct Environment {
    private let findTool: (String) -> URL?

    /// Whether the selected Xcode developer directory is Xcode.
    let xcodePresent: Bool

    /// The API generation `ainkrad` targets — mirrors `AinkradAppKit.apiVersion`.
    let targetGeneration: Int

    /// Injectable initializer for tests: stub `find` and `xcodePresent`
    /// to report an environment deterministically, without touching the
    /// real filesystem or `PATH`.
    init(
        find: @escaping (String) -> URL?,
        xcodePresent: Bool,
        targetGeneration: Int = AinkradAppKit.apiVersion
    ) {
        self.findTool = find
        self.xcodePresent = xcodePresent
        self.targetGeneration = targetGeneration
    }

    /// The real environment: probes `DEVELOPER_DIR` / `xcode-select -p`
    /// for the selected Xcode, and `which` for external tools on `PATH`.
    init() {
        self.init(
            find: Environment.locate,
            xcodePresent: Environment.detectXcodePresent()
        )
    }

    /// Locates `tool` on `PATH`, or `nil` if it isn't found.
    func find(_ tool: String) -> URL? {
        findTool(tool)
    }

    private static func locate(_ tool: String) -> URL? {
        guard let path = run("/usr/bin/which", arguments: [tool]) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func detectXcodePresent() -> Bool {
        if let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            return developerDir.contains("/Xcode.app")
        }
        guard let selectedPath = run("/usr/bin/xcode-select", arguments: ["-p"]) else {
            return false
        }
        return selectedPath.contains("/Xcode.app")
    }

    /// Runs `executable` with `arguments`, returning trimmed stdout on
    /// success (exit code 0) or `nil` on failure/launch error.
    private static func run(_ executable: String, arguments: [String]) -> String? {
        // `ProcessRunner` rather than raw pipes: this had the same
        // run/wait/read ordering as every other deadlock in the family. The
        // probes here are short-output, so it never hung in practice — which is
        // exactly why it would have been the last one anyone fixed.
        ProcessRunner.output(executable, arguments: arguments)
    }
}
