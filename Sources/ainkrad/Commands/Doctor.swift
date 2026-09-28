import ArgumentParser
import Foundation

/// One row of the `ainkrad doctor` checklist.
struct DoctorRow {
    let name: String
    let passed: Bool
    let detail: String
}

/// Environment probe — verifies the local toolchain the other `ainkrad`
/// subcommands depend on (Xcode, XcodeGen, gh) and reports the CLI's
/// target SDK generation.
struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Verify the local toolchain ainkrad depends on."
    )

    /// Pure reporting function: builds the checklist rows from `env`.
    /// Kept separate from `run()` so tests can exercise it against a stub
    /// `Environment` without touching the real machine.
    static func report(env: Environment) -> [DoctorRow] {
        var rows: [DoctorRow] = []

        rows.append(DoctorRow(
            name: "Xcode",
            passed: env.xcodePresent,
            detail: env.xcodePresent
                ? "Xcode selected"
                : "Xcode not selected (check DEVELOPER_DIR / xcode-select -p)"
        ))

        if let xcodegen = env.find("xcodegen") {
            rows.append(DoctorRow(name: "XcodeGen", passed: true, detail: xcodegen.path))
        } else {
            rows.append(DoctorRow(name: "XcodeGen", passed: false, detail: "xcodegen not found on PATH"))
        }

        if let gh = env.find("gh") {
            rows.append(DoctorRow(name: "gh", passed: true, detail: gh.path))
        } else {
            rows.append(DoctorRow(name: "gh", passed: false, detail: "gh not found on PATH"))
        }

        rows.append(DoctorRow(
            name: "Target SDK generation",
            passed: true,
            detail: "\(env.targetGeneration)"
        ))

        return rows
    }

    func run() throws {
        let rows = Doctor.report(env: Environment())
        for row in rows {
            let symbol = row.passed ? "✅" : "❌"
            print("\(symbol) \(row.name): \(row.detail)")
        }
    }
}
