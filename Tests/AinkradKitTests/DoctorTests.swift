import Foundation
import Testing

@testable import ainkrad

@Test func doctorReportsFailingXcodeRowWhenXcodeAbsent() {
    let env = Environment(
        find: { _ in nil },
        xcodePresent: false,
        targetGeneration: 7
    )

    let rows = Doctor.report(env: env)

    #expect(!rows.isEmpty)

    let xcodeRow = rows.first { $0.name == "Xcode" }
    #expect(xcodeRow != nil)
    #expect(xcodeRow?.passed == false)
}

@Test func doctorReportsPassingRowsWhenToolsPresent() {
    let env = Environment(
        find: { tool in URL(fileURLWithPath: "/usr/local/bin/\(tool)") },
        xcodePresent: true,
        targetGeneration: 7
    )

    let rows = Doctor.report(env: env)

    #expect(rows.allSatisfy { $0.passed })
    #expect(rows.contains { $0.name == "Target SDK generation" })
}

@Test func doctorLinesArePlainText() {
    #expect(DoctorRow(name: "gh", passed: true, detail: "/bin/gh").line == "ok   gh: /bin/gh")
    #expect(DoctorRow(name: "gh", passed: false, detail: "missing").line == "FAIL gh: missing")
}
