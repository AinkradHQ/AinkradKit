import AinkradAppKit
import Foundation
import Testing

@testable import ainkrad

/// Forbidden placeholder tokens from `AinkradPluginTemplate` — none of these
/// may remain anywhere in a scaffolded output tree.
private let forbiddenTokens = [
    "myplugin",
    "MyApp",
    "TemplatePlugin",
    "MyPluginEntryPoint",
    "My Plugin",
    "puzzlepiece.extension",
]

/// Recursively collects every file under `root`.
private func allFiles(under root: URL) -> [URL] {
    guard
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        )
    else { return [] }

    var files: [URL] = []
    for case let url as URL in enumerator {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        if values?.isRegularFile == true {
            files.append(url)
        }
    }
    return files
}

/// Asserts none of `forbiddenTokens` appear in any text file under `root`.
private func assertNoPlaceholderTokensRemain(under root: URL) {
    for file in allFiles(under: root) {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
        for token in forbiddenTokens {
            #expect(
                !contents.contains(token),
                "found leftover placeholder token \"\(token)\" in \(file.lastPathComponent)"
            )
        }
    }
}

private func readInfoPlist(at root: URL) -> [String: Any] {
    let plistURL = root.appendingPathComponent("Sources/Plugin/Info.plist")
    let data = try! Data(contentsOf: plistURL)
    let plist = try! PropertyListSerialization.propertyList(from: data, format: nil)
    return plist as! [String: Any]
}

private func makeTempDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ainkrad-scaffolder-tests-\(UUID().uuidString)")
    return dir
}

@Test func scaffoldsAppWithSubstitutedIdentityAndStampedAPIVersion() throws {
    let destination = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: destination) }

    try TemplateScaffolder().scaffold(
        name: "MyWidget",
        id: "myapp",
        displayName: "My Widget",
        icon: "star.fill",
        into: destination
    )

    let plist = readInfoPlist(at: destination)
    #expect(plist["AinkradAppID"] as? String == "myapp")
    #expect(plist["AinkradDisplayName"] as? String == "My Widget")
    #expect(plist["AinkradIconSymbol"] as? String == "star.fill")
    #expect(plist["AinkradAPIVersion"] as? Int == AinkradAppKit.apiVersion)
    // A deliberate tripwire, not a duplicate of the line above: it fires when
    // the CLI's SDK pin moves, so somebody has to notice that newly
    // scaffolded apps will target a different generation from here on. Update
    // it consciously.
    //
    // Moved 8 → 9 when the pin went to AinkradAppKit 30ccbe6 for M3's
    // SignalWire and socket client. Generation 9 is the current SDK and
    // minSupportedAPIVersion is 8, so a freshly scaffolded app targets 9 and
    // still loads in any host from generation 9 onward.
    // Moved 9 -> 10 with the pin to AinkradAppKit 8944e95. Newly scaffolded
    // apps now target generation 10; minSupportedAPIVersion is 8, so they load
    // in any host from generation 8 onward.
    // Moved 10 -> 11 with the pin to AinkradAppKit c465461 (Basic Mode).
    // minSupportedAPIVersion is 9, so a freshly scaffolded app loads in any
    // host from generation 9 onward -- and, more to the point, it can now
    // conform to `AinkradAppModes`. Left at 10, `ainkrad new` produced an app
    // that could not have a basic mode at all.
    #expect(AinkradAppKit.apiVersion == 11)
    #expect((plist["AinkradAuthor"] as? String)?.isEmpty == false)
    #expect((plist["description"] as? String)?.isEmpty == false)
    #expect(plist["NSPrincipalClass"] as? String == "MyWidgetEntryPoint")
    #expect(plist["CFBundleName"] as? String == "MyWidget")
    #expect(plist["CFBundleExecutable"] as? String == "MyWidget")

    assertNoPlaceholderTokensRemain(under: destination)
}

