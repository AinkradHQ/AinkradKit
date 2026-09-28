import ArgumentParser
import Foundation

/// `ainkrad build` — the ONE blessed build path: wraps XcodeGen + xcodebuild
/// with the correct fixed environment (Xcode via `DEVELOPER_DIR`) so
/// developers never hit "which Xcode / which flag" failures.
///
/// Kept thin: all building logic lives in `BundleBuilder`.
struct Build: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build an Ainkrad App into a loadable .bundle."
    )

    @Argument(help: "Path to the app's project directory. Defaults to the current directory.")
    var projectDir: String?

    func run() throws {
        let directory = URL(fileURLWithPath: projectDir ?? ".")
        let bundle = try BundleBuilder().build(projectDir: directory)
        print("Built \(bundle.path)")
    }
}
