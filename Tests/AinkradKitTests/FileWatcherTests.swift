import Foundation
import Testing

@testable import ainkrad

/// Real integration test for `FileWatcher`: this is the exact regression
/// the FSEvents rewrite fixes — a non-recursive watch on the project root
/// never sees an edit two levels down (`Sources/Plugin/PluginApp.swift`),
/// which is exactly where a scaffolded Ainkrad app's editable sources live.
///
/// FSEvents delivery is asynchronous with real (if small) latency, so this
/// polls up to a generous timeout rather than sleeping a fixed amount or
/// hanging forever if the fix regresses.
@Test func fileWatcherFiresOnChangeWhenANestedFileIsWritten() async throws {
    let projectDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ainkrad-filewatcher-tests-\(UUID().uuidString)")
    let nestedDir = projectDir.appendingPathComponent("Sources/Plugin")
    try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: projectDir) }

    let nestedFile = nestedDir.appendingPathComponent("PluginApp.swift")
    try "// initial".write(to: nestedFile, atomically: true, encoding: .utf8)

    let watcher = FileWatcher(directory: projectDir)
    defer { watcher.stop() }

    final class FireBox: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func markFired() {
            lock.lock()
            fired = true
            lock.unlock()
        }
        func hasFired() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return fired
        }
    }
    let fireBox = FireBox()
    watcher.onChange = { fireBox.markFired() }

    try watcher.start()

    // Give the stream a moment to actually start delivering before we
    // write, so the write isn't racing stream setup.
    try await Task.sleep(nanoseconds: 200_000_000)

    try "// edited".write(to: nestedFile, atomically: true, encoding: .utf8)

    let deadline = Date().addingTimeInterval(5)
    while !fireBox.hasFired() && Date() < deadline {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    #expect(fireBox.hasFired(), "FileWatcher must fire onChange for a write to a nested file")
}

/// Regression for the `ainkrad dev` infinite-rebuild loop: the build writes
/// the regenerated `.xcodeproj` and DerivedData (`.ainkrad-build`) back into
/// the watched tree, and those writes must never count as a change worth
/// rebuilding for — otherwise every rebuild triggers the next, forever.
@Test func buildArtifactAndVCSPathsAreIgnoredButRealEditsAreNot() {
    // Build / VCS / OS output — must be ignored.
    #expect(FileWatcher.isBuildArtifact("/proj/.ainkrad-build/Build/Products/Debug/App.bundle/Contents/x"))
    #expect(FileWatcher.isBuildArtifact("/proj/App.xcodeproj/project.pbxproj"))
    #expect(FileWatcher.isBuildArtifact("/proj/App.xcworkspace/contents.xcworkspacedata"))
    #expect(FileWatcher.isBuildArtifact("/proj/.git/index"))
    #expect(FileWatcher.isBuildArtifact("/proj/.build/debug/App"))
    #expect(FileWatcher.isBuildArtifact("/proj/DerivedData/App/Build/x"))
    #expect(FileWatcher.isBuildArtifact("/proj/Sources/Plugin/.DS_Store"))

    // Real developer edits — must NOT be ignored.
    #expect(!FileWatcher.isBuildArtifact("/proj/Sources/Plugin/PluginApp.swift"))
    #expect(!FileWatcher.isBuildArtifact("/proj/project.yml"))
    #expect(!FileWatcher.isBuildArtifact("/proj/Info.plist"))
    #expect(!FileWatcher.isBuildArtifact("/proj/Assets/icon.png"))

    // A batch of pure build output collapses to "nothing to do"...
    #expect(
        FileWatcher.onlyBuildArtifactsChanged([
            "/proj/App.xcodeproj/project.pbxproj",
            "/proj/.ainkrad-build/Build/Products/Debug/App.bundle/x",
        ]))
    // ...but a batch mixing a real edit with build output still rebuilds.
    #expect(
        !FileWatcher.onlyBuildArtifactsChanged([
            "/proj/.ainkrad-build/Build/x",
            "/proj/Sources/Plugin/PluginApp.swift",
        ]))
    // An empty batch is nothing to do.
    #expect(FileWatcher.onlyBuildArtifactsChanged([]))
}