@Test func scaffoldedSwiftSourcesUseSubstitutedNames() throws {
    let destination = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: destination) }

    try TemplateScaffolder().scaffold(
        name: "MyWidget",
        id: "myapp",
        displayName: "My Widget",
        icon: "star.fill",
        into: destination
    )

    let appSwift = try String(
        contentsOf: destination.appendingPathComponent("Sources/Plugin/PluginApp.swift"),
        encoding: .utf8
    )
    #expect(appSwift.contains("struct MyWidget: AinkradApp"))
    #expect(appSwift.contains("static let id = \"myapp\""))
    #expect(appSwift.contains("static let displayName = \"My Widget\""))
    #expect(appSwift.contains("static let icon = \"star.fill\""))

    let entryPointSwift = try String(
        contentsOf: destination.appendingPathComponent("Sources/Plugin/PluginEntryPoint.swift"),
        encoding: .utf8
    )
    #expect(entryPointSwift.contains("@objc(MyWidgetEntryPoint)"))
    #expect(entryPointSwift.contains("final class MyWidgetEntryPoint"))
    #expect(entryPointSwift.contains("MyWidget.self"))

    let projectYML = try String(
        contentsOf: destination.appendingPathComponent("project.yml"),
        encoding: .utf8
    )
    #expect(projectYML.contains("MyWidget:"))
    #expect(projectYML.contains("PRODUCT_BUNDLE_IDENTIFIER: com.example.plugin.myapp"))

    assertNoPlaceholderTokensRemain(under: destination)
}

/// Regression: `name` is arbitrary caller input and may itself contain a
/// substitution token as a substring (here, "MyApp" inside "MyAppTwo").
/// Sequential whole-string replacement passes would re-scan and mangle the
/// text a prior pass just inserted (producing e.g. "MyAppTwoTwo"); the
/// scaffolder must substitute in a single left-to-right pass so this can't
/// happen.
@Test func nameContainingAnotherTokenAsSubstringIsNotDoubleSubstituted() throws {
    let destination = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: destination) }

    try TemplateScaffolder().scaffold(
        name: "MyAppTwo",
        id: "myapptwo",
        displayName: "My App Two",
        icon: "star.fill",
        into: destination
    )

    let appSwift = try String(
        contentsOf: destination.appendingPathComponent("Sources/Plugin/PluginApp.swift"),
        encoding: .utf8
    )
    #expect(appSwift.contains("struct MyAppTwo: AinkradApp"))
    #expect(!appSwift.contains("MyAppTwoTwo"))

    let plist = readInfoPlist(at: destination)
    #expect(plist["CFBundleName"] as? String == "MyAppTwo")
    #expect(plist["NSPrincipalClass"] as? String == "MyAppTwoEntryPoint")
}

/// Closes the build-artifact footgun: `ainkrad build` drops a derived-data
/// dir (`.ainkrad-build/`) and `ainkrad publish` a `dist/`-style output into
/// the generated project, so every scaffolded app must ship a `.gitignore`
/// covering those (and the template's own `build/`/`.build/` outputs) from
/// day one.
@Test func scaffoldsAGitignoreCoveringBuildArtifacts() throws {
    let destination = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: destination) }

    try TemplateScaffolder().scaffold(
        name: "MyWidget",
        id: "myapp",
        displayName: "My Widget",
        icon: "star.fill",
        into: destination
    )

    let gitignoreURL = destination.appendingPathComponent(".gitignore")
    #expect(FileManager.default.fileExists(atPath: gitignoreURL.path))

    let contents = try String(contentsOf: gitignoreURL, encoding: .utf8)
    for entry in [".build/", "build/", ".ainkrad-build/", "dist/", "*.bundle.zip"] {
        #expect(contents.contains(entry), "expected .gitignore to cover \"\(entry)\"")
    }
}

@Test func rejectsInvalidAppID() {
    let destination = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: destination) }

    #expect(throws: (any Error).self) {
        try TemplateScaffolder().scaffold(
            name: "MyWidget",
            id: "my app",  // space is not in PluginValidation's allowed charset
            displayName: "My Widget",
            icon: "star.fill",
            into: destination
        )
    }
}

