import ArgumentParser

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct Ainkrad: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ainkrad",
        abstract: "Scaffold, build, validate, and publish Ainkrad Apps.",
        // A literal, not stamped at build time, so it said 0.1.0 in every
        // release through v0.2.1. `scripts/release-cli.sh` now refuses to ship
        // unless this matches the tag — bump it in the release commit.
        version: "0.2.2",
        subcommands: [Doctor.self, New.self, Build.self, Validate.self, Dev.self, Publish.self,
                      Notify.self]
    )
}
