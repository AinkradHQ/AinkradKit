import Foundation
import Testing

@testable import ainkrad

/// End-to-end: scaffold a sample app with `TemplateScaffolder` (Task 4),
/// then hand it to `BundleBuilder.build` and confirm it produces a real,
/// on-disk `.bundle`. This is a real `xcodegen generate` + `xcodebuild
/// build`, so it is slow — kept to this single case, with a generous time
/// limit rather than a fast timeout that could false-fail under load.
@Test(
    "BundleBuilder builds a scaffolded app end-to-end and returns its .bundle",
    .enabled(if: buildToolchainAvailable(), "requires Xcode and xcodegen on this machine"),
    .timeLimit(.minutes(10))
)
func buildsScaffoldedAppEndToEnd() throws {
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("ainkrad-bundlebuilder-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: destination) }

    try TemplateScaffolder().scaffold(
        name: "SampleWidget",
        id: "samplewidget",
        displayName: "Sample Widget",
        icon: "star.fill",
        into: destination
    )

    let bundleURL = try BundleBuilder().build(projectDir: destination)

    #expect(bundleURL.pathExtension == "bundle")
    #expect(FileManager.default.fileExists(atPath: bundleURL.path))
}