/// Edge case: a hyphenated id is a legal `AinkradAppID` even though it is
/// not a legal Swift identifier — `name` and `id` are decoupled.
@Test func scaffoldsWithHyphenatedIDAndUnicodeDisplayName() throws {
    let destination = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: destination) }

    try TemplateScaffolder().scaffold(
        name: "CoffeeApp",
        id: "my-app",
        displayName: "咖啡 Café ☕️",
        icon: "cup.and.saucer.fill",
        into: destination
    )

    let plist = readInfoPlist(at: destination)
    #expect(plist["AinkradAppID"] as? String == "my-app")
    #expect(plist["AinkradDisplayName"] as? String == "咖啡 Café ☕️")
    #expect(plist["AinkradAPIVersion"] as? Int == AinkradAppKit.apiVersion)

    let projectYML = try String(
        contentsOf: destination.appendingPathComponent("project.yml"),
        encoding: .utf8
    )
    #expect(projectYML.contains("PRODUCT_BUNDLE_IDENTIFIER: com.example.plugin.my-app"))

    assertNoPlaceholderTokensRemain(under: destination)
}

/// The tripwire for the scaffolded SDK pin.
///
/// `ainkrad new` writes a project.yml pinning `TemplateScaffolder.sdkRevision`,
/// while the stamped `AinkradAPIVersion` comes from the CLI's own linked SDK.
/// If those two disagree, a new app declares one generation and links another —
/// which is precisely what had happened: the template still carried a
/// generation-8 revision long after the CLI moved on.
@Suite("Scaffolded SDK pin")
struct ScaffoldedSDKPinTests {
    @Test("the scaffolded revision is the one this CLI is built against")
    func pinMatchesPackage() throws {
        // Read from Package.swift rather than a second constant: a constant
        // compared to a constant tests only that someone typed the same thing
        // twice, which is the mistake this is here to catch.
        let packageURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AinkradKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: packageURL, encoding: .utf8)

        let pinned =
            manifest
            .components(separatedBy: "AinkradAppKit")
            .dropFirst()
            .compactMap { chunk -> String? in
                guard let start = chunk.range(of: "revision: \"") else { return nil }
                let rest = chunk[start.upperBound...]
                guard let end = rest.firstIndex(of: "\"") else { return nil }
                return String(rest[..<end])
            }
            .first

        let actual = try #require(pinned, "could not find the AinkradAppKit pin in Package.swift")
        // A new app must not link a different SDK than the tool that made it.
        #expect(
            TemplateScaffolder.sdkRevision == actual,
            "the scaffolded pin does not match the CLI's own SDK pin")
    }

    @Test("the placeholder is not itself the real revision")
    func placeholderIsDistinct() {
        // If these ever became equal the substitution would be a no-op and
        // the drift would return silently.
        #expect(TemplateScaffolder.templateSDKRevision != TemplateScaffolder.sdkRevision)
    }

    @Test("the template carries the placeholder, so the substitution fires")
    func templateCarriesPlaceholder() throws {
        // Pin bumps kept editing the template's revision to the new pin, which
        // left `templateSDKRevision` matching nothing: the substitution became a
        // silent no-op and only the hand edit kept the output right. The two
        // tests above could not see it — they compare constants, not the file.
        let templateURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // AinkradKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Sources/ainkrad/Resources/Template/project.yml")
        let template = try String(contentsOf: templateURL, encoding: .utf8)
        #expect(
            template.contains(TemplateScaffolder.templateSDKRevision),
            "the template's AinkradAppKit revision must be the placeholder")
        #expect(
            !template.contains(TemplateScaffolder.sdkRevision),
            "the template must not carry the real pin — the scaffolder substitutes it")
    }

    @Test("a scaffolded project pins the CLI's own SDK revision")
    func scaffoldedProjectPinsSDKRevision() throws {
        // What the three tests above add up to, checked on the one file that
        // matters: the project.yml `ainkrad new` actually writes.
        let destination = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        try TemplateScaffolder().scaffold(
            name: "PinCheck", id: "pincheck", displayName: "Pin Check",
            icon: "star.fill", into: destination
        )

        let project = try String(
            contentsOf: destination.appendingPathComponent("project.yml"),
            encoding: .utf8)
        #expect(project.contains("revision: \(TemplateScaffolder.sdkRevision)"))
        #expect(!project.contains(TemplateScaffolder.templateSDKRevision))
    }
}

