// NOTE: `await Ainkrad.main()` is ambiguous on this toolchain (Swift 6.4 /
// swift-argument-parser 1.8.2): overload resolution for the bare `main`
// symbol resolves to `ParsableCommand`'s synchronous `main()` instead of
// `AsyncParsableCommand`'s async one, tripping the library's own
// async/sync-root debug assertion. Calling `asyncParseAsRoot()` + `run()`
// directly (what `AsyncParsableCommand.main()` does internally) sidesteps
// the ambiguity.
import ArgumentParser

do {
    var command = try await Ainkrad.asyncParseAsRoot()
    if var asyncCommand = command as? AsyncParsableCommand {
        try await asyncCommand.run()
    } else {
        try command.run()
    }
} catch {
    Ainkrad.exit(withError: error)
}