/// Task 2.6: `ainkrad new` produces a plugin that lints and hooks from day
/// one. Scaffolds into a temp dir, asserts the 8 guardrail files exist and
/// are byte-identical to the embedded copies, that every file under
/// `scripts/` (including the pre-push hook) is executable, and that a
/// `git init` + `scripts/design-lint.sh --check` in the scaffold exits 0.
@Test func scaffoldedPluginShipsExecutableGuardrailsThatPassLintCheck() throws {
    let destination = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: destination) }

    try TemplateScaffolder().scaffold(
        name: "MyWidget",
        id: "myapp",
        displayName: "My Widget",
        icon: "star.fill",
        into: destination
    )

    let templateURL = try TemplateScaffolder.embeddedTemplateURL()

    // The 8 synced guardrail files (same set `guardrails-sync.sh`
    // distributes): they must exist and be byte-identical to the embedded
    // copies the scaffolder copied them from.
    let guardrailFiles = [
        "scripts/design-lint.sh",
        "scripts/design-lint-awk.awk",
        "scripts/design-lint-baseline.sh",
        "scripts/design-lint-selftest.sh",
        "scripts/design-lint-selftest-ratchet.sh",
        "scripts/git-hooks/pre-push",
        "scripts/guardrails.mk",
        ".swift-format",
    ]
    for relative in guardrailFiles {
        let scaffoldedURL = destination.appendingPathComponent(relative)
        #expect(
            FileManager.default.fileExists(atPath: scaffoldedURL.path),
            "scaffold is missing guardrail file \(relative)"
        )
        let scaffoldedData = try? Data(contentsOf: scaffoldedURL)
        let embeddedData = try? Data(contentsOf: templateURL.appendingPathComponent(relative))
        #expect(
            scaffoldedData != nil && scaffoldedData == embeddedData,
            "\(relative) differs from the embedded template copy"
        )
    }

    // The scaffolded baseline (all zeros — a fresh plugin has no history to
    // ratchet) and the Makefile lint wiring travel with the same change.
    #expect(
        FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(".design-lint-baseline").path
        )
    )
    let makefile = try String(
        contentsOf: destination.appendingPathComponent("Makefile"), encoding: .utf8
    )
    #expect(makefile.contains("build: lint generate"))
    #expect(makefile.contains("include scripts/guardrails.mk"))

    // Every file under scripts/ (including the hook) must be executable in
    // the scaffold, not just in the repo: SPM `.copy` resources may lose the
    // exec bit on the way into the bundle, in which case `TemplateScaffolder`
    // restores 0755 explicitly.
    let scriptsURL = destination.appendingPathComponent("scripts", isDirectory: true)
    guard
        let enumerator = FileManager.default.enumerator(
            at: scriptsURL, includingPropertiesForKeys: [.isRegularFileKey]
        )
    else {
        Issue.record("could not enumerate scaffolded scripts/")
        return
    }
    var scriptCount = 0
    for case let url as URL in enumerator {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            continue
        }
        scriptCount += 1
        let permissions =
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?
            .uint16Value ?? 0
        #expect(
            permissions & 0o111 == 0o111,
            "\(url.lastPathComponent) is not executable (mode 0\(String(permissions, radix: 8)))"
        )
    }
    #expect(scriptCount == 7)

    // A fresh scaffold must pass the lint gate: `git init` + stage (so the
    // tracked-only `--check` sees the files) + `--check` exits 0.
    let git = URL(fileURLWithPath: "/usr/bin/git")
    let initResult = try ProcessRunner.run(git, arguments: ["init", "-q"], currentDirectory: destination)
    #expect(initResult.succeeded, "git init failed: \(initResult.standardError)")
    let addResult = try ProcessRunner.run(git, arguments: ["add", "-A"], currentDirectory: destination)
    #expect(addResult.succeeded, "git add failed: \(addResult.standardError)")
    let checkResult = try ProcessRunner.run(
        destination.appendingPathComponent("scripts/design-lint.sh"),
        arguments: ["--check"],
        currentDirectory: destination
    )
    #expect(
        checkResult.exitCode == 0,
        "design-lint.sh --check failed:\n\(checkResult.standardOutput)\n\(checkResult.standardError)"
    )
}
